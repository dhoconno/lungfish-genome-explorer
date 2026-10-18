// ReferenceBundle+SequenceAccess.swift - Chromosome lookup and sequence fetches for reference bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os
import LungfishCore

/// Logs the lookups and fetches of this file under the subsystem and category `ReferenceBundle` uses.
private let sequenceAccessLogger = Logger(subsystem: "com.lungfish.core", category: "ReferenceBundle")

// MARK: - ReferenceBundleSequenceCache

/// The chromosome name index and the sequence reader of one open ``ReferenceBundle``.
///
/// Each is built once, on first use, and kept for the life of the bundle. A reference with
/// hundreds of thousands of sequences then parses its `.fai` once rather than on every fetch,
/// and finds a name without scanning every record. The two slots sit behind separate locks, so
/// a name lookup never waits behind a `.fai` parse. Each slot is built while its lock is held,
/// so concurrent first callers build it once and the others wait. A reader build that throws is
/// not kept, so a later fetch tries again and throws what a fresh reader throws.
final class ReferenceBundleSequenceCache: Sendable {
    /// The reader of the bundle's genome FASTA.
    enum Reader: Sendable {
        case bgzip(SyncBgzipFASTAReader)
        case plain(IndexedFASTAReader)
    }

    /// First position of each name and of each alias in `genome.chromosomes`.
    struct NameIndex: Sendable {
        let byName: [String: Int]
        let byAlias: [String: Int]

        init(_ chromosomes: [ChromosomeInfo]) {
            var byName: [String: Int] = [:]
            byName.reserveCapacity(chromosomes.count)
            var byAlias: [String: Int] = [:]
            for (position, chromosome) in chromosomes.enumerated() {
                if byName[chromosome.name] == nil { byName[chromosome.name] = position }
                for alias in chromosome.aliases where byAlias[alias] == nil { byAlias[alias] = position }
            }
            self.byName = byName
            self.byAlias = byAlias
        }

        /// The answer of `first(where: { $0.name == name || $0.aliases.contains(name) })`.
        func position(of name: String) -> Int? {
            switch (byName[name], byAlias[name]) {
            case let (named?, aliased?): return min(named, aliased)
            case let (named?, nil): return named
            case let (nil, aliased?): return aliased
            case (nil, nil): return nil
            }
        }
    }

    private struct NameState: Sendable {
        var index: NameIndex?
        var fallbackAnswers: [String: Int?] = [:]
        var indexBuilds = 0
        var fallbackRuns = 0

        mutating func buildIndexIfNeeded(_ chromosomes: [ChromosomeInfo]) {
            guard index == nil else { return }
            index = NameIndex(chromosomes)
            indexBuilds += 1
        }
    }

    private struct ReaderState: Sendable {
        var reader: Reader?
        var builds = 0
    }

    /// Bounds the remembered fallback answers, since every unknown name a caller asks for adds one.
    private static let fallbackAnswerLimit = 1_024
    private let names = OSAllocatedUnfairLock(initialState: NameState())
    private let readers = OSAllocatedUnfairLock(initialState: ReaderState())

    /// The position in `chromosomes` of the record `ReferenceBundle.chromosome(named:)` returns for `name`.
    ///
    /// `chromosomes` is the bundle's `genome.chromosomes`, the same array on every call, since the
    /// manifest of a bundle never changes.
    func position(of name: String, in chromosomes: [ChromosomeInfo]) -> Int? {
        let known: Int?? = names.withLock { state in
            state.buildIndexIfNeeded(chromosomes)
            if let position = state.index?.position(of: name) { return .some(position) }
            return state.fallbackAnswers[name]
        }
        if let known { return known }
        // The fallback scans every record several times (17 s for a missing SILVA name), so it runs outside the lock.
        let mappedName = mapVCFChromosomes([name], toBundleChromosomes: chromosomes)[name]
        return names.withLock { state in
            let answer = mappedName.flatMap { state.index?.byName[$0] }
            if state.fallbackAnswers.count < Self.fallbackAnswerLimit { state.fallbackAnswers[name] = answer }
            state.fallbackRuns += 1
            return answer
        }
    }

    /// Builds the name index now, unless a lookup has built it already.
    func prepareNameIndex(for chromosomes: [ChromosomeInfo]) {
        names.withLock { $0.buildIndexIfNeeded(chromosomes) }
    }

    /// The reader of the bundle's genome, built by the first call and kept for the later ones.
    func reader(for bundle: ReferenceBundle, path: String, indexPath: String, gzipIndexPath: String?) throws -> Reader {
        try readers.withLock { state in
            if let reader = state.reader { return reader }
            let genomeURL = try bundle.memberURL(for: path, field: "genome.path")
            let faiURL = try bundle.memberURL(for: indexPath, field: "genome.indexPath")
            let reader: Reader
            if let gzipIndexPath {
                let gziURL = try bundle.memberURL(for: gzipIndexPath, field: "genome.gzipIndexPath")
                reader = .bgzip(try SyncBgzipFASTAReader(url: genomeURL, faiURL: faiURL, gziURL: gziURL))
            } else {
                reader = .plain(try IndexedFASTAReader(url: genomeURL, indexURL: faiURL))
            }
            state.reader = reader
            state.builds += 1
            return reader
        }
    }

