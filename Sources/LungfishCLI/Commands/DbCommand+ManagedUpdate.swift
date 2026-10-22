// DbCommand+ManagedUpdate.swift - `conda db update` for a database the lock pins as one hosted file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishCore
import Synchronization

/// The managed branch of `db update`, kept apart from the catalog branch so DbCommand.swift stays under the
/// file-size ratchet (CHTC lane C2-RIBOPIN).
extension DbCommand.DbUpdateSubcommand {
    /// `db update <managed id>` brings a managed database such as `deacon-ribokmers` to the lock's pin. The registry
    /// replaces the installed copy only after the new file passes the lock check. SIGTERM, the app's Cancel, cancels
    /// the download, leaves the installed copy as it was and ends the run as cancelled with exit 125. The run is
    /// recorded under `<storage root>/provenance/databases` with the installed SHA-256 before and after, the lock's
    /// SHA-256 and the outcome: `replaced`, `already matched`, `refused` (the update did not replace the installed
    /// copy, and the failure says why) or `cancelled` (CHTC lane C2-RIBOPIN).
    func updateManaged(
        _ id: String,
        events: CLIEventEmitter,
        say: @escaping @Sendable (String) -> Void,
        formatter: TerminalFormatter,
        eventsOn: Bool,
        quiet: Bool
    ) async throws {
        let registry = DbCommand.managedRegistry
        let startedAt = Date()
        events.emitStart("Updating \(id)...")
        say(formatter.header("Updating \(id)"))
        let before = try? await registry.pinStatus(for: id)
        if let before {
            say(formatter.info("Installed copy: \(before.summary(databaseID: id))"))
        }
        let ended = await ManagedToolLeaf.cancellingOnSIGTERM { () async throws -> URL in
            try await registry.updateManagedDatabase(id) { fraction, message in
                if eventsOn {
                    events.emitProgress(min(max(fraction, 0), 1), message: message)
                } else if !quiet {
                    print("\r\(formatter.info("[\(Int((fraction * 100).rounded()))%] \(message)"))", terminator: "")
                }
            }
        }
        var failure: String?
        var installed: URL?
        var cancelled = false
        switch ended {
        case .success(let url):
            installed = url
        case .failure(let error):
            if Self.endedOnCancel(error) { cancelled = true } else { failure = error.localizedDescription }
        }
        let after = try? await registry.pinStatus(for: id)
        let version = await registry.requiredDatabaseManifest(for: id)?.version ?? "unknown"
        let outcome: String
        if cancelled {
            outcome = "cancelled"
        } else if failure != nil {
            outcome = "refused"
        } else if case .matchesPin? = before {
            outcome = "already matched"
        } else {
            outcome = "replaced"
        }
        ManagedToolLeaf.writeRecord(
            ManagedToolLeaf.Record(
                workflowName: "conda-database-update",
                folder: "databases",
                label: id,
                argv: ["lungfish-cli", "conda", "db", "update", id, "--yes"],
                explicit: [
                    "databases": .array([.string(id)]),
                    "outcome": .string(outcome),
                    "installedSHA256Before": .string(before?.installedSHA256 ?? "none"),
                    "installedSHA256After": .string(after?.installedSHA256 ?? "none"),
                    "pinnedSHA256": .string(after?.pinnedSHA256 ?? before?.pinnedSHA256 ?? "none"),
                ],
                pluginPack: nil,
                steps: [ManagedToolLeaf.Step(id: id, version: version, failure: failure)],
                status: cancelled ? .cancelled : (failure == nil ? .completed : .failed),
                failure: cancelled ? "Cancelled" : failure,
                startedAt: startedAt,
                endedAt: Date()
            ),
            storageRoot: ManagedToolLeaf.currentStorageRoot()
        )
        say("")
        if cancelled {
            let message = "Update cancelled. The installed database was left as it was."
            events.emitFailed(message)
            say(message)
            throw CLIExitCode.cancelled.exitCode
        }
        if let failure {
            events.emitFailed("Failed '\(id)': \(failure)")
            say(formatter.error("Failed '\(id)': \(failure)"))
            throw CLIExitCode.failure.exitCode
        }
        if let after {
            say(formatter.success("Database '\(id)' \(after.summary(databaseID: id))"))
        }
        events.emitComplete(outputs: installed.map { [$0.path] } ?? [], message: "Updated \(id)")
    }

    /// Whether the update of a managed database ended on a cancel. The registry reports a cancelled download as
    /// `installationCancelled`, and a caught SIGTERM settles a run that a tool's death turned into a failure.
    static func endedOnCancel(_ error: any Error) -> Bool {
        if case .installationCancelled? = error as? HumanScrubberDatabaseError { return true }
        return ManagedToolLeaf.endedOnCancel(error)
    }
}
