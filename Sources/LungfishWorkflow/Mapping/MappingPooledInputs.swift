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
