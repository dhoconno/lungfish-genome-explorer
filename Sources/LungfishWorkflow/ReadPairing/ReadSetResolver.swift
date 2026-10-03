// ReadSetResolver.swift - The one place that decides how a sample's reads are paired
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract this implements.

import Foundation
import LungfishIO

/// Turns the input a user chose into a ``ReadSetPlan``: the sample's mate
/// pairs and single reads, in the form one tool's ``ReadPairingCapability``
/// takes.
///
/// How each bundle layout is read:
/// - A root file is scanned (``FASTQInputLayoutResolver``). With no mates it
///   gives single reads, with every record followed by its mate it gives one
///   interleaved mate pair, and with both it gives a mixed stream. A `full`
///   derivative is read the same way, so a re-imported `fastq merge` output
///   whose sidecar records the L3 classification is a mixed stream.
/// - A chunked root (`source-files.json`) gives each chunk as single reads,
///   unless it holds exactly two files named as mates and records a
///   short-read platform. A root whose recorded platform is Oxford Nanopore
///   or PacBio is never paired at all. A root holding only `preview.fastq`
///   throws, because the preview is a subset of the sample.
/// - A `fullPaired` derivative gives its R1 and R2 as one mate pair.
/// - A `fullMixed` derivative gives its roles: R1 and R2 files as a mate
///   pair, merged files as merged reads, unpaired files as orphans. A role
///   file that is missing throws, so no read is silently left out.
/// - A virtual derivative is materialized, read whole once (a truncated
///   file throws) and its one file scanned, with the
///   merge evidence of every bundle it derives from as hints, so a subset of
///   a merge or repair derivative is never read as strict pairs.
///
/// A tool that takes pairs and single reads as separate files gets a mixed
/// stream split by fragment name. A tool that takes one stream gets
/// separate pairs and single reads interleaved by name. Both writes are
/// recorded as ``ReadSetStep``s. A sample that holds only single reads or
/// only pairs is handed over as it is found, with no step.
public struct ReadSetResolver: Sendable {
    /// Where materialized, split and interleaved files are written. Created
    /// when first needed.
    public let materializationDirectory: URL
    public let materializer: any CLISequenceInputMaterializing & Sendable
    /// Whether to count the records of every file whose count the bundle
    /// does not record.
    public let countReads: Bool

