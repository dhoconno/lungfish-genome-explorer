// DependencyReconcilerProvenance.swift - One provenance envelope per reconciliation run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DependencyReconcilerProvenance")

/// Writes the audit record for a reconciliation run.
///
/// A run produces no scientific output files, so the envelope is built directly rather than
/// through `ProvenanceRunBuilder`, whose success path requires at least one output descriptor.
/// The file still decodes as a `ProvenanceEnvelope`: what it records is the set of dependency
/// changes that were attempted, one `ProvenanceStep` per item, so a result produced afterwards
/// can be traced to the exact tool versions this run put in place.
public enum DependencyReconcilerProvenance {
    public enum ItemKind: String, Sendable {
        case bootstrap
        case environment
        case database
        case removal
    }

    /// One attempted item: what it was, and whether it worked.
    public struct ItemRecord: Sendable {
        public let id: String
        public let kind: ItemKind
        public let title: String
        /// nil when the item succeeded.
        public let failure: String?
        public let startedAt: Date
        public let endedAt: Date

        public init(id: String, kind: ItemKind, title: String, failure: String?, startedAt: Date, endedAt: Date) {
            self.id = id
            self.kind = kind
            self.title = title
            self.failure = failure
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    static let directoryName = "provenance/dependencies"

    /// Writes `<storageRoot>/provenance/dependencies/<ISO8601>-<set>.lungfish-provenance.json`.
    ///
    /// Provenance is an audit trail, not a precondition: a write failure is logged and the
    /// reconciliation result stands, because refusing to report a completed install because
    /// its receipt-adjacent log could not be written would be strictly worse for the user.
    @discardableResult
    public static func write(
        records: [ItemRecord],
        plan: ReconciliationPlan,
        manifest: ManagedToolLock,
        storageRoot: URL,
        appVersion: String,
        startedAt: Date,
        endedAt: Date
    ) -> URL? {
        let envelope = envelope(
            records: records,
            plan: plan,
            manifest: manifest,
            appVersion: appVersion,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let directory = storageRoot
            .appendingPathComponent(directoryName, isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(timestampComponent(startedAt))-\(filenameSafe(plan.targetDependencySet)).lungfish-provenance.json"
        )
        do {
            return try ProvenanceWriter().write(envelope, toSidecar: url)
        } catch {
            logger.warning(
                "Failed to write dependency reconciliation provenance: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func envelope(
        records: [ItemRecord],
        plan: ReconciliationPlan,
        manifest: ManagedToolLock,
        appVersion: String,
        startedAt: Date,
        endedAt: Date
    ) -> ProvenanceEnvelope {
        let failures = records.compactMap(\.failure)
        let argv = ["lungfish", "tools", "update", "--set", plan.targetDependencySet]
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "dependency-reconcile",
            workflowVersion: appVersion,
            toolName: "lungfish",
            toolVersion: appVersion,
            argv: argv,
            options: ProvenanceOptions(
                explicit: [
                    "dependencySet": .string(plan.targetDependencySet),
                    "manifestHash": .string(manifest.manifestHash),
                ],
                defaults: [:],
                resolvedDefaults: [:]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: appVersion,
                dependencySet: plan.targetDependencySet
            ),
            steps: records.map(step(for:)),
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            exitStatus: failures.isEmpty ? 0 : 1,
            stderr: failures.isEmpty ? nil : failures.joined(separator: "\n")
        )
    }

    private static func step(for record: ItemRecord) -> ProvenanceStep {
        ProvenanceStep(
            toolName: record.id,
            toolVersion: "unknown",
            argv: [record.kind.rawValue, record.id],
            reproducibleCommand: record.title,
            resolvedOptions: ["kind": .string(record.kind.rawValue)],
            exitStatus: record.failure == nil ? 0 : 1,
            wallTimeSeconds: record.endedAt.timeIntervalSince(record.startedAt),
            stderr: record.failure,
            startedAt: record.startedAt,
            completedAt: record.endedAt
        )
    }

    /// A colon-free ISO8601 stamp, so the filename is valid on every filesystem the app
    /// supports (including ExFAT volumes, where `:` is illegal).
    static func timestampComponent(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }

    static func filenameSafe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
