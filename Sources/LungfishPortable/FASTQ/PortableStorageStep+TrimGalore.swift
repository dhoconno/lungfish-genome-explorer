// PortableStorageStep+TrimGalore.swift - The Trim Galore route of the portable storage step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension PortableStoragePlan {

    /// The argv of one Trim Galore `--clumpify` call. Trim Galore writes the gzip of its output itself at
    /// `--compression`, and `memoryBytes` is the heap the caller names, rounded down to whole GiB and at least 1.
    package static func trimGaloreClumpifyArguments(
        inputFiles: [URL],
        outputDirectory: URL,
        paired: Bool,
        threads: Int,
        compressionLevel: Int,
        memoryBytes: Int64
    ) -> [String] {
        let memoryGB = max(1, memoryBytes / 1_073_741_824)
        var args = [
            "--clumpify",
            "--compression", String(compressionLevel),
            "--cores", String(max(2, threads)),
            "--memory", "\(memoryGB)G",
            "--output_dir", outputDirectory.path,
        ]
        if paired {
            args.append("--paired")
        }
        args.append(contentsOf: inputFiles.map(\.path))
        return args
    }

    /// The argv of the `reformat.sh` launch that interleaves Trim Galore's two paired outputs into one file.
    package static func trimGaloreInterleaveArguments(
        r1: URL, r2: URL, output: URL, compressionLevel: Int, threads: Int
    ) -> [String] {
        [
            "in1=\(r1.path)",
            "in2=\(r2.path)",
            "out=\(output.path)",
            "ow=t",
            "pigz=t",
            "zl=\(compressionLevel)",
            "threads=\(max(1, threads))",
            "interleaved=t",
        ]
    }

    /// The one single-end output of a Trim Galore call in `directory`.
    package static func trimGaloreSingleOutput(in directory: URL) throws -> URL {
        let outputs = try fastqOutputs(in: directory).filter { url in
            ["_trimmed.fq.gz", "_trimmed.fastq.gz", "_trimmed.fq", "_trimmed.fastq"]
                .contains { url.lastPathComponent.hasSuffix($0) }
        }
        guard let output = outputs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw PortableStorageError.storageFailed("trim_galore did not produce a single-end clumped FASTQ")
        }
        return output
    }

    /// The two paired outputs of a Trim Galore call in `directory`. Plain input gives plain `_val_N.fq` under
    /// `--clumpify`, and `reformat.sh` reads either when it interleaves them.
    package static func trimGalorePairedOutputs(in directory: URL) throws -> (r1: URL, r2: URL) {
        let outputs = try fastqOutputs(in: directory)
        func mate(_ number: Int) -> URL? {
            outputs.first { url in
                ["_val_\(number).fq.gz", "_val_\(number).fq"].contains { url.lastPathComponent.hasSuffix($0) }
            }
        }
        guard let r1 = mate(1), let r2 = mate(2) else {
            throw PortableStorageError.storageFailed("trim_galore did not produce paired clumped FASTQs")
        }
        return (r1, r2)
    }

    private static func fastqOutputs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let name = url.lastPathComponent.lowercased()
            return [".fq.gz", ".fastq.gz", ".fq", ".fastq"].contains { name.hasSuffix($0) }
        }
    }
}

extension PortableStorageStep {

    /// How the inputs of a Trim Galore run hold their reads.
    package enum TrimGalorePairing: Sendable, Equatable {
        /// An R1 and an R2 file, run in Trim Galore's paired mode and interleaved again after it.
        case pairs
        /// Reads without mates, run in single-end mode.
        case single
        /// One file whose mates sit together. It is scanned first and run as pairs, as single reads, or split.
        case interleavedFile
    }

