// FastqImportONTSubcommand+Events.swift - `fastq import-ont` speaks events and turns SIGTERM into a cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Phase 2.10 lane A53 (panel decisions C11, C5 and P2). The window launches this leaf for an ONT import,
/// so the row it shows is the leaf's stream. With `--format json` the leaf prints `CLIEvent` lines on
/// standard output and nothing else there. The words are the ones the row showed when the import ran in
/// the app. The row began "Detecting layout...", then showed the workflow's stage words as they came, and
/// ended with the count of bundles and reads. Human text still goes to standard error in both modes.
extension FastqImportONTSubcommand {
    /// The first detail of the import's row, the words `ONTImportOperationCoordinator` begins it with.
    static let firstDetail = "Detecting layout..."

    /// The message of the `failed` event that stands for a cancel. The exit status 125 carries the cancel
    /// for the window, and this line is the stream's own record of it.
    static let cancelledMessage = "Import cancelled"

    /// What the stream and the error report for a failure: the message of a usage error, else the
    /// error's own description.
    static func failureText(_ error: any Error) -> String {
        (error as? ValidationError)?.message ?? error.localizedDescription
    }

    /// Runs the import with SIGTERM turned into a cancel.
    ///
    /// The window's Cancel signals the leaf's group and tree, and kills them after
    /// `CLIProcessLauncher.operationGrace`. Without a handler the leaf died at once and left its staging
    /// folder. The signal now cancels the task that runs the import, whose chunk loops check for the
    /// cancel, and the workflow rolls its staged bundles back before the leaf exits 125. The leaf listens
    /// before the task starts, so a SIGTERM caught earlier cancels the task as soon as it exists, and a
    /// second SIGTERM ends the command at once. The existing-bundle copy is one synchronous staged copy and
    /// finishes whatever the signal.
    func run() async throws {
        let pendingCancel = PendingTaskCancel<Swift.Result<Void, any Error>>()
        let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
            FileHandle.standardError.write(Data("Cancelling the import\n".utf8))
            pendingCancel.cancel()
        }
        defer { termination.end() }
        let task = Task { () -> Swift.Result<Void, any Error> in
            do {
                try await self.execute(
                    emit: { printEventLine($0) },
                    cancelRequested: { SIGTERMCancellation.signalCaught || pendingCancel.cancelRequested }
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        pendingCancel.attach(task)
        if case .failure(let error) = await task.value {
            throw error
        }
    }

    /// Runs the import and ends the stream with exactly one terminal event.
    ///
    /// - Parameters:
    ///   - emit: Receives each event line. Tests and the transcript captures hand in a sink.
    ///   - cancelRequested: Whether a SIGTERM or another cancel was asked for. A failure that follows a
    ///     cancel is a cancel, also when the tool died of the same signal first. A run that finished is
    ///     never turned into a cancel, since the import publishes its bundles before it returns.
    func execute(
        emit: @escaping (String) -> Void,
        cancelRequested: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        let events = CLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
        events.emitStart(message: Self.firstDetail)
        do {
            try await importONT(events: events)
        } catch {
            if error is CancellationError || Task.isCancelled || cancelRequested() {
                events.emitFailed(Self.cancelledMessage)
                FileHandle.standardError.write(Data("\(Self.cancelledMessage)\n".utf8))
                throw CLIExitCode.cancelled.exitCode
            }
            events.emitFailed(Self.failureText(error))
            throw error
        }
    }
}
