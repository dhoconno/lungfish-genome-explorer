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
    /// gzip members and plain members cannot be joined into one stream.
    case mixedCompression

    var errorDescription: String? {
        switch self {
        case .mixedCompression:
            return "The inputs mix compressed and uncompressed FASTQ files, which cannot be pooled into one file. "
                + "Map them one by one, or pool inputs that are all compressed or all plain."
        }
    }
}

enum MappingPooledInputs {
    /// The most bytes of a member held in memory at once while joining.
    private static let joinChunkSize = 4 * 1024 * 1024

    /// `resolved` with its execution files written, in input order, into one
    /// new FASTQ in `directory`, the run's input folder. The file is named
    /// `pooled-<UUID>` so it never collides with the `concatenated-<UUID>` join
    /// of one bundle, it carries a ``SequenceInputConcatenation`` sidecar so
    /// the record shows the join as a `cat` step with every member as an input,
    /// and it is published through ``DurableReplace`` from a stage file, so a
    /// reader never finds a partial file under the final name.
    ///
    /// The join streams in chunks of at most ``joinChunkSize`` and stops between
    /// chunks when the task is cancelled. A join that throws, a cancel among
    /// them, removes the file, its sidecar and the folder when the join created
    /// it. The join computes no hash. The step that records it hashes the file.
    ///
    /// Gzip members form a multi-member gzip stream, which every mapper reads as
    /// one file. A plain member that does not end in a newline gets one, so its
    /// last record and the next member's first stay apart. The one input that
    /// results names the first input as its origin and every member as its
    /// source. The caller keeps every chosen input in the request's lineage.
    ///
    /// - Throws: ``MappingPooledInputsError/mixedCompression`` for members of both
    ///   kinds, before anything is written.
    static func join(_ resolved: ResolvedSequenceInputs, into directory: URL) throws -> ResolvedSequenceInputs {
        let members = resolved.executionInputURLs
        guard members.count > 1, let first = resolved.inputs.first else { return resolved }
        let compression = Set(members.map { $0.pathExtension.lowercased() == "gz" })
        guard compression.count == 1, let gzipped = compression.first else {
            throw MappingPooledInputsError.mixedCompression
        }
        let fileManager = FileManager.default
        let folderExisted = fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputName = "pooled-\(UUID().uuidString).\(gzipped ? "fastq.gz" : "fastq")"
        let concatenation = SequenceInputConcatenation(
            bundleURL: first.originalURL,
            memberURLs: members,
            outputURL: directory.appendingPathComponent(outputName)
        )
        let began = Date()
        do {
            try DurableReplace.transaction {
                try concatenation.save()
                try DurableReplace.replace(named: outputName, in: directory, recovery: .none) { stage in
                    for member in members {
                        try append(member, to: stage, endingWithLineBreak: !gzipped)
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

    /// Streams `member` into `stage`, checking for a cancel before every chunk.
    private static func append(
        _ member: URL,
        to stage: DurableReplace.StageWriter,
        endingWithLineBreak: Bool
    ) throws {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: member)
        defer { try? input.close() }
        var lastByte: UInt8?
        while let chunk = try input.read(upToCount: joinChunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try stage.write(chunk)
            lastByte = chunk.last
        }
        if endingWithLineBreak, let lastByte, lastByte != UInt8(ascii: "\n") {
            try stage.write(Data([UInt8(ascii: "\n")]))
        }
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
