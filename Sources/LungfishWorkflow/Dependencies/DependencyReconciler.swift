// DependencyReconciler.swift - Applies a ReconciliationPlan and records what happened
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DependencyReconciler")

/// Where the reconciler reports progress, without `LungfishWorkflow` having to know about
/// `OperationCenter` (which lives in `LungfishKit`). The App supplies an adapter.
public protocol DependencyOperationSink: Sendable {
    func start(title: String, detail: String) -> UUID
    func update(id: UUID, progress: Double, detail: String)
    func log(id: UUID, message: String)
    func complete(id: UUID, detail: String)
    func fail(id: UUID, detail: String, error: String)
}

public enum DependencyReconcilerError: Error, LocalizedError, Equatable {
    case alreadyApplying

    public var errorDescription: String? {
        switch self {
        case .alreadyApplying:
            return "A tool update is already running. Wait for it to finish before starting another."
        }
    }
}

/// Every side effect reconciliation performs, injected so the actor is testable without
/// conda, the network, or the database registries.
public struct ReconcilerServices: Sendable {
    public var createEnvironment: @Sendable (
        _ name: String,
        _ spec: String,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Void
    public var removeEnvironment: @Sendable (_ name: String) async throws -> Void
    public var smokeTest: @Sendable (_ environment: String) async throws -> Void
    public var installRegistryDatabase: @Sendable (
        _ id: String,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL
    public var updateMetagenomicsDatabase: @Sendable (
        _ catalogID: String,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Void
    public var installBootstrap: @Sendable (_ targetVersion: String) async throws -> Void
    public var prefetchPipeline: @Sendable (_ id: String, _ revision: String) async throws -> Void
    public var listEnvironments: @Sendable () async -> [String: [CondaMetaPackage]]
    public var installedPackIDs: @Sendable () async -> Set<String>
    public var registryDatabaseVersions: @Sendable () async -> [String: String]
    public var metagenomicsDatabaseVersions: @Sendable () async -> [String: String]
    public var installedMicromambaVersion: @Sendable () async -> String?

    public init(
        createEnvironment: @escaping @Sendable (String, String, @escaping @Sendable (Double, String) -> Void) async throws -> Void,
        removeEnvironment: @escaping @Sendable (String) async throws -> Void,
        smokeTest: @escaping @Sendable (String) async throws -> Void,
        installRegistryDatabase: @escaping @Sendable (String, @escaping @Sendable (Double, String) -> Void) async throws -> URL,
        updateMetagenomicsDatabase: @escaping @Sendable (String, @escaping @Sendable (Double, String) -> Void) async throws -> Void,
        installBootstrap: @escaping @Sendable (String) async throws -> Void,
        prefetchPipeline: @escaping @Sendable (String, String) async throws -> Void,
        listEnvironments: @escaping @Sendable () async -> [String: [CondaMetaPackage]],
        installedPackIDs: @escaping @Sendable () async -> Set<String>,
        registryDatabaseVersions: @escaping @Sendable () async -> [String: String],
        metagenomicsDatabaseVersions: @escaping @Sendable () async -> [String: String],
        installedMicromambaVersion: @escaping @Sendable () async -> String?
    ) {
        self.createEnvironment = createEnvironment
        self.removeEnvironment = removeEnvironment
        self.smokeTest = smokeTest
        self.installRegistryDatabase = installRegistryDatabase
        self.updateMetagenomicsDatabase = updateMetagenomicsDatabase
        self.installBootstrap = installBootstrap
        self.prefetchPipeline = prefetchPipeline
        self.listEnvironments = listEnvironments
        self.installedPackIDs = installedPackIDs
        self.registryDatabaseVersions = registryDatabaseVersions
        self.metagenomicsDatabaseVersions = metagenomicsDatabaseVersions
        self.installedMicromambaVersion = installedMicromambaVersion
    }
}

public extension ReconcilerServices {
    /// The real services, wired to `CondaManager`, the two database registries, and the
    /// bundled micromamba.
    ///
    /// Every member is a closure and nothing here touches the filesystem or spawns a process
    /// at construction time, so tests can start from `.live` and override only the closures
    /// they exercise without paying for (or being affected by) the real environment.
    static func live(condaManager: CondaManager, storageRoot: URL) -> ReconcilerServices {
        ReconcilerServices(
            createEnvironment: { name, spec, progress in
                try await condaManager.createEnvironment(name: name, packages: [spec], progress: progress)
            },
            removeEnvironment: { name in
                try await condaManager.removeEnvironment(name: name)
            },
            smokeTest: { environment in
                guard let requirement = Self.requirement(forEnvironment: environment) else { return }
                try await PluginPackStatusService.runSmokeTest(requirement, condaManager: condaManager)
            },
            installRegistryDatabase: { id, progress in
                try await DatabaseRegistry.shared.installManagedDatabase(id, reinstall: true, progress: progress)
            },
            updateMetagenomicsDatabase: { catalogID, progress in
                try await MetagenomicsDatabaseRegistry.shared.updateDatabase(catalogID: catalogID, progress: progress)
            },
            installBootstrap: { targetVersion in
                try await Self.installBundledMicromamba(condaManager: condaManager, targetVersion: targetVersion)
            },
            prefetchPipeline: { id, revision in
                // TaxTriagePipeline resolves and caches its repository on first run and exposes
                // no public prefetch entry point, so there is nothing to warm here. Recording
                // the pinned revision in the receipt is what keeps a later bump visible as drift.
                logger.info(
                    "Pipeline prefetch for '\(id, privacy: .public)' at \(revision, privacy: .public) skipped: no public prefetch API"
                )
            },
            listEnvironments: {
                let envsURL = condaManager.rootPrefix.appendingPathComponent("envs", isDirectory: true)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: envsURL.path)) ?? []
                var result: [String: [CondaMetaPackage]] = [:]
                for name in names where !name.hasPrefix(".") {
                    result[name] = CondaMetaReader.packages(inEnvironment: envsURL.appendingPathComponent(name))
                }
                return result
            },
            installedPackIDs: {
                var installed: Set<String> = []
                for pack in PluginPack.builtIn {
                    if pack.isRequiredBeforeLaunch {
                        // The required pack is definitionally in scope; whether its environments
                        // exist is what the plan is for.
                        installed.insert(pack.id)
                        continue
                    }
                    let environments = pack.toolRequirements
                        .filter { $0.managedDatabaseID == nil }
                        .map(\.environment)
                    guard !environments.isEmpty else { continue }
                    // Any one environment present means the user opted into this pack. Requiring
                    // all of them would make a half-installed pack invisible to reconciliation,
                    // which is exactly the state that needs repairing.
                    let anyPresent = environments.contains { name in
                        FileManager.default.fileExists(
                            atPath: condaManager.rootPrefix.appendingPathComponent("envs/\(name)").path
                        )
                    }
                    if anyPresent { installed.insert(pack.id) }
                }
                return installed
            },
            registryDatabaseVersions: {
                await Self.registryDatabaseVersions(storageRoot: storageRoot)
            },
            metagenomicsDatabaseVersions: {
                let databases = (try? await MetagenomicsDatabaseRegistry.shared.availableDatabases()) ?? []
                var versions: [String: String] = [:]
                for database in databases where database.status == .ready {
                    guard let catalogID = database.catalogID, let version = database.version else { continue }
                    versions[catalogID] = version
                }
                return versions
            },
            installedMicromambaVersion: {
                await Self.readMicromambaVersion(at: condaManager.rootPrefix.appendingPathComponent("bin/micromamba"))
            }
        )
    }

    /// The pack requirement that owns `environment`, used to find its smoke test.
    private static func requirement(forEnvironment environment: String) -> PackToolRequirement? {
        for pack in PluginPack.builtIn {
            if let match = pack.toolRequirements.first(where: { $0.environment == environment }) {
                return match
            }
        }
        return nil
    }

    /// Installed versions for `DatabaseRegistry`-managed databases.
    ///
    /// The registry does not record a version per install, so the version is recovered in
    /// order of confidence: what our own receipt recorded, then the manifest version when the
    /// installed filename matches what the manifest pins, and `"unknown"` otherwise (which the
    /// planner treats as drift, so a database of indeterminate age is offered for update).
    private static func registryDatabaseVersions(storageRoot: URL) async -> [String: String] {
        let manifest = ManagedToolLock.bundled
        let receipt = try? DependencyReceiptStore(storageRoot: storageRoot).load()
        var versions: [String: String] = [:]
        for id in DatabaseRegistry.knownIDs {
            guard let installedPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: id) else { continue }
            if let recorded = receipt?.databases[id]?.version {
                versions[id] = recorded
            } else if let spec = manifest.database(id: id), spec.filename == installedPath.lastPathComponent {
                versions[id] = spec.version
            } else {
                versions[id] = "unknown"
            }
        }
        return versions
    }

