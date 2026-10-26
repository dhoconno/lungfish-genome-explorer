// MappingPooledInputs.swift - The one FASTQ a pooled mapping run reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane MAPPOOL (MAP-POOLED, obs-13, BIO-C2 fix 1, SWIFT 4 and 5,
// ARCH). Several inputs that are not bound as R1 and R2 are pooled as single
// reads (docs/contracts/READ-PAIRING.md). Handed to the mappers as one file
// each, BBMap read only the first, bwa-mem2 read two files as mates and
// stopped on its name check, and minimap2 refused three and skipped the
// surplus records of the longer of two. The resolver joins them here, so every
// mapper reads one stream, the argv holds one path and the record is true.
//
// Phase 3.0 lane MAP (MAP-POOLED-PAIRS, BIO-C2 Q2). The pool is planned input
// by input first (pairedPool). Inputs of single reads still join as above.
// Inputs of pairs join so every input keeps its pairs, and a pool that mixes
// pairs and single reads, long and short reads, or interleaved inputs and
// inputs of R1 and R2 files stops before any join.

import Foundation
import LungfishCore
import LungfishIO

enum MappingPooledInputsError: LocalizedError, Sendable, Equatable {
    /// gzip members and plain members cannot be joined into one stream. The
    /// names are those of the chosen inputs, a bundle by its folder name and a
    /// loose file by its file name.
    case mixedCompression(compressed: [String], uncompressed: [String])

    var errorDescription: String? {
        switch self {
        case .mixedCompression(let compressed, let uncompressed):
            return "These inputs mix compressed and uncompressed FASTQ files, so they cannot be pooled into one file. "
                + "Compressed inputs are \(compressed.joined(separator: ", ")). "
                + "Uncompressed inputs are \(uncompressed.joined(separator: ", ")). "
                + "Choose inputs that are all compressed or all uncompressed, or map the bundles one by one."
        }
    }
}

enum MappingPooledInputs {
    /// `resolved` with its execution files written, in input order, into one
    /// new FASTQ in `directory`, the run's input folder. The file is named
    /// `pooled-<UUID>` so it never collides with the `concatenated-<UUID>` join
    /// of one bundle, it carries a ``SequenceInputConcatenation`` sidecar so
    /// the record shows the join as a `cat` step with every member as an input,
    /// and it is published through ``DurableReplace`` from a stage file, so a
    /// reader never finds a partial file under the final name.
    ///
    /// The join streams through ``ReadFileWriters`` in chunks and stops before
    /// each member and each chunk when the task is cancelled. A join that
    /// throws, a cancel among them, removes the file, its sidecar and the
    /// folder when the join created it. The join computes no hash. The step
    /// that records it hashes the file.
    ///
    /// Gzip members form a multi-member gzip stream, which every mapper reads as
    /// one file. A plain member that does not end in a line break gets one
    /// before a member that starts a record (ReadFileWriters.append), so its
    /// last record and the next member's first stay apart. The one input that
    /// results names the first input as its origin and every member as its
    /// source. The caller keeps every chosen input in the request's lineage.
    ///
    /// - Throws: ``MappingPooledInputsError/mixedCompression(compressed:uncompressed:)``
    ///   for members of both kinds, before anything is written.
    static func join(_ resolved: ResolvedSequenceInputs, into directory: URL) throws -> ResolvedSequenceInputs {
        let members = resolved.executionInputURLs
        guard members.count > 1, let first = resolved.inputs.first else { return resolved }
        let compression = Set(members.map { $0.pathExtension.lowercased() == "gz" })
        guard compression.count == 1, let gzipped = compression.first else {
            func isCompressed(_ input: ResolvedSequenceInputs.Input) -> Bool {
                input.executionURLs.contains { $0.pathExtension.lowercased() == "gz" }
            }
            throw MappingPooledInputsError.mixedCompression(
                compressed: resolved.inputs.filter(isCompressed).map { $0.originalURL.lastPathComponent },
                uncompressed: resolved.inputs.filter { !isCompressed($0) }.map { $0.originalURL.lastPathComponent }
            )
        }
        let fileManager = FileManager.default
        let folderExisted = fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputName = "pooled-\(UUID().uuidString).\(gzipped ? "fastq.gz" : "fastq")"
        // One origin per member, so the record names the bundle that made each file.
        let memberBundles = resolved.inputs.flatMap { input in input.executionURLs.map { _ in input.originalURL } }
        let concatenation = SequenceInputConcatenation(
            bundleURL: first.originalURL,
            memberURLs: members,
            outputURL: directory.appendingPathComponent(outputName),
            memberBundleURLs: memberBundles.count == members.count ? memberBundles : nil
        )
        let began = Date()
        do {
            try DurableReplace.transaction {
                try concatenation.save()
                try ReadFileWriters.publish(concatenation.outputURL) { stage in
                    var lastByte: UInt8?
                    for member in members {
                        try Task.checkCancellation()
                        lastByte = try ReadFileWriters.append(
                            member,
                            to: stage,
                            after: lastByte,
                            checkingCancellation: true
                        ) ?? lastByte
                    }
                }
            }
        } catch {
            concatenation.removeOutput()
            if !folderExisted { try? fileManager.removeItem(at: directory) }
            throw error
        }
        return ResolvedSequenceInputs(
            inputs: [ResolvedSequenceInputs.Input(
                originalURL: first.originalURL,
                executionURLs: [concatenation.outputURL],
                wasMaterialized: true,
                concatenatedFrom: members
            )],
            materializationStartedAt: resolved.materializationStartedAt ?? began,
            materializationEndedAt: Date()
        )
    }
}

