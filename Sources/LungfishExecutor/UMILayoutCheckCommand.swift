// UMILayoutCheckCommand.swift - lungfish-executor umi-layout-check, the UMI layout check of a UMI chain as a child of
// the executor (Phase 5.3 lane EX-UMI, ARCH-UMI-CHECKER)
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

/// `lungfish-executor umi-layout-check`, run by a `tool` step the plan pins to its own executor build. It parses the argv
/// into ``UMILayoutCheck/Arguments``, finds the decompressor the argv names by its pinned id on the step's `PATH`, reads
/// the pairs through ``ExecutorChildLauncher`` on a reader thread, as `read-fastq` does, and writes
/// ``UMILayoutCheck/Report`` as the step's `home` file. The rule lives in `UMILayoutCheck` alone. Its words go to standard
/// error, so a failed step's record carries them. A pass or a warning exits 0, a failure `failed`, a signal
/// `interrupted`, and a missing or bad flag `usage` with the usage. Every path is relative to the working directory, the
/// work root.
enum UMILayoutCheckCommand {
    /// The reader thread's result, handed to `main`.
    private final class Outcome: Sendable {
        private let value = Mutex<Result<UMILayoutCheck.Counts, ReadCommand.ReadFailure>?>(nil)

        func set(_ result: Result<UMILayoutCheck.Counts, ReadCommand.ReadFailure>) { value.withLock { $0 = result } }
        var current: Result<UMILayoutCheck.Counts, ReadCommand.ReadFailure>? { value.withLock { $0 } }
    }

    /// The first regular executable file named `id` in a folder of `path`, the step's `PATH`, whose folders are absolute.
    static func program(named id: String, path: String?) -> String? {
        for folder in (path ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let candidate = "\(folder)/\(id)"
            var info = stat()
            if stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }

    /// Runs the mode. Called from `main` after the termination signals are blocked and before any thread exists.
    static func main(_ arguments: [String]) -> Int32 {
        let check: UMILayoutCheck.Arguments
        do {
            check = try UMILayoutCheck.Arguments(argv: arguments)
        } catch {
            let message = (error as? UMILayoutCheck.UsageError)?.message ?? String(describing: error)
            RunCommand.say("lungfish-executor: \(message)\n\(UMILayoutCheck.usage)")
            return ExecutorExitCode.usage
        }
        guard let decompressor = program(named: check.decompressor, path: ProcessInfo.processInfo.environment["PATH"]) else {
            RunCommand.say("UMI layout check failed: the decompressor \(check.decompressor), which the plan pins, is not on the "
                + "step's PATH. This sample gets no UMI counts.\n")
            return ExecutorExitCode.failed
        }
        let grace = StepCommand.defaultGraceSeconds
        // Before any thread or child exists, as in step mode (tally-r2 K3-1).
        let subreaper = ChildSubreaper.setAndConfirm()
        if let reason = StepCommand.refusal(StepCommand.Options(grace: grace, program: [decompressor]), subreaper: subreaper) {
            RunCommand.say("lungfish-executor: refused: \(reason)\n")
            return ExecutorExitCode.refused
        }

        ExecutorSignals.ignoreBrokenPipe()
        let controller = StepController()
        let sources = ExecutorSignals.watch(queue: DispatchQueue(label: "lungfish-executor.signals")) { signal in
            controller.interrupt(signal)
        }
        // The check starts no program but the decompressor the plan pins (ARCH-UMI-CHECKER item 5).
        let launcher = ExecutorChildLauncher(
            controller: controller, decompressor: decompressor, allowedPrograms: [decompressor], graceSeconds: grace
        )
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            let result = Result {
                try UMILayoutCheck.measure(
                    check, read1: root.appendingPathComponent(check.read1), read2: root.appendingPathComponent(check.read2),
                    launcher: launcher)
            }
            outcome.set(result.mapError { ReadCommand.ReadFailure(reason: ReadCommand.describe($0)) })
            done.signal()
        }
        reader.name = "lungfish-executor umi-layout-check"
        reader.start()
        withExtendedLifetime(sources) { done.wait() }

        // The end-of-step check: anything left under the executor or in a tracked group fails the check.
        var leftovers = StepResult()
        let lingering = !controller.liveCandidates().isEmpty
        if lingering {
            controller.stopTree(grace: grace, into: &leftovers)
        }
        controller.reapAdoptedOrphans()
        if let signal = controller.interruptSignal {
            RunCommand.say("lungfish-executor: interrupted: The executor received \(ExecutorSignals.name(signal)) and stopped the check.\n")
            return ExecutorExitCode.interrupted
        }
        if lingering {
            RunCommand.say("lungfish-executor: failed: \(StepReason.lingeringProcess)\n")
            return ExecutorExitCode.failed
        }
        switch outcome.current {
        case .success(let counts)?:
            return finish(UMILayoutCheck.Report(counts: counts, arguments: check), output: root.appendingPathComponent(check.output))
        case .failure(let failure)?:
            RunCommand.say("UMI layout check failed: \(failure.reason) This sample gets no UMI counts.\n")
            return ExecutorExitCode.failed
        case nil:
            return ExecutorExitCode.failed
        }
    }

    /// Writes the report as the `home` file, then its words, and returns 0 for a pass or a warning.
    static func finish(_ report: UMILayoutCheck.Report, output: URL) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (encoder.encode(report) + Data("\n".utf8)).write(to: output)
        } catch {
            RunCommand.say("UMI layout check failed: the check could not write its report. \(ReadCommand.describe(error)) "
                + "This sample gets no UMI counts.\n")
            return ExecutorExitCode.failed
        }
        RunCommand.say(report.words + "\n")
        return report.verdict == .failed ? ExecutorExitCode.failed : ExecutorExitCode.succeeded
    }
}
