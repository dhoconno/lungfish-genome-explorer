// FastpPairedRunner.swift - Runs fastp so that interleaved mates stay together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The four fastp trims used to hand fastp one file with -i/-o, so fastp
// judged every record on its own. A read that --cut_right trimmed to
// nothing was discarded even with --disable_length_filtering (fastp fails
// a zero-length read before any filter switch applies), its mate stayed,
// and from that record on every positional pair of the interleaved output
// was wrong. Measured with the managed fastp 1.3.6 on the HG002 chr20
// fixture (91,148 reads): 250 reads vanished (240 orphaned mates plus 5
// whole pairs), and 21,895 of 45,449 positional pairs of the output were
// mismatched. fastp's paired mode keeps or drops both mates together and
// trims adapters by overlap analysis, which single-end mode cannot do (656
// reads on the same fixture carried adapters that single-end auto-detection
// missed).
//
// The window's in-process trims (import recipes, batch derivatives) took a
// third route, `--interleaved_in` with a reformat.sh re-interleave, which
// cannot detect read 2 adapters and kept 90,622 reads where the CLI kept
// 90,556. This runner is now the one implementation behind
// `lungfish-cli fastq trim` and the window alike; it lives in
// LungfishWorkflow so both can call it.
//
// The layout is decided from the records by NAME
// (FASTQPairInterleaver.countMixed), never guessed from the first names.
// Paired input is partitioned by name into R1, R2, and unpaired reads in
// one pass (a strictly interleaved file leaves the unpaired stream empty),
// fastp runs `-i R1 -I R2 -o out1 -O out2` on the pairs (which also lets
// `--detect_adapter_for_pe` work, since fastp cannot detect read 2
// adapters from an --interleaved_in file), the unpaired reads of a mixed
// file run single-end, and the outputs are interleaved again with the
// unpaired reads appended. `--pairing single` runs every record alone.

import Foundation
import LungfishCore
import LungfishIO

/// How one fastp trim runs on its single input.
public enum FastpReadLayoutPlan: Equatable, Sendable {
    /// Every record on its own: `fastp -i in -o out`.
    case singleEnd
    /// Every record is followed by its mate: the file is split into R1/R2,
    /// fastp runs paired, and its two outputs are interleaved again.
    case interleaved(pairs: Int)
    /// Adjacent pairs mixed with unpaired reads: the pairs run as
    /// ``interleaved(pairs:)`` and the unpaired reads as ``singleEnd``, and
    /// the output holds the trimmed pairs followed by the trimmed unpaired
    /// reads.
    case splitMixed(pairs: Int, unpaired: Int)

    /// Whether fastp runs in its paired mode for any part of the input.
    public var isPaired: Bool {
        if case .singleEnd = self { return false }
        return true
    }

    /// Provenance value for the plan.
    public var provenanceValue: ParameterValue {
        switch self {
        case .singleEnd: return .string("single_end")
        case .interleaved: return .string("interleaved")
        case .splitMixed: return .string("split_mixed")
        }
    }

    /// Decides the plan for `inputURL` from a resolved pairing.
    ///
    /// A decision that is not pair-aware (an explicit `--pairing single`,
    /// or a file whose records do not alternate) runs single-end without
    /// reading the file. Otherwise every record is scanned by name, so a
    /// recorded `interleaved` over a file that has lost its pairing still
    /// runs safely.
    public static func resolve(inputURL: URL, decision: FASTQPairingDecision) throws -> FastpReadLayoutPlan {
        try resolve(inputURL: inputURL, pairAware: decision.pairAware)
    }

    /// Decides the plan for `inputURL`: single-end when the caller does not
    /// pair, otherwise from a by-name scan of every record.
    public static func resolve(inputURL: URL, pairAware: Bool) throws -> FastpReadLayoutPlan {
        guard pairAware else { return .singleEnd }
        return plan(for: try FASTQPairInterleaver.countMixed(interleaved: inputURL))
    }

    public static func plan(for counts: FASTQPairInterleaver.MixedCounts) -> FastpReadLayoutPlan {
        if counts.pairs == 0 { return .singleEnd }
        if counts.unpaired == 0 { return .interleaved(pairs: counts.pairs) }
        return .splitMixed(pairs: counts.pairs, unpaired: counts.unpaired)
    }

