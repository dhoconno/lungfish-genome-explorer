// FASTQIngestionPipeline+TrimGaloreSplit.swift - Trim Galore stores merged reads and read pairs as clumpify does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

extension FASTQIngestionPipeline {

    /// Runs one Trim Galore call and returns its provenance step with the version evidence it recorded. Every call
    /// of either Trim Galore route records its own step with the argv it ran.
    func runTrimGalore(
        arguments args: [String],
        inputs: [URL],
        outputDirectory: URL,
        config: FASTQIngestionConfig,
        timeout: Double
    ) async throws -> (step: StepExecution, evidence: ToolVersionEvidence) {
        let trimGalore = try await runner.toolPath(for: .trimGalore)
        let stepClock = ProvenanceRunClock()
        let result = try await runner.runProcess(
            executableURL: trimGalore,
            arguments: args,
            workingDirectory: config.outputDirectory,
            timeout: timeout,
            toolName: "trim_galore"
        )
        let stepCompletedAt = stepClock.now

        guard result.isSuccess else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FASTQIngestionError.clumpifyFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let evidence = await versionEvidence(for: .trimGalore)
        let step = StepExecution(
            toolName: "trim_galore",
            toolVersion: evidence.recordedString,
            command: [trimGalore.path] + args,
            inputs: inputs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            },
            outputs: [ProvenanceRecorder.fileOrDirectoryRecord(url: outputDirectory, format: .unknown, role: .output)],
            exitCode: result.exitCode,
            wallTime: stepCompletedAt.timeIntervalSince(stepClock.startedAt),
            stderr: result.stderr.isEmpty ? nil : result.stderr,
            managedToolID: NativeTool.trimGalore.managedToolID, toolVersionEvidence: evidence,
            startTime: stepClock.startedAt,
            endTime: stepCompletedAt
        )
        return (step, evidence)
    }

    /// Stores a file that mixes mate pairs with unpaired reads (a merging recipe's merged reads beside its pairs)
    /// through Trim Galore the way ``clumpify(config:heapGB:outputFile:progress:)`` stores it through clumpify: the
    /// scan found the mates by name, the file is split into a file of pairs and a file of unpaired reads, Trim
    /// Galore's paired mode runs on the pairs and its single-end mode on the unpaired reads, each half is deleted
    /// once it is processed, the processed unpaired reads join the end of the processed pairs in place, and the
    /// joined file is compressed and counted. Trim Galore writes a pair as two files, so the pairs are interleaved
    /// again before the join. The split, the join and the count check are the code the bbtools route runs.
    func trimGaloreStoreMixed(
        config: FASTQIngestionConfig,
        input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let fm = FileManager.default
        let expectedRecords = counts.pairs * 2 + counts.unpaired
        let memoryBytes = ClumpingTool.clumpifyHeapBytes(
            physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        )

        progress(0.04, "Separating mate pairs from unpaired reads...")
        let halves = try await Self.splitMixedByMate(
            input, counts: counts, in: config.outputDirectory, scratchPrefix: ".trim-galore-split"
        )
        let scratch = halves.scratch
        defer { try? fm.removeItem(at: scratch) }

        // The pairs: Trim Galore's paired mode takes R1 and R2, so the file of pairs is split in two first.
        let pairsInput = scratch.appendingPathComponent("pairs-in", isDirectory: true)
        let pairsOutput = scratch.appendingPathComponent("pairs-out", isDirectory: true)
        try fm.createDirectory(at: pairsInput, withIntermediateDirectories: true)
        try fm.createDirectory(at: pairsOutput, withIntermediateDirectories: true)
        let stem = Self.deriveBaseName(from: input)
        let r1 = pairsInput.appendingPathComponent("\(stem)_R1.fastq")
        let r2 = pairsInput.appendingPathComponent("\(stem)_R2.fastq")
        let pairsFile = halves.pairs
        try await Self.detachedWork {
            FileManager.default.createFile(atPath: r1.path, contents: nil)
            FileManager.default.createFile(atPath: r2.path, contents: nil)
            let r1Handle = try FileHandle(forWritingTo: r1)
            defer { try? r1Handle.close() }
            let r2Handle = try FileHandle(forWritingTo: r2)
            defer { try? r2Handle.close() }
            _ = try FASTQPairInterleaver.deinterleave(interleaved: pairsFile, r1: r1Handle, r2: r2Handle)
        }
        try? fm.removeItem(at: halves.pairs)

        let pairsArguments = Self.trimGaloreClumpifyArguments(
            inputFiles: [r1, r2],
            outputDirectory: pairsOutput,
            pairingMode: .pairedEnd,
            threads: config.threads,
            compressionLevel: config.compressionLevel,
            memoryBytes: memoryBytes
        )
        progress(0.1, "Launching Trim Galore --clumpify on mate pairs...")
        let (pairsStep, evidence) = try await runTrimGalore(
            arguments: pairsArguments,
            inputs: [r1, r2],
            outputDirectory: pairsOutput,
            config: config,
            timeout: max(900, Double(Self.estimatedUncompressedInputBytes(for: [r1, r2])) / 2_500_000)
        )
        try? fm.removeItem(at: pairsInput)

        let trimmedPairs = try Self.trimGalorePairedOutputs(in: pairsOutput)
        let interleavedPairs = scratch.appendingPathComponent("pairs.trimmed.fastq")
        let interleave = try await interleavePairedFASTQ(
            r1: trimmedPairs.r1,
            r2: trimmedPairs.r2,
            outputFile: interleavedPairs,
            config: config,
            progress: { fraction, message in progress(0.4 + fraction * 0.1, message) }
        )
        try? fm.removeItem(at: pairsOutput)
        try Task.checkCancellation()

        // The unpaired reads: Trim Galore's single-end mode.
        let unpairedOutput = scratch.appendingPathComponent("unpaired-out", isDirectory: true)
        try fm.createDirectory(at: unpairedOutput, withIntermediateDirectories: true)
        let unpairedArguments = Self.trimGaloreClumpifyArguments(
            inputFiles: [halves.unpaired],
            outputDirectory: unpairedOutput,
            pairingMode: .singleEnd,
            threads: config.threads,
            compressionLevel: config.compressionLevel,
            memoryBytes: memoryBytes
        )
        progress(0.55, "Launching Trim Galore --clumpify on unpaired reads...")
        let (unpairedStep, _) = try await runTrimGalore(
            arguments: unpairedArguments,
            inputs: [halves.unpaired],
            outputDirectory: unpairedOutput,
            config: config,
            timeout: max(900, Double(Self.estimatedUncompressedInputBytes(for: [halves.unpaired])) / 2_500_000)
        )
        try? fm.removeItem(at: halves.unpaired)

        let trimmedUnpaired = try Self.trimGaloreSingleOutput(in: unpairedOutput)
        guard !Self.isGzipCompressed(trimmedUnpaired) else {
            throw FASTQIngestionError.clumpifyFailed(
                "trim_galore wrote compressed output for plain unpaired reads, which cannot join the pairs in place"
            )
        }
        let combined = scratch.appendingPathComponent("combined.fastq")
        try Self.appendAndRename(trimmedUnpaired, to: interleavedPairs, as: combined)
        let compressed = try await compress(
            inputFile: combined,
            outputFile: outputFile,
            threads: config.threads,
            progress: { fraction, message in progress(0.8 + fraction * 0.15, message) }
        )

        progress(0.95, "Verifying read count...")
        try await Self.verifyStoredRecordCount(
            in: outputFile, expected: expectedRecords, tool: "trim_galore", mayRemoveReads: true
        )
        progress(1.0, "Trim Galore complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "trim_galore",
            toolVersion: evidence.version,
            commandLine: [
                "trim_galore \(pairsArguments.joined(separator: " "))",
                interleave.commandLine,
                "trim_galore \(unpairedArguments.joined(separator: " "))",
                compressed.commandLine,
            ].joined(separator: " && "),
            steps: [pairsStep] + interleave.steps + [unpairedStep] + compressed.steps
        )
    }
}
