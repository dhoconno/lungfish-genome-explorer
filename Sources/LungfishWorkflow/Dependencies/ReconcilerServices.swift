// ReconcilerServices.swift - Every side effect reconciliation performs, injected for testing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DependencyReconciler")

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
    /// Whether `envs/<environment>/bin/<executable>` exists and is executable.
    ///
    /// Read by the planner only for manifest entries that set `preserveExistingInstall`: it is
    /// how "a usable install is already here" is judged without running the tool.
    public var environmentExecutableExists: @Sendable (_ environment: String, _ executable: String) -> Bool

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
        installedMicromambaVersion: @escaping @Sendable () async -> String?,
        environmentExecutableExists: @escaping @Sendable (String, String) -> Bool = { _, _ in false }
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
        self.environmentExecutableExists = environmentExecutableExists
    }
}

public extension ReconcilerServices {
    /// The real services, wired to `CondaManager`, the two database registries, and the
    /// bundled micromamba.
    ///
    /// Every member is a closure and nothing here touches the filesystem or spawns a process
    /// at construction time, so tests can start from `.live` and override only the closures
    /// they exercise without paying for (or being affected by) the real environment.
    static func live(
        condaManager: CondaManager,
        storageRoot: URL,
        metagenomicsRegistry: MetagenomicsDatabaseRegistry = .shared
    ) -> ReconcilerServices {
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
                Self.installedPackIDs(
                    manifest: ManagedToolLock.bundled,
                    environmentExists: { name in
                        FileManager.default.fileExists(
                            atPath: condaManager.rootPrefix.appendingPathComponent("envs/\(name)").path
                        )
                    }
                )
            },
            registryDatabaseVersions: {
                await Self.registryDatabaseVersions(storageRoot: storageRoot)
            },
            metagenomicsDatabaseVersions: {
                let databases = (try? await metagenomicsRegistry.installedDatabaseSnapshot()) ?? []
                return Self.metagenomicsDatabaseVersions(from: databases)
            },
            installedMicromambaVersion: {
                await Self.readMicromambaVersion(at: condaManager.rootPrefix.appendingPathComponent("bin/micromamba"))
            },
            environmentExecutableExists: { environment, executable in
                let url = condaManager.rootPrefix
                    .appendingPathComponent("envs/\(environment)/bin/\(executable)")
                return FileManager.default.isExecutableFile(atPath: url.path)
            }
        )
    }

    /// Which optional packs this machine has, judged only by the environments the manifest
    /// itself pins to each pack.
    ///
    /// The pack's own `toolRequirements` cannot answer this: several packs list the same
    /// general-purpose tool, so `wastewater-surveillance` (which requires `ivar` and `minimap2`
    /// alongside `freyja`) would count as installed on any machine that ever installed variant
    /// calling or read mapping. Reconciliation would then plan `freyja` for a user who never
    /// asked for it, and on arm64 that install cannot succeed. The manifest's `packTools` are
    /// the pack-specific pins, so a shared environment never licenses a pack that merely
    /// consumes it.
    ///
    /// A pack the manifest pins nothing for is never reported installed: with no pins there is
    /// no evidence to read, and inventing some would resurrect the same over-broad guess.
    static func installedPackIDs(
        manifest: ManagedToolLock,
        environmentExists: (String) -> Bool
    ) -> Set<String> {
        var pinnedEnvironments: [String: [String]] = [:]
        for packTool in manifest.packTools {
            pinnedEnvironments[packTool.packID, default: []].append(packTool.environment)
        }

        var installed: Set<String> = []
        for pack in PluginPack.builtIn {
            // The required pack is definitionally in scope; whether its environments exist is
            // what the plan is for.
            if pack.isRequiredBeforeLaunch {
                installed.insert(pack.id)
                continue
            }
            guard let environments = pinnedEnvironments[pack.id] else { continue }
            // Any one of *this pack's* environments present means the user opted in. Requiring
            // all of them would make a half-installed pack invisible to reconciliation, which is
            // exactly the state that needs repairing.
            if environments.contains(where: environmentExists) { installed.insert(pack.id) }
        }
        return installed
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

    /// Installed versions for `MetagenomicsDatabaseRegistry`-managed databases, keyed by
    /// the manifest database id the planner compares against.
    ///
    /// Keying by the row's *recorded* `catalogID` alone silently dropped every database a
    /// user registered from disk: `registerExisting` stores no catalog identity, so `Viral`
    /// and `Standard-16` on real machines have `catalogID == nil` and were never planned,
    /// while `db list` and `db info` advertised an update for them the whole time. Resolving
    /// through ``MetagenomicsDatabaseInfo/resolvedCatalogID`` applies the same two-step match
    /// those surfaces use, so what is advertised is what gets planned.
    ///
    /// When two rows resolve to the same catalog id (a hand-registered copy alongside a
    /// catalog-installed one, say), the row that records the identity itself wins: it is the
    /// one `resolveUpdateTarget` will actually replace, so the planned "installed version"
    /// must be its version and not the other row's.
    static func metagenomicsDatabaseVersions(
        from databases: [MetagenomicsDatabaseInfo]
    ) -> [String: String] {
        var versions: [String: String] = [:]
        var keyedByRecordedID: Set<String> = []
        for database in databases.sorted(by: { $0.name < $1.name }) where database.status == .ready {
            guard let catalogID = database.resolvedCatalogID, let version = database.version else { continue }
            if database.catalogID != nil {
                versions[catalogID] = version
                keyedByRecordedID.insert(catalogID)
            } else if !keyedByRecordedID.contains(catalogID), versions[catalogID] == nil {
                versions[catalogID] = version
            }
        }
        return versions
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
    ///
    /// The checksum is read from the manifest's `osx-arm64` entry unconditionally, which is
    /// correct only because the app ships a single arm64 binary and targets Apple Silicon
    /// exclusively. If a second architecture is ever bundled, this must select the entry by the
    /// running architecture instead: verifying an x86_64 binary against the arm64 hash would
    /// fail every install rather than catching a real mismatch.
    static func installBundledMicromamba(
        condaManager: CondaManager,
        targetVersion: String,
        bundledURL: URL? = RuntimeResourceLocator.path("Tools/micromamba", in: .workflow),
        expectedSHA256: String? = ManagedToolLock.bundled.bootstrap?.micromamba.sha256?["osx-arm64"],
        expectedPackagedSHA256: String? = ManagedToolLock.bundled.bootstrap?.micromamba.packagedSha256?["osx-arm64-adhoc"],
        signedBundleValidator: (@Sendable (URL) -> Bool)? = nil,
        versionProvider: (@Sendable (URL) async -> String?)? = nil
    ) async throws {
        guard let bundled = bundledURL else {
            throw CondaError.micromambaNotFound
        }
        guard let expectedSHA256, !expectedSHA256.isEmpty else {
            throw CondaError.micromambaDownloadFailed("manifest pins no micromamba sha256 for osx-arm64")
        }
        let actual = try Self.sha256Hex(of: bundled)
        let matchesUpstream = actual == expectedSHA256.lowercased()
        let matchesPackaged = expectedPackagedSHA256.map { actual == $0.lowercased() } ?? false
        let hasTrustedSignature = signedBundleValidator?(bundled)
            ?? BundledMicromambaIntegrity.validatesDeveloperIDPackage(executableURL: bundled)
        guard matchesUpstream || matchesPackaged || hasTrustedSignature else {
            throw CondaError.micromambaDownloadFailed(
                "bundled micromamba checksum \(actual) does not match a pinned source or packaged checksum and has no trusted app signature"
            )
        }
        let destination = await condaManager.micromambaPath
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".micromamba-\(UUID().uuidString).staged")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: bundled, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard try Self.sha256Hex(of: staged) == actual else {
            throw CondaError.micromambaDownloadFailed("staged micromamba changed while it was copied")
        }
        let observedVersion = if let versionProvider {
            await versionProvider(staged)
        } else {
            await readMicromambaVersion(at: staged)
        }
        guard let observedVersion,
              !DependencyPlanner.needsBootstrapUpdate(installed: observedVersion, target: targetVersion) else {
            throw CondaError.micromambaDownloadFailed(
                "bundled micromamba does not report the pinned version \(targetVersion)"
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        logger.info("Installed bundled micromamba \(targetVersion, privacy: .public) at \(destination.path, privacy: .public)")
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// How long `micromamba --version` may take before it is killed and treated as unreadable.
    ///
    /// A version probe that has not answered in ten seconds is not going to: the binary is
    /// wedged, being scanned, or sitting on an unresponsive volume. Reporting nil re-plans a
    /// bootstrap install, which is the right response to a micromamba that cannot answer.
    private static let micromambaVersionTimeout: TimeInterval = 10

    /// `micromamba --version`, or nil when the binary is missing, unrunnable, or too slow.
    ///
    /// The launch, read, and wait all run on a background queue rather than inline in the
    /// continuation: `readDataToEndOfFile` and `waitUntilExit` both block, and blocking a
    /// cooperative-pool thread starves every other task sharing it. stderr goes to the null
    /// device instead of a `Pipe`, because nothing drains a stderr pipe here and a child that
    /// fills the 64KB buffer would block forever writing to it.
    static func readMicromambaVersion(at path: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runMicromambaVersionProbe(at: path))
            }
        }
    }

    /// Blocking body of the version probe. Must be called off the cooperative pool.
    private static func runMicromambaVersionProbe(at path: URL) -> String? {
        let process = Process()
        process.executableURL = path
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.warning(
                "Could not run micromamba --version: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // Arm the timeout before reading: the read itself is what would otherwise hang, so
        // terminating the child is what unblocks it.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let deadline = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + micromambaVersionTimeout,
            execute: deadline
        )
        defer { deadline.cancel() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if timedOut.withLock({ $0 }) {
            logger.warning(
                "micromamba --version timed out after \(Int(micromambaVersionTimeout), privacy: .public)s"
            )
            return nil
        }
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return nil
        }
        return output
    }
}