    // Counting seams for the tests.
    var nameIndexBuildCount: Int { names.withLock { $0.indexBuilds } }
    var fallbackRunCount: Int { names.withLock { $0.fallbackRuns } }
    var readerBuildCount: Int { readers.withLock { $0.builds } }
}

// MARK: - Chromosome Lookup

extension ReferenceBundle {

    /// Returns information about a specific chromosome.
    ///
    /// - Parameter name: Chromosome name (e.g., "chr1")
    /// - Returns: Chromosome information, or nil if not found
    public func chromosome(named name: String) -> ChromosomeInfo? {
        guard let chromosomes = manifest.genome?.chromosomes else { return nil }
        return sequenceCache.position(of: name, in: chromosomes).map { chromosomes[$0] }
    }

    /// Returns the length of a chromosome.
    ///
    /// - Parameter name: Chromosome name
    /// - Returns: Length in base pairs, or nil if chromosome not found
    public func chromosomeLength(named name: String) -> Int64? {
        chromosome(named: name)?.length
    }

    /// Name of the first chromosome in the bundle, read without copying every name as ``chromosomeNames`` does.
    public var firstChromosomeName: String? {
        manifest.genome?.chromosomes.first?.name
    }

    /// Builds the chromosome name index and the sequence reader now, rather than at the first lookup and fetch.
    ///
    /// For a reference with hundreds of thousands of sequences this parses the whole `.fai`, so call
    /// it off the main actor. A bundle without a genome has nothing to build.
    ///
    /// - Throws: The error the first fetch would throw when the genome files cannot be opened.
    public func prepareSequenceAccess() throws {
        guard let genome = manifest.genome else { return }
        sequenceCache.prepareNameIndex(for: genome.chromosomes)
        _ = try sequenceCache.reader(
            for: self, path: genome.path, indexPath: genome.indexPath, gzipIndexPath: genome.gzipIndexPath
        )
    }

    // MARK: - Sequence Access

    /// Fetches sequence data for a genomic region.
    ///
    /// Uses the indexed bgzip-compressed FASTA for efficient random access.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` if the sequence cannot be fetched
    public func fetchSequence(region: GenomicRegion) async throws -> String {
        try readSequence(region: region, caller: "fetchSequence")
    }

    /// Synchronously fetches sequence data for a genomic region.
    ///
    /// This version reads the FASTA file directly without async, useful when
    /// Swift Tasks are not executing properly in the app context.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` if the sequence cannot be fetched
    public func fetchSequenceSync(region: GenomicRegion) throws -> String {
        try readSequence(region: region, caller: "fetchSequenceSync")
    }

    /// The body of both fetches. It makes the checks in the order both fetches always made them,
    /// then reads through the one reader the bundle keeps.
    private func readSequence(region: GenomicRegion, caller: String) throws -> String {
        sequenceAccessLogger.info("\(caller, privacy: .public): START \(region.description)")

        // A variant-only bundle has no sequence data.
        guard let genome = manifest.genome else {
            return ""
        }

        guard let chromInfo = chromosome(named: region.chromosome) else {
            sequenceAccessLogger.error("\(caller, privacy: .public): Chromosome '\(region.chromosome)' not found in manifest")
            throw ReferenceBundleError.chromosomeNotFound(region.chromosome)
        }

        guard region.start >= 0 && region.end <= chromInfo.length else {
            sequenceAccessLogger.log(
                level: FASTAOutOfBoundsLog.level(start: region.start, end: region.end, length: Int(chromInfo.length)),
                "\(caller, privacy: .public): Region out of bounds: end=\(region.end) > length=\(chromInfo.length)"
            )
            throw ReferenceBundleError.regionOutOfBounds(region, chromInfo.length)
        }
        let fetchRegion = canonicalRegion(region, for: chromInfo)

        let reader = try sequenceCache.reader(
            for: self, path: genome.path, indexPath: genome.indexPath, gzipIndexPath: genome.gzipIndexPath
        )
        switch reader {
        case .bgzip(let bgzipReader):
            let sequence = try bgzipReader.fetchSync(region: fetchRegion)
            sequenceAccessLogger.info("\(caller, privacy: .public): DONE (bgzip) \(fetchRegion.chromosome):\(fetchRegion.start)-\(fetchRegion.end) -> \(sequence.count) bp")
            return sequence
        case .plain(let plainReader):
            let sequence = try plainReader.fetchSync(region: fetchRegion)
            sequenceAccessLogger.info("\(caller, privacy: .public): DONE (uncompressed) \(fetchRegion.chromosome):\(fetchRegion.start)-\(fetchRegion.end) -> \(sequence.count) bp")
            return sequence
        }
    }

    /// The region renamed to the record's own name, so an alias or a versioned name reads the FASTA record.
    private func canonicalRegion(_ region: GenomicRegion, for chromosome: ChromosomeInfo) -> GenomicRegion {
        guard region.chromosome != chromosome.name else { return region }
        return GenomicRegion(chromosome: chromosome.name, start: region.start, end: region.end)
    }
}
