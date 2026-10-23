// ReadCommand.swift - lungfish-executor read-fastq, one FASTQ read through the portable reader and the launcher (lane K3B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import LungfishPortable
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lungfish-executor read-fastq`, one plain or gzip FASTQ read through the portable reader and ``ExecutorChildLauncher``.
///
/// Grammar: `lungfish-executor read-fastq [--decompressor <absolute program>] [--grace <seconds>] [--stream-out <file>]
/// <file>`. With `--decompressor` a gzip file is read through that program's `-dc`, the image's `pigz`, and without it
/// through `/usr/bin/gzip -dc`, the Mac's route. It prints one JSON report on stdout: the records `countRecords` counts,
/// the bases with their Q20 and Q30 counts, the stream's SHA-256 when `--stream-out` keeps the stream, the decompressor's
/// version line and how each child ended. The decompression tests run it where no XCTest exists, a CHTC node among them.
/// The reader runs on a thread of its own, the step's reader thread, while `main` waits. Exit codes are `ExecutorExitCode`.
enum ReadCommand {
    static let usage = "usage: lungfish-executor read-fastq [--decompressor <program>] [--grace <seconds>] [--stream-out <file>] <file>\n"

    struct Options: Equatable, Sendable {
        var decompressor: String?
        var grace = StepCommand.defaultGraceSeconds
        var streamOut: String?
        var file = ""
    }

    /// What one read gave.
    struct Counts: Equatable, Sendable {
        var records = 0
        var bases = 0
        var q20Bases = 0
        var q30Bases = 0
        var streamBytes = 0
        var streamSHA256: String?
    }

    struct Report: Codable, Equatable, Sendable {
        var executorVersion = ExecutorCommand.version
        var file: String
        /// The absolute program that decompresses a gzip input.
        var decompressor: String
        var decompressorVersion: String?
        /// `succeeded`, `failed`, `interrupted` or `refused`.
        var outcome = "refused"
        var reason: String?
        var exitCode = ExecutorExitCode.refused
        var signal: Int32?
        var records: Int?
        var bases: Int?
        var q20Bases: Int?
        var q30Bases: Int?
        var streamBytes: Int?
        var streamSHA256: String?
        var children: [ReaderChildEnd] = []
        var stoppedProcesses: [Int32] = []
        var escalatedToSIGKILL = false
        var orphanSweep: String
        var wallSeconds = 0.0
    }

    struct ReadFailure: Error, Equatable, Sendable {
        let reason: String
    }

    /// The reader thread's result, handed to `main`.
    private final class Outcome: Sendable {
        private let value = Mutex<(version: String?, result: Result<Counts, ReadFailure>?)>((nil, nil))

        func set(version: String?) { value.withLock { $0.version = version } }
        func set(result: Result<Counts, ReadFailure>) { value.withLock { $0.result = result } }
        var current: (version: String?, result: Result<Counts, ReadFailure>?) { value.withLock { $0 } }
    }

