// TaxonomyExtractionPipeline+Sources.swift - A taxon's reads from every read file of a Kraken2 result, pairs first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension TaxonomyExtractionPipeline {

    /// One taxon's reads from every file of `files`, one output per file in
    /// order (``extractEachSource(config:tree:matePairStarts:progress:)``).
    /// Each R1 file and the R2 file after it are read in step, as kraken2
    /// read them, and every other file with seqkit grep. `config` gives the
    /// taxa, the classification output, and the folder and base name of the
    /// outputs. Its source files are `files`.
    func extractEachFile(
        config: TaxonomyExtractionConfig,
        files: [KrakenResultReadSources.File],
        tree: TaxonTree,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (outputs: [URL?], taxIds: Set<Int>, readCount: Int) {
        for (index, file) in files.enumerated() where file.role == .r1 {
            guard index + 1 < files.count, files[index + 1].role == .r2 else {
                throw ClassifierExtractionError.kraken2SourceMissing
            }
        }
        let matePairStarts = files.indices.filter { files[$0].role == .r1 }
        return try await extractEachSource(
            config: TaxonomyExtractionConfig(
                taxIds: config.taxIds,
                includeChildren: config.includeChildren,
                sourceFiles: files.map(\.url),
                outputFiles: files.indices.map { _ in config.outputFile },
                classificationOutput: config.classificationOutput,
                taxonomyReport: config.taxonomyReport,
                keepReadPairs: config.keepReadPairs
            ),
            tree: tree,
            matePairStarts: matePairStarts,
            progress: progress
        )
    }

    /// Writes a taxon's reads, extracted file by file from `files`
    /// (``extractEachFile(config:files:tree:progress:)``): the pairs of each
    /// R1 and R2 file, each R1 record followed by its R2 record, to `pairs`,
    /// then the reads of every other file, in file order and unchanged, to
    /// `reads` (D7d). One handle may be both, since every pair of files comes
    /// before the other files. Returns the number of pairs.
    static func writeExtractedReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        pairs: FileHandle,
        reads: FileHandle
    ) throws -> Int {
        var pairCount = 0
        for (index, file) in files.enumerated() {
            switch file.role {
            case .r1:
                guard let output = outputs[index] else { continue }
                pairCount += try copyRecords(of: output, into: pairs) / 2
            case .r2:
                continue
            case .adjacentMates, .reads:
                guard let output = outputs[index] else { continue }
                _ = try copyRecords(of: output, into: reads)
            }
        }
        return pairCount
    }

    /// Copies `file` into `handle` unchanged and returns its record count.
    private static func copyRecords(of file: URL, into handle: FileHandle) throws -> Int {
        let reader = try FASTQRawLineReader(url: file)
        defer { reader.close() }
        var lines = 0
        while let chunk = try reader.readChunk() {
            lines += chunk.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            try handle.write(contentsOf: chunk)
        }
        return lines / 4
    }

    /// How an extracted FASTQ pairs (D7d), counted over the whole file by
    /// the layout scan's pairing rule: interleaved when it holds only pairs,
    /// single-end with roles in the form a merge recipe records when it mixes
    /// pairs with single reads, and single-end when it holds no pair.
    static func extractedLayout(
        of fastqURL: URL,
        singleReadRole: ReadClassification.FileRole
    ) throws -> (mode: IngestionMetadata.PairingMode, roles: ReadClassification?) {
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: fastqURL)
        guard counts.pairs > 0 else { return (.singleEnd, nil) }
        guard counts.singles > 0 else { return (.interleaved, nil) }
        let roles = FASTQMixedLayoutHint.classification(
            pairs: counts.pairs,
            singles: counts.singles,
            singleRole: singleReadRole,
            filename: fastqURL.lastPathComponent
        )
        return (.singleEnd, roles)
    }

    /// One taxon's reads from every file of `files` in one gzip FASTQ, the
    /// file a one-file extraction writes for `config.outputFile`: each pair's
    /// R1 record followed by its R2 record, then the reads of every other
    /// file (D7d, D7e). A mix of pairs and single reads records its roles
    /// beside it. The provenance counts the records of that one file.
    func extractIntoOneFile(
        config: TaxonomyExtractionConfig,
        files: [KrakenResultReadSources.File],
        scratch: URL,
        tree: TaxonTree,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        let runClock = ProvenanceRunClock()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let baseName = config.outputFile.deletingPathExtension().lastPathComponent
        let perFile = TaxonomyExtractionConfig(
            taxIds: config.taxIds,
            includeChildren: config.includeChildren,
            sourceFiles: files.map(\.url),
            outputFiles: files.indices.map { scratch.appendingPathComponent("\(baseName)_R\($0 + 1).fastq") },
            classificationOutput: config.classificationOutput,
            taxonomyReport: config.taxonomyReport,
            keepReadPairs: config.keepReadPairs
        )
        let extraction = try await extractEachFile(config: perFile, files: files, tree: tree, progress: progress)

        let plain = scratch.appendingPathComponent("\(baseName).fastq")
        fileManager.createFile(atPath: plain.path, contents: nil)
        let handle = try FileHandle(forWritingTo: plain)
        do {
            _ = try Self.writeExtractedReads(extraction.outputs, of: files, pairs: handle, reads: handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let output = config.outputFile.deletingLastPathComponent()
            .appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(baseName)).fastq.gz")
        try KrakenOutputCompactor.gzipCopy(source: plain, destination: output)
        if files.contains(where: { $0.role != .reads }),
           let roles = try Self.extractedLayout(of: plain, singleReadRole: KrakenResultReadSources.singleReadFileRole(of: files)).roles {
            FASTQMixedLayoutHint.write(
                ReadClassification(files: roles.files.map { .init(filename: output.lastPathComponent, role: $0.role, readCount: $0.readCount) }),
                beside: output
            )
        }

        let records = try FASTQPairInterleaver.countRecords(in: plain)
        try await recordProvenance(
            config: TaxonomyExtractionConfig(
                taxIds: config.taxIds,
                includeChildren: config.includeChildren,
                sourceFiles: files.map(\.url),
                outputFiles: [output],
                classificationOutput: config.classificationOutput,
                taxonomyReport: config.taxonomyReport,
                keepReadPairs: config.keepReadPairs
            ),
            resolvedTaxIds: extraction.taxIds,
            outputURLs: [output],
            extractedCount: records,
            runtime: runClock.elapsed,
            commandPrefix: ["LungfishWorkflow", "extract-taxon-reads"]
        )
        return output
    }
}

extension KrakenResultReadSources {

    /// The role a mix of these files' pairs and single reads records for its
    /// single reads: merged when any file holds merged reads, else unpaired.
    static func singleReadFileRole(of files: [File]) -> ReadClassification.FileRole {
        files.contains { $0.singleReadRole == .merged || $0.singleReadRole == .mergedOrOrphan } ? .merged : .unpaired
    }
}