    /// Copies the app-bundled micromamba over the conda root's copy, verifying the manifest
    /// checksum first when one is pinned.
    private static func installBundledMicromamba(condaManager: CondaManager, targetVersion: String) async throws {
        guard let bundled = RuntimeResourceLocator.path("Tools/micromamba", in: .workflow) else {
            throw CondaError.micromambaNotFound
        }
        let expected = ManagedToolLock.bundled.bootstrap?.micromamba.sha256?["osx-arm64"]
        if let expected, !expected.isEmpty {
            let actual = try Self.sha256Hex(of: bundled)
            guard actual == expected.lowercased() else {
                throw CondaError.micromambaDownloadFailed(
                    "bundled micromamba checksum \(actual) does not match the pinned \(expected)"
                )
            }
        } else {
            logger.info("Manifest pins no micromamba sha256 for osx-arm64; installing bundled binary unverified")
        }

        let destination = await condaManager.micromambaPath
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: bundled, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        logger.info("Installed bundled micromamba \(targetVersion, privacy: .public) at \(destination.path, privacy: .public)")
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `micromamba --version`, or nil when the binary is missing or unrunnable.
    private static func readMicromambaVersion(at path: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = path
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty
            else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: output)
        }
    }
}

/// Which parts of a plan the caller chose to apply.
public struct PlanSelection: Sendable, Equatable {
    public var environments: Set<String>
    public var databases: Set<String>
    public var includeRemovals: Bool

