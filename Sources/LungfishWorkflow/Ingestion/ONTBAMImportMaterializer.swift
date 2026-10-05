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
    case pacBioBAMUnsupported(String)
    case requiresSingleBAM(String)
    case collationFailed(String)
    case conversionFailed(String)
    case compressionFailed(String)
    case emptyOutput(String)

    public var errorDescription: String? {
        switch self {
        case .pacBioBAMUnsupported(let filename):
            return "PacBio BAM import is not supported yet. Convert \(filename) with samtools fastq and import the FASTQ."
        case .requiresSingleBAM(let sample):
            return "BAM read input for \(sample) must be a single file, not an R1/R2 pair."
        case .collationFailed(let detail):
            return "Could not bring the mates of the BAM together with samtools collate: \(detail)"
        case .conversionFailed(let detail):
            return "Could not convert the BAM to FASTQ: \(detail)"
        case .compressionFailed(let detail):
            return "Could not compress the temporary FASTQ: \(detail)"
        case .emptyOutput(let filename):
            return "Converting \(filename) produced an empty FASTQ."
        }
    }
}

public enum ONTBAMImportMaterializer {
    public static let primaryReadFlagFilter = 0x900
    /// The SAM flag of a read from a paired run.
    static let pairedReadFlag = 0x1

    /// Refuses only PacBio BAM (its kinetics and per-read tags need their own
    /// conversion, owner ruling 4). Every other BAM converts with
    /// `samtools fastq`, whatever its platform. A paired BAM converts to
    /// interleaved /1 and /2 records, which `--pairing auto` records as
    /// interleaved mates. A paired BAM that is not grouped by read name is
    /// collated first (``needsCollation(bamURL:)``).
    public static func checkPlatform(_ platform: SequencingPlatform, for pair: SamplePair) throws {
        if platform == .pacbio {
            throw ONTBAMImportError.pacBioBAMUnsupported(pair.r1.lastPathComponent)
        }
    }

    public static func materializeIfNeeded(
        pair: SamplePair,
        platform: IngestionPlatform,
        workspace: URL,
        threads: Int = 1,
        runner: NativeToolRunner = .shared
    ) async throws -> ONTBAMMaterialization {
        try await materializeIfNeeded(
            pair: pair, platform: platform.sequencingPlatform, workspace: workspace,
            threads: threads, runner: runner
        )
    }

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
        try checkPlatform(platform, for: pair)