    /// What one Trim Galore storage run needs, all chosen before it starts.
    package struct TrimGaloreRun: Sendable {
        package var inputs: [URL]
        package var pairing: TrimGalorePairing
        package var output: URL
        /// The folder every launch runs in and the parent of the run's scratch folders.
        package var workingDirectory: URL
        /// The base name the split R1 and R2 files of an interleaved file take, such as `sample`.
        package var stem: String
        package var threads: Int
        /// The user's gzip level, Trim Galore's `--compression` and the interleave's `zl=`.
        package var compressionLevel: Int
        /// The heap Trim Galore's `--memory` names.
        package var memoryBytes: Int64
        /// The compressor plain output is written with, nil when none is installed.
        package var compressor: PortableCompressor?
        /// The seconds each launch may run, the plan's deadline on the executor (K2 review O-1). Nil takes the Mac's
        /// rules from the input size.
        package var deadlineSeconds: Double?

        package init(
            inputs: [URL], pairing: TrimGalorePairing, output: URL, workingDirectory: URL, stem: String,
            threads: Int, compressionLevel: Int, memoryBytes: Int64, compressor: PortableCompressor?,
            deadlineSeconds: Double? = nil
        ) {
            self.inputs = inputs
            self.pairing = pairing
            self.output = output
            self.workingDirectory = workingDirectory
            self.stem = stem
            self.threads = threads
            self.compressionLevel = compressionLevel
            self.memoryBytes = memoryBytes
            self.compressor = compressor
            self.deadlineSeconds = deadlineSeconds
        }
    }

    /// What a Trim Galore storage run did: every accepted launch in order, the first a Trim Galore call, and the
    /// report of its call on pairs and of its call on single or unpaired reads, as the run made them.
    package struct TrimGaloreOutcome: Sendable {
        package var records: [Launcher.Record]
        package var pairsReport: TrimGaloreReport?
        package var unpairedReport: TrimGaloreReport?
    }

