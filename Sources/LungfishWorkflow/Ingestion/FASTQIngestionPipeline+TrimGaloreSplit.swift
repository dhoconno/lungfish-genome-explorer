// FASTQIngestionPipeline+TrimGaloreSplit.swift - Trim Galore stores merged reads and read pairs as clumpify does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

extension FASTQIngestionPipeline {

    /// Runs one Trim Galore call and returns its provenance step, the version evidence it recorded and its trimming
    /// report. Every call of either Trim Galore route records its own step with the argv it ran and, as resolved
    /// options, the effective parameters and the read counts its report names. A call without a readable report
    /// fails, because the reads it removed could not be counted.
    func runTrimGalore(
        arguments args: [String],
        inputs: [URL],
        outputDirectory: URL,
        config: FASTQIngestionConfig,
        timeout: Double
    ) async throws -> (step: StepExecution, evidence: ToolVersionEvidence, report: TrimGaloreReport) {
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

        let report = try Self.readTrimGaloreReport(in: outputDirectory)
        let evidence = await versionEvidence(for: .trimGalore)
        let step = StepExecution(
            toolName: "trim_galore",
            toolVersion: evidence.recordedString,
            command: [trimGalore.path] + args,
            resolvedOptions: Self.trimGaloreResolvedOptions(report),
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
        return (step, evidence, report)
    }

    /// Runs Trim Galore's `--clumpify` mode for final-stage FASTQ storage optimization.
    ///
    /// Trim Galore writes paired-end data as two files, while Lungfish bundles store
    /// paired imports as one interleaved FASTQ. For paired inputs, this method uses
    /// BBTools `reformat.sh` only as a streaming interleaver after Trim Galore. A file that mixes pairs with
    /// unpaired reads goes through ``trimGaloreStoreMixed(config:input:counts:outputFile:progress:)``. Every call's
    /// trimming report accounts for the reads it removed (``verifyTrimGaloreAccounting(reported:scanned:counted:)``).
    func trimGaloreClumpify(
        config: FASTQIngestionConfig,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let fm = FileManager.default
        _ = try await runner.toolPath(for: .trimGalore)
        let trimOutputDirectory = config.outputDirectory.appendingPathComponent(
            "trim-galore-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: trimOutputDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: trimOutputDirectory) }

        let timeoutSeconds = max(900, Double(Self.estimatedUncompressedInputBytes(for: config.inputFiles)) / 2_500_000)

        // An interleaved single file runs in Trim Galore's single-end mode
        // otherwise, which clumps and filters each mate on its own and splits
        // the pairs. Split it into R1/R2 first and run --paired; the paired
        // outputs are interleaved again below.
        var trimInputs = config.inputFiles
        var trimPairing = config.pairingMode
        // The records the call is given, checked against its report: the scan's count where the route scans,
        // otherwise the input files' record count.
        var scannedRecords: Int?
        if config.pairingMode == .interleaved, config.inputFiles.count == 1 {
            let interleavedInput = config.inputFiles[0]
            let counts = try await Self.detachedWork {
                try FASTQPairInterleaver.countMixed(interleaved: interleavedInput)
            }
            scannedRecords = counts.pairs * 2 + counts.unpaired
            switch Self.singleFileClumpPlan(for: counts) {
            case .unpaired:
                trimPairing = .singleEnd
            case .interleaved:
                let splitDirectory = trimOutputDirectory.appendingPathComponent("input", isDirectory: true)
                try fm.createDirectory(at: splitDirectory, withIntermediateDirectories: true)
                let stem = Self.deriveBaseName(from: interleavedInput)
                let r1 = splitDirectory.appendingPathComponent("\(stem)_R1.fastq")
                let r2 = splitDirectory.appendingPathComponent("\(stem)_R2.fastq")
                try await Self.detachedWork {
                    FileManager.default.createFile(atPath: r1.path, contents: nil)
                    FileManager.default.createFile(atPath: r2.path, contents: nil)
                    let r1Handle = try FileHandle(forWritingTo: r1)
                    defer { try? r1Handle.close() }
                    let r2Handle = try FileHandle(forWritingTo: r2)
                    defer { try? r2Handle.close() }
                    _ = try FASTQPairInterleaver.deinterleave(interleaved: interleavedInput, r1: r1Handle, r2: r2Handle)
                }
                trimInputs = [r1, r2]
                trimPairing = .pairedEnd
            case .splitMixed:
                // Merged reads beside read pairs: the split, per-half run and join clumpify uses.
                return try await trimGaloreStoreMixed(
                    config: config, input: interleavedInput, counts: counts, outputFile: outputFile, progress: progress
                )
            }
        }

        let args = Self.trimGaloreClumpifyArguments(
            inputFiles: trimInputs,
            outputDirectory: trimOutputDirectory,
            pairingMode: trimPairing,
            threads: config.threads,
            compressionLevel: config.compressionLevel,
            memoryBytes: ClumpingTool.clumpifyHeapBytes(
                physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)
            )
        )

        let inputFiles = config.inputFiles
        let inputRecords: Int
        if let scannedRecords {
            inputRecords = scannedRecords
        } else {
            inputRecords = try await Self.detachedWork {
                try inputFiles.reduce(0) { $0 + (try FASTQPairInterleaver.countRecords(in: $1)) }
            }
        }

        progress(0.05, "Launching Trim Galore --clumpify...")
        let (trimStep, evidence, report) = try await runTrimGalore(
            arguments: args,
            inputs: config.inputFiles,
            outputDirectory: trimOutputDirectory,
            config: config,
            timeout: timeoutSeconds
        )
        let removal = report.paired
            ? Self.storageReadRemoval(pairs: report, unpaired: nil)
            : Self.storageReadRemoval(pairs: nil, unpaired: report)

        if trimPairing == .pairedEnd {
            let pairedOutputs = try Self.trimGalorePairedOutputs(in: trimOutputDirectory)
            let interleaveRecord = try await interleavePairedFASTQ(
                r1: pairedOutputs.r1,
                r2: pairedOutputs.r2,
                outputFile: outputFile,
                config: config,
                progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            )
            try await Self.verifyTrimGaloreOutput(interleaveRecord.url, reported: report, scanned: inputRecords)
            return FASTQProcessingRecord(
                url: interleaveRecord.url,
                tool: "trim_galore",
                toolVersion: evidence.version,
                commandLine: "trim_galore \(args.joined(separator: " ")) && \(interleaveRecord.commandLine)",
                steps: [trimStep] + interleaveRecord.steps,
                readsRemovedByStorage: removal
            )
        }

        let trimmedOutput = try Self.trimGaloreSingleOutput(in: trimOutputDirectory)
        try? fm.removeItem(at: outputFile)
        // Trim Galore --clumpify writes plain FASTQ for plain input (its
        // --gzip is ignored in that mode), so compress it instead of moving.
        var compressionSteps: [StepExecution] = []
        var compressionCommand = ""
        if Self.isGzipCompressed(trimmedOutput) {
            try fm.moveItem(at: trimmedOutput, to: outputFile)
        } else {
            let compressed = try await compress(
                inputFile: trimmedOutput,
                outputFile: outputFile,
                threads: config.threads,
                progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            )
            compressionSteps = compressed.steps
            compressionCommand = " && " + compressed.commandLine
        }

        guard fm.fileExists(atPath: outputFile.path) else {
            throw FASTQIngestionError.clumpifyFailed("trim_galore completed without producing output")
        }

        try await Self.verifyTrimGaloreOutput(outputFile, reported: report, scanned: inputRecords)
        progress(1.0, "Trim Galore complete")
        return FASTQProcessingRecord(
            url: outputFile,
            tool: "trim_galore",
            toolVersion: evidence.version,
            commandLine: "trim_galore \(args.joined(separator: " "))" + compressionCommand,
            steps: [trimStep] + compressionSteps,
            readsRemovedByStorage: removal
        )
    }

    /// Stores a file that mixes mate pairs with unpaired reads (a merging recipe's merged reads beside its pairs)
    /// through Trim Galore the way ``clumpify(config:heapGB:outputFile:progress:)`` stores it through clumpify: the
    /// scan found the mates by name, the file is split into a file of pairs and a file of unpaired reads, Trim
    /// Galore's paired mode runs on the pairs and its single-end mode on the unpaired reads, each half is deleted
    /// once it is processed, the processed unpaired reads join the end of the processed pairs in place, and the
    /// joined file is compressed and counted. Trim Galore writes a pair as two files, so the pairs are interleaved
    /// again before the join. The split, the join and the count check are the code the bbtools route runs. Each
    /// half's output must hold exactly what its trimming report says was written, and the joined file the sum.
    func trimGaloreStoreMixed(
        config: FASTQIngestionConfig,
        input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        outputFile: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQProcessingRecord {
        let fm = FileManager.default
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
        let (pairsStep, evidence, pairsReport) = try await runTrimGalore(
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
        try await Self.verifyTrimGaloreOutput(interleavedPairs, reported: pairsReport, scanned: counts.pairs * 2)
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
        let (unpairedStep, _, unpairedReport) = try await runTrimGalore(
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
        try await Self.verifyTrimGaloreOutput(trimmedUnpaired, reported: unpairedReport, scanned: counts.unpaired)
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
            in: outputFile, expected: pairsReport.recordsWritten + unpairedReport.recordsWritten, tool: "trim_galore"
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
            steps: [pairsStep] + interleave.steps + [unpairedStep] + compressed.steps,
            readsRemovedByStorage: Self.storageReadRemoval(pairs: pairsReport, unpaired: unpairedReport)
        )
    }
}