    static func parse(_ arguments: [String]) -> Result<Options, StepCommand.UsageError> {
        var options = Options()
        var files: [String] = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--decompressor", "--grace", "--stream-out"].contains(flag) else {
                if flag.hasPrefix("--") { return .failure("unknown option \(flag)") }
                files.append(flag)
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { return .failure("\(flag) needs a value") }
            let value = arguments[index + 1]
            index += 2
            switch flag {
            case "--decompressor": options.decompressor = value
            case "--grace":
                guard let seconds = Double(value), seconds.isFinite else { return .failure("--grace needs a number") }
                options.grace = seconds
            default: options.streamOut = value
            }
        }
        guard files.count == 1 else { return .failure("read-fastq takes one FASTQ file") }
        options.file = files[0]
        return .success(options)
    }

    /// Reads `url` through `launcher` twice, once for `FASTQPairInterleaver.countRecords` and once by chunk for the bases,
    /// their qualities and the stream, which goes to `streamOut` when given and is then hashed.
    static func inspect(_ url: URL, launcher: any PortableChildLauncher, streamOut: String? = nil) throws -> Counts {
        var counts = Counts()
        counts.records = try FASTQPairInterleaver.countRecords(in: url, launcher: launcher)
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }
        let sink = try streamOut.map { path throws(ExecutorSpawn.Failure) in try ExecutorSpawn.openForWriting(path) }
        defer { sink.map { _ = close($0) } }
        var line = 0
        while let chunk = try reader.readChunk() {
            counts.streamBytes += chunk.count
            if let sink, !writeAll(sink, Data(chunk)) {
                throw ReadFailure(reason: "Could not write the stream to \(streamOut ?? "").")
            }
            for byte in chunk {
                if byte == 0x0A {
                    line &+= 1
                } else if line & 3 == 3 && byte != 0x0D {
                    counts.bases += 1
                    if byte >= 53 { counts.q20Bases += 1 }
                    if byte >= 63 { counts.q30Bases += 1 }
                }
            }
        }
        if let streamOut {
            counts.streamSHA256 = try PortableDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: streamOut))
        }
        return counts
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? ReadFailure { return failure.reason }
        if let failure = error as? ExecutorSpawn.Failure { return failure.reason }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Runs the mode. Called from `main` after the termination signals are blocked and before any thread exists.
    static func main(_ arguments: [String]) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            FileHandle.standardError.write(Data("lungfish-executor: \(error.message)\n\(usage)".utf8))
            return ExecutorExitCode.usage
        }
        let started = ContinuousClock.now
        // Before any thread or child exists, as in step mode (tally-r2 K3-1).
        let subreaper = ChildSubreaper.setAndConfirm()
        let program = options.decompressor ?? "/usr/bin/gzip"
        var report = Report(file: options.file, decompressor: program, orphanSweep: subreaper.isSet ? "subreaper" : "parentWalkOnly")
        if let reason = StepCommand.refusal(StepCommand.Options(grace: options.grace, program: [program]), subreaper: subreaper) {
            report.reason = reason
            return finish(report)
        }

        ExecutorSignals.ignoreBrokenPipe()
        ExecutorSpawn.markInheritedDescriptorsCloseOnExec()
        let controller = StepController()
        let sources = ExecutorSignals.watch(queue: DispatchQueue(label: "lungfish-executor.signals")) { signal in
            controller.interrupt(signal)
        }
        let log = ReaderChildLog()
        let launcher = ExecutorChildLauncher(
            controller: controller, decompressor: options.decompressor, graceSeconds: options.grace, log: log
        )
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            if let decompressor = options.decompressor {
                outcome.set(version: launcher.versionLine(of: decompressor))
            }
            let result = Result { try inspect(URL(fileURLWithPath: options.file), launcher: launcher, streamOut: options.streamOut) }
            outcome.set(result: result.mapError { ReadFailure(reason: describe($0)) })
            done.signal()
        }
        reader.name = "lungfish-executor reader"
        reader.start()
        withExtendedLifetime(sources) { done.wait() }

        // The end-of-step check: anything left under the executor or in a tracked group fails the run.
        var leftovers = StepResult()
        let lingering = !controller.liveCandidates().isEmpty
        if lingering {
            controller.stopTree(grace: options.grace, into: &leftovers)
        }
        controller.reapAdoptedOrphans()
        let (version, result) = outcome.current
        report.decompressorVersion = version
        report.children = log.all
        report.stoppedProcesses = leftovers.stoppedProcesses
        report.escalatedToSIGKILL = leftovers.escalatedToSIGKILL || report.children.contains { $0.escalatedToSIGKILL }
        if let signal = controller.interruptSignal {
            report.outcome = "interrupted"
            report.exitCode = ExecutorExitCode.interrupted
            report.signal = signal
            report.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        } else if lingering || report.children.contains(where: { $0.drainExpired }) {
            report.outcome = "failed"
            report.exitCode = ExecutorExitCode.failed
            report.reason = StepReason.lingeringProcess
        } else if case .failure(let failure)? = result {
            report.outcome = "failed"
            report.exitCode = ExecutorExitCode.failed
            report.reason = failure.reason
        } else if case .success(let counts)? = result {
            report.outcome = "succeeded"
            report.exitCode = ExecutorExitCode.succeeded
            report.records = counts.records
            report.bases = counts.bases
            report.q20Bases = counts.q20Bases
            report.q30Bases = counts.q30Bases
            report.streamBytes = counts.streamBytes
            report.streamSHA256 = counts.streamSHA256
        }
        report.wallSeconds = StepController.seconds(since: started)
        return finish(report)
    }

    private static func finish(_ report: Report) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else {
            FileHandle.standardError.write(Data("lungfish-executor: the report could not be encoded\n".utf8))
            return ExecutorExitCode.failed
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        if let reason = report.reason {
            FileHandle.standardError.write(Data("lungfish-executor: \(report.outcome): \(reason)\n".utf8))
        }
        return report.exitCode
    }
}
