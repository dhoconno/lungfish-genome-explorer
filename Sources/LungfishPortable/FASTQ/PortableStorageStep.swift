// PortableStorageStep.swift - The storage run of an import, over a launcher seam
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why a storage step failed. Each platform maps a case to its own error, and the Mac shows the words it showed
/// before the seam.
package enum PortableStorageError: Error, Equatable, Sendable {
    /// A storage tool failed or wrote no output. The text is the tool's stderr tail or a plain reason.
    case storageFailed(String)
    /// A BBTools launch that carried ``BBToolsOutOfMemory/flag`` ended because its JVM ran out of heap.
    case outOfMemory(tool: String, arguments: [String])
    /// The compressor failed. The text is its stderr tail.
    case compressionFailed(String)
    /// The step had to compress and its caller named no compressor.
    case compressorNotFound
    /// An interleaved output does not hold every R1 and R2 record.
    case pairedOutputVerificationFailed(String)
}

/// A mixed file split by mate name into one file of whole pairs and one of unpaired reads, in a scratch folder the
/// caller removes.
package struct PortableMixedFileHalves: Sendable {
    package let scratch: URL
    package let pairs: URL
    package let unpaired: URL
}

/// The record counts and the split that every storage route runs, which start no tool of their own. A gzip file is
/// read through `launcher`.
package enum PortableStorageChecks {

    /// Runs blocking work off the cooperative pool and forwards the caller's cancellation to it, which a detached
    /// task does not inherit. A caller cancelled before the work starts gets `CancellationError` at once.
    package static func detachedWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Splits `input`, which the scan found to mix pairs with unpaired reads, into the two halves of a new scratch
    /// folder under `parent` and checks the split against the scan. Every route splits here, so a pair is a pair by
    /// one rule (``FASTQPairInterleaver/partitionMixed(interleaved:pairs:unpaired:launcher:)``). A failed split
    /// removes its scratch folder.
    package static func splitMixedByMate(
        _ input: URL,
        counts: FASTQPairInterleaver.MixedCounts,
        in parent: URL,
        scratchPrefix: String,
        launcher: any PortableChildLauncher
    ) async throws -> PortableMixedFileHalves {
        let fm = FileManager.default
        let scratch = parent.appendingPathComponent("\(scratchPrefix)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let halves = PortableMixedFileHalves(
            scratch: scratch,
            pairs: scratch.appendingPathComponent("pairs.fastq"),
            unpaired: scratch.appendingPathComponent("unpaired.fastq")
        )
        do {
            try await detachedWork {
                FileManager.default.createFile(atPath: halves.pairs.path, contents: nil)
                FileManager.default.createFile(atPath: halves.unpaired.path, contents: nil)
                let pairsHandle = try FileHandle(forWritingTo: halves.pairs)
                defer { try? pairsHandle.close() }
                let unpairedHandle = try FileHandle(forWritingTo: halves.unpaired)
                defer { try? unpairedHandle.close() }
                let split = try FASTQPairInterleaver.partitionMixed(
                    interleaved: input,
                    pairs: pairsHandle,
                    unpaired: unpairedHandle,
                    launcher: launcher
                )
                guard split == counts else {
                    throw PortableStorageError.storageFailed(
                        "the pair scan found \(counts.pairs) pairs and \(counts.unpaired) unpaired reads, but the split wrote \(split.pairs) and \(split.unpaired)"
                    )
                }
            }
        } catch {
            try? fm.removeItem(at: scratch)
            throw error
        }
        return halves
    }

    /// Counts the stored output against the reads the storage tool kept and removes the output when the count is
    /// wrong, so the originals stay the only copy.
    package static func verifyStoredRecordCount(
        in output: URL,
        expected: Int,
        tool: String,
        launcher: any PortableChildLauncher
    ) async throws {
        let records = try await detachedWork { try FASTQPairInterleaver.countRecords(in: output, launcher: launcher) }
        guard records == expected else {
            try? FileManager.default.removeItem(at: output)
            throw PortableStorageError.storageFailed(
                "expected \(expected) reads after \(tool) but \(output.lastPathComponent) holds \(records); originals were kept"
            )
        }
    }

    /// Confirms an interleaved output holds exactly R1 + R2 records. Counting streams each file once, so the check
    /// costs one extra read of the inputs and output, the price of never deleting a pair whose mate went missing.
    package static func verifyInterleavedRecordCount(
        output: URL, r1: URL, r2: URL, launcher: any PortableChildLauncher
    ) async throws {
        let counts = try await detachedWork { () throws -> (r1: Int, r2: Int, output: Int) in
            let r1Count = try FASTQPairInterleaver.countRecords(in: r1, launcher: launcher)
            try Task.checkCancellation()
            let r2Count = try FASTQPairInterleaver.countRecords(in: r2, launcher: launcher)
            try Task.checkCancellation()
            let outputCount = try FASTQPairInterleaver.countRecords(in: output, launcher: launcher)
            return (r1Count, r2Count, outputCount)
        }
        guard counts.r1 == counts.r2 else {
            throw PortableStorageError.pairedOutputVerificationFailed(
                "\(r1.lastPathComponent) has \(counts.r1) reads but \(r2.lastPathComponent) has \(counts.r2)"
            )
        }
        guard counts.output == counts.r1 + counts.r2 else {
            throw PortableStorageError.pairedOutputVerificationFailed(
                "expected \(counts.r1 + counts.r2) interleaved reads (R1 + R2) but \(output.lastPathComponent) holds \(counts.output)"
            )
        }
    }
}

