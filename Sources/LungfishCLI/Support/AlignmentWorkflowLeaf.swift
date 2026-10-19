// AlignmentWorkflowLeaf.swift - What the Inspector's alignment workflow leaves share around their service call
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Runs `work` so that SIGTERM cancels it instead of ending the command, and returns how it ended
/// (Phase 2.10 lane A54, decision P2). The command listens before the task starts, so a SIGTERM
/// caught before then cancels the task as soon as it exists, and a second SIGTERM ends the command
/// at once. This is the shape `bam remove-track` uses, for any result type.
///
/// The app signals the command's whole group at once, so a tool that got the same SIGTERM can end the
/// work before this process has run its handler. A busy machine delays the thread the kernel must wake
/// for the handler, and the command then read its own SIGTERM as a failure of the tool. The kernel notes a
/// post at once, and `SIGTERMCancellation.signalCaught` reads that note beside the handler's count, so a
/// failure with a post behind it ends as the cancel it answers (Phase 2.10 lane FXS).
func runCancellingOnSIGTERM<Value: Sendable>(
    _ work: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error> {
    let pendingCancel = PendingTaskCancel<Result<Value, any Error>>()
    let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
    defer { termination.end() }
    let task = Task { () -> Result<Value, any Error> in
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }
    pendingCancel.attach(task)
    let ran = await task.value
    if case .failure(let error) = ran, !(error is CancellationError), SIGTERMCancellation.signalCaught {
        return .failure(CancellationError())
    }
    return ran
}

/// The service call of a duplicate leaf, handed the progress handler. A test passes a stand-in that
/// needs no samtools, and the leaf runs the real service when none is passed.
typealias DuplicateWorkflowRunner = @Sendable (
    @escaping @Sendable (Double, String) -> Void
) async throws -> AlignmentDuplicateService.WorkflowResult

/// The record of a run that SIGTERM cancelled, for a leaf whose service writes its own record only
/// when the run completes. It names the command and claims no output, and the `note` says what the
/// cancel left on disk. It sits where `url` says, never over a record of an earlier completed run.
struct CancelledAlignmentWorkflowRecord {
    let workflow: String
    let argv: [String]
    let explicit: [String: ParameterValue]
    let note: String
    let startedAt: Date
    let url: URL

    /// The folder of a bundle that holds the cancelled records of its workflows.
    static func folder(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("cancelled", isDirectory: true)
    }

    /// A record file in `folder`, named for the workflow and a short run ID, so two cancels never collide.
    static func newURL(in folder: URL, workflow: String) -> URL {
        let slug = workflow.replacingOccurrences(of: " ", with: "-")
        return folder.appendingPathComponent(
            "\(slug)-\(UUID().uuidString.prefix(8))\(ProvenanceRecorder.provenanceFilename)"
        )
    }

    func write() throws {
        let builder = ProvenanceRunBuilder(
            workflowName: workflow,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: workflow,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: explicit, defaults: [:], resolved: explicit)
        .runtime(ProvenanceRuntimeIdentity())
        let envelope = try builder.complete(
            exitStatus: Int(CLIExitCode.cancelled.rawValue),
            status: .cancelled,
            stderr: note,
            startedAt: startedAt,
            endedAt: Date()
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProvenanceWriter().write(envelope, toSidecar: url)
    }
}

/// The output side of an alignment workflow leaf. With `--format json` standard output holds only
/// `CLIEvent` lines and standard error stays empty, because `say` prints nothing then. Otherwise the
/// text goes to `emit`.
struct AlignmentWorkflowLeafOutput {
    let eventsOn: Bool
    let quiet: Bool
    let events: CLIEventEmitter
    private let emit: (String) -> Void

    init(eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void) {
        self.eventsOn = eventsOn
        self.quiet = quiet
        self.emit = emit
        self.events = CLIEventEmitter(enabled: eventsOn, emit: emit)
    }

    /// One line of human text. With events on the stages already travel as events, so it prints nothing
    /// and standard error stays empty, as `bam filter --format json` always left it.
    func say(_ text: String) {
        guard !eventsOn, !quiet else { return }
        emit(text)
    }

    /// The service's progress handler: each stage is a progress event with the service's words.
    var progressHandler: @Sendable (Double, String) -> Void {
        let events = events
        return { fraction, message in events.emitProgress(fraction, message: message) }
    }

    /// Ends a run that failed: the `failed` event, the text, and the exit status 64.
    func failed(_ message: String) -> ExitCode {
        events.emitFailed(message)
        say("Error: \(message)")
        return CLIExitCode.workflowError.exitCode
    }

    /// Ends a run that was refused before it changed anything: the `failed` event, the text, exit 3.
    func refused(_ message: String) -> ExitCode {
        events.emitFailed(message)
        say("Error: \(message)")
        return CLIExitCode.inputError.exitCode
    }

    /// Ends a run that SIGTERM cancelled: the record, the `failed` event, the text, and exit 125. A
    /// record that cannot be written is a warning in either mode. It is a `log` event at warning level
    /// under `--format json`, where `say` prints nothing, and a line of text otherwise.
    func cancelled(_ message: String, record: CancelledAlignmentWorkflowRecord) -> ExitCode {
        do {
            try record.write()
        } catch {
            events.emitLog(.warning, "Could not write the cancelled record: \(error.localizedDescription)")
            say("Warning: could not write the cancelled record: \(error.localizedDescription)")
        }
        events.emitFailed(message)
        say(message)
        return CLIExitCode.cancelled.exitCode
    }
}
