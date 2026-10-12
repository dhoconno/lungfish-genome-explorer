// ProcessViralReconWorkflowProcessRunner.swift - Runs lungfish-cli for the Viral Recon and Local Workflow routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os

/// Runs `lungfish-cli workflow run` for the two routes that start a Nextflow workflow from the app, Viral
/// Recon and Local Workflow, on ``CLIProcessLauncher`` like every other app runner of the CLI.
///
/// A cancel gives the CLI SIGTERM and ``terminationGracePeriod`` to stop Nextflow and record its run as
/// cancelled before ToolProcess sends SIGKILL to the CLI's tree. The runner returns once the tree is
/// gone, with the CLI's own exit code when it stopped by itself. The route reads the row's state to tell
/// a cancel from a failure, so a cancelled run returns a result and does not throw.
///
/// Every line the CLI writes is handed to the route as it arrives. The result keeps only the last
/// ``defaultOutputTailLimit`` bytes of each stream, so a run that logs for hours holds a bounded amount
/// in memory. The route writes that tail to the run bundle's `logs` folder and reads its last lines for
/// the failure detail. When a stream was cut, its text says so on its first line.
///
/// One runner serves one run at a time, as ``CLIRunCancellation`` does. Each production attempt makes
/// its own runner.
final class ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    /// The time the CLI has between SIGTERM and SIGKILL after a cancel, to stop Nextflow and record its
    /// run as cancelled. It nests inside the ten seconds OperationCenter waits before it forces a
    /// cancelling row to read Cancelled, as the classifier route's grace does.
    static let terminationGracePeriod: Duration = .seconds(6)
    /// How long the run waits for a descendant that holds the CLI's output open after the CLI exited.
    /// Short, so a cancel stays inside the ten seconds.
    static let drainGracePeriod: Duration = .milliseconds(500)
    /// The most bytes the result keeps of each stream, the last ones.
    static let defaultOutputTailLimit = ToolProcessSpec.defaultStderrCaptureLimit

    private let executableURL: URL?
    private let outputTailLimit: Int
    private let cancellation = CLIRunCancellation()

    init(
        executableURL: URL? = nil,
        outputTailLimit: Int = ProcessViralReconWorkflowProcessRunner.defaultOutputTailLimit
    ) {
        self.executableURL = executableURL
        self.outputTailLimit = outputTailLimit
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        guard let cliURL = executableURL ?? CLIBinaryLocator.cliBinaryPath() else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }
        var spec = CLIProcessLauncher.spec(
            executableURL: cliURL,
            arguments: arguments,
            standardOutput: .captured,
            terminationGracePeriod: Self.terminationGracePeriod,
            drainGracePeriod: Self.drainGracePeriod
        )
        spec.workingDirectory = workingDirectory
        spec.stdout = .capture(limit: outputTailLimit)
        spec.stderr = .capture(limit: outputTailLimit)

        let relay = ProcessOutputRelay(outputHandler)
        let outcome = await CLIProcessLauncher.run(
            spec,
            cancellation: cancellation,
            onStdoutLine: { relay.send(.standardOutput($0)) },
            onStderrLine: { relay.send(.standardError($0)) }
        )

        switch outcome {
        case .launchFailed(let reason):
            throw LungfishCLIRunner.RunError.launchFailed(reason)
        case .cancelled(let exit?), .exited(let exit):
            return result(of: exit, didStreamOutput: relay.didSend)
        case .cancelled(nil):
            // A cancel came before the launch, so nothing ran.
            return ViralReconWorkflowProcessResult(
                exitCode: AnalysisRunExitCode.cancelled,
                standardOutput: "",
                standardError: "",
                didStreamOutput: false
            )
        }
    }

    /// Stops the CLI, whether it is running or about to start. It returns at once.
    func cancel() {
        cancellation.cancel()
    }

    private func result(of exit: CLIProcessExit, didStreamOutput: Bool) -> ViralReconWorkflowProcessResult {
        var standardError = Self.tail(of: exit.stderr, limit: outputTailLimit)
        if let incomplete = exit.incompleteOutput {
            // A descendant kept the output open after the CLI exited, so the text may miss its last
            // lines. The exit code stays the truth about the run. The reason reads as a warning line.
            if !standardError.isEmpty, !standardError.hasSuffix("\n") { standardError += "\n" }
            standardError += incomplete + "\n"
        }
        return ViralReconWorkflowProcessResult(
            exitCode: exit.status,
            standardOutput: Self.tail(of: exit.stdout, limit: outputTailLimit),
            standardError: standardError,
            didStreamOutput: didStreamOutput
        )
    }

    /// The text of a stream as the result keeps it. ToolProcess keeps the last `limit` bytes of a
    /// stream, which can begin inside a line, so a cut stream loses that partial line and says where it
    /// was cut. A stream that fits is returned as it is.
    static func tail(of text: String, limit: Int) -> String {
        guard text.utf8.count >= limit else { return text }
        let afterPartialLine = String(text.drop(while: { !$0.isNewline }).dropFirst())
        return "[Earlier output was left out. Only the last \(limit) bytes were kept.]\n" + afterPartialLine
    }
}

/// Hands each line the CLI writes to the route's handler on the main actor, in the order the CLI wrote
/// them, and remembers whether it handed over any. The route logs the whole output itself after the run
/// when none was streamed.
private final class ProcessOutputRelay: Sendable {
    private let handler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    private let sent = OSAllocatedUnfairLock(initialState: false)

    init(_ handler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) {
        self.handler = handler
    }

    var didSend: Bool {
        sent.withLock { $0 }
    }

    func send(_ output: ViralReconWorkflowProcessOutput) {
        guard let handler else { return }
        sent.withLock { $0 = true }
        // The main queue keeps the lines in order, and every line is queued before the run returns, so
        // the route sees them all before it reads the result.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(output)
            }
        }
    }
}
