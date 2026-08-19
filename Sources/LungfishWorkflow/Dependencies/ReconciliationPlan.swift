// ReconciliationPlan.swift - The diff between the dependency manifest and this machine
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The work needed to bring this machine in line with the dependency manifest.
///
/// A plan is produced by `DependencyPlanner.plan(_:)` from a pure snapshot of manifest,
/// receipt, and disk state, and consumed by the reconciler (and the Update Tools UI) as the
/// list of installs, reinstalls, removals, database updates, pipeline prefetches, and
/// bootstrap upgrades to perform.
public struct ReconciliationPlan: Codable, Sendable, Equatable {
    /// Why a given piece of work is in the plan.
    public enum ChangeReason: String, Codable, Sendable {
        /// The environment does not exist on disk at all.
        case missing
        /// The pinned package version changed since the recorded install.
        case specChanged
        /// Only the conda build string changed; the version is unchanged.
        case buildChanged
        /// Disk metadata disagrees with what the receipt claims (tampering, partial install,
        /// unreadable `conda-meta`, or a receipt entry that never reached `.installed`).
        case metadataMismatch
        /// The environment is no longer pinned by the manifest.
        ///
        /// Reserved for UI mapping: retirements travel in `removeEnvironments` (plain names), so
        /// the planner never attaches this reason to an `EnvironmentChange` today.
        case retired
        /// Bootstrap (micromamba) work.
        ///
        /// Reserved for UI mapping: bootstrap work travels in `bootstrapUpdate`, so the planner
        /// never attaches this reason to an `EnvironmentChange` today.
        case bootstrap
        /// The environment would have been reinstalled for unreadable provenance, but the
        /// manifest entry sets `preserveExistingInstall` and a usable install is already there.
        ///
        /// Advisory only: entries carrying this reason travel in `preservedEnvironments` and are
        /// never installed, reinstalled, or removed.
        case localInstallPreserved
    }

    public struct EnvironmentChange: Codable, Sendable, Equatable, Identifiable {
        public var id: String { environment }
        public let environment: String
        public let packID: String
        public let currentSpec: String?
        public let targetSpec: String
        public let reason: ChangeReason
        public let isRequired: Bool

        public init(
            environment: String,
            packID: String,
            currentSpec: String?,
            targetSpec: String,
            reason: ChangeReason,
            isRequired: Bool
        ) {
            self.environment = environment
            self.packID = packID
            self.currentSpec = currentSpec
            self.targetSpec = targetSpec
            self.reason = reason
            self.isRequired = isRequired
        }
    }

    /// Which subsystem owns the installed copy of a database, and so which one performs the update.
    public enum DatabaseManager: String, Codable, Sendable {
        case databaseRegistry
        case metagenomicsRegistry
    }

    public struct DatabaseChange: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let displayName: String
        public let installedVersion: String?
        public let targetVersion: String
        public let policy: DatabaseUpdatePolicy
        public let estimatedBytes: Int64
        public let managedBy: DatabaseManager

        public init(
            id: String,
            displayName: String,
            installedVersion: String?,
            targetVersion: String,
            policy: DatabaseUpdatePolicy,
            estimatedBytes: Int64,
            managedBy: DatabaseManager
        ) {
            self.id = id
            self.displayName = displayName
            self.installedVersion = installedVersion
            self.targetVersion = targetVersion
            self.policy = policy
            self.estimatedBytes = estimatedBytes
            self.managedBy = managedBy
        }
    }

    public struct PipelineChange: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let currentRevision: String?
        public let targetRevision: String

        public init(id: String, currentRevision: String?, targetRevision: String) {
            self.id = id
            self.currentRevision = currentRevision
            self.targetRevision = targetRevision
        }
    }

    public struct BootstrapChange: Codable, Sendable, Equatable {
        public let currentVersion: String?
        public let targetVersion: String

        public init(currentVersion: String?, targetVersion: String) {
            self.currentVersion = currentVersion
            self.targetVersion = targetVersion
        }
    }

    public var installEnvironments: [EnvironmentChange]
    public var reinstallEnvironments: [EnvironmentChange]
    /// Environments deliberately left alone: the manifest pins a different build, but the entry
    /// opted into `preserveExistingInstall` and a usable local install is already present.
    ///
    /// Advisory: this list is reported, never applied. It is excluded from `isEmpty` and
    /// `hasRequiredWork` so a machine carrying a preserved environment still reconciles clean.
    public var preservedEnvironments: [EnvironmentChange]
    public var removeEnvironments: [String]
    public var databaseUpdates: [DatabaseChange]
    public var pipelinePrefetch: [PipelineChange]
    public var bootstrapUpdate: BootstrapChange?
    public var targetDependencySet: String
    public var estimatedDownloadBytes: Int64

    public init(
        installEnvironments: [EnvironmentChange],
        reinstallEnvironments: [EnvironmentChange],
        removeEnvironments: [String],
        databaseUpdates: [DatabaseChange],
        pipelinePrefetch: [PipelineChange],
        bootstrapUpdate: BootstrapChange?,
        targetDependencySet: String,
        estimatedDownloadBytes: Int64,
        preservedEnvironments: [EnvironmentChange] = []
    ) {
        self.installEnvironments = installEnvironments
        self.reinstallEnvironments = reinstallEnvironments
        self.preservedEnvironments = preservedEnvironments
        self.removeEnvironments = removeEnvironments
        self.databaseUpdates = databaseUpdates
        self.pipelinePrefetch = pipelinePrefetch
        self.bootstrapUpdate = bootstrapUpdate
        self.targetDependencySet = targetDependencySet
        self.estimatedDownloadBytes = estimatedDownloadBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installEnvironments = try c.decode([EnvironmentChange].self, forKey: .installEnvironments)
        reinstallEnvironments = try c.decode([EnvironmentChange].self, forKey: .reinstallEnvironments)
        // Plans written before this field existed decode as "nothing was preserved".
        preservedEnvironments = try c.decodeIfPresent([EnvironmentChange].self, forKey: .preservedEnvironments) ?? []
        removeEnvironments = try c.decode([String].self, forKey: .removeEnvironments)
        databaseUpdates = try c.decode([DatabaseChange].self, forKey: .databaseUpdates)
        pipelinePrefetch = try c.decode([PipelineChange].self, forKey: .pipelinePrefetch)
        bootstrapUpdate = try c.decodeIfPresent(BootstrapChange.self, forKey: .bootstrapUpdate)
        targetDependencySet = try c.decode(String.self, forKey: .targetDependencySet)
        estimatedDownloadBytes = try c.decode(Int64.self, forKey: .estimatedDownloadBytes)
    }

    /// True when there is nothing at all to do.
    public var isEmpty: Bool {
        installEnvironments.isEmpty
            && reinstallEnvironments.isEmpty
            && removeEnvironments.isEmpty
            && databaseUpdates.isEmpty
            && pipelinePrefetch.isEmpty
            && bootstrapUpdate == nil
    }

    /// True when the plan contains work the user cannot defer: a required-pack environment
    /// change, or a database whose update policy is `.required`.
    public var hasRequiredWork: Bool {
        installEnvironments.contains(where: \.isRequired)
            || reinstallEnvironments.contains(where: \.isRequired)
            || databaseUpdates.contains { $0.policy == .required }
    }
}
