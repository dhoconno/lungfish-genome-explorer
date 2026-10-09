// CLIProcessLauncher.swift - Builds the one lungfish-cli ToolProcessSpec and maps its outcome once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// How one `lungfish-cli` run ended, mapped the same way for every runner.
public enum CLIProcessOutcome: Sendable {
    /// lungfish-cli could not be launched, for this reason.
    case launchFailed(reason: String)
    /// A cancel was asked for before or during the run. The exit is nil when
    /// the cancel came before the launch, so nothing ran.
    case cancelled(CLIProcessExit?)
    /// The run ended with no cancel asked for.
    case exited(CLIProcessExit)
}

/// The exit of a `lungfish-cli` process and what it wrote.
public struct CLIProcessExit: Sendable, Equatable {
    /// The exit code, or the signal number when a signal ended the CLI.
    public let status: Int32
    /// Captured standard output as UTF-8, with invalid bytes replaced. Empty
    /// when the run streamed event lines without keeping them.
    public let stdout: String
    /// Captured standard error as UTF-8, with invalid bytes replaced.
    public let stderr: String
    /// Why the output cannot be trusted, or nil when it is complete.
    public let incompleteOutput: String?

    public init(status: Int32, stdout: String, stderr: String, incompleteOutput: String?) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.incompleteOutput = incompleteOutput
    }

    init(_ result: ToolProcessResult) {
        self.init(
            status: result.status,
            stdout: result.stdoutText,
            stderr: result.stderrText,
            // A run that ToolProcess stopped on purpose is cut short by
            // design, so its output is not reported as incomplete.
            incompleteOutput: result.stop == nil ? result.incompleteOutputReason : nil
        )
    }

    /// True when the CLI exited with status 0 and its output is complete.
    /// Incomplete output counts as a failure even after a clean exit.
    public var succeeded: Bool {
        status == 0 && incompleteOutput == nil
    }

    /// Standard error followed by the incomplete-output reason, for the
    /// detail of a failure.
    public var failureDetail: String {
        [stderr, incompleteOutput ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Launches `lungfish-cli` from the app on ``ToolProcess``.
///
/// Every runner that spawns the CLI builds its spec here and reads its
/// outcome through ``run(_:cancellation:onStdoutLine:)``, so the environment,
/// the event line limit, stdin and the mapping of the result are the same for
/// all of them. Callers keep only their own event decoding and messages.
public enum CLIProcessLauncher {
    /// The longest stdout line delivered whole. A `complete` event that lists
    /// thousands of outputs passes the 64 KB default, and a JSON event cut in
    /// pieces cannot be decoded.
    public static let maxEventLineBytes = 16 * 1024 * 1024

    /// What the run does with the CLI's standard output.
    public enum StandardOutput: Sendable {
        /// Delivers each line to the caller and keeps none of it, for the
        /// JSON event stream.
        case events
        /// Keeps all of it for ``CLIProcessExit/stdout`` and delivers each
        /// line too.
        case captured
    }

    /// The spec every `lungfish-cli` launch uses.
    ///
    /// - Parameters:
    ///   - executableURL: The `lungfish-cli` binary.
    ///   - arguments: The CLI argv after the binary.
    ///   - standardOutput: Whether stdout is streamed as events or kept.
    ///   - terminationGracePeriod: How long the CLI's tree has between
    ///     SIGTERM and SIGKILL on a cancel. Zero kills it at once.
    ///   - drainGracePeriod: How long to wait for a descendant that holds
    ///     the output open after the CLI exits. Nil keeps the ToolProcess default.
    public static func spec(
        executableURL: URL,
        arguments: [String],
        standardOutput: StandardOutput = .events,
        terminationGracePeriod: Duration = .zero,
        drainGracePeriod: Duration? = nil
    ) -> ToolProcessSpec {
        var spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: ManagedStorageConfigStore().subprocessEnvironment(),
            stdin: .null,
            stdout: standardOutput == .events ? .capture(limit: 0) : .capture(),
            terminationGracePeriod: terminationGracePeriod,
            maxLineBytes: maxEventLineBytes,
            label: "lungfish-cli"
        )
        if let drainGracePeriod {
            spec.drainGracePeriod = drainGracePeriod
        }
        return spec
    }

    /// Runs `spec` through `cancellation` and maps the result.
    ///
    /// - Parameters:
    ///   - spec: A spec from ``spec(executableURL:arguments:standardOutput:terminationGracePeriod:drainGracePeriod:)``.
    ///   - cancellation: Lets any thread cancel the run. Cancelling the
    ///     calling task cancels it too.
    ///   - onStdoutLine: Receives each stdout line, one at a time, before
    ///     this method returns.
    public static func run(
        _ spec: ToolProcessSpec,
        cancellation: CLIRunCancellation,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async -> CLIProcessOutcome {
        let outcome = await cancellation.run(spec) { event in
            guard let onStdoutLine, case .output(.stdout, let line) = event else { return }
            onStdoutLine(line)
        }
        return map(outcome.result, cancelRequested: outcome.cancelRequested)
    }

    /// Maps a ToolProcess result onto the outcome every runner reads.
    static func map(
        _ result: Result<ToolProcessResult, ToolProcessError>,
        cancelRequested: Bool
    ) -> CLIProcessOutcome {
        switch result {
        case .success(let finished):
            let exit = CLIProcessExit(finished)
            return cancelRequested || finished.stop == .cancelled ? .cancelled(exit) : .exited(exit)
        case .failure(.cancelled(let results)):
            return .cancelled(results.first.map(CLIProcessExit.init))
        case .failure(.launchFailed(_, let reason, _)):
            return .launchFailed(reason: reason)
        case .failure(let error):
            return .launchFailed(reason: error.localizedDescription)
        }
    }
}
