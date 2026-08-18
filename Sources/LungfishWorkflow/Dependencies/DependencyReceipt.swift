// DependencyReceipt.swift - What the app believes is installed on this machine
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The persisted record of what the app installed on this machine: conda environments,
/// registry-managed databases, prefetched pipelines, and the micromamba bootstrap.
///
/// The receipt is the "actual" side of reconciliation; `DependencyManifest` is the
/// "desired" side. When no receipt exists (users upgrading from pre-receipt builds), one
/// is synthesized from what is on disk via `DependencyReceiptStore.synthesize`.
public struct DependencyReceipt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The manifest `dependencySet` these installs came from; nil when synthesized.
    public var dependencySet: String?
    public var appVersion: String?
    public var manifestHash: String?
    public var updatedAt: Date
    /// True when the receipt was reconstructed from disk rather than written by an install.
    public var synthesized: Bool
    /// Keyed by conda environment name.
    public var environments: [String: EnvironmentEntry]
    /// Keyed by database id (DatabaseRegistry-managed entries only).
    public var databases: [String: DatabaseEntry]
    /// Keyed by pipeline id.
    public var pipelines: [String: PipelineEntry]
    public var bootstrap: BootstrapEntry?

    public struct EnvironmentEntry: Codable, Sendable, Equatable {
        public var packageSpec: String
        /// The owning pack when the manifest knows this environment; nil otherwise.
        public var packID: String?
        public var installedAt: Date
        public var state: EntryState

        public init(packageSpec: String, packID: String?, installedAt: Date, state: EntryState) {
            self.packageSpec = packageSpec
            self.packID = packID
            self.installedAt = installedAt
            self.state = state
        }
    }

    public struct DatabaseEntry: Codable, Sendable, Equatable {
        public var version: String
        public var path: String?
        public var installedAt: Date

        public init(version: String, path: String?, installedAt: Date) {
            self.version = version
            self.path = path
            self.installedAt = installedAt
        }
    }

    public struct PipelineEntry: Codable, Sendable, Equatable {
        public var revision: String
        public var prefetchedAt: Date?

        public init(revision: String, prefetchedAt: Date?) {
            self.revision = revision
            self.prefetchedAt = prefetchedAt
        }
    }

    public struct BootstrapEntry: Codable, Sendable, Equatable {
        public var micromambaVersion: String

        public init(micromambaVersion: String) {
            self.micromambaVersion = micromambaVersion
        }
    }

    public enum EntryState: String, Codable, Sendable {
        case installed
        case pending
        case failed
    }

    public init(
        schemaVersion: Int,
        dependencySet: String?,
        appVersion: String?,
        manifestHash: String?,
        updatedAt: Date,
        synthesized: Bool,
        environments: [String: EnvironmentEntry],
        databases: [String: DatabaseEntry],
        pipelines: [String: PipelineEntry],
        bootstrap: BootstrapEntry?
    ) {
        self.schemaVersion = schemaVersion
        self.dependencySet = dependencySet
        self.appVersion = appVersion
        self.manifestHash = manifestHash
        self.updatedAt = updatedAt
        self.synthesized = synthesized
        self.environments = environments
        self.databases = databases
        self.pipelines = pipelines
        self.bootstrap = bootstrap
    }

    /// Rounds every date down to a whole second, matching the ISO8601 on-disk resolution.
    ///
    /// Without this, an in-memory receipt never compares equal to the one read back from
    /// disk, because the sub-second component does not survive encoding.
    mutating func truncateDatesToWholeSeconds() {
        updatedAt = updatedAt.truncatedToWholeSecond
        environments = environments.mapValues { entry in
            var entry = entry
            entry.installedAt = entry.installedAt.truncatedToWholeSecond
            return entry
        }
        databases = databases.mapValues { entry in
            var entry = entry
            entry.installedAt = entry.installedAt.truncatedToWholeSecond
            return entry
        }
        pipelines = pipelines.mapValues { entry in
            var entry = entry
            entry.prefetchedAt = entry.prefetchedAt?.truncatedToWholeSecond
            return entry
        }
    }

    public static func empty() -> DependencyReceipt {
        .init(
            schemaVersion: currentSchemaVersion,
            dependencySet: nil,
            appVersion: nil,
            manifestHash: nil,
            updatedAt: Date(),
            synthesized: false,
            environments: [:],
            databases: [:],
            pipelines: [:],
            bootstrap: nil
        )
    }
}

private extension Date {
    /// The instant rounded down to the second, which is all ISO8601 encoding preserves.
    var truncatedToWholeSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