    public init(
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: .shared),
        countReads: Bool = false
    ) {
        self.materializationDirectory = materializationDirectory.standardizedFileURL
        self.materializer = materializer
        self.countReads = countReads
    }

    /// The plan for one input, a `.lungfishfastq` bundle, a file inside one
    /// or a loose FASTQ or FASTA file. Every file this call wrote is removed
    /// when it throws.
    public func plan(
        for inputURL: URL,
        capability: ReadPairingCapability,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ReadSetPlan {
        let written = WrittenFiles()
        do {
            try Task.checkCancellation()
            var source = try await inspect(inputURL.standardizedFileURL, written: written, progress: progress)
            if countReads { source = try source.counted() }
            return try deliver(source, inputURL: inputURL, capability: capability, written: written)
        } catch {
            written.removeAll()
            throw error
        }
    }

    /// One plan per input, each input its own sample.
    public func plans(
        for inputURLs: [URL],
        capability: ReadPairingCapability,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [ReadSetPlan] {
        var plans: [ReadSetPlan] = []
        for inputURL in inputURLs {
            plans.append(try await plan(for: inputURL, capability: capability, progress: progress))
        }
        return plans
    }

    /// The plan for loose files the user named by role: an R1 and R2 file
    /// whose records correspond by position, and files of single reads.
    public func plan(
        r1: URL,
        r2: URL,
        singleReads: [URL] = [],
        singleReadRole: ReadSetReadRole = .mergedOrOrphan,
        capability: ReadPairingCapability
    ) throws -> ReadSetPlan {
        let written = WrittenFiles()
        do {
            var parts: [ReadSetSource.Part] = [.pair(ReadSetMatePair(files: .separate(r1: r1, r2: r2)))]
            parts += singleReads.map { .single(ReadSetSingleReads(url: $0, role: singleReadRole)) }
            var source = ReadSetSource(
                parts: parts,
                layout: singleReads.isEmpty ? .pairedFiles : .pairedFilesWithSingleReads,
                reason: singleReads.isEmpty
                    ? "The R1 and R2 files were named as one mate pair."
                    : "The R1 and R2 files were named as one mate pair, with \(singleReads.count) file(s) of single reads.",
                platform: nil,
                wasMaterialized: false
            )
            if countReads { source = try source.counted() }
            return try deliver(source, inputURL: r1, capability: capability, written: written)
        } catch {
            written.removeAll()
            throw error
        }
    }

    // MARK: - Inspection

    func inspect(
        _ inputURL: URL,
        written: WrittenFiles,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> ReadSetSource {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) else {
            return try inspectFile(inputURL, platform: nil, hints: nil, roleEvidence: nil, wasMaterialized: false)
        }
        let platform = Self.recordedPlatform(of: bundleURL)
        let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL)
        switch manifest?.payload {
        case .fullFASTA:
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL) else {
                throw ReadSetResolverError.noReads(path: bundleURL.path)
            }
            return try inspectFile(fastaURL, platform: platform, hints: nil, roleEvidence: nil, wasMaterialized: false)
        case .fullPaired:
            guard let pair = FASTQBundle.pairedFASTQURLs(forDerivedBundle: bundleURL) else {
                throw ReadSetResolverError.noReads(path: bundleURL.path)
            }
            try Self.requireFiles([pair.r1, pair.r2], in: bundleURL)
            if Self.isLongRead(platform) {
                return Self.longReadSource([pair.r1, pair.r2], platform: platform)
            }
            return ReadSetSource(
                parts: [.pair(ReadSetMatePair(files: .separate(r1: pair.r1, r2: pair.r2)))],
                layout: .pairedFiles,
                reason: "The paired derivative names its R1 and R2 files.",
                platform: platform,
                wasMaterialized: false
            )
        case .fullMixed(let classification):
            return try inspectClassifiedFiles(classification, in: bundleURL, platform: platform)
        case .full:
            guard let fileURL = FASTQBundle.fullPayloadFASTQURL(forDerivedBundle: bundleURL) else {
                throw ReadSetResolverError.noReads(path: bundleURL.path)
            }
            try Self.requireFiles([fileURL], in: bundleURL)
            return try inspectFile(fileURL, platform: platform, hints: nil, roleEvidence: nil, wasMaterialized: false)
        case .some:
            return try await inspectVirtual(bundleURL, platform: platform, written: written, progress: progress)
        case nil:
            return try inspectRoot(bundleURL, platform: platform)
        }
    }

    private func inspectRoot(_ bundleURL: URL, platform: SequencingPlatform?) throws -> ReadSetSource {
        if let readManifest = ReadManifest.load(from: bundleURL),
           Set(readManifest.classification.files.map(\.filename)).count > 1 {
            return try inspectClassifiedFiles(readManifest.classification, in: bundleURL, platform: platform)
        }
        let files: [URL]
        let isChunked = FASTQBundle.isMultiFileBundle(bundleURL)
        if isChunked {
            guard let members = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !members.isEmpty else {
                throw ReadSetResolverError.noReads(path: bundleURL.path)
            }
            try Self.requireFiles(members, in: bundleURL)
            files = members.map(\.standardizedFileURL)
        } else {
            files = Self.physicalFASTQFiles(in: bundleURL)
        }
        guard !files.isEmpty else { throw ReadSetResolverError.noReads(path: bundleURL.path) }
        if Self.isLongRead(platform) {
            return Self.longReadSource(files, platform: platform)
        }
        // A chunked root pairs by file name only when a short-read platform
        // is recorded (an unrecognised import records `unknown`). A legacy
        // root holding two files keeps the file-name rule.
        let mayPairByName = !isChunked || Self.isKnownShortRead(platform)
        if mayPairByName, let pair = MatePairFileNaming.matePair(in: files, sequencingPlatform: platform) {
            return ReadSetSource(
                parts: [.pair(ReadSetMatePair(files: .separate(r1: pair.r1, r2: pair.r2)))],
                layout: .pairedFiles,
                reason: "The bundle's two files are named as R1 and R2 of one sample.",
                platform: platform,
                wasMaterialized: false
            )
        }
        if files.count == 1, !isChunked {
            return try inspectFile(files[0], platform: platform, hints: nil, roleEvidence: nil, wasMaterialized: false)
        }
        return ReadSetSource(
            parts: files.map { .single(ReadSetSingleReads(url: $0, role: .singleEnd)) },
            layout: .multiFileRoot,
            reason: "The bundle holds \(files.count) files, each read as single reads.",
            platform: platform,
            wasMaterialized: false
        )
    }

    /// A merge or repair derivative's files by role.
    private func inspectClassifiedFiles(
        _ classification: ReadClassification,
        in bundleURL: URL,
        platform: SequencingPlatform?
    ) throws -> ReadSetSource {
        func url(_ entry: ReadClassification.FileEntry) throws -> URL {
            try FASTQBundle.validatedBundleMemberURL(
                for: entry.filename,
                in: bundleURL,
                field: "readClassification.files[].filename"
            ).standardizedFileURL
        }
        let distinctFiles = Set(classification.files.map(\.filename))
        if distinctFiles.count == 1, let entry = classification.files.first {
            // Every role names one file: the L3 form, kinds of records inside it.
            let fileURL = try url(entry)
            try Self.requireFiles([fileURL], in: bundleURL)
            return try inspectFile(fileURL, platform: platform, hints: nil, roleEvidence: classification, wasMaterialized: false)
        }
        let r1Entries = classification.files.filter { $0.role == .pairedR1 }
        let r2Entries = classification.files.filter { $0.role == .pairedR2 }
        guard r1Entries.count == r2Entries.count else {
            throw ReadSetResolverError.unmatchedMateFiles(
                bundlePath: bundleURL.path,
                r1Files: r1Entries.count,
                r2Files: r2Entries.count
            )
        }
        var parts: [ReadSetSource.Part] = []
        for (r1Entry, r2Entry) in zip(r1Entries, r2Entries) {
            let r1 = try url(r1Entry)
            let r2 = try url(r2Entry)
            try Self.requireFiles([r1, r2], in: bundleURL)
            parts.append(.pair(ReadSetMatePair(files: .separate(r1: r1, r2: r2), pairCount: r1Entry.readCount)))
        }
        for entry in classification.files where entry.role == .merged || entry.role == .unpaired {
            let fileURL = try url(entry)
            try Self.requireFiles([fileURL], in: bundleURL)
            parts.append(.single(ReadSetSingleReads(
                url: fileURL,
                role: entry.role == .merged ? .merged : .orphan,
                readCount: entry.readCount
            )))
        }
        if Self.isLongRead(platform) {
            return Self.longReadSource(parts.flatMap(\.urls), platform: platform)
        }
        let holdsPairs = !r1Entries.isEmpty
        let holdsSingles = parts.count > r1Entries.count
        return ReadSetSource(
            parts: parts,
            layout: holdsPairs && holdsSingles ? .mixedDerivative : (holdsPairs ? .pairedFiles : .multiFileRoot),
            reason: "The derivative records its files by role (\(classification.compositionLabel)).",
            platform: platform,
            wasMaterialized: false
        )
    }

    /// A virtual derivative, materialized into one file and scanned with the
    /// merge evidence of every bundle it derives from.
    private func inspectVirtual(
        _ bundleURL: URL,
        platform: SequencingPlatform?,
        written: WrittenFiles,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> ReadSetSource {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: materializationDirectory.path) {
            try fileManager.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
            written.addDirectory(materializationDirectory)
        }
        progress?("Materializing \(bundleURL.lastPathComponent)...")
        let before = Set((try? fileManager.contentsOfDirectory(atPath: materializationDirectory.path)) ?? [])
        let materialized: URL
        do {
            materialized = try await materializer.materialize(
                bundleURL: bundleURL,
                tempDirectory: materializationDirectory,
                progress: progress
            ).standardizedFileURL
        } catch {
            let after = (try? fileManager.contentsOfDirectory(atPath: materializationDirectory.path)) ?? []
            for entry in after where !before.contains(entry) {
                try? fileManager.removeItem(at: materializationDirectory.appendingPathComponent(entry))
            }
            throw error
        }
        written.add(materialized)
        let lineage = Self.lineageEvidence(of: bundleURL)
        var hints = FASTQReadLayoutClassifier.metadataHints(for: bundleURL)
        if let evidence = lineage.evidence, !hints.hasMergedOrUnpairedReads {
            hints.hasMergedOrUnpairedReads = true
            hints.mergeEvidence = evidence
        }
        return try inspectFile(
            materialized,
            platform: platform,
            hints: hints,
            roleEvidence: lineage.classification,
            wasMaterialized: true
        )
    }

    /// One file, scanned for its layout. `hints` replaces the metadata the
    /// file's own bundle gives, for a file materialized away from it.
    /// `roleEvidence` says what the reads without a mate are.
    private func inspectFile(
        _ fileURL: URL,
        platform: SequencingPlatform?,
        hints: FASTQPairingMetadataHints?,
        roleEvidence: ReadClassification?,
        wasMaterialized: Bool
    ) throws -> ReadSetSource {
        let file = fileURL.standardizedFileURL
        if SequenceFormat.from(url: file) == .fasta {
            return ReadSetSource(
                parts: [.single(ReadSetSingleReads(url: file, role: .singleEnd))],
                layout: .fasta,
                reason: "The input is FASTA, read as single records.",
                platform: platform,
                wasMaterialized: wasMaterialized
            )
        }
        // A materialized file was written for this run, so it is read whole
        // once. A truncated or unreadable file stops the plan, and the
        // by-name counts are exact.
        let materializedCounts = wasMaterialized ? try FASTQPairInterleaver.countMixed(interleaved: file) : nil
        if Self.isLongRead(platform) {
            var source = Self.longReadSource([file], platform: platform)
            source.wasMaterialized = wasMaterialized
            return source
        }
        let resolution: FASTQInputLayoutResolution
        if let hints {
            let scan = try FASTQReadLayoutClassifier.readHeaders(from: file)
            let classification = FASTQReadLayoutClassifier.classify(
                headers: scan.headers,
                scannedWholeFile: scan.scannedWholeFile,
                metadata: hints
            )
            resolution = FASTQInputLayoutResolution(
                layout: FASTQInputLayout(readLayout: classification.layout),
                source: .contentScan,
                classification: classification,
                reason: classification.reason
            )
        } else {
            resolution = FASTQInputLayoutResolver.resolve(inputURLs: [file])
        }
        // The scan reads a bounded number of records. The whole-file count
        // of a materialization outranks it, so pairs followed by single reads
        // past the scan limit (the D2 shape) are mixed, never strict pairs.
        var layout = resolution.layout
        var layoutReason = resolution.reason
        if let counts = materializedCounts, counts.pairs > 0, counts.unpaired > 0, layout != .mixedMergedAndPairs {
            layout = .mixedMergedAndPairs
            layoutReason = "The whole file holds \(counts.pairs) adjacent mate pairs and \(counts.unpaired) reads without a mate, so it mixes pairs and single reads. \(resolution.reason)"
        }
        // A classification in the L3 form, every role naming this file,
        // records the counts of its kinds of records.
        let ownClassification = wasMaterialized ? nil : Self.singleFileClassification(of: file)
        let evidence = roleEvidence ?? ownClassification
        switch layout {
        case .strictlyInterleaved:
            return ReadSetSource(
                parts: [.pair(ReadSetMatePair(
                    files: .interleaved(file),
                    pairCount: materializedCounts?.pairs ?? ownClassification.map { $0.pairedReadCount / 2 }
                ))],
                layout: .interleavedFile,
                reason: layoutReason,
                platform: platform,
                wasMaterialized: wasMaterialized
            )
        case .mixedMergedAndPairs:
            return ReadSetSource(
                parts: [.mixed(ReadSetMixedStream(
                    url: file,
                    pairCount: materializedCounts?.pairs ?? ownClassification.map { $0.pairedReadCount / 2 },
                    singleReadCount: materializedCounts?.unpaired
                        ?? ownClassification.map { $0.mergedReadCount + $0.unpairedReadCount },
                    singleReadRole: Self.singleReadRole(from: evidence)
                ))],
                layout: .mixedFile,
                reason: layoutReason,
                platform: platform,
                wasMaterialized: wasMaterialized
            )
        case .singleEnd, .pairedFiles:
            return ReadSetSource(
                parts: [.single(ReadSetSingleReads(
                    url: file,
                    role: .singleEnd,
                    readCount: materializedCounts.map { $0.pairs * 2 + $0.unpaired }
                ))],
                layout: .singleEndFile,
                reason: layoutReason,
                platform: platform,
                wasMaterialized: wasMaterialized
            )
        }
    }
}