        let collation = needsCollation(bamURL: pair.r1)
            ? try await collate(pair: pair, workspace: workspace, threads: threads, runner: runner)
            : nil
        let conversionInput = collation?.output ?? pair.r1
        let fastqURL = workspace.appendingPathComponent("\(pair.sampleName)-from-bam.fastq")
        let compressedURL = workspace.appendingPathComponent("\(pair.sampleName)-from-bam.fastq.gz")
        let bamToFASTQArguments = [
            "fastq", "-F", String(primaryReadFlagFilter), conversionInput.path,
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
            inputs: [ProvenanceRecorder.fileRecord(url: conversionInput, format: .bam, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: fastqURL, format: .fastq, role: .output)],
            exitCode: conversion.exitCode,
            wallTime: conversionEndedAt.timeIntervalSince(conversionStartedAt),
            stderr: conversion.stderr.nilIfEmpty,
            dependsOn: collation.map { [$0.step.id] } ?? [],
            startTime: conversionStartedAt,
            endTime: conversionEndedAt
        )
        // The collated copy is scratch. A failed run leaves it to the
        // caller's workspace, which is removed with the import.
        if let collation {
            try? FileManager.default.removeItem(at: collation.output)
        }

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
            provenanceSteps: (collation.map { [$0.step] } ?? []) + [conversionStep, compressionStep]
        )
    }

    // MARK: - Mates that are not adjacent

    /// Whether the mates of a BAM must be brought together before
    /// `samtools fastq`, which writes a pair as adjacent /1 and /2 records only
    /// when its two records are adjacent in the BAM.
    ///
    /// A BAM whose `@HD` line says it is grouped by read name (`SO:queryname`
    /// or `GO:query`) holds its mates together. Any other order, including a
    /// missing `SO`, which the SAM specification reads as unsorted, may keep
    /// them apart, as coordinate sorting does. Only a BAM whose first primary
    /// records carry the paired flag is collated, so an unpaired BAM, such as
    /// dorado output, converts exactly as before. The header and records are
    /// read natively from the start of the BGZF stream.
    static func needsCollation(bamURL: URL) -> Bool {
        var window = 4 << 20
        while true {
            guard let data = GzipPrefixDecoder.decodedPrefix(of: bamURL, maxBytes: window) else { return false }
            if let decided = needsCollation(decodedBAMPrefix: data) { return decided }
            // The window ended before the first primary record. Read further,
            // up to 64 MiB, then convert as before.
            guard data.count >= window, window < 64 << 20 else { return false }
            window *= 4
        }
    }

    /// The decision for the decoded start of a BAM, or nil when the data ends
    /// before the first complete primary record.
    static func needsCollation(decodedBAMPrefix data: Data) -> Bool? {
        let bytes = [UInt8](data)
        func int32(at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Int(Int32(bitPattern: value))
        }
        guard bytes.count >= 8, bytes[0] == 0x42, bytes[1] == 0x41, bytes[2] == 0x4D, bytes[3] == 0x01,
              let textLength = int32(at: 4), textLength >= 0 else { return false }
        guard 8 + textLength <= bytes.count else { return nil }
        if isGroupedByReadName(samHeader: String(decoding: bytes[8..<(8 + textLength)], as: UTF8.self)) {
            return false
        }
        var offset = 8 + textLength
        guard let referenceCount = int32(at: offset), referenceCount >= 0 else { return nil }
        offset += 4
        for _ in 0..<referenceCount {
            guard let nameLength = int32(at: offset), nameLength >= 0 else { return nil }
            offset += 8 + nameLength
        }
        // Each record is its length, then refID, pos, l_read_name, mapq, bin
        // and n_cigar_op, then the flag 14 bytes in.
        var sawPrimaryRecord = false
        while let blockSize = int32(at: offset), blockSize >= 32, offset + 4 + blockSize <= bytes.count {
            let flag = Int(bytes[offset + 18]) | Int(bytes[offset + 19]) << 8
            if flag & primaryReadFlagFilter == 0 {
                if flag & pairedReadFlag != 0 { return true }
                sawPrimaryRecord = true
            }
            offset += 4 + blockSize
        }
        return sawPrimaryRecord ? false : nil
    }

    /// Whether the `@HD` line of SAM header text says the records are grouped
    /// by read name.
    static func isGroupedByReadName(samHeader: String) -> Bool {
        guard let line = samHeader.split(separator: "\n", maxSplits: 1).first, line.hasPrefix("@HD\t") else {
            return false
        }
        let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return fields.contains("SO:queryname") || fields.contains("GO:query")
    }

    /// Groups the records of a BAM by read name with `samtools collate`, so
    /// `samtools fastq` writes each pair as adjacent /1 and /2 records. The
    /// collated copy and the scratch files of `collate` go in `workspace`,
    /// which the importer makes in the project's temporary folder.
    private static func collate(
        pair: SamplePair,
        workspace: URL,
        threads: Int,
        runner: NativeToolRunner
    ) async throws -> (output: URL, step: StepExecution) {
        let collatedURL = workspace.appendingPathComponent("\(pair.sampleName)-collated.bam")
        let arguments = [
            "collate", "-@", String(max(0, threads - 1)),
            "-T", workspace.appendingPathComponent("\(pair.sampleName)-collate").path,
            "-o", collatedURL.path, pair.r1.path,
        ]
        // Collation reads and writes the whole BAM twice, so a large file
        // needs longer than the runner's default.
        let timeout = max(900, Double(fileSize(of: pair.r1)) / 2_500_000)
        let startedAt = Date()
        let result = try await runner.run(.samtools, arguments: arguments, timeout: timeout)
        let endedAt = Date()
        guard result.isSuccess else {
            throw ONTBAMImportError.collationFailed(result.stderr)
        }
        let step = StepExecution(
            toolName: "samtools",
            toolVersion: await runner.getToolVersion(.samtools) ?? "unknown",
            command: result.arguments.isEmpty ? ["samtools"] + arguments : result.arguments,
            durableReplayArgv: ["samtools"] + arguments,
            inputs: [ProvenanceRecorder.fileRecord(url: pair.r1, format: .bam, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: collatedURL, format: .bam, role: .output)],
            exitCode: result.exitCode,
            wallTime: endedAt.timeIntervalSince(startedAt),
            stderr: result.stderr.nilIfEmpty,
            startTime: startedAt,
            endTime: endedAt
        )
        return (collatedURL, step)
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