    /// The counts the by-name partition of the input must reproduce.
    public var expectedCounts: FASTQPairInterleaver.MixedCounts? {
        switch self {
        case .singleEnd: return nil
        case .interleaved(let pairs): return .init(pairs: pairs, unpaired: 0)
        case .splitMixed(let pairs, let unpaired): return .init(pairs: pairs, unpaired: unpaired)
        }
    }
}

/// What a fastp trim records after ``FastpPairedRunner/run``.
public struct FastpPairedRunOutcome: Sendable {
    public let plan: FastpReadLayoutPlan
    /// The first fastp run (the paired run when there is one).
    public let result: NativeToolResult
    /// The argv of that run, without the executable.
    public let nativeArguments: [String]
    /// Provenance step ID of that run, so the extra steps can depend on it.
    public let stepID: UUID
    /// The files that run read and wrote, when they differ from the
    /// operation's own input and output.
    public let stepInputs: [FileRecord]?
    public let stepOutputs: [FileRecord]?
    /// The second fastp run (mixed input), the interleave, and the gzip, in
    /// dependency order. The sidecar next to the output keeps only the
    /// steps that write the output itself; the run directory's envelope
    /// keeps them all.
    public let extraSteps: [ProvenanceStep]
}

/// A fastp run that did not finish, with the message the caller shows.
public struct FastpPairedRunError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum FastpPairedRunner {
    /// Runs one native tool and returns its result. The window passes a
    /// closure that also records the run for the derivative's provenance.
    public typealias Executor = @Sendable (NativeTool, [String]) async throws -> NativeToolResult

    /// The fastp argv for one run, without the executable: the input and
    /// output flags, then the caller's options.
    ///
    /// - Parameter detectPairedAdapters: add `--detect_adapter_for_pe` to
    ///   a paired run, so paired input gets the adapter auto-detection that
    ///   single-end input gets by default, on top of overlap analysis.
    public static func fastpArguments(
        inputPath: String,
        mateInputPath: String? = nil,
        outputPath: String,
        mateOutputPath: String? = nil,
        options: [String],
        detectPairedAdapters: Bool
    ) -> [String] {
        var args = ["-i", inputPath]
        if let mateInputPath {
            args += ["-I", mateInputPath]
        }
        args += ["-o", outputPath]
        if let mateOutputPath {
            args += ["-O", mateOutputPath]
        }
        if mateInputPath != nil, detectPairedAdapters {
            args.append("--detect_adapter_for_pe")
        }
        return args + options
    }

