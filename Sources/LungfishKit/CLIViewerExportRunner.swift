// CLIViewerExportRunner.swift - The one runner every viewer export runs its lungfish-cli leaf on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Runs a viewer export's `lungfish-cli` leaf for its Operations row (Phase 2.12, ARCH ruling X-4, rule 2 of 1.5).
///
/// The view keeps its save panel, begins the row with its own `begin<Family><Thing>ExportOperation` helper and hands
/// this runner the argv that row records, so row and record name one command. The leaf writes the payload and its
/// record in one `writeAtomically` transaction, and the app writes no byte after the
/// leaf exits (rule 4). The runner shows the leaf's events on the row through ``OperationCenterCLIBridge``, settles the
/// row and returns how the run ended. The view shows today's alert through ``ResultExportCoordinator`` for a failure
/// only, and a cancel reads Cancelled with no alert (UX 4).
///
/// A cancel sends the leaf SIGTERM and gives it ``terminationGracePeriod``, the launcher's
/// ``CLIProcessLauncher/operationGrace``, to roll its transaction back before SIGKILL, so a cancelled export leaves no
/// payload and no record. Every export lane runs on this one runner and adds none of its own.
public actor CLIViewerExportRunner {
    /// How a run ended. The row is already settled when the caller reads it.
    public enum Outcome: Sendable, Equatable {
        /// The leaf wrote this file and its record. The row reads Completed with the file's link, and a user's cancel
        /// from the row that came after the commit gives it the detail `Finished before Cancel took effect` (see `run`).
        case completed(URL)
        /// The run was cancelled. The row reads Cancelled.
        case cancelled
        /// The leaf failed. The row reads Failed with the failure's message.
        case failed(Failure)
    }

    /// A failed export, whose message is the leaf's `failed` event or the transport's error. The view passes it to
    /// ``ResultExportCoordinator/reportFailure(fileName:error:window:title:presenter:)``, which keeps today's words.
    public struct Failure: Error, LocalizedError, Sendable, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// The time the leaf has between SIGTERM and SIGKILL to roll its transaction back.
    public static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the leaf's output open after the leaf exited.
    public static let drainGracePeriod = CLIProcessLauncher.operationDrain

    private let transport: CLISubprocessTransport

    public init(cliURLOverride: URL? = nil) {
        transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Stops the leaf, whether it is running or about to start. It returns at once from any thread, so a row's cancel
    /// callback calls it directly.
    public nonisolated func cancel() {
        transport.cancel()
    }

    /// Runs the leaf for the row `operationID` and settles the row.
    ///
    /// - Parameters:
    ///   - arguments: The leaf's argv without the executable, the array the row's `cliCommand` was built from.
    ///   - outputURL: The file the leaf writes. A leaf with events names it in its `complete` line, which wins.
    ///   - operationID: The row the begin helper started.
    ///   - completionDetail: The row's detail once the leaf wrote the file.
    ///   - emitsEvents: False for an existing leaf whose contract row is not `.events`. It runs without
    ///     `--format json`, writes no `complete` line, and its row completes on exit 0.
    ///   - environmentAdditions: Variables laid over the app's subprocess environment for this run only. No
    ///     production caller passes any. A test passes the leaf's hold variable.
    ///
    /// A cancel that lands after the leaf committed, so that it exits 0 with a `complete` line naming its file,
    /// returns `.completed(file)` (review 12.31-M3a Fix 6, ruled by the manager). The file and its record are on disk,
    /// so the row reads Completed with the file's link (Phase 2.13 M842). When the user cancelled from the row, which
    /// `OperationCenter` had set to cancelling, its detail reads `Finished before Cancel took effect`. A cancel that
    /// lands before the commit reads Cancelled by user with no link, and every other route keeps that rule.
    public func run(
        arguments: [String],
        outputURL: URL,
        operationID: UUID,
        completionDetail: String,
        emitsEvents: Bool = true,
        environmentAdditions: [String: String] = [:]
    ) async -> Outcome {
        let written: URL
        do {
            let result = try await transport.run(
                arguments: arguments,
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
                environmentAdditions: environmentAdditions,
                completionOutlivesCancel: true,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
            )
            written = result.outputs.first.map { URL(fileURLWithPath: $0) } ?? outputURL
        } catch is CancellationError {
            await OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            return .cancelled
        } catch CLISubprocessTransport.RunError.missingCompletion where !emitsEvents {
            written = outputURL
        } catch {
            let failure = Self.failure(for: error)
            await OperationCenterCLIBridge.failOperation(
                operationID, detail: failure.message, fallbackMessage: failure.message
            )
            return .failed(failure)
        }
        // The leaf exited 0 with its file and record written, which a Cancel that reached the row since cannot undo.
        await OperationCenterCLIBridge.completeOperation(
            operationID, detail: completionDetail, outputURLs: [written], committed: true
        )
        return .completed(written)
    }

    /// The leaf's `failed` message when it wrote one, else the transport's description of the error.
    static func failure(for error: Error) -> Failure {
        if case let CLISubprocessTransport.RunError.failedEvent(message, _) = error {
            return Failure(message: message)
        }
        return Failure(message: error.localizedDescription)
    }
}