/// Files a resolver call wrote, removed when the call fails. One call owns
/// it and never shares it with another task.
final class WrittenFiles {
    private var files: [URL] = []
    private var directories: [URL] = []

    func add(_ url: URL) {
        files.append(url)
    }

    func addDirectory(_ url: URL) {
        directories.append(url)
    }

    func removeAll() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        for url in directories.reversed() { try? FileManager.default.removeItem(at: url) }
    }
}

public enum ReadSetResolverError: LocalizedError, Sendable, Equatable {
    case noReads(path: String)
    case missingFile(bundlePath: String, filePath: String)
    case unmatchedMateFiles(bundlePath: String, r1Files: Int, r2Files: Int)
    case mateNameMismatch(r1Path: String, r2Path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .noReads(let path):
            return "No reads could be found for \(path)."
        case .missingFile(let bundlePath, let filePath):
            return "The bundle \(bundlePath) records a reads file that is missing: \(filePath). No read is left out silently, so the run stops."
        case .unmatchedMateFiles(let bundlePath, let r1Files, let r2Files):
            return "The bundle \(bundlePath) records \(r1Files) R1 file(s) and \(r2Files) R2 file(s), so its pairs cannot be matched."
        case .mateNameMismatch(let r1Path, let r2Path, let detail):
            return "The R1 and R2 files do not hold the same fragments in the same order (\(r1Path), \(r2Path)): \(detail)"
        }
    }
}
