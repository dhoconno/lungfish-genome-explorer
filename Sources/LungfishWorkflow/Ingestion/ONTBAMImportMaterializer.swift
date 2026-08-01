// ONTBAMImportMaterializer.swift — Temporary BAM-to-FASTQ materialization for ONT imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct ONTBAMMaterialization: Sendable {
    public let processingPair: SamplePair
    public let provenanceSteps: [StepExecution]

    public init(processingPair: SamplePair, provenanceSteps: [StepExecution]) {
        self.processingPair = processingPair
        self.provenanceSteps = provenanceSteps
    }
}

public enum ONTBAMImportError: Error, LocalizedError, Sendable {
    case requiresONT(String)
    case requiresSingleBAM(String)
    case conversionFailed(String)
    case compressionFailed(String)
    case emptyOutput(String)

    public var errorDescription: String? {
        switch self {
        case .requiresONT(let filename):
            return "BAM read input \(filename) is supported only for Oxford Nanopore imports."
        case .requiresSingleBAM(let sample):
            return "BAM read input for \(sample) must be a single file, not an R1/R2 pair."
        case .conversionFailed(let detail):
            return "Could not convert the ONT BAM to FASTQ: \(detail)"
        case .compressionFailed(let detail):
            return "Could not compress the temporary FASTQ: \(detail)"
        case .emptyOutput(let filename):
            return "Converting \(filename) produced an empty FASTQ."
        }
    }
}

public enum ONTBAMImportMaterializer {
    public static let primaryReadFlagFilter = 0x900

    public static func materializeIfNeeded(
        pair: SamplePair,
        platform: SequencingPlatform,
        workspace: URL,
        threads: Int = 1,
        runner: NativeToolRunner = .shared
    ) async throws -> ONTBAMMaterialization {
        let r1IsBAM = SequencingReadImportSource.isBAM(pair.r1)
        let r2IsBAM = pair.r2.map(SequencingReadImportSource.isBAM) ?? false
        guard r1IsBAM || r2IsBAM else {
            return ONTBAMMaterialization(processingPair: pair, provenanceSteps: [])
        }
        guard r1IsBAM, pair.r2 == nil else {
            throw ONTBAMImportError.requiresSingleBAM(pair.sampleName)
        }
        guard platform == .ont else {
            throw ONTBAMImportError.requiresONT(pair.r1.lastPathComponent)
        }

        let fastqURL = workspace.appendingPathComponent("\(pair.sampleName)-from-bam.fastq")
        let compressedURL = workspace.appendingPathComponent("\(pair.sampleName)-from-bam.fastq.gz")
        let bamToFASTQArguments = [
            "fastq", "-F", String(primaryReadFlagFilter), pair.r1.path,
        ]
        let conversionStartedAt = Date()
        let conversion = try await runner.runWithFileOutput(
            .samtools,
            arguments: bamToFASTQArguments,
            outputFile: fastqURL
        )
        let conversionEndedAt = Date()
        guard conversion.isSuccess else {
            throw ONTBAMImportError.conversionFailed(conversion.stderr)
        }
        guard fileSize(of: fastqURL) > 0 else {
            throw ONTBAMImportError.emptyOutput(pair.r1.lastPathComponent)
        }

        let conversionStep = StepExecution(
            toolName: "samtools",
            toolVersion: await runner.getToolVersion(.samtools) ?? "unknown",
            command: conversion.arguments.isEmpty ? ["samtools"] + bamToFASTQArguments : conversion.arguments,
            durableReplayArgv: shellReplayArguments(
                executable: "samtools",
                arguments: bamToFASTQArguments,
                output: fastqURL
            ),
            inputs: [ProvenanceRecorder.fileRecord(url: pair.r1, format: .bam, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: fastqURL, format: .fastq, role: .output)],
            exitCode: conversion.exitCode,
            wallTime: conversionEndedAt.timeIntervalSince(conversionStartedAt),
            stderr: conversion.stderr.nilIfEmpty,
            startTime: conversionStartedAt,
            endTime: conversionEndedAt
        )

        let compressionArguments = ["-p", String(max(1, threads)), "-c", fastqURL.path]
        let compressionStartedAt = Date()
        let compression = try await runner.runWithFileOutput(
            .pigz,
            arguments: compressionArguments,
            outputFile: compressedURL
        )
        let compressionEndedAt = Date()
        guard compression.isSuccess else {
            throw ONTBAMImportError.compressionFailed(compression.stderr)
        }
        guard fileSize(of: compressedURL) > 0 else {
            throw ONTBAMImportError.emptyOutput(pair.r1.lastPathComponent)
        }

        let compressionStep = StepExecution(
            toolName: "pigz",
            toolVersion: await runner.getToolVersion(.pigz) ?? "unknown",
            command: compression.arguments.isEmpty ? ["pigz"] + compressionArguments : compression.arguments,
            durableReplayArgv: shellReplayArguments(
                executable: "pigz",
                arguments: compressionArguments,
                output: compressedURL
            ),
            inputs: [ProvenanceRecorder.fileRecord(url: fastqURL, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: compressedURL, format: .fastq, role: .output)],
            exitCode: compression.exitCode,
            wallTime: compressionEndedAt.timeIntervalSince(compressionStartedAt),
            stderr: compression.stderr.nilIfEmpty,
            dependsOn: [conversionStep.id],
            startTime: compressionStartedAt,
            endTime: compressionEndedAt
        )

        let processingPair = SamplePair(
            sampleName: pair.sampleName,
            r1: compressedURL,
            r2: nil,
            relativePath: pair.relativePath,
            metadata: pair.metadata,
            sampleSheetURL: pair.sampleSheetURL
        )
        return ONTBAMMaterialization(
            processingPair: processingPair,
            provenanceSteps: [conversionStep, compressionStep]
        )
    }

    private static func fileSize(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func shellReplayArguments(
        executable: String,
        arguments: [String],
        output: URL
    ) -> [String] {
        let invocation = ([executable] + arguments).map(shellEscape).joined(separator: " ")
        return ["/bin/sh", "-c", "\(invocation) > \(shellEscape(output.path))"]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