    /// Runs fastp on `inputURL` according to `plan` and leaves the result
    /// at `outputPath` (gzip-compressed when the path ends in `.gz`, as
    /// fastp itself does for a single-end run).
    ///
    /// - Parameters:
    ///   - options: fastp arguments other than the input and output flags
    ///     (``FastpTrimOptions/options(for:threads:extraArguments:)``).
    ///   - detectPairedAdapters: see ``fastpArguments(inputPath:mateInputPath:outputPath:mateOutputPath:options:detectPairedAdapters:)``.
    ///   - failureLabel: names the operation in the error thrown when fastp
    ///     fails ("fastp combined trim").
    ///   - stepNamePrefix: names the bookkeeping steps in provenance
    ///     ("lungfish fastq trim").
    ///   - runner: the tool runner that reports fastp's version.
    ///   - execute: runs fastp; defaults to `runner`. The window passes its
    ///     provenance-collecting wrapper.
    public static func run(
        inputURL: URL,
        outputPath: String,
        plan: FastpReadLayoutPlan,
        options: [String],
        detectPairedAdapters: Bool,
        failureLabel: String,
        stepNamePrefix: String,
        runner: NativeToolRunner = .shared,
        execute: Executor? = nil
    ) async throws -> FastpPairedRunOutcome {
        let execute: Executor = execute ?? { tool, arguments in
            try await runner.run(tool, arguments: arguments)
        }
        let stepID = UUID()

        guard let expectedCounts = plan.expectedCounts else {
            let args = fastpArguments(
                inputPath: inputURL.path,
                outputPath: outputPath,
                options: options,
                detectPairedAdapters: false
            )
            let result = try await execute(.fastp, args)
            guard result.isSuccess else {
                throw FastpPairedRunError("\(failureLabel) failed: \(result.stderr)")
            }
            return FastpPairedRunOutcome(
                plan: plan, result: result, nativeArguments: args, stepID: stepID,
                stepInputs: nil, stepOutputs: nil, extraSteps: []
            )
        }

        let fm = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)
        let scratch = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".fastp-pairs-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // Partition by name, so fastp's positional pairing only ever sees
        // records that are mates. A strictly interleaved file leaves the
        // unpaired stream empty.
        let r1 = scratch.appendingPathComponent("in_R1.fastq")
        let r2 = scratch.appendingPathComponent("in_R2.fastq")
        let unpaired = scratch.appendingPathComponent("in_unpaired.fastq")
        try await Task.detached(priority: .utility) {
            for url in [r1, r2, unpaired] {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let r1Handle = try FileHandle(forWritingTo: r1)
            defer { try? r1Handle.close() }
            let r2Handle = try FileHandle(forWritingTo: r2)
            defer { try? r2Handle.close() }
            let unpairedHandle = try FileHandle(forWritingTo: unpaired)
            defer { try? unpairedHandle.close() }
            let split = try FASTQPairInterleaver.partitionMixed(
                interleaved: inputURL, r1: r1Handle, r2: r2Handle, unpaired: unpairedHandle
            )
            guard split == expectedCounts else {
                throw FastpPairedRunError(
                    "the pair scan found \(expectedCounts.pairs) pairs and \(expectedCounts.unpaired) unpaired reads, but the split wrote \(split.pairs) and \(split.unpaired)"
                )
            }
        }.value

        // fastp on the pairs: both mates kept or dropped together.
        let out1 = scratch.appendingPathComponent("out_R1.fastq")
        let out2 = scratch.appendingPathComponent("out_R2.fastq")
        let pairedArgs = fastpArguments(
            inputPath: r1.path,
            mateInputPath: r2.path,
            outputPath: out1.path,
            mateOutputPath: out2.path,
            options: options,
            detectPairedAdapters: detectPairedAdapters
        )
        let pairedResult = try await execute(.fastp, pairedArgs)
        guard pairedResult.isSuccess else {
            throw FastpPairedRunError("\(failureLabel) failed on the mate pairs: \(pairedResult.stderr)")
        }
        let stepInputs = [r1, r2].map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) }
        let stepOutputs = [out1, out2].map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }

        var extraSteps: [ProvenanceStep] = []
        var dependencies = [stepID]
        let toolVersion = await runner.getToolVersion(.fastp) ?? "unknown"

        // fastp on the unpaired reads of a mixed file, each on its own.
        var unpairedTrimmed: URL?
        if expectedCounts.unpaired > 0 {
            let trimmed = scratch.appendingPathComponent("out_unpaired.fastq")
            let singleArgs = fastpArguments(
                inputPath: unpaired.path,
                outputPath: trimmed.path,
                options: options,
                detectPairedAdapters: false
            )
            let singleStarted = Date()
            let singleResult = try await execute(.fastp, singleArgs)
            let singleCompleted = Date()
            guard singleResult.isSuccess else {
                throw FastpPairedRunError("\(failureLabel) failed on the unpaired reads: \(singleResult.stderr)")
            }
            let singleStep = ProvenanceStep(
                toolName: NativeTool.fastp.rawValue,
                toolVersion: toolVersion,
                argv: singleResult.arguments.isEmpty ? [NativeTool.fastp.executableName] + singleArgs : singleResult.arguments,
                inputs: [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: unpaired, format: .fastq, role: .input))],
                outputs: [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: trimmed, format: .fastq, role: .output))],
                exitStatus: Int(singleResult.exitCode),
                wallTimeSeconds: singleCompleted.timeIntervalSince(singleStarted),
                stderr: singleResult.stderr.isEmpty ? nil : singleResult.stderr,
                startedAt: singleStarted,
                completedAt: singleCompleted
            )
            extraSteps.append(singleStep)
            dependencies.append(singleStep.id)
            unpairedTrimmed = trimmed
        }

        // Interleave out1/out2 again (and append the unpaired reads) into
        // the plain output, or into a scratch file that gzip then writes.
        let compress = outputPath.lowercased().hasSuffix(".gz")
        let plainTarget = compress ? scratch.appendingPathComponent("interleaved.fastq") : outputURL
        let interleaveStarted = Date()
        let appended = unpairedTrimmed
        let expectedRecords = try await Task.detached(priority: .utility) {
            try Self.writeInterleaved(r1: out1, r2: out2, appending: appended, to: plainTarget)
        }.value
        let interleaveCompleted = Date()
        let written = try await Task.detached(priority: .utility) {
            try FASTQPairInterleaver.countRecords(in: plainTarget)
        }.value
        guard written == expectedRecords else {
            throw FastpPairedRunError(
                "\(failureLabel) wrote \(written) reads where \(expectedRecords) were expected after re-interleaving"
            )
        }
        var interleaveArgv = [CLICommandIdentity.executableName, "fastq", "interleave", "--in1", out1.path, "--in2", out2.path, "-o", plainTarget.path]
        if let unpairedTrimmed {
            interleaveArgv = ["/bin/sh", "-lc", interleaveArgv.map(shellEscape).joined(separator: " ") + " && cat \(shellEscape(unpairedTrimmed.path)) >> \(shellEscape(plainTarget.path))"]
        }
        let interleaveStep = ProvenanceStep(
            toolName: "\(stepNamePrefix) interleave",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: interleaveArgv,
            inputs: ([out1, out2] + (unpairedTrimmed.map { [$0] } ?? [])).map {
                ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input))
            },
            outputs: [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: plainTarget, format: .fastq, role: .output))],
            exitStatus: 0,
            wallTimeSeconds: interleaveCompleted.timeIntervalSince(interleaveStarted),
            dependsOn: dependencies,
            startedAt: interleaveStarted,
            completedAt: interleaveCompleted
        )
        extraSteps.append(interleaveStep)

        if compress {
            let gzip = try gzipCompressFASTQ(
                sourceURL: plainTarget,
                outputURL: outputURL,
                failureDescription: "the re-interleaved reads of"
            )
            let gzipCompleted = Date()
            extraSteps.append(ProvenanceStep(
                toolName: gzip.command.first ?? "/usr/bin/gzip",
                toolVersion: "system",
                argv: gzip.command,
                inputs: [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: plainTarget, format: .fastq, role: .input))],
                outputs: [ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output))],
                exitStatus: Int(gzip.exitCode),
                wallTimeSeconds: gzip.wallTime,
                stderr: gzip.stderr?.isEmpty == false ? gzip.stderr : nil,
                dependsOn: [interleaveStep.id],
                startedAt: gzipCompleted.addingTimeInterval(-gzip.wallTime),
                completedAt: gzipCompleted
            ))
        }

        return FastpPairedRunOutcome(
            plan: plan,
            result: pairedResult,
            nativeArguments: pairedArgs,
            stepID: stepID,
            stepInputs: stepInputs,
            stepOutputs: stepOutputs,
            extraSteps: extraSteps
        )
    }

    /// Interleaves `r1` and `r2` into `target`, then appends every record of
    /// `unpaired`, and returns the record count the target must hold.
    private static func writeInterleaved(r1: URL, r2: URL, appending unpaired: URL?, to target: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        fm.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        let counts = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle)
        var expected = counts.writtenRecords
        if let unpaired {
            expected += try FASTQPairInterleaver.countRecords(in: unpaired)
            let source = try FileHandle(forReadingFrom: unpaired)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
        }
        return expected
    }
}

// MARK: - gzip

/// What `gzipCompressFASTQ` records for provenance.
public struct FASTQGzipProvenanceResult: Sendable {
    public let command: [String]
    public let inputURL: URL
    public let outputURL: URL
    public let exitCode: Int32
    public let wallTime: TimeInterval
    public let stderr: String?
}

/// Writes `sourceURL` gzip-compressed to `outputURL` with the system gzip,
/// replacing any file there.
public func gzipCompressFASTQ(
    sourceURL: URL,
    outputURL: URL,
    failureDescription: String
) throws -> FASTQGzipProvenanceResult {
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }

    let process = Process()
    let command = ["/usr/bin/gzip", "-c", sourceURL.path]
    let stderrPipe = Pipe()
    let startedAt = Date()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = Array(command.dropFirst())
    process.standardOutput = outputHandle
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stderr = String(
        decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    let wallTime = Date().timeIntervalSince(startedAt)
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        throw FastpPairedRunError("gzip failed while compressing \(failureDescription) \(outputURL.path)\(suffix)")
    }
    return FASTQGzipProvenanceResult(
        command: command,
        inputURL: sourceURL,
        outputURL: outputURL,
        exitCode: process.terminationStatus,
        wallTime: wallTime,
        stderr: stderr
    )
}
