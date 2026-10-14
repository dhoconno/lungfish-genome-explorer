// ManagedToolLeafSupport.swift - What the managed tools and packs leaves share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The parts `tools update`, `conda install --pack` and `conda db update` share (Phase 2.10 lane A52,
/// family L10, plan decisions C5 and P2).
///
/// The Update Tools sheet, the Plugin Manager's pack install and reinstall, and its database update
/// run these leaves under the app's cancel. The app sends the CLI SIGTERM and gives it the 6 second
/// grace, so each leaf turns SIGTERM into a cancel of its own task, records its run as cancelled and
/// exits 125 (`CLIExitCode.cancelled`). A second SIGTERM ends it at once.
enum ManagedToolLeaf {
    /// Runs `work` so that SIGTERM cancels it instead of ending the command. The command listens
    /// before the task starts, so a SIGTERM caught before then cancels the task as soon as it
    /// exists, and a second SIGTERM ends the command at once.
    static func cancellingOnSIGTERM<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        let pendingCancel = PendingTaskCancel<Result<T, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let task = Task { () -> Result<T, any Error> in
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        pendingCancel.attach(task)
        return await task.value
    }

    /// Whether a run that ended with `error` ended on a cancel. A SIGTERM also reaches the tools of
    /// the command's process group, so a tool that dies of it first reaches the command as a failure,
    /// and the caught signal settles which it was.
    static func endedOnCancel(_ error: (any Error)?) -> Bool {
        error is CancellationError || SIGTERMCancellation.signalCaught
    }

    // MARK: - The record of a run

    /// One item of a run, such as an environment of a pack or a database.
    struct Step: Sendable, Equatable {
        let id: String
        let version: String
        /// nil when the item succeeded.
        let failure: String?
    }

    /// The record a leaf writes for its run, `<storage root>/provenance/<folder>/<time>-<label>.lungfish-provenance.json`.
    struct Record: Sendable {
        var workflowName: String
        var folder: String
        var label: String
        var argv: [String]
        var explicit: [String: ParameterValue]
        var pluginPack: String?
        var steps: [Step]
        var status: RunStatus
        var failure: String?
        var startedAt: Date
        var endedAt: Date
    }

    static func recordDirectory(storageRoot: URL, folder: String) -> URL {
        storageRoot.appendingPathComponent("provenance/\(folder)", isDirectory: true)
    }

    /// The record files in `folder` now, so a caller can tell the one a run wrote.
    static func recordNames(storageRoot: URL, folder: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: recordDirectory(storageRoot: storageRoot, folder: folder).path
        )) ?? []
        return Set(names.filter { $0.hasSuffix(".lungfish-provenance.json") })
    }

    /// Writes `record` and returns its file, or nil when it could not be written. A record is an
    /// audit trail, so a failure to write it is noted on standard error and never changes the exit.
    @discardableResult
    static func writeRecord(_ record: Record, storageRoot: URL) -> URL? {
        let url = recordDirectory(storageRoot: storageRoot, folder: record.folder)
            .appendingPathComponent("\(stamp(record.startedAt))-\(filenameSafe(record.label)).lungfish-provenance.json")
        do {
            return try ProvenanceWriter().write(envelope(for: record), toSidecar: url)
        } catch {
            printStatusLine("Warning: could not write the record of this run: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rewrites the status of the record at `url` to cancelled. It returns false when the record
    /// cannot be read or written.
    @discardableResult
    static func markCancelled(sidecar url: URL, reason: String) -> Bool {
        do {
            guard var envelope = try ProvenanceEnvelopeReader.load(fromSidecar: url) else { return false }
            envelope.status = .cancelled
            envelope.exitStatus = Int(CLIExitCode.cancelled.rawValue)
            envelope.stderr = reason
            _ = try ProvenanceWriter().write(envelope, toSidecar: url)
            return true
        } catch {
            return false
        }
    }

    static func envelope(for record: Record) -> ProvenanceEnvelope {
        let appVersion = LungfishAppVersion.short
        let exitStatus: Int
        switch record.status {
        case .completed: exitStatus = 0
        case .cancelled: exitStatus = Int(CLIExitCode.cancelled.rawValue)
        case .failed, .running: exitStatus = 1
        }
        return ProvenanceEnvelope(
            createdAt: record.startedAt,
            workflowName: record.workflowName,
            workflowVersion: appVersion,
            toolName: "lungfish",
            toolVersion: appVersion,
            argv: record.argv,
            options: ProvenanceOptions(explicit: record.explicit, defaults: [:], resolvedDefaults: [:]),
            runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: appVersion, pluginPack: record.pluginPack),
            steps: record.steps.map { step in
                ProvenanceStep(
                    toolName: step.id,
                    toolVersion: step.version,
                    argv: [record.folder, step.id],
                    reproducibleCommand: step.id,
                    exitStatus: step.failure == nil ? 0 : 1,
                    wallTimeSeconds: nil,
                    stderr: step.failure,
                    startedAt: record.startedAt,
                    completedAt: record.endedAt
                )
            },
            wallTimeSeconds: record.endedAt.timeIntervalSince(record.startedAt),
            exitStatus: exitStatus,
            stderr: record.failure,
            status: record.status
        )
    }

    /// A colon-free UTC stamp, so the file name is valid on every volume the app supports.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }

    static func filenameSafe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// The managed storage root a leaf records under, `--storage-root` already applied.
    static func currentStorageRoot() -> URL {
        CondaCommand.storageRootOverride ?? ManagedStorageConfigStore().currentLocation().rootURL
    }
}
