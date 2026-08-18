// DependencyPlanner.swift - Pure manifest-vs-machine diff
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Everything the planner needs to know about this machine.
///
/// The planner performs no IO: callers gather disk and registry state first and hand it over
/// as a snapshot, which keeps the diffing policy synchronous, deterministic, and testable.
public struct DependencyPlannerInputs: Sendable {
    public let manifest: ManagedToolLock
    public let receipt: DependencyReceipt
    /// Environment name -> packages read from its `conda-meta`. An empty array means the
    /// environment directory exists but carries no readable metadata.
    public let installedEnvironments: [String: [CondaMetaPackage]]
    /// Optional packs the user has installed; pack tools for other packs are not planned.
    public let installedPackIDs: Set<String>
    /// `DatabaseRegistry`-managed databases: id -> installed version. Installed entries only.
    public let registryDatabaseVersions: [String: String]
    /// Metagenomics catalog databases: catalog id -> installed version. Ready entries only.
    public let metagenomicsDatabaseVersions: [String: String]
    public let installedMicromambaVersion: String?
    /// Download-size estimate per environment, used for the plan's progress budget.
    public let estimatedEnvBytes: @Sendable (String) -> Int64

    public init(
        manifest: ManagedToolLock,
        receipt: DependencyReceipt,
        installedEnvironments: [String: [CondaMetaPackage]],
        installedPackIDs: Set<String>,
        registryDatabaseVersions: [String: String],
        metagenomicsDatabaseVersions: [String: String],
        installedMicromambaVersion: String?,
        estimatedEnvBytes: @escaping @Sendable (String) -> Int64 = { _ in 150 * 1_048_576 }
    ) {
        self.manifest = manifest
        self.receipt = receipt
        self.installedEnvironments = installedEnvironments
        self.installedPackIDs = installedPackIDs
        self.registryDatabaseVersions = registryDatabaseVersions
        self.metagenomicsDatabaseVersions = metagenomicsDatabaseVersions
        self.installedMicromambaVersion = installedMicromambaVersion
        self.estimatedEnvBytes = estimatedEnvBytes
    }
}

