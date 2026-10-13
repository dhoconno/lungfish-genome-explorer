// RouteParityHarness+Launch.swift - How a side runs: the built CLI, a rebased command, standard output in process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30.
//
// - `runCLI` launches the built `lungfish-cli` through `CLIProcessLauncher`, the launch every CLI
//   route of the app uses, with the app's subprocess environment, grace and drain, and cancels it
//   the way the app's Cancel does when asked (RouteParityHarness+Cancel.swift). Side C' runs each
//   line of the recorded command this way, and a family's side C may too.
// - `rebased` is the rebase of docs/contracts/CLI-EQUIVALENCE.md, the same rule as
//   `RecordedCLICommand.rebased` in LungfishAppTests, which RouteParityHarnessReplayTests pins.
// - `capturingStandardOutput` runs a command in this process with its standard output in a file,
//   as the Kraken2 executor case of ClassifierReadSetParityTests reads the events a
//   `kraken2 classify --format json` prints (lane F3, moved here by Q30).

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension RouteParityHarness {
    /// Why a recorded command does not become a replay.
    public enum ReplayError: Error, Equatable, CustomStringConvertible {
        case notALungfishCLICommand(String)
        case argumentOutsideRoot(argument: String, root: String)
        case nothingRebased(root: String)

        public var description: String {
            switch self {
            case .notALungfishCLICommand(let line):
                return "The line does not start with \(CLICommandIdentity.executableName): \(line)"
            case .argumentOutsideRoot(let argument, let root):
                return "The argument \(argument) names \(root) but does not start with it."
            case .nothingRebased(let root):
                return "No argument of the recorded command starts with \(root)."
            }
        }
    }

    /// One run of the built CLI through the real transport.
    public struct CLIRun: Sendable {
        /// The exit status, or nil when the CLI did not run or was stopped before it exited.
        public let status: Int32?
        public let end: RouteParityEnd
        /// The exit, with the end of standard error for a failure.
        public let detail: String
        public let stdout: String
        public let stderr: String
        /// What the cancel observed, when `runCLI` cancelled the run.
        public let cancel: RouteParityCancelObservation?
    }

    /// Runs the built CLI at `binary` with `arguments` through `CLIProcessLauncher`, with the
    /// grace and drain every GUI route gives it and `environment` laid over the app's subprocess
    /// environment, and stops it as failed after `timeout`. Standard output is kept, and a warning
    /// event on it makes a clean exit complete with warnings. With `cancelWhen`, the run is
    /// cancelled the way the app's Cancel reaches a CLI route once `cancelWhen` holds, read every
    /// 20 ms for up to 30 seconds (RouteParityHarness+Cancel.swift).
    public static func runCLI(
        _ binary: URL,
        arguments: [String],
        timeout: Duration,
        environment: [String: String] = [:],
        cancelWhen isReached: (@Sendable () -> Bool)? = nil
    ) async -> CLIRun {
        var spec = CLIProcessLauncher.spec(
            executableURL: binary,
            arguments: arguments,
            standardOutput: .captured,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain
        )
        spec.timeout = timeout
        spec.environment.merge(environment) { _, override in override }
        let cancellation = CLIRunCancellation()
        let ended = RunEnd()
        let watch = isReached.map { cancelOnce(cancellation, when: $0, unless: ended) }
        let outcome = await CLIProcessLauncher.run(spec, cancellation: cancellation)
        let endedAt = ContinuousClock.now
        ended.set()
        let sent = await watch?.value
        func observed(_ status: Int32?) -> RouteParityCancelObservation? {
            sent.map { RouteParityCancelObservation(status: status, elapsed: endedAt - $0.sent, tree: $0.tree) }
        }
        switch outcome {
        case .exited(let exit):
            var end = RouteParityEnd.ofExit(exit.status, warned: warned(exit.stdout))
            if exit.incompleteOutput != nil, end != .cancelled { end = .failed }
            let detail = end == .failed ? "exit \(exit.status): \(tail(exit.failureDetail))" : "exit \(exit.status)"
            return CLIRun(
                status: exit.status, end: end, detail: detail, stdout: exit.stdout, stderr: exit.stderr, cancel: observed(exit.status)
            )
        case .cancelled(let exit):
            let detail = exit.map { "cancelled, exit \($0.status)" } ?? "cancelled before launch"
            return CLIRun(
                status: exit?.status, end: .cancelled, detail: detail, stdout: exit?.stdout ?? "", stderr: exit?.stderr ?? "",
                cancel: observed(exit?.status)
            )
        case .launchFailed(let reason):
            return CLIRun(status: nil, end: .failed, detail: "no exit: \(reason)", stdout: "", stderr: "", cancel: nil)
        }
    }

    /// Whether `stdout` holds a `log` event at level `warning`.
    static func warned(_ stdout: String) -> Bool {
        let decoder = CLIEventLineDecoder()
        return stdout.split(separator: "\n").contains { line in
            guard case .log(let level, _)? = (try? decoder.decodeLine(String(line)))?.event else { return false }
            return level == .warning
        }
    }

    /// The last 20 lines of `text`.
    static func tail(_ text: String) -> String {
        text.components(separatedBy: "\n").suffix(20).joined(separator: "\n")
    }

    // MARK: - The recorded command

    /// The arguments after `lungfish-cli` of one line of a recorded command.
    public static func arguments(ofLine line: String) throws -> [String] {
        let words = try AdvancedCommandLineOptions.parse(line)
        guard words.first == CLICommandIdentity.executableName else {
            throw ReplayError.notALungfishCLICommand(line)
        }
        return Array(words.dropFirst())
    }

    /// Rewrites every argument of `command` that starts with `rootA` so it starts with `rootB`,
    /// line by line, and quotes the result as `OperationCenter.buildCLICommand` does. An argument
    /// that names `rootA` anywhere but at its start throws, because the replay would then read or
    /// write the first run's files, and so does a command with no argument under `rootA`, whose
    /// replay would compare a run with itself.
    public static func rebased(_ command: String, from rootA: URL, to rootB: URL) throws -> String {
        let spellingsA = rootSpellings(rootA)
        let pathB = rootB.standardizedFileURL.path
        var replaced = 0
        let lines = try command.components(separatedBy: "\n").map { line -> String in
            let rebasedWords = try arguments(ofLine: line).map { word -> String in
                if let spelling = spellingsA.first(where: { word == $0 || word.hasPrefix($0 + "/") }) {
                    replaced += 1
                    return pathB + word.dropFirst(spelling.count)
                }
                if let spelling = spellingsA.first(where: { word.contains($0 + "/") || word.hasSuffix($0) }) {
                    throw ReplayError.argumentOutsideRoot(argument: word, root: spelling)
                }
                return word
            }
            return OperationCenter.buildCLICommand(subcommand: "", args: rebasedWords)
        }
        guard replaced > 0 else { throw ReplayError.nothingRebased(root: rootA.path) }
        return lines.joined(separator: "\n")
    }

    /// Every spelling of a temporary root, longest first. Foundation drops a leading `/private`
    /// from `/private/var` and `/private/tmp` when it standardizes a path, so a recorded command
    /// may carry either form.
    static func rootSpellings(_ root: URL) -> [String] {
        var forms: Set<String> = [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        for form in forms {
            if form.hasPrefix("/private/") {
                forms.insert(String(form.dropFirst("/private".count)))
            } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                forms.insert("/private" + form)
            }
        }
        return forms
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Standard output in process

    /// The two descriptor calls `capturingStandardOutput` makes, which a test replaces to make
    /// one of them fail.
    public struct DescriptorCalls: Sendable {
        public var dup: @Sendable (Int32) -> Int32
        public var dup2: @Sendable (Int32, Int32) -> Int32

        public init(dup: @escaping @Sendable (Int32) -> Int32, dup2: @escaping @Sendable (Int32, Int32) -> Int32) {
            self.dup = dup
            self.dup2 = dup2
        }

        /// The system's `dup` and `dup2`.
        public static let system = DescriptorCalls(dup: { Darwin.dup($0) }, dup2: { Darwin.dup2($0, $1) })
    }

    /// Why `capturingStandardOutput` could not move standard output to its file or back.
    public enum StandardOutputError: Error, Equatable, CustomStringConvertible {
        /// `dup` could not save standard output, so nothing moved and the body did not run.
        case notSaved
        /// `dup2` could not send standard output to the file. It was put back, and the body did not run.
        case notMoved
        /// `dup2` could not put standard output back after the body ran, so it still goes to the file.
        case notRestored

        public var description: String {
            switch self {
            case .notSaved: return "dup could not save standard output, so the command did not run."
            case .notMoved: return "dup2 could not send standard output to the events file, so the command did not run."
            case .notRestored: return "dup2 could not put standard output back, so it still goes to the events file."
            }
        }
    }

    /// Runs `body` with this process's standard output sent to a new file in `folder`, puts
    /// standard output back, and returns what `body` returned with the lines it printed. An error
    /// `body` throws is thrown once standard output is back. Each descriptor call is checked
    /// (2.8 Q4). A failed `dup` throws before `body` runs, a failed move puts standard output back
    /// and throws before `body` runs, and a failed restore throws ``StandardOutputError/notRestored``
    /// whatever `body` did.
    public static func capturingStandardOutput<Value>(
        in folder: URL,
        descriptors: DescriptorCalls = .system,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async throws -> (value: Value, lines: [String]) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("events-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(stdout)
        let savedStdout = descriptors.dup(STDOUT_FILENO)
        guard savedStdout >= 0 else {
            try? handle.close()
            throw StandardOutputError.notSaved
        }
        guard descriptors.dup2(handle.fileDescriptor, STDOUT_FILENO) >= 0 else {
            _ = descriptors.dup2(savedStdout, STDOUT_FILENO)
            close(savedStdout)
            try? handle.close()
            throw StandardOutputError.notMoved
        }
        let result: Result<Value, any Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        fflush(stdout)
        let restored = descriptors.dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try handle.close()
        guard restored >= 0 else { throw StandardOutputError.notRestored }
        let value = try result.get()
        let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        return (value, lines)
    }
}