/// A pool whose inputs all hold read pairs, joined so that every input keeps
/// its pairs (Phase 3.0 lane MAP, MAP-POOLED-PAIRS, BIO-C2 Q2).
struct MappingPooledPairs: Sendable {
    /// One input that names the first chosen input as its origin, with the
    /// pooled interleaved file, or the pooled R1 file and the pooled R2 file.
    let resolved: ResolvedSequenceInputs
    let layoutResolution: FASTQInputLayoutResolution
    /// Whether the pool is an R1 file and an R2 file bound as mates.
    let pairedEnd: Bool
}

extension MappingPooledInputs {
    /// The platforms whose reads are short reads (READ-PAIRING.md, L4).
    static let shortReadPlatforms: Set<SequencingPlatform> = [.illumina, .element, .ultima, .mgi]

    /// Plans every input of a pool on its own with ``ReadSetResolver`` and
    /// decides the pool from what each holds. The plan writes no split, so a
    /// pool that stops leaves nothing behind but a virtual bundle's
    /// materialization, which the single-read pool reuses.
    ///
    /// Inputs that all hold pairs pool into one interleaved file, A's pairs
    /// then B's, when each holds one interleaved file, and into one R1 file
    /// and one R2 file in the same input order when each holds an R1 and an
    /// R2 file. Every join is a recorded `cat` step, as for single reads.
    ///
    /// - Parameter pairsMates: whether the run maps mates as pairs at all. A
    ///   long-read preset maps every record on its own, so its pool is single
    ///   reads whatever the inputs hold, and only the platform rule applies.
    /// - Returns: nil when every input holds single reads or the run never
    ///   pairs, so the caller pools the files as single reads.
    /// - Throws: ``MappingInputResolverError`` before any join, for a pool of
    ///   Oxford Nanopore or PacBio inputs beside short-read inputs, of inputs of
    ///   pairs beside inputs of single reads, or of interleaved inputs beside
    ///   inputs of R1 and R2 files.
    static func pairedPool(
        _ inputURLs: [URL],
        pairsMates: Bool,
        resolver: ReadSetResolver,
        into directory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> MappingPooledPairs? {
        var plans: [(input: URL, plan: ReadSetPlan)] = []
        for inputURL in inputURLs {
            try Task.checkCancellation()
            let plan = try await resolver.plan(for: inputURL, capability: .pairsOnlyWhenAllPaired, progress: progress)
            plans.append((inputURL.standardizedFileURL, plan))
        }
        func names(_ selected: [(input: URL, plan: ReadSetPlan)]) -> [String] {
            selected.map { $0.input.lastPathComponent }
        }

        let longReads = plans.filter { FASTQLongReadRule.isLongRead($0.plan.sequencingPlatform) }
        let shortReads = plans.filter { $0.plan.sequencingPlatform.map(shortReadPlatforms.contains) ?? false }
        if !longReads.isEmpty, !shortReads.isEmpty {
            throw MappingInputResolverError.poolMixesLongAndShortReads(longReads: names(longReads), shortReads: names(shortReads))
        }
        guard pairsMates else { return nil }

        let mixed = plans.filter { $0.plan.sampleHoldsPairsAndSingleReads }
        let paired = plans.filter { !$0.plan.sampleHoldsPairsAndSingleReads && !$0.plan.matePairs.isEmpty }
        let single = plans.filter { !$0.plan.sampleHoldsPairsAndSingleReads && $0.plan.matePairs.isEmpty }
        if paired.isEmpty, mixed.isEmpty { return nil }
        guard mixed.isEmpty, single.isEmpty else {
            throw MappingInputResolverError.poolMixesPairsAndSingleReads(
                pairs: names(paired),
                singleReads: names(single),
                pairsAndSingleReads: names(mixed)
            )
        }

        var interleaved: [ResolvedSequenceInputs.Input] = []
        var r1Files: [ResolvedSequenceInputs.Input] = []
        var r2Files: [ResolvedSequenceInputs.Input] = []
        for (input, plan) in plans {
            for pair in plan.matePairs {
                switch pair.files {
                case .interleaved(let url):
                    interleaved.append(.init(originalURL: input, executionURLs: [url], wasMaterialized: plan.wasMaterialized))
                case .separate(let r1, let r2):
                    r1Files.append(.init(originalURL: input, executionURLs: [r1], wasMaterialized: plan.wasMaterialized))
                    r2Files.append(.init(originalURL: input, executionURLs: [r2], wasMaterialized: plan.wasMaterialized))
                }
            }
        }
        guard interleaved.isEmpty || r1Files.isEmpty else {
            throw MappingInputResolverError.poolMixesMateFileForms(
                interleaved: uniqueNames(interleaved),
                mateFiles: uniqueNames(r1Files)
            )
        }
        func joined(_ inputs: [ResolvedSequenceInputs.Input]) throws -> ResolvedSequenceInputs {
            try join(ResolvedSequenceInputs(inputs: inputs, materializationStartedAt: nil, materializationEndedAt: nil), into: directory)
        }

        if !interleaved.isEmpty {
            return MappingPooledPairs(
                resolved: try joined(interleaved),
                layoutResolution: FASTQInputLayoutResolution(
                    layout: .strictlyInterleaved,
                    source: .pooledFiles,
                    reason: "\(plans.count) inputs of interleaved pairs are pooled into one interleaved file, and each keeps its pairs."
                ),
                pairedEnd: false
            )
        }
        let pooledR1 = try joined(r1Files)
        let pooledR2: ResolvedSequenceInputs
        do {
            pooledR2 = try joined(r2Files)
        } catch {
            for url in pooledR1.executionInputURLs { SequenceInputConcatenation.load(for: url)?.removeOutput() }
            throw error
        }
        return MappingPooledPairs(
            resolved: ResolvedSequenceInputs(
                inputs: [ResolvedSequenceInputs.Input(
                    originalURL: plans[0].input,
                    executionURLs: pooledR1.executionInputURLs + pooledR2.executionInputURLs,
                    wasMaterialized: true,
                    isMatePair: true,
                    concatenatedFrom: pooledR1.inputs.flatMap(\.concatenatedFrom) + pooledR2.inputs.flatMap(\.concatenatedFrom)
                )],
                materializationStartedAt: pooledR1.materializationStartedAt,
                materializationEndedAt: pooledR2.materializationEndedAt
            ),
            layoutResolution: FASTQInputLayoutResolution(
                layout: .pairedFiles,
                source: .pooledFiles,
                reason: "\(plans.count) inputs of R1 and R2 files are pooled into one R1 file and one R2 file, and each keeps its pairs."
            ),
            pairedEnd: true
        )
    }

    /// The names of the chosen inputs of `inputs`, each once, in input order.
    private static func uniqueNames(_ inputs: [ResolvedSequenceInputs.Input]) -> [String] {
        var seen = Set<String>()
        return inputs.map(\.originalURL.lastPathComponent).filter { seen.insert($0).inserted }
    }
}

extension MappingRunRequest {
    /// This request with `originalInputFASTQURLs` replaced. A pool joins its
    /// inputs into one execution file, and ``withInputLineage(_:)`` names one
    /// original per execution file, so the resolver sets every chosen input here.
    /// The recorded command and the input records then name every bundle the
    /// run read.
    func withOriginalInputFASTQURLs(_ originalInputFASTQURLs: [URL]) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: modeID,
            inputFASTQURLs: inputFASTQURLs,
            originalInputFASTQURLs: originalInputFASTQURLs,
            inputMaterializationStartedAt: inputMaterializationStartedAt,
            inputMaterializationEndedAt: inputMaterializationEndedAt,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: sourceReferenceBundleURL,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            readGroup: readGroup,
            pairedEnd: pairedEnd,
            threads: threads,
            includeSecondary: includeSecondary,
            includeSupplementary: includeSupplementary,
            minimumMappingQuality: minimumMappingQuality,
            advancedArguments: advancedArguments,
            compatibilityReadClassOverride: compatibilityReadClassOverride,
            inputLayout: inputLayout,
            outputTrackName: outputTrackName,
            readSetLayout: readSetLayout
        )
    }
}