    /// Stores reads through Trim Galore's `--clumpify` mode. Trim Galore writes a pair as two files, so the pairs are
    /// interleaved again with `reformat.sh`. An interleaved file runs in paired mode after a split by mate, since
    /// single-end mode would clump and filter each mate on its own. A file that mixes pairs with unpaired reads goes
    /// through the split, per-half run and join the clumpify route uses. Every call's output is counted against its
    /// trimming report (``TrimGaloreReport/verifyAccounting(scanned:counted:)``).
    package func trimGalore(
        _ run: TrimGaloreRun,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TrimGaloreOutcome {
        let fm = FileManager.default
        _ = try await launcher.executableURL(for: .trimGalore)
        let trimOutputDirectory = run.workingDirectory.appendingPathComponent(
            "trim-galore-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: trimOutputDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: trimOutputDirectory) }

        let timeoutSeconds = run.deadlineSeconds ?? max(
            900, Double(PortableStoragePlan.estimatedUncompressedInputBytes(for: run.inputs)) / 2_500_000
        )
        let childLauncher = self.childLauncher
        var trimInputs = run.inputs
        var paired = run.pairing == .pairs
        // The records the call is given, checked against its report: the scan's count where the route scans,
        // otherwise the input files' record count.
        var scannedRecords: Int?
        if run.pairing == .interleavedFile {
            let interleavedInput = run.inputs[0]
            let counts = try await PortableStorageChecks.detachedWork {
                try FASTQPairInterleaver.countMixed(interleaved: interleavedInput, launcher: childLauncher)
            }
            scannedRecords = counts.pairs * 2 + counts.unpaired
            switch PortableStoragePlan.singleFileClumpPlan(for: counts) {
            case .unpaired:
                paired = false
            case .interleaved:
                let splitDirectory = trimOutputDirectory.appendingPathComponent("input", isDirectory: true)
                try fm.createDirectory(at: splitDirectory, withIntermediateDirectories: true)
                let r1 = splitDirectory.appendingPathComponent("\(run.stem)_R1.fastq")
                let r2 = splitDirectory.appendingPathComponent("\(run.stem)_R2.fastq")
                try await deinterleave(interleavedInput, r1: r1, r2: r2)
                trimInputs = [r1, r2]
                paired = true
            case .splitMixed:
                return try await trimGaloreMixed(run, input: interleavedInput, counts: counts, progress: progress)
            }
        }

        let args = PortableStoragePlan.trimGaloreClumpifyArguments(
            inputFiles: trimInputs, outputDirectory: trimOutputDirectory, paired: paired, threads: run.threads,
            compressionLevel: run.compressionLevel, memoryBytes: run.memoryBytes
        )
        let inputFiles = run.inputs
        let inputRecords: Int
        if let scannedRecords {
            inputRecords = scannedRecords
        } else {
            inputRecords = try await PortableStorageChecks.detachedWork {
                try inputFiles.reduce(0) { $0 + (try FASTQPairInterleaver.countRecords(in: $1, launcher: childLauncher)) }
            }
        }

        progress(0.05, "Launching Trim Galore --clumpify...")
        let (trimRecord, report) = try await launchTrimGalore(
            arguments: args, inputs: run.inputs, outputDirectory: trimOutputDirectory,
            workingDirectory: run.workingDirectory, timeout: timeoutSeconds
        )
        let pairsReport = report.paired ? report : nil
        let unpairedReport = report.paired ? nil : report

        if paired {
            let pairedOutputs = try PortableStoragePlan.trimGalorePairedOutputs(in: trimOutputDirectory)
            let interleaveRecord = try await interleave(
                r1: pairedOutputs.r1, r2: pairedOutputs.r2, output: run.output, run: run,
                progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            )
            try await verifyOutput(run.output, reported: report, scanned: inputRecords)
            return TrimGaloreOutcome(
                records: [trimRecord, interleaveRecord], pairsReport: pairsReport, unpairedReport: unpairedReport
            )
        }

        let trimmedOutput = try PortableStoragePlan.trimGaloreSingleOutput(in: trimOutputDirectory)
        try? fm.removeItem(at: run.output)
        // Trim Galore --clumpify writes plain FASTQ for plain input (its --gzip is ignored in that mode), so plain
        // output is compressed instead of moved.
        var records = [trimRecord]
        if PortableStoragePlan.isGzipCompressed(trimmedOutput) {
            try fm.moveItem(at: trimmedOutput, to: run.output)
        } else {
            records.append(try await compress(
                input: trimmedOutput, output: run.output, compressor: run.compressor, threads: run.threads,
                timeout: run.deadlineSeconds, progress: { fraction, msg in progress(0.75 + fraction * 0.25, msg) }
            ))
        }
        guard fm.fileExists(atPath: run.output.path) else {
            throw PortableStorageError.storageFailed("trim_galore completed without producing output")
        }
        try await verifyOutput(run.output, reported: report, scanned: inputRecords)
        progress(1.0, "Trim Galore complete")
        return TrimGaloreOutcome(records: records, pairsReport: pairsReport, unpairedReport: unpairedReport)
    }

    /// Stores a file that mixes mate pairs with unpaired reads the way the clumpify route stores it: the file is
    /// split by mate name, Trim Galore's paired mode runs on the pairs and its single-end mode on the unpaired reads,
    /// each half is deleted once it is processed, the processed unpaired reads join the end of the processed pairs in
    /// place, and the joined file is compressed and counted. Each half's output must hold exactly what its report
    /// says was written, and the joined file the sum.
    private func trimGaloreMixed(
        _ run: TrimGaloreRun,
        input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TrimGaloreOutcome {
        let fm = FileManager.default
        progress(0.04, "Separating mate pairs from unpaired reads...")
        let halves = try await PortableStorageChecks.splitMixedByMate(
            input, counts: counts, in: run.workingDirectory, scratchPrefix: ".trim-galore-split",
            launcher: childLauncher
        )
        let scratch = halves.scratch
        defer { try? fm.removeItem(at: scratch) }

        // The pairs: Trim Galore's paired mode takes R1 and R2, so the file of pairs is split in two first.
        let pairsInput = scratch.appendingPathComponent("pairs-in", isDirectory: true)
        let pairsOutput = scratch.appendingPathComponent("pairs-out", isDirectory: true)
        try fm.createDirectory(at: pairsInput, withIntermediateDirectories: true)
        try fm.createDirectory(at: pairsOutput, withIntermediateDirectories: true)
        let r1 = pairsInput.appendingPathComponent("\(run.stem)_R1.fastq")
        let r2 = pairsInput.appendingPathComponent("\(run.stem)_R2.fastq")
        try await deinterleave(halves.pairs, r1: r1, r2: r2)
        try? fm.removeItem(at: halves.pairs)

        let pairsArguments = PortableStoragePlan.trimGaloreClumpifyArguments(
            inputFiles: [r1, r2], outputDirectory: pairsOutput, paired: true, threads: run.threads,
            compressionLevel: run.compressionLevel, memoryBytes: run.memoryBytes
        )
        progress(0.1, "Launching Trim Galore --clumpify on mate pairs...")
        let (pairsRecord, pairsReport) = try await launchTrimGalore(
            arguments: pairsArguments, inputs: [r1, r2], outputDirectory: pairsOutput,
            workingDirectory: run.workingDirectory,
            timeout: run.deadlineSeconds
                ?? max(900, Double(PortableStoragePlan.estimatedUncompressedInputBytes(for: [r1, r2])) / 2_500_000)
        )
        try? fm.removeItem(at: pairsInput)

        let trimmedPairs = try PortableStoragePlan.trimGalorePairedOutputs(in: pairsOutput)
        let interleavedPairs = scratch.appendingPathComponent("pairs.trimmed.fastq")
        let interleaveRecord = try await interleave(
            r1: trimmedPairs.r1, r2: trimmedPairs.r2, output: interleavedPairs, run: run,
            progress: { fraction, message in progress(0.4 + fraction * 0.1, message) }
        )
        try? fm.removeItem(at: pairsOutput)
        try await verifyOutput(interleavedPairs, reported: pairsReport, scanned: counts.pairs * 2)
        try Task.checkCancellation()

        // The unpaired reads: Trim Galore's single-end mode.
        let unpairedOutput = scratch.appendingPathComponent("unpaired-out", isDirectory: true)
        try fm.createDirectory(at: unpairedOutput, withIntermediateDirectories: true)
        let unpairedArguments = PortableStoragePlan.trimGaloreClumpifyArguments(
            inputFiles: [halves.unpaired], outputDirectory: unpairedOutput, paired: false, threads: run.threads,
            compressionLevel: run.compressionLevel, memoryBytes: run.memoryBytes
        )
        progress(0.55, "Launching Trim Galore --clumpify on unpaired reads...")
        let (unpairedRecord, unpairedReport) = try await launchTrimGalore(
            arguments: unpairedArguments, inputs: [halves.unpaired], outputDirectory: unpairedOutput,
            workingDirectory: run.workingDirectory,
            timeout: run.deadlineSeconds ?? max(
                900, Double(PortableStoragePlan.estimatedUncompressedInputBytes(for: [halves.unpaired])) / 2_500_000
            )
        )
        try? fm.removeItem(at: halves.unpaired)

        let trimmedUnpaired = try PortableStoragePlan.trimGaloreSingleOutput(in: unpairedOutput)
        guard !PortableStoragePlan.isGzipCompressed(trimmedUnpaired) else {
            throw PortableStorageError.storageFailed(
                "trim_galore wrote compressed output for plain unpaired reads, which cannot join the pairs in place"
            )
        }
        try await verifyOutput(trimmedUnpaired, reported: unpairedReport, scanned: counts.unpaired)
        let combined = scratch.appendingPathComponent("combined.fastq")
        try PortableFileJoin.appendAndRename(trimmedUnpaired, to: interleavedPairs, as: combined)
        let compressRecord = try await compress(
            input: combined, output: run.output, compressor: run.compressor, threads: run.threads,
            timeout: run.deadlineSeconds, progress: { fraction, message in progress(0.8 + fraction * 0.15, message) }
        )

        progress(0.95, "Verifying read count...")
        try await PortableStorageChecks.verifyStoredRecordCount(
            in: run.output, expected: pairsReport.recordsWritten + unpairedReport.recordsWritten, tool: "trim_galore",
            launcher: childLauncher
        )
        progress(1.0, "Trim Galore complete")
        return TrimGaloreOutcome(
            records: [pairsRecord, interleaveRecord, unpairedRecord, compressRecord],
            pairsReport: pairsReport, unpairedReport: unpairedReport
        )
    }

    /// Runs one Trim Galore call and records it with its report. A call without a readable report fails, because
    /// the reads it removed could not be counted.
    private func launchTrimGalore(
        arguments args: [String],
        inputs: [URL],
        outputDirectory: URL,
        workingDirectory: URL,
        timeout: Double
    ) async throws -> (Launcher.Record, TrimGaloreReport) {
        let executable = try await launcher.executableURL(for: .trimGalore)
        let launch = PortableToolLaunch(
            tool: .trimGalore, arguments: args, workingDirectory: workingDirectory, timeout: timeout
        )
        let outcome = try await launcher.run(launch)
        guard outcome.isSuccess else {
            let stderr = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
            throw PortableStorageError.storageFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let report = try TrimGaloreReport.read(in: outputDirectory)
        let record = await launcher.record(PortableToolRun(
            launch: launch, executableURL: executable, outcome: outcome, inputs: inputs, outputs: [outputDirectory],
            report: report
        ))
        return (record, report)
    }

    /// Interleaves Trim Galore's two paired outputs into `output` with `reformat.sh` and records the launch.
    private func interleave(
        r1: URL,
        r2: URL,
        output: URL,
        run: TrimGaloreRun,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Launcher.Record {
        let executable = try await launcher.executableURL(for: .reformat)
        let args = PortableStoragePlan.trimGaloreInterleaveArguments(
            r1: r1, r2: r2, output: output, compressionLevel: run.compressionLevel, threads: run.threads
        )
        let timeoutSeconds = run.deadlineSeconds
            ?? max(600, Double(PortableStoragePlan.estimatedUncompressedInputBytes(for: [r1, r2])) / 5_000_000)
        progress(0.1, "Interleaving paired Trim Galore outputs...")
        let launch = PortableToolLaunch(
            tool: .reformat, arguments: args, workingDirectory: run.workingDirectory, timeout: timeoutSeconds
        )
        let outcome = try await launcher.run(launch)
        guard outcome.isSuccess else {
            throw PortableStorageError.storageFailed(
                String((outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr).suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw PortableStorageError.storageFailed("reformat.sh completed without producing interleaved output")
        }
        let record = await launcher.record(PortableToolRun(
            launch: launch, executableURL: executable, outcome: outcome, inputs: [r1, r2], outputs: [output]
        ))
        progress(1.0, "Interleaving complete")
        return record
    }

    /// Splits an interleaved file of whole pairs into an R1 and an R2 file.
    private func deinterleave(_ input: URL, r1: URL, r2: URL) async throws {
        let childLauncher = self.childLauncher
        try await PortableStorageChecks.detachedWork {
            FileManager.default.createFile(atPath: r1.path, contents: nil)
            FileManager.default.createFile(atPath: r2.path, contents: nil)
            let r1Handle = try FileHandle(forWritingTo: r1)
            defer { try? r1Handle.close() }
            let r2Handle = try FileHandle(forWritingTo: r2)
            defer { try? r2Handle.close() }
            _ = try FASTQPairInterleaver.deinterleave(
                interleaved: input, r1: r1Handle, r2: r2Handle, launcher: childLauncher
            )
        }
    }

    private func verifyOutput(_ output: URL, reported: TrimGaloreReport, scanned: Int) async throws {
        try await PortableStorageChecks.verifyTrimGaloreOutput(
            output, reported: reported, scanned: scanned, launcher: childLauncher
        )
    }
}

extension PortableStorageChecks {

    /// Counts `output` and checks it with ``TrimGaloreReport/verifyAccounting(scanned:counted:)``, removing `output`
    /// when the check fails so the originals stay the only copy.
    package static func verifyTrimGaloreOutput(
        _ output: URL, reported: TrimGaloreReport, scanned: Int, launcher: any PortableChildLauncher
    ) async throws {
        let counted = try await detachedWork { try FASTQPairInterleaver.countRecords(in: output, launcher: launcher) }
        do {
            try reported.verifyAccounting(scanned: scanned, counted: counted)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
