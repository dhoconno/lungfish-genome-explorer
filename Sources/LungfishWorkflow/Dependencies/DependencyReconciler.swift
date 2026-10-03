// DependencyReconciler.swift - Applies a ReconciliationPlan and records what happened
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DependencyReconciler")

/// Brings this machine in line with the dependency manifest.
///
/// The reconciler owns the receipt: every item transitions through `.pending` and lands on
/// `.installed` or `.failed`, and the receipt is saved after each transition so an interrupted
/// update resumes where it stopped rather than restarting. The manifest's `dependencySet` is
/// stamped only when no *required* item failed, which is what keeps a partially updated machine
/// re-planning the same remaining work at the next launch.
public actor DependencyReconciler {
    private let manifest: ManagedToolLock
    private let storageRoot: URL
    private let services: ReconcilerServices
    private let appVersion: String
    private let operationCenter: DependencyOperationSink?
    private let store: DependencyReceiptStore
    /// Guards against a second apply while one is in flight; the receipt is not
    /// safe to interleave writes into.
    private var isApplying = false

    /// Key under which a failure to persist the receipt is reported in `ReconciliationResult.failed`.
    ///
    /// Not an installable item: it names the bookkeeping step, so callers can tell "your tools
    /// did not install" apart from "your tools installed but we could not write that down".
    public static let receiptItemID = "dependency-receipt"

    public init(
        manifest: ManagedToolLock,
        storageRoot: URL,
        services: ReconcilerServices,
        appVersion: String,
        operationCenter: DependencyOperationSink?
    ) {
        self.manifest = manifest
        self.storageRoot = storageRoot.standardizedFileURL
        self.services = services
        self.appVersion = appVersion
        self.operationCenter = operationCenter
        self.store = DependencyReceiptStore(storageRoot: storageRoot)
    }

    // MARK: - Receipt

    /// The stored receipt, or one synthesized from what is installed.
    ///
    /// A synthesized receipt is deliberately NOT saved: persisting it would claim the app
    /// installed environments it merely found, and would mask a corrupt receipt as a clean
    /// one. It is written for the first time by a successful apply or by `stampCurrentSet()`.
    public func loadOrSynthesizeReceipt() async throws -> DependencyReceipt {
        do {
            if let stored = try store.load() { return stored }
            logger.info("No dependency receipt found; synthesizing from installed environments")
        } catch {
            logger.warning(
                "Dependency receipt unreadable (\(error.localizedDescription, privacy: .public)); synthesizing from installed environments"
            )
        }
        return store.synthesize(environments: await services.listEnvironments(), manifest: manifest)
    }

    // MARK: - Planning

    public func currentPlan() async throws -> ReconciliationPlan {
        let receipt = try await loadOrSynthesizeReceipt()
        let inputs = DependencyPlannerInputs(
            manifest: manifest,
            receipt: receipt,
            installedEnvironments: await services.listEnvironments(),
            installedPackIDs: await services.installedPackIDs(),
            registryDatabaseVersions: await services.registryDatabaseVersions(),
            metagenomicsDatabaseVersions: await services.metagenomicsDatabaseVersions(),
            installedMicromambaVersion: await services.installedMicromambaVersion(),
            knownEnvironmentNames: Self.builtInPackEnvironmentNames(),
            environmentExecutableExists: services.environmentExecutableExists
        )
        return DependencyPlanner.plan(inputs)
    }

    /// Every environment name any built-in pack owns, whether or not this manifest pins it.
    ///
    /// Passed to the planner as `knownEnvironmentNames` so a pack-owned environment is never
    /// mistaken for a stale leftover and proposed for removal. Both `requirements` (the modern
    /// form) and bare `packages` (the legacy form, where the package name is the environment
    /// name) contribute.
    static func builtInPackEnvironmentNames() -> Set<String> {
        var names: Set<String> = []
        for pack in PluginPack.builtIn {
            for requirement in pack.requirements {
                names.insert(requirement.environment)
            }
            names.formUnion(pack.packages)
        }
        return names
    }

    // MARK: - Applying

    /// Runs the selected parts of `plan`, saving the receipt after every state transition.
    ///
    /// Order: bootstrap, required environments, optional environments, databases, removals,
    /// pipeline prefetch. Failures never abort the run: each item records its own failure and
    /// the next item proceeds, because a machine that gets four of five tools updated is
    /// strictly better off than one that stops at the first error.
    @discardableResult
    public func apply(
        _ plan: ReconciliationPlan,
        selection: PlanSelection,
        progress: @escaping @Sendable (String, Double, String) -> Void
    ) async throws -> ReconciliationResult {
        guard !isApplying else { throw DependencyReconcilerError.alreadyApplying }
        isApplying = true
        defer { isApplying = false }

        let startedAt = Date()
        var receipt = try await loadOrSynthesizeReceipt()
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        var records: [DependencyReconcilerProvenance.ItemRecord] = []
        // Only a *required* failure withholds the dependency-set stamp. An optional pack tool
        // or an advisory database that fails leaves the set current for everything else.
        var requiredFailed = false

        let parent = operationCenter?.start(
            title: "Update tools to \(plan.targetDependencySet)",
            detail: applyDetail(plan: plan, selection: selection)
        )

        // 1. Bootstrap: micromamba drives every environment operation that follows.
        if let bootstrap = plan.bootstrapUpdate {
            await runItem(
                id: "micromamba",
                title: "Update micromamba to \(bootstrap.targetVersion)",
                kind: .bootstrap,
                targetVersion: bootstrap.targetVersion,
                isRequired: true,
                progress: progress,
                succeeded: &succeeded,
                failed: &failed,
                requiredFailed: &requiredFailed,
                records: &records
            ) { report in
                try await self.services.installBootstrap(bootstrap.targetVersion)
                report(1.0, "micromamba \(bootstrap.targetVersion) installed")
                receipt.bootstrap = .init(micromambaVersion: bootstrap.targetVersion)
                receipt = self.saveBookkeeping(receipt)
            }
        }

        // 2. Environments: required first, so a partially completed run leaves the app usable.
        let environmentChanges = (plan.installEnvironments + plan.reinstallEnvironments)
            .filter { selection.environments.contains($0.environment) }
            .sorted { lhs, rhs in
                lhs.isRequired == rhs.isRequired
                    ? lhs.environment < rhs.environment
                    : (lhs.isRequired && !rhs.isRequired)
            }

        // Captured once, before the loop, and deliberately not refreshed inside it. A create
        // that fails partway can leave a directory behind; re-reading disk per item would make
        // later items see that debris as "already installed" and try to remove it, turning one
        // failure into a different kind. The pre-loop snapshot answers the only question this
        // loop actually asks -- was this environment there when the run started -- and the env
        // loop is the sole mutator of environment directories during an apply, so nothing else
        // invalidates it.
        let installedEnvironments = await services.listEnvironments()
        for change in environmentChanges {
            let failure = await runItem(
                id: change.environment,
                title: "Install \(change.environment) \(change.targetSpec)",
                kind: .environment,
                targetVersion: CondaSpec(spec: change.targetSpec)?.version ?? "unknown",
                isRequired: change.isRequired,
                progress: progress,
                succeeded: &succeeded,
                failed: &failed,
                requiredFailed: &requiredFailed,
                records: &records
            ) { report in
                receipt.environments[change.environment] = .init(
                    packageSpec: change.targetSpec,
                    packID: change.packID,
                    installedAt: Date(),
                    state: .pending
                )
                receipt = self.saveBookkeeping(receipt)

                // A reinstall replaces the environment rather than solving on top of it, so a
                // downgrade or a build change cannot leave the old package behind.
                if installedEnvironments[change.environment] != nil {
                    try await self.services.removeEnvironment(change.environment)
                }
                try await self.services.createEnvironment(change.environment, change.targetSpec) { fraction, message in
                    report(fraction, message)
                }
                try await self.services.smokeTest(change.environment)

                receipt.environments[change.environment] = .init(
                    packageSpec: change.targetSpec,
                    packID: change.packID,
                    installedAt: Date(),
                    state: .installed
                )
                receipt = self.saveBookkeeping(receipt)
            }

            // A failed environment is recorded as `.failed` rather than left `.pending`, so the
            // next plan sees a definite outcome and re-proposes the work.
            if failure != nil {
                receipt.environments[change.environment] = .init(
                    packageSpec: change.targetSpec,
                    packID: change.packID,
                    installedAt: Date(),
                    state: .failed
                )
                receipt = saveBookkeeping(receipt)
            }
        }

        // 3. Databases the caller selected.
        for update in plan.databaseUpdates where selection.databases.contains(update.id) {
            await runItem(
                id: update.id,
                title: "Update \(update.displayName) to \(update.targetVersion)",
                kind: .database,
                targetVersion: update.targetVersion,
                isRequired: update.policy == .required,
                progress: progress,
                succeeded: &succeeded,
                failed: &failed,
                requiredFailed: &requiredFailed,
                records: &records
            ) { report in
                switch update.managedBy {
                case .databaseRegistry:
                    let installedURL = try await self.services.installRegistryDatabase(update.id) { fraction, message in
                        report(fraction, message)
                    }
                    // Only DatabaseRegistry-managed databases are recorded here; the
                    // metagenomics registry keeps its own manifest of installed versions.
                    receipt.databases[update.id] = .init(
                        version: update.targetVersion,
                        path: installedURL.path,
                        installedAt: Date()
                    )
                    receipt = self.saveBookkeeping(receipt)
                case .metagenomicsRegistry:
                    try await self.services.updateMetagenomicsDatabase(update.id) { fraction, message in
                        report(fraction, message)
                    }
                }
            }
        }

        // 4. Removals, only once every required item succeeded: removing a retired environment
        // while a replacement failed to install would take away a tool and give nothing back.
        if selection.includeRemovals && !requiredFailed {
            for name in plan.removeEnvironments {
                await runItem(
                    id: name,
                    title: "Remove retired environment \(name)",
                    kind: .removal,
                    isRequired: false,
                    progress: progress,
                    succeeded: &succeeded,
                    failed: &failed,
                    requiredFailed: &requiredFailed,
                    records: &records
                ) { report in
                    try await self.services.removeEnvironment(name)
                    receipt.environments.removeValue(forKey: name)
                    receipt = self.saveBookkeeping(receipt)
                    report(1.0, "Removed \(name)")
                }
            }
        } else if selection.includeRemovals {
            logger.info("Skipping \(plan.removeEnvironments.count) removal(s): a required item failed")
        }

        // 5. Pipeline prefetch is best effort: Nextflow resolves an un-prefetched revision on
        // first run, so a prefetch failure is not a reconciliation failure.
        for prefetch in plan.pipelinePrefetch {
            do {
                try await services.prefetchPipeline(prefetch.id, prefetch.targetRevision)
                succeeded.append(prefetch.id)
            } catch {
                logger.warning(
                    "Pipeline prefetch for '\(prefetch.id, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // The set is stamped only when no required item failed; the item states are persisted
        // either way, so the next plan sees exactly what happened. A save failure here must not
        // discard the run: the work is already done on disk, and throwing past the operation and
        // provenance bookkeeping would leave the user with an install they cannot see recorded.
        if !requiredFailed {
            receipt = stampSet(into: receipt)
        }
        do {
            receipt = try store.save(receipt)
        } catch {
            logger.error(
                "Failed to save the dependency receipt after reconciling: \(error.localizedDescription, privacy: .public)"
            )
            failed[Self.receiptItemID] = error.localizedDescription
        }

        if let parent {
            // A counts line in the parent's history, so the expanded row summarises the run
            // without the reader having to add up the child rows themselves.
            operationCenter?.log(
                id: parent,
                message: "Finished \(plan.targetDependencySet): \(succeeded.count) succeeded, \(failed.count) failed"
            )
            // An unsaveable receipt is the one "failure" that is not a failure of the work: every
            // real item succeeded and the tools are installed. Failing the parent operation over
            // it would tell the user their update did not happen, which is the opposite of true,
            // so that case completes with a warning instead.
            let realFailures = failed.filter { $0.key != Self.receiptItemID }
            if failed.isEmpty {
                operationCenter?.complete(
                    id: parent,
                    detail: "Updated \(succeeded.count) item(s) to \(plan.targetDependencySet)"
                )
            } else if realFailures.isEmpty {
                operationCenter?.completeWithWarning(
                    id: parent,
                    detail: "Updated \(succeeded.count) item(s) to \(plan.targetDependencySet); completed with warning: receipt not saved"
                )
            } else {
                operationCenter?.fail(
                    id: parent,
                    detail: "\(succeeded.count) updated, \(realFailures.count) failed",
                    error: failed.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
                )
            }
        }

        DependencyReconcilerProvenance.write(
            records: records,
            plan: plan,
            manifest: manifest,
            storageRoot: storageRoot,
            appVersion: appVersion,
            startedAt: startedAt,
            endedAt: Date()
        )

        return ReconciliationResult(succeeded: succeeded, failed: failed, receipt: receipt)
    }

    /// Saves an in-progress receipt, treating a write failure as a bookkeeping problem rather
    /// than an item failure.
    ///
    /// These mid-apply saves exist so an interrupted run resumes accurately. That is worth
    /// having, but it must not gate the install itself: a storage root that cannot be written
    /// would otherwise turn every item into a failure before the install was even attempted,
    /// which is a strictly worse outcome than an install whose progress note went unrecorded.
    /// The final save at the end of `apply` is where an unwritable receipt is reported.
    private func saveBookkeeping(_ receipt: DependencyReceipt) -> DependencyReceipt {
        do {
            return try store.save(receipt)
        } catch {
            logger.warning(
                "Could not record dependency progress: \(error.localizedDescription, privacy: .public)"
            )
            return receipt
        }
    }

    /// Records the manifest's dependency set as current without doing any work.
    ///
    /// Used at launch when the plan is empty: the machine already satisfies the manifest, so
    /// the receipt should say so (including pipeline revisions, so a later revision bump is
    /// planned as drift rather than silently ignored).
    public func stampCurrentSet() async throws {
        var receipt = try await loadOrSynthesizeReceipt()
        receipt = stampSet(into: receipt)
        try store.save(receipt)
    }

    /// Marks `receipt` as satisfying the current manifest: the set identifier, the manifest
    /// hash, the app version, the pinned pipeline revisions, and the bootstrap version.
    private func stampSet(into receipt: DependencyReceipt) -> DependencyReceipt {
        var receipt = receipt
        receipt.dependencySet = manifest.resolvedDependencySet
        receipt.manifestHash = manifest.manifestHash
        receipt.appVersion = appVersion
        receipt.synthesized = false
        for pipeline in manifest.pipelines {
            receipt.pipelines[pipeline.id] = .init(
                revision: pipeline.revision,
                prefetchedAt: receipt.pipelines[pipeline.id]?.prefetchedAt
            )
        }
        if let micromamba = manifest.bootstrap?.micromamba.version {
            receipt.bootstrap = .init(micromambaVersion: micromamba)
        }
        return receipt
    }

    // MARK: - Item execution

    /// Runs one item as its own operation, converting a thrown error into a recorded failure.
    ///
    /// `body` receives a `report` closure that forwards item progress to both the caller's
    /// progress callback and the operation sink. Returns the failure message, or nil on success,
    /// so the caller can record item-specific fallout (a `.failed` receipt entry, say) without
    /// a second closure racing `body` for the same mutable state.
    @discardableResult
    private func runItem(
        id: String,
        title: String,
        kind: DependencyReconcilerProvenance.ItemKind,
        targetVersion: String = "unknown",
        isRequired: Bool,
        progress: @escaping @Sendable (String, Double, String) -> Void,
        succeeded: inout [String],
        failed: inout [String: String],
        requiredFailed: inout Bool,
        records: inout [DependencyReconcilerProvenance.ItemRecord],
        body: (@escaping @Sendable (Double, String) -> Void) async throws -> Void
    ) async -> String? {
        let operation = operationCenter?.start(title: title, detail: id)
        let sink = operationCenter
        let startedAt = Date()
        // Progress updates replace the row's detail line; the log is what the expanded row
        // keeps. Without a log call an item leaves no history behind at all, so each item
        // records its start, its outcome, and (on failure) the error.
        if let operation { sink?.log(id: operation, message: Self.itemStartLogMessage(kind: kind, title: title)) }
        let report: @Sendable (Double, String) -> Void = { fraction, message in
            progress(id, fraction, message)
            if let operation { sink?.update(id: operation, progress: fraction, detail: message) }
        }

        do {
            try await body(report)
            succeeded.append(id)
            records.append(.init(
                id: id, kind: kind, title: title, targetVersion: targetVersion, failure: nil,
                startedAt: startedAt, endedAt: Date()
            ))
            if let operation {
                sink?.log(id: operation, message: "\(id) ready")
                sink?.complete(id: operation, detail: "\(id) ready")
            }
            return nil
        } catch {
            let message = error.localizedDescription
            failed[id] = message
            if isRequired { requiredFailed = true }
            records.append(.init(
                id: id, kind: kind, title: title, targetVersion: targetVersion, failure: message,
                startedAt: startedAt, endedAt: Date()
            ))
            logger.error("Reconcile item '\(id, privacy: .public)' failed: \(message, privacy: .public)")
            if let operation {
                sink?.log(id: operation, message: "\(id) failed: \(message)")
                sink?.fail(id: operation, detail: "\(id) failed", error: message)
            }
            return message
        }
    }

    /// The opening history line for an item, phrased for what the item actually does.
    ///
    /// `title` already names the target ("Install samtools <its full conda spec>", "Remove
    /// retired environment foo"), so the verb comes from the kind and the specifics come from
    /// the title rather than being rebuilt here.
    private static func itemStartLogMessage(
        kind: DependencyReconcilerProvenance.ItemKind,
        title: String
    ) -> String {
        switch kind {
        case .environment, .bootstrap:
            return "Installing: \(title)"
        case .database:
            return "Updating database: \(title)"
        case .removal:
            return "Removing: \(title)"
        }
    }

    private func applyDetail(plan: ReconciliationPlan, selection: PlanSelection) -> String {
        let environments = (plan.installEnvironments + plan.reinstallEnvironments)
            .filter { selection.environments.contains($0.environment) }
            .count
        let databases = plan.databaseUpdates.filter { selection.databases.contains($0.id) }.count
        return "\(environments) tool(s), \(databases) database(s)"
    }
}