/// Diffs the dependency manifest against a snapshot of this machine, producing a
/// `ReconciliationPlan`. Pure: same inputs always yield the same plan, and output arrays are
/// sorted so plans are stable across runs.
public enum DependencyPlanner {
    /// Nextflow work-directory caches sit alongside managed environments and must never be
    /// proposed for removal: `env-<md5>` and bare hex names of hash length.
    private static let hexEnvPattern = try! NSRegularExpression(pattern: #"^(env-)?[0-9a-f]{32,64}$"#)

    static func isHexCacheEnvironment(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return hexEnvPattern.firstMatch(in: name, range: range) != nil
    }

    /// One environment the manifest wants present, with the pack that owns it.
    private struct DesiredEnvironment {
        let environment: String
        let spec: String
        let packID: String
        let isRequired: Bool
    }

    public static func plan(_ inputs: DependencyPlannerInputs) -> ReconciliationPlan {
        let manifest = inputs.manifest
        var plan = ReconciliationPlan(
            installEnvironments: [],
            reinstallEnvironments: [],
            removeEnvironments: [],
            databaseUpdates: [],
            pipelinePrefetch: [],
            bootstrapUpdate: nil,
            targetDependencySet: manifest.resolvedDependencySet,
            estimatedDownloadBytes: 0
        )

        planEnvironments(inputs, into: &plan)
        planRemovals(inputs, into: &plan)
        planDatabases(inputs, into: &plan)
        planPipelines(inputs, into: &plan)
        planBootstrap(inputs, into: &plan)

        return plan
    }

    // MARK: - Environments

    private static func planEnvironments(_ inputs: DependencyPlannerInputs, into plan: inout ReconciliationPlan) {
        let manifest = inputs.manifest
        // Managed tools are always desired; pack tools only for packs the user installed.
        var desired = manifest.tools.map {
            DesiredEnvironment(environment: $0.environment, spec: $0.packageSpec, packID: manifest.packID, isRequired: true)
        }
        for packTool in manifest.packTools where inputs.installedPackIDs.contains(packTool.packID) {
            desired.append(DesiredEnvironment(environment: packTool.environment, spec: packTool.packageSpec,
                                              packID: packTool.packID, isRequired: false))
        }

        for target in desired.sorted(by: { $0.environment < $1.environment }) {
            let receiptEntry = inputs.receipt.environments[target.environment]
            func change(_ reason: ReconciliationPlan.ChangeReason) -> ReconciliationPlan.EnvironmentChange {
                ReconciliationPlan.EnvironmentChange(
                    environment: target.environment,
                    packID: target.packID,
                    currentSpec: receiptEntry?.packageSpec,
                    targetSpec: target.spec,
                    reason: reason,
                    isRequired: target.isRequired
                )
            }

            guard let onDisk = inputs.installedEnvironments[target.environment] else {
                // No environment directory at all. Optional pack tools reach this only when the
                // pack is installed but its environment was removed underneath us.
                plan.installEnvironments.append(change(.missing))
                plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(target.environment)
                continue
            }

            guard let reason = reinstallReason(target: target, onDisk: onDisk, receiptEntry: receiptEntry) else { continue }
            plan.reinstallEnvironments.append(change(reason))
            plan.estimatedDownloadBytes += inputs.estimatedEnvBytes(target.environment)
        }

        plan.installEnvironments.sort { $0.environment < $1.environment }
        plan.reinstallEnvironments.sort { $0.environment < $1.environment }
    }

    /// Why this existing environment needs reinstalling, or nil when it already satisfies the manifest.
    ///
    /// Disk is the authority: the receipt only refines *why* disk disagrees. When the receipt
    /// already claims the manifest spec but disk says otherwise, something outside the app
    /// changed the environment, which is a `.metadataMismatch` rather than a normal upgrade.
    private static func reinstallReason(
        target: DesiredEnvironment,
        onDisk: [CondaMetaPackage],
        receiptEntry: DependencyReceipt.EnvironmentEntry?
    ) -> ReconciliationPlan.ChangeReason? {
        // An unparsable pin cannot be checked against anything, so treat the environment as unverifiable.
        guard let targetSpec = CondaSpec(spec: target.spec) else { return .metadataMismatch }
        // Covers both an environment with no readable conda-meta at all (empty array) and one
        // whose metadata lacks the pinned package: either way the install cannot be confirmed.
        guard let primary = onDisk.first(where: { $0.name == targetSpec.name }) else { return .metadataMismatch }

        if targetSpec.matches(primary) {
            // Disk satisfies the manifest. A receipt entry stuck in pending/failed still means
            // the recorded install never completed cleanly, so redo it.
            if let receiptEntry, receiptEntry.state != .installed { return .metadataMismatch }
            return nil
        }

        // Disk disagrees with the manifest. If the receipt already claims the manifest spec,
        // the receipt is lying about disk: tampering, not an upgrade.
        if receiptEntry?.packageSpec == target.spec { return .metadataMismatch }
        // Same version, different build string: a rebuild rather than a version bump.
        if primary.version == targetSpec.version { return .buildChanged }
        // A version bump the receipt recorded (or never recorded) is an ordinary spec change.
        return .specChanged
    }

    // MARK: - Retired environments

    private static func planRemovals(_ inputs: DependencyPlannerInputs, into plan: inout ReconciliationPlan) {
        let manifest = inputs.manifest
        // Every environment the manifest knows, including pack tools for packs that are not
        // installed: an uninstalled pack's environment is absent, not retired.
        let known = Set(manifest.tools.map(\.environment) + manifest.packTools.map(\.environment))
        for name in inputs.installedEnvironments.keys.sorted()
        where !known.contains(name) && !isHexCacheEnvironment(name) {
            plan.removeEnvironments.append(name)
        }
    }

    // MARK: - Databases

    private static func planDatabases(_ inputs: DependencyPlannerInputs, into plan: inout ReconciliationPlan) {
        for spec in inputs.manifest.databases.sorted(by: { $0.id < $1.id }) {
            let installed: (version: String, manager: ReconciliationPlan.DatabaseManager)?
            if let version = inputs.registryDatabaseVersions[spec.id] {
                installed = (version, .databaseRegistry)
            } else if let version = inputs.metagenomicsDatabaseVersions[spec.id] {
                installed = (version, .metagenomicsRegistry)
            } else {
                // Databases the user never downloaded are never planned: reconciliation
                // updates what is installed, it does not acquire new databases.
                installed = nil
            }
            guard let installed, installed.version != spec.version else { continue }

            let bytes = spec.sizeBytes ?? 0
            plan.databaseUpdates.append(ReconciliationPlan.DatabaseChange(
                id: spec.id,
                displayName: spec.displayName,
                installedVersion: installed.version,
                targetVersion: spec.version,
                policy: spec.effectiveUpdatePolicy,
                estimatedBytes: bytes,
                managedBy: installed.manager
            ))
            plan.estimatedDownloadBytes += bytes
        }
    }

    // MARK: - Pipelines

    private static func planPipelines(_ inputs: DependencyPlannerInputs, into plan: inout ReconciliationPlan) {
        for pipeline in inputs.manifest.pipelines.sorted(by: { $0.id < $1.id }) {
            // Only *recorded* drift is planned. A pipeline the receipt has never seen is not
            // stale, it is simply not prefetched yet, and Nextflow resolves it on first run;
            // planning those would mean no machine is ever fully reconciled.
            guard let current = inputs.receipt.pipelines[pipeline.id]?.revision,
                  current != pipeline.revision else { continue }
            plan.pipelinePrefetch.append(ReconciliationPlan.PipelineChange(
                id: pipeline.id,
                currentRevision: current,
                targetRevision: pipeline.revision
            ))
        }
    }

    // MARK: - Bootstrap

    private static func planBootstrap(_ inputs: DependencyPlannerInputs, into plan: inout ReconciliationPlan) {
        guard let target = inputs.manifest.bootstrap?.micromamba.version,
              inputs.installedMicromambaVersion != target else { return }
        plan.bootstrapUpdate = ReconciliationPlan.BootstrapChange(
            currentVersion: inputs.installedMicromambaVersion,
            targetVersion: target
        )
    }
}