/// The storage run of an import: the clumpify launches, the split and join of a mixed file, the compressor and the
/// record counts. It starts every tool through `launcher` and reads gzip through `childLauncher`, so the Mac import
/// and the Linux executor run one step. Its caller names the heap, the threads, the binning, the environment and the
/// compressor, and the step decides nothing from the host.
package struct PortableStorageStep<Launcher: PortableToolLauncher>: Sendable {
    package let launcher: Launcher
    package let childLauncher: any PortableChildLauncher
    /// Receives one line for the caller's log, such as the clumpify plan of a single file.
    package let log: @Sendable (String) -> Void

    package init(
        launcher: Launcher,
        childLauncher: any PortableChildLauncher,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.launcher = launcher
        self.childLauncher = childLauncher
        self.log = log
    }

    /// What one clumpify storage run needs, all chosen before it starts.
    package struct ClumpifyRun: Sendable {
        /// One file, or an R1 and an R2 file.
        package var inputs: [URL]
        package var output: URL
        /// The folder clumpify runs in and the parent of a mixed file's scratch folder.
        package var workingDirectory: URL
        package var heapGB: Int
        package var threads: Int
        package var qualityBinning: QualityBinningScheme
        /// The whole environment clumpify sees. The step adds `_JAVA_OPTIONS` for the heap.
        package var environment: [String: String]
        /// The compressor a mixed file's joined halves are written with, nil when none is installed.
        package var compressor: PortableCompressor?
        /// The seconds each launch may run, the plan's deadline on the executor (K2 review O-1, tally-r2 K4-06). Nil
        /// takes the Mac's rule of at least 900 seconds and one second for each 2.5 MB of input.
        package var deadlineSeconds: Double?
        /// True when the step runs the writer probe right before each launch that writes the stored gzip and hands
        /// its result to that launch's record (`PortableToolRun.writerProbe`), as the Mac import asks from C4-10. The
        /// executor probes on its own and leaves it false.
        package var probesWriter: Bool

        package init(
            inputs: [URL], output: URL, workingDirectory: URL, heapGB: Int, threads: Int,
            qualityBinning: QualityBinningScheme, environment: [String: String], compressor: PortableCompressor?,
            deadlineSeconds: Double? = nil, probesWriter: Bool = false
        ) {
            self.inputs = inputs
            self.output = output
            self.workingDirectory = workingDirectory
            self.heapGB = heapGB
            self.threads = threads
            self.qualityBinning = qualityBinning
            self.environment = environment
            self.compressor = compressor
            self.deadlineSeconds = deadlineSeconds
            self.probesWriter = probesWriter
        }
    }

    /// Sorts reads by k-mer similarity with `clumpify.sh`, which writes the gzip output itself. R1 and R2 run as one
    /// launch. A single file is scanned first so mates stay adjacent and no record is lost
    /// (``PortableStoragePlan/SingleFileClumpPlan``). A mixed file is split, each half clumped and deleted, the halves
    /// joined in place and compressed. A single file's output is then counted against the scan.
    package func clumpify(
        _ run: ClumpifyRun,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [Launcher.Record] {
        let inputFile = run.inputs[0]
        let inputFile2 = run.inputs.count > 1 ? run.inputs[1] : nil
        // A run with no deadline has no limit. The Mac launcher gives it the limit of the run when a person set one.
        let timeoutSeconds = run.deadlineSeconds ?? .infinity

        // Override any JAVA_TOOL_OPTIONS that might constrain heap below our calculated value.
        // BBTools reads -Xmx from its own args, but _JAVA_OPTIONS takes highest priority.
        var environment = run.environment
        environment["_JAVA_OPTIONS"] = "-Xmx\(run.heapGB)g"
        let fm = FileManager.default

        func arguments(_ input: URL, _ output: URL, interleaved: Bool, input2: URL? = nil) -> [String] {
            PortableStoragePlan.clumpifyArguments(
                input: input,
                input2: input2,
                output: output,
                interleaved: interleaved,
                heapGB: run.heapGB,
                threads: run.threads,
                qualityBinning: run.qualityBinning
            )
        }
        // A launch that writes the stored gzip itself runs right after the writer probe when the caller asks for it,
        // so the probe's result lands on that launch's record. A mixed file's halves are written plain and then
        // compressed, so their launches run no probe (ARCH N3 condition 2).
        func clumpifyOnce(
            _ args: [String], inputs: [URL], output: URL, writesStoredGzip: Bool = false
        ) async throws -> Launcher.Record {
            var probe: PortableBBToolsWriterProbe?
            if writesStoredGzip, run.probesWriter, let level = Self.compressionLevel(of: args) {
                probe = try await probeBBToolsWriter(environment: environment, compressionLevel: level, threads: run.threads)
            }
            return try await launchClumpify(
                arguments: args, inputs: inputs, output: output, workingDirectory: run.workingDirectory,
                environment: environment, timeout: timeoutSeconds, writerProbe: probe
            )
        }

        if let inputFile2 {
            progress(0.05, "Launching bbtools clumpify.sh...")
            return [try await clumpifyOnce(
                arguments(inputFile, run.output, interleaved: true, input2: inputFile2),
                inputs: [inputFile, inputFile2], output: run.output, writesStoredGzip: true
            )]
        }

        progress(0.02, "Checking which reads are mates...")
        let childLauncher = self.childLauncher
        let counts = try await PortableStorageChecks.detachedWork {
            try FASTQPairInterleaver.countMixed(interleaved: inputFile, launcher: childLauncher)
        }
        let expectedRecords = counts.pairs * 2 + counts.unpaired
        let plan = PortableStoragePlan.singleFileClumpPlan(for: counts)
        log("Clumpify plan \(String(describing: plan)): \(counts.pairs) mate pairs, \(counts.unpaired) unpaired reads")

        var records: [Launcher.Record] = []
        switch plan {
        case .unpaired, .interleaved:
            progress(0.05, "Launching bbtools clumpify.sh...")
            records.append(try await clumpifyOnce(
                arguments(inputFile, run.output, interleaved: plan == .interleaved),
                inputs: [inputFile], output: run.output, writesStoredGzip: true
            ))
        case .splitMixed:
            // Partition by name so each half gets the right flag, clump each,
            // then compress the concatenation as one stream.
            progress(0.04, "Separating mate pairs from unpaired reads...")
            let halves = try await PortableStorageChecks.splitMixedByMate(
                inputFile, counts: counts, in: run.workingDirectory, scratchPrefix: ".clumpify-split",
                launcher: childLauncher
            )
            let scratch = halves.scratch
            defer { try? fm.removeItem(at: scratch) }
            let pairsURL = halves.pairs
            let unpairedURL = halves.unpaired

            let clumpedPairs = scratch.appendingPathComponent("pairs.clumped.fastq")
            let clumpedUnpaired = scratch.appendingPathComponent("unpaired.clumped.fastq")
            progress(0.1, "Launching bbtools clumpify.sh on mate pairs...")
            records.append(try await clumpifyOnce(
                arguments(pairsURL, clumpedPairs, interleaved: true), inputs: [pairsURL], output: clumpedPairs
            ))
            // Each half goes once it is clumped, and the clumped unpaired
            // reads join the end of the clumped pairs in place, so scratch
            // never holds the split, both clumped halves and their join at
            // once (F9 re-review N4).
            try? fm.removeItem(at: pairsURL)
            progress(0.5, "Launching bbtools clumpify.sh on unpaired reads...")
            records.append(try await clumpifyOnce(
                arguments(unpairedURL, clumpedUnpaired, interleaved: false), inputs: [unpairedURL],
                output: clumpedUnpaired
            ))
            try? fm.removeItem(at: unpairedURL)
            let combined = scratch.appendingPathComponent("combined.fastq")
            try PortableFileJoin.appendAndRename(clumpedUnpaired, to: clumpedPairs, as: combined)
            records.append(try await compress(
                input: combined,
                output: run.output,
                compressor: run.compressor,
                threads: run.threads,
                timeout: run.deadlineSeconds,
                progress: { fraction, msg in progress(0.8 + fraction * 0.2, msg) }
            ))
        }

        progress(0.95, "Verifying read count...")
        try await PortableStorageChecks.verifyStoredRecordCount(
            in: run.output, expected: expectedRecords, tool: "clumpify.sh", launcher: childLauncher
        )
        return records
    }

    /// Runs one `clumpify.sh` launch and records it. The out-of-memory status is checked before success, so a JVM
    /// that ran out of heap is never reported as a plain failure.
    private func launchClumpify(
        arguments args: [String],
        inputs: [URL],
        output: URL,
        workingDirectory: URL,
        environment: [String: String],
        timeout: Double,
        writerProbe: PortableBBToolsWriterProbe? = nil
    ) async throws -> Launcher.Record {
        let executable = try await launcher.executableURL(for: .clumpify)
        let launch = PortableToolLaunch(
            tool: .clumpify, arguments: args, workingDirectory: workingDirectory, environment: environment,
            timeout: timeout
        )
        let outcome = try await launcher.run(launch)
        if BBToolsOutOfMemory.isOutOfMemory(exitCode: outcome.exitCode) {
            throw PortableStorageError.outOfMemory(tool: "clumpify.sh", arguments: args)
        }
        guard outcome.isSuccess else {
            let stderr = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
            throw PortableStorageError.storageFailed(
                String(stderr.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw PortableStorageError.storageFailed("clumpify.sh completed without producing output")
        }
        return await launcher.record(PortableToolRun(
            launch: launch, executableURL: executable, outcome: outcome, inputs: inputs, outputs: [output],
            writerProbe: writerProbe
        ))
    }

    /// Compresses `input` into `output` with the named compressor at its default level and records the launch. A nil
    /// `timeout` nil is no limit, and the Mac launcher then gives the compressor the limit of the run when a person set one.
    package func compress(
        input: URL,
        output: URL,
        compressor: PortableCompressor?,
        threads: Int,
        timeout: Double? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Launcher.Record {
        guard let compressor else { throw PortableStorageError.compressorNotFound }
        let args = compressor.arguments(threads: threads, input: input)
        let timeoutSeconds = timeout ?? .infinity

        progress(0.1, "Compressing with \(compressor.rawValue)...")

        let executable = try await launcher.executableURL(for: compressor.tool)
        let launch = PortableToolLaunch(
            tool: compressor.tool, arguments: args, timeout: timeoutSeconds, standardOutput: output
        )
        let outcome = try await launcher.run(launch)
        guard outcome.isSuccess else {
            throw PortableStorageError.compressionFailed(
                String(outcome.stderr.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        progress(1.0, "Compression complete")
        return await launcher.record(PortableToolRun(
            launch: launch, executableURL: executable, outcome: outcome, inputs: [input], outputs: [output]
        ))
    }
}
