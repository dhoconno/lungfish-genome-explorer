// ExtractReadsCommand+Events.swift - extract reads' events, refusals and SIGTERM cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// What a run of `extract reads` wrote, which its `complete` event names.
struct ExtractReadsOutcome: Sendable {
    /// The bundle, or the read files when the run wrote no bundle.
    let outputs: [String]
    let readCount: Int

    /// The `complete` event's message, such as `Extracted 42 reads`.
    var message: String { "Extracted \(readCount) read\(readCount == 1 ? "" : "s")" }
}

/// A refusal of `extract reads` before it writes anything, which exits 3 and names the fix.
struct ExtractReadsRefusal: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension ExtractReadsSubcommand {
    static let startMessage = "Extracting reads…"
    static let cancelledMessage = "Read extraction cancelled. Nothing was published."

    /// Runs the extraction (Phase 2.10 lane A51). With `--format json` standard output holds only
    /// `CLIEvent` lines and the human text goes to standard error. SIGTERM, the app's Cancel, stops
    /// the run, which is recorded as cancelled, and the command exits 125. A refusal exits 3.
    func run() async throws {
        try await timeLimit.scope { try await runUnderLimit() }
    }

    private func runUnderLimit() async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(Self.startMessage)
        let startedAt = Date()
        switch await extractCancellingOnSIGTERM() {
        case .success(let outcome):
            events.emitComplete(outputs: outcome.outputs, message: outcome.message)
        case .failure(let error) where error is CancellationError:
            await recordCancelledRun(startedAt: startedAt)
            events.emitFailed(Self.cancelledMessage)
            say(Self.cancelledMessage)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let refusal as ExtractReadsRefusal):
            events.emitFailed(refusal.message)
            say(TerminalFormatter(useColors: globalOptions.useColors).error(refusal.message))
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            throw error
        }
    }

    /// Human text, on standard output, or on standard error while events are on.
    func say(_ text: String) {
        printHumanLine(text, eventsOn: globalOptions.outputFormat == .json)
    }

    /// A progress line, rewritten in place on a terminal, or one line on standard error while
    /// events are on.
    func progressLine(_ text: String) {
        guard !globalOptions.quiet else { return }
        if globalOptions.outputFormat == .json {
            printStatusLine(text)
        } else {
            print("\r\(text)", terminator: "")
        }
    }

    /// Runs `extract()` so that SIGTERM cancels it instead of ending the command. The command
    /// listens before the task starts, so a SIGTERM caught before then cancels the task as soon as
    /// it exists, and a second SIGTERM ends the command at once.
    private func extractCancellingOnSIGTERM() async -> Result<ExtractReadsOutcome, any Error> {
        let pendingCancel = PendingTaskCancel<Result<ExtractReadsOutcome, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let command = self
        let task = Task { () -> Result<ExtractReadsOutcome, any Error> in
            do {
                return .success(try await command.extract())
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        return await task.value
    }

    /// Records a run that a cancel stopped as cancelled, in the folder its record goes to. A
    /// failure to write it does not hide the cancel.
    private func recordCancelledRun(startedAt: Date) async {
        if indexFile != nil {
            // Beside the bundle the run would have published, which the next published run removes.
            _ = try? AlignmentReadExtractionInvocation.recordCancelledRun(evidenceInvocation, startedAt: startedAt)
            return
        }
        let outputURL = URL(fileURLWithPath: output)
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish extract reads",
            parameters: strategyParameterValues(alignmentIndexURL: nil),
            toolName: "lungfish extract reads",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(outputURL: outputURL),
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: Self.cancelledMessage,
            status: .cancelled,
            outputDirectory: outputURL.deletingLastPathComponent(),
            writeFileSidecars: false
        )
    }
}