    public init(environments: Set<String>, databases: Set<String>, includeRemovals: Bool) {
        self.environments = environments
        self.databases = databases
        self.includeRemovals = includeRemovals
    }

    /// Everything the plan proposes.
    public static func all(from plan: ReconciliationPlan) -> PlanSelection {
        PlanSelection(
            environments: Set(
                plan.installEnvironments.map(\.environment) + plan.reinstallEnvironments.map(\.environment)
            ),
            databases: Set(plan.databaseUpdates.map(\.id)),
            includeRemovals: true
        )
    }

    /// Only the work the user cannot defer: required environments and `.required` databases.
    /// Removals are deferrable, so they are excluded.
    public static func requiredOnly(from plan: ReconciliationPlan) -> PlanSelection {
        PlanSelection(
            environments: Set(
                (plan.installEnvironments + plan.reinstallEnvironments)
                    .filter(\.isRequired)
                    .map(\.environment)
            ),
            databases: Set(plan.databaseUpdates.filter { $0.policy == .required }.map(\.id)),
            includeRemovals: false
        )
    }
}

/// What one `apply` accomplished.
public struct ReconciliationResult: Sendable, Equatable {
    /// Item identifiers (environment names, database ids, "micromamba") that succeeded.
    public var succeeded: [String]
    /// Item identifier -> failure message.
    public var failed: [String: String]
    public var receipt: DependencyReceipt

    public init(succeeded: [String], failed: [String: String], receipt: DependencyReceipt) {
        self.succeeded = succeeded
        self.failed = failed
        self.receipt = receipt
    }
}

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
            knownEnvironmentNames: Self.builtInPackEnvironmentNames()
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

        let installedEnvironments = await services.listEnvironments()
        for change in environmentChanges {
            let failure = await runItem(
                id: change.environment,
                title: "Install \(change.environment) \(change.targetSpec)",
                kind: .environment,
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
            failed["dependency-receipt"] = error.localizedDescription
        }

        if let parent {
            let detail = failed.isEmpty
                ? "Updated \(succeeded.count) item(s) to \(plan.targetDependencySet)"
                : "\(succeeded.count) updated, \(failed.count) failed"
            if failed.isEmpty {
                operationCenter?.complete(id: parent, detail: detail)
            } else {
                operationCenter?.fail(
                    id: parent,
                    detail: detail,
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
        let report: @Sendable (Double, String) -> Void = { fraction, message in
            progress(id, fraction, message)
            if let operation { sink?.update(id: operation, progress: fraction, detail: message) }
        }

        do {
            try await body(report)
            succeeded.append(id)
            records.append(.init(
                id: id, kind: kind, title: title, failure: nil,
                startedAt: startedAt, endedAt: Date()
            ))
            if let operation { sink?.complete(id: operation, detail: "\(id) ready") }
            return nil
        } catch {
            let message = error.localizedDescription
            failed[id] = message
            if isRequired { requiredFailed = true }
            records.append(.init(
                id: id, kind: kind, title: title, failure: message,
                startedAt: startedAt, endedAt: Date()
            ))
            logger.error("Reconcile item '\(id, privacy: .public)' failed: \(message, privacy: .public)")
            if let operation { sink?.fail(id: operation, detail: "\(id) failed", error: message) }
            return message
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
