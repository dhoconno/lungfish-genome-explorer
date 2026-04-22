@preconcurrency import Foundation
import LungfishCore
import os.log

private let logger = Logger(
    subsystem: LogSubsystem.workflow,
    category: "PluginPackStatusService"
)

public enum PluginPackState: String, Sendable, Codable, Hashable {
    case ready
    case needsInstall
    case installing
    case failed
}

public struct PluginPackInstallProgress: Sendable, Codable, Hashable {
    public let requirementID: String?
    public let requirementDisplayName: String?
    public let overallFraction: Double
    public let itemFraction: Double
    public let message: String

    public init(
        requirementID: String?,
        requirementDisplayName: String?,
        overallFraction: Double,
        itemFraction: Double,
        message: String
    ) {
        self.requirementID = requirementID
        self.requirementDisplayName = requirementDisplayName
        self.overallFraction = overallFraction
        self.itemFraction = itemFraction
        self.message = message
    }
}

public struct PackToolStatus: Sendable, Codable, Hashable, Identifiable {
    public let requirement: PackToolRequirement
    public let environmentExists: Bool
    public let missingExecutables: [String]
    public let smokeTestFailure: String?
    public let storageUnavailablePath: String?

    public init(
        requirement: PackToolRequirement,
        environmentExists: Bool,
        missingExecutables: [String],
        smokeTestFailure: String?,
        storageUnavailablePath: String?
    ) {
        self.requirement = requirement
        self.environmentExists = environmentExists
        self.missingExecutables = missingExecutables
        self.smokeTestFailure = smokeTestFailure
        self.storageUnavailablePath = storageUnavailablePath
    }

    public var id: String { requirement.id }
    public var isReady: Bool {
        storageUnavailablePath == nil && missingExecutables.isEmpty && smokeTestFailure == nil
    }
    public var needsReinstall: Bool { storageUnavailablePath == nil && environmentExists && !isReady }
    public var hasVolatileSmokeTestFailure: Bool { smokeTestFailure != nil }

    public var statusText: String {
        if storageUnavailablePath != nil {
            return "Storage unavailable"
        }
        if isReady {
            return "Ready"
        }
        if requirement.managedDatabaseID != nil {
            return environmentExists ? "Needs refresh" : "Needs download"
        }
        if needsReinstall {
            return "Needs reinstall"
        }
        return "Needs install"
    }
}

public struct PluginPackStatus: Sendable, Codable, Hashable, Identifiable {
    public let pack: PluginPack
    public let state: PluginPackState
    public let toolStatuses: [PackToolStatus]
    public let failureMessage: String?

    public init(
        pack: PluginPack,
        state: PluginPackState,
        toolStatuses: [PackToolStatus],
        failureMessage: String?
    ) {
        self.pack = pack
        self.state = state
        self.toolStatuses = toolStatuses
        self.failureMessage = failureMessage
    }

    public var id: String { pack.id }
    public var shouldReinstall: Bool {
        toolStatuses.contains {
            $0.requirement.managedDatabaseID == nil && $0.needsReinstall
        }
    }
    public var hasVolatileSmokeTestFailure: Bool {
        toolStatuses.contains(where: \.hasVolatileSmokeTestFailure)
    }
}

public protocol PluginPackStatusProviding: Sendable {
    func visibleStatuses() async -> [PluginPackStatus]
    func status(for pack: PluginPack) async -> PluginPackStatus
    func status(forPackID packID: String) async -> PluginPackStatus?
    func invalidateVisibleStatusesCache() async
    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws
}

public extension PluginPackStatusProviding {
    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return await status(for: pack)
    }
}

public enum PluginPackStatusServiceError: Swift.Error, LocalizedError, Equatable {
    case storageUnavailable(URL)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let root):
            return "Storage location unavailable: \(root.path)"
        }
    }
}

public actor PluginPackStatusService: PluginPackStatusProviding {
    private struct CachedPackStatus {
        let generation: Int
        let timestamp: Date
        let status: PluginPackStatus
        let fingerprint: PackStatusFingerprint?
    }

    private struct PlannedInstallTarget {
        let requirement: PackToolRequirement
        let reinstall: Bool
    }

    private struct PackStatusFingerprint: Codable, Equatable {
        let components: [String]
    }

    private struct PersistedPackStatusSnapshot: Codable {
        let timestamp: Date
        let status: PluginPackStatus
        let fingerprint: PackStatusFingerprint?
    }

    private struct PersistedVisibleStatusesSnapshot: Codable {
        let timestamp: Date
        let statuses: [PluginPackStatus]
    }

    private struct PersistedStatusSnapshotStore: Codable {
        let visibleStatuses: PersistedVisibleStatusesSnapshot?
        let packStatuses: [String: PersistedPackStatusSnapshot]
    }

    public typealias InstallAction = @Sendable (
        _ packages: [String],
        _ environment: String,
        _ reinstall: Bool,
        _ progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> Void
    public typealias DatabaseInstallAction = @Sendable (
        _ databaseID: String,
        _ reinstall: Bool,
        _ progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL
    public typealias DatabaseInstalledCheck = @Sendable (_ databaseID: String) async -> Bool
    public typealias StorageAvailability = @Sendable () -> ManagedStorageAvailability

    public static let shared = PluginPackStatusService(condaManager: .shared)

    private let condaManager: CondaManager
    private let installAction: InstallAction
    private let databaseInstallAction: DatabaseInstallAction
    private let databaseInstalledCheck: DatabaseInstalledCheck
    private let storageAvailability: StorageAvailability
    private let cacheLifetime: TimeInterval
    private let persistedSnapshotsURL: URL
    private var cacheGeneration = 0
    private var hasLoadedPersistedSnapshots = false
    private var cachedVisibleStatuses: (generation: Int, timestamp: Date, statuses: [PluginPackStatus])?
    private var inFlightVisibleStatuses: (generation: Int, task: Task<[PluginPackStatus], Never>)?
    private var cachedPackStatuses: [String: CachedPackStatus] = [:]
    private var inFlightPackStatuses: [String: (generation: Int, task: Task<PluginPackStatus, Never>)] = [:]

    public init(
        condaManager: CondaManager,
        installAction: InstallAction? = nil,
        databaseInstallAction: DatabaseInstallAction? = nil,
        databaseInstalledCheck: DatabaseInstalledCheck? = nil,
        storageAvailability: StorageAvailability? = nil,
        cacheLifetime: TimeInterval = 300
    ) {
        self.condaManager = condaManager
        self.installAction = installAction ?? { [condaManager] packages, environment, reinstall, progress in
            if reinstall {
                try await condaManager.reinstall(packages: packages, environment: environment, progress: progress)
            } else {
                try await condaManager.install(packages: packages, environment: environment, progress: progress)
            }
        }
        self.databaseInstallAction = databaseInstallAction ?? { databaseID, reinstall, progress in
            try await DatabaseRegistry.shared.installManagedDatabase(
                databaseID,
                reinstall: reinstall,
                progress: progress
            )
        }
        self.databaseInstalledCheck = databaseInstalledCheck ?? { databaseID in
            await DatabaseRegistry.shared.isDatabaseInstalled(databaseID)
        }
        self.storageAvailability = storageAvailability ?? {
            DatabaseRegistry.managedStorageAvailability()
        }
        self.cacheLifetime = cacheLifetime
        self.persistedSnapshotsURL = condaManager.rootPrefix
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("plugin-pack-statuses.json")
    }

    public func visibleStatuses() async -> [PluginPackStatus] {
        loadPersistedSnapshotsIfNeeded()
        let generation = cacheGeneration
        if let cachedVisibleStatuses,
           cachedVisibleStatuses.generation == generation {
            if !containsVolatileSmokeTestFailure(cachedVisibleStatuses.statuses),
               await visibleStatusesFingerprintMatches(forGeneration: generation) {
                return cachedVisibleStatuses.statuses
            }

            if !containsVolatileSmokeTestFailure(cachedVisibleStatuses.statuses),
               Date().timeIntervalSince(cachedVisibleStatuses.timestamp) < cacheLifetime {
                _ = visibleStatusesRefreshTask(forGeneration: generation)
                return cachedVisibleStatuses.statuses
            }
        }

        if let inFlightVisibleStatuses, inFlightVisibleStatuses.generation == generation {
            return await inFlightVisibleStatuses.task.value
        }

        return await visibleStatusesRefreshTask(forGeneration: generation).value
    }

    public func status(for pack: PluginPack) async -> PluginPackStatus {
        loadPersistedSnapshotsIfNeeded()
        let generation = cacheGeneration

        if let cached = cachedPackStatuses[pack.id], cached.generation == generation {
            if !cached.status.hasVolatileSmokeTestFailure,
               await packFingerprintMatches(for: pack, cached: cached) {
                return cached.status
            }

            if !cached.status.hasVolatileSmokeTestFailure,
               Date().timeIntervalSince(cached.timestamp) < cacheLifetime {
                _ = packStatusRefreshTask(for: pack, generation: generation)
                return cached.status
            }
        }

        let task = packStatusRefreshTask(for: pack, generation: generation)
        return await task.value
    }

    public func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return await status(for: pack)
    }

    private func computeStatus(for pack: PluginPack) async -> PluginPackStatus {
        let storageAvailability = storageAvailability()
        if case .unavailable(let unavailableRoot) = storageAvailability {
            return makePackStatus(
                pack: pack,
                toolStatuses: unavailableToolStatuses(for: pack, root: unavailableRoot),
                bootstrapReady: false,
                storageAvailability: storageAvailability
            )
        }

        let bootstrapReady = await bootstrapIsReady()
        var toolStatuses: [PackToolStatus] = []
        toolStatuses.reserveCapacity(pack.toolRequirements.count)

        for requirement in pack.toolRequirements {
            toolStatuses.append(await evaluate(requirement, bootstrapReady: bootstrapReady))
        }

        return makePackStatus(
            pack: pack,
            toolStatuses: toolStatuses,
            bootstrapReady: bootstrapReady,
            storageAvailability: storageAvailability
        )
    }

    private func makePackStatus(
        pack: PluginPack,
        toolStatuses: [PackToolStatus],
        bootstrapReady: Bool,
        storageAvailability: ManagedStorageAvailability
    ) -> PluginPackStatus {
        if case .unavailable = storageAvailability {
            return PluginPackStatus(
                pack: pack,
                state: .failed,
                toolStatuses: toolStatuses,
                failureMessage: "Storage location unavailable"
            )
        }

        let state: PluginPackState = toolStatuses.allSatisfy(\.isReady) && bootstrapReady ? .ready : .needsInstall
        let failureMessage = toolStatuses.first(where: { !$0.isReady })?.smokeTestFailure

        return PluginPackStatus(
            pack: pack,
            state: state,
            toolStatuses: toolStatuses,
            failureMessage: failureMessage
        )
    }

    public func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        if case .unavailable(let unavailableRoot) = storageAvailability() {
            throw PluginPackStatusServiceError.storageUnavailable(unavailableRoot)
        }

        let installTargets = await plannedInstallTargets(for: pack, requestedReinstall: reinstall)
        guard !installTargets.isEmpty else {
            progress?(PluginPackInstallProgress(
                requirementID: nil,
                requirementDisplayName: nil,
                overallFraction: 1.0,
                itemFraction: 1.0,
                message: "\(pack.name) ready"
            ))
            return
        }

        await invalidateVisibleStatusesCache()
        let totalSteps = max(installTargets.count, 1)
        for (index, target) in installTargets.enumerated() {
            let requirement = target.requirement
            let base = Double(index) / Double(totalSteps)
            if let databaseID = requirement.managedDatabaseID {
                progress?(PluginPackInstallProgress(
                    requirementID: requirement.id,
                    requirementDisplayName: requirement.displayName,
                    overallFraction: base,
                    itemFraction: 0,
                    message: target.reinstall
                        ? "Reinstalling \(requirement.displayName)…"
                        : "Installing \(requirement.displayName)…"
                ))
                _ = try await databaseInstallAction(databaseID, target.reinstall) { fraction, message in
                    let scaled = base + (fraction / Double(totalSteps))
                    progress?(PluginPackInstallProgress(
                        requirementID: requirement.id,
                        requirementDisplayName: requirement.displayName,
                        overallFraction: scaled,
                        itemFraction: fraction,
                        message: message
                    ))
                }
                progress?(PluginPackInstallProgress(
                    requirementID: requirement.id,
                    requirementDisplayName: requirement.displayName,
                    overallFraction: base + (1.0 / Double(totalSteps)),
                    itemFraction: 1.0,
                    message: "\(requirement.displayName) installed"
                ))
                continue
            }

            try await installAction(
                requirement.installPackages,
                requirement.environment,
                target.reinstall
            ) { fraction, message in
                let scaled = base + (fraction / Double(totalSteps))
                progress?(PluginPackInstallProgress(
                    requirementID: requirement.id,
                    requirementDisplayName: requirement.displayName,
                    overallFraction: scaled,
                    itemFraction: fraction,
                    message: message
                ))
            }
        }
        await runPostInstallHooks(
            for: pack,
            installedEnvironments: Set(installTargets.map(\.requirement.environment))
        )
        await invalidateVisibleStatusesCache()
        progress?(PluginPackInstallProgress(
            requirementID: nil,
            requirementDisplayName: nil,
            overallFraction: 1.0,
            itemFraction: 1.0,
            message: "\(pack.name) ready"
        ))
    }

    private func plannedInstallTargets(
        for pack: PluginPack,
        requestedReinstall: Bool
    ) async -> [PlannedInstallTarget] {
        let knownStatus: PluginPackStatus
        if let cachedStatus = cachedPackStatuses[pack.id]?.status {
            knownStatus = cachedStatus
        } else {
            knownStatus = await computeStatus(for: pack)
        }
        let toolStatuses = Dictionary(uniqueKeysWithValues: knownStatus.toolStatuses.map { ($0.requirement.id, $0) })

        return pack.toolRequirements.compactMap { requirement in
            guard let toolStatus = toolStatuses[requirement.id] else {
                return PlannedInstallTarget(requirement: requirement, reinstall: requestedReinstall)
            }

            guard !toolStatus.isReady else { return nil }

            if requirement.managedDatabaseID != nil {
                return PlannedInstallTarget(requirement: requirement, reinstall: false)
            }

            return PlannedInstallTarget(
                requirement: requirement,
                reinstall: toolStatus.environmentExists
            )
        }
    }

    public func invalidateVisibleStatusesCache() async {
        cacheGeneration += 1
        hasLoadedPersistedSnapshots = true
        cachedVisibleStatuses = nil
        inFlightVisibleStatuses = nil
        cachedPackStatuses = [:]
        inFlightPackStatuses = [:]
        try? FileManager.default.removeItem(at: persistedSnapshotsURL)
    }

    private func computeVisibleStatuses(forGeneration generation: Int) async -> [PluginPackStatus] {
        let storageAvailability = storageAvailability()
        if case .unavailable(let unavailableRoot) = storageAvailability {
            let statuses = PluginPack.visibleForCLI.map { pack in
                makePackStatus(
                    pack: pack,
                    toolStatuses: unavailableToolStatuses(for: pack, root: unavailableRoot),
                    bootstrapReady: false,
                    storageAvailability: storageAvailability
                )
            }
            storeVisibleStatuses(statuses, fingerprints: [:], forGeneration: generation)
            return statuses
        }

        let bootstrapReady = await bootstrapIsReady()
        var requirementCache: [PackToolRequirement: PackToolStatus] = [:]
        var statuses: [PluginPackStatus] = []
        var fingerprints: [String: PackStatusFingerprint] = [:]
        statuses.reserveCapacity(PluginPack.visibleForCLI.count)
        for pack in PluginPack.visibleForCLI {
            var toolStatuses: [PackToolStatus] = []
            toolStatuses.reserveCapacity(pack.toolRequirements.count)
            for requirement in pack.toolRequirements {
                if let cached = requirementCache[requirement] {
                    toolStatuses.append(cached)
                    continue
                }
                let evaluated = await evaluate(requirement, bootstrapReady: bootstrapReady)
                requirementCache[requirement] = evaluated
                toolStatuses.append(evaluated)
            }
            statuses.append(makePackStatus(
                pack: pack,
                toolStatuses: toolStatuses,
                bootstrapReady: bootstrapReady,
                storageAvailability: storageAvailability
            ))
            fingerprints[pack.id] = await currentFingerprint(for: pack)
        }
        storeVisibleStatuses(statuses, fingerprints: fingerprints, forGeneration: generation)
        return statuses
    }

    private func storeVisibleStatuses(
        _ statuses: [PluginPackStatus],
        fingerprints: [String: PackStatusFingerprint],
        forGeneration generation: Int
    ) {
        guard generation == cacheGeneration else { return }
        cachedVisibleStatuses = (generation, Date(), statuses)
        let timestamp = Date()
        for status in statuses {
            cachedPackStatuses[status.pack.id] = CachedPackStatus(
                generation: generation,
                timestamp: timestamp,
                status: status,
                fingerprint: fingerprints[status.pack.id]
            )
        }
        persistSnapshots()
    }

    private func visibleStatusesRefreshTask(forGeneration generation: Int) -> Task<[PluginPackStatus], Never> {
        if let inFlightVisibleStatuses, inFlightVisibleStatuses.generation == generation {
            return inFlightVisibleStatuses.task
        }

        let task = Task { [self] in
            let statuses = await computeVisibleStatuses(forGeneration: generation)
            await clearVisibleStatusesRefreshTask(forGeneration: generation)
            return statuses
        }
        inFlightVisibleStatuses = (generation, task)
        return task
    }

    private func packStatusRefreshTask(
        for pack: PluginPack,
        generation: Int
    ) -> Task<PluginPackStatus, Never> {
        if let inFlight = inFlightPackStatuses[pack.id], inFlight.generation == generation {
            return inFlight.task
        }

        let task = Task { [self] in
            let status = await computeStatus(for: pack)
            let fingerprint = await currentFingerprint(for: pack)
            await storePackStatus(status, fingerprint: fingerprint, forGeneration: generation)
            await clearPackStatusRefreshTask(forPackID: pack.id, generation: generation)
            return status
        }

        inFlightPackStatuses[pack.id] = (generation, task)
        return task
    }

    private func storePackStatus(
        _ status: PluginPackStatus,
        fingerprint: PackStatusFingerprint?,
        forGeneration generation: Int
    ) {
        guard generation == cacheGeneration else { return }
        cachedPackStatuses[status.pack.id] = CachedPackStatus(
            generation: generation,
            timestamp: Date(),
            status: status,
            fingerprint: fingerprint
        )
        persistSnapshots()
    }

    private func clearVisibleStatusesRefreshTask(forGeneration generation: Int) {
        guard inFlightVisibleStatuses?.generation == generation else { return }
        inFlightVisibleStatuses = nil
    }

    private func clearPackStatusRefreshTask(forPackID packID: String, generation: Int) {
        guard inFlightPackStatuses[packID]?.generation == generation else { return }
        inFlightPackStatuses[packID] = nil
    }

    private func containsVolatileSmokeTestFailure(_ statuses: [PluginPackStatus]) -> Bool {
        statuses.contains(where: \.hasVolatileSmokeTestFailure)
    }

    private func loadPersistedSnapshotsIfNeeded() {
        guard !hasLoadedPersistedSnapshots else { return }
        hasLoadedPersistedSnapshots = true

        guard let data = try? Data(contentsOf: persistedSnapshotsURL) else { return }

        do {
            let store = try JSONDecoder().decode(PersistedStatusSnapshotStore.self, from: data)
            if let visibleStatuses = store.visibleStatuses,
               !containsVolatileSmokeTestFailure(visibleStatuses.statuses) {
                cachedVisibleStatuses = (
                    generation: cacheGeneration,
                    timestamp: visibleStatuses.timestamp,
                    statuses: visibleStatuses.statuses
                )
            }

            for (packID, snapshot) in store.packStatuses {
                guard !snapshot.status.hasVolatileSmokeTestFailure else { continue }
                cachedPackStatuses[packID] = CachedPackStatus(
                    generation: cacheGeneration,
                    timestamp: snapshot.timestamp,
                    status: snapshot.status,
                    fingerprint: snapshot.fingerprint
                )
            }
        } catch {
            logger.warning(
                "Failed to load persisted plugin-pack status snapshots: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistSnapshots() {
        let packSnapshots = cachedPackStatuses.reduce(into: [String: PersistedPackStatusSnapshot]()) { snapshots, entry in
            guard !entry.value.status.hasVolatileSmokeTestFailure else { return }
            snapshots[entry.key] = PersistedPackStatusSnapshot(
                timestamp: entry.value.timestamp,
                status: entry.value.status,
                fingerprint: entry.value.fingerprint
            )
        }
        let snapshotStore = PersistedStatusSnapshotStore(
            visibleStatuses: cachedVisibleStatuses.flatMap {
                guard !containsVolatileSmokeTestFailure($0.statuses) else { return nil }
                return PersistedVisibleStatusesSnapshot(timestamp: $0.timestamp, statuses: $0.statuses)
            },
            packStatuses: packSnapshots
        )

        do {
            try FileManager.default.createDirectory(
                at: persistedSnapshotsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshotStore)
            try data.write(to: persistedSnapshotsURL, options: .atomic)
        } catch {
            logger.warning(
                "Failed to persist plugin-pack status snapshots: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func bootstrapIsReady() async -> Bool {
        let micromambaPath = await condaManager.micromambaPath
        return FileManager.default.fileExists(atPath: micromambaPath.path)
            && FileManager.default.isExecutableFile(atPath: micromambaPath.path)
    }

    private func visibleStatusesFingerprintMatches(forGeneration generation: Int) async -> Bool {
        for pack in PluginPack.visibleForCLI {
            guard let cached = cachedPackStatuses[pack.id], cached.generation == generation else {
                return false
            }
            guard await packFingerprintMatches(for: pack, cached: cached) else {
                return false
            }
        }
        return true
    }

    private func packFingerprintMatches(
        for pack: PluginPack,
        cached: CachedPackStatus
    ) async -> Bool {
        guard let cachedFingerprint = cached.fingerprint else {
            return false
        }
        return await currentFingerprint(for: pack) == cachedFingerprint
    }

    private func currentFingerprint(for pack: PluginPack) async -> PackStatusFingerprint {
        let rootPrefix = condaManager.rootPrefix.standardizedFileURL
        let managedStorageRoot = rootPrefix.deletingLastPathComponent()
        let envsRoot = rootPrefix.appendingPathComponent("envs", isDirectory: true)
        let micromambaPath = await condaManager.micromambaPath

        var components = [
            fingerprintComponent(for: envsRoot),
            fingerprintComponent(for: micromambaPath),
        ]

        for requirement in pack.toolRequirements {
            if let managedDatabaseID = requirement.managedDatabaseID {
                let databaseURL = managedStorageRoot
                    .appendingPathComponent("databases", isDirectory: true)
                    .appendingPathComponent(managedDatabaseID, isDirectory: true)
                components.append(fingerprintComponent(for: databaseURL))
                continue
            }

            let envURL = await condaManager.environmentURL(named: requirement.environment)
            components.append(fingerprintComponent(for: envURL))
            components.append(fingerprintComponent(for: envURL.appendingPathComponent("conda-meta", isDirectory: true)))
            components.append(fingerprintComponent(for: envURL.appendingPathComponent("bin", isDirectory: true)))

            for executableURL in monitoredExecutableURLs(for: requirement, envURL: envURL) {
                components.append(fingerprintComponent(for: executableURL))
            }
        }

        return PackStatusFingerprint(components: components)
    }

    private func monitoredExecutableURLs(
        for requirement: PackToolRequirement,
        envURL: URL
    ) -> [URL] {
        var urls: [URL] = []
        var seenPaths: Set<String> = []

        func appendIfNeeded(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            urls.append(url.standardizedFileURL)
        }

        for executable in requirement.executables {
            appendIfNeeded(envURL.appendingPathComponent("bin/\(executable)"))
            for fallbackPath in requirement.fallbackExecutablePaths[executable] ?? [] {
                appendIfNeeded(envURL.appendingPathComponent(fallbackPath))
            }
        }

        if let smokeExecutable = requirement.smokeTest?.executable {
            appendIfNeeded(envURL.appendingPathComponent("bin/\(smokeExecutable)"))
        }

        return urls.sorted { $0.path < $1.path }
    }

    private func fingerprintComponent(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return "\(path)|missing"
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let type = (attributes?[.type] as? FileAttributeType)?.rawValue ?? "unknown"
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let modificationTime = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970
            .rounded(.toNearestOrEven)
            ?? -1

        return "\(path)|type=\(type)|size=\(size)|perm=\(permissions)|mtime=\(modificationTime)"
    }

    private func evaluate(
        _ requirement: PackToolRequirement,
        bootstrapReady: Bool
    ) async -> PackToolStatus {
        if let managedDatabaseID = requirement.managedDatabaseID {
            let databaseInstalled = await databaseInstalledCheck(managedDatabaseID)
            return PackToolStatus(
                requirement: requirement,
                environmentExists: databaseInstalled,
                missingExecutables: [],
                smokeTestFailure: databaseInstalled ? nil : "\(requirement.displayName) is not installed",
                storageUnavailablePath: nil
            )
        }

        let envURL = await condaManager.environmentURL(named: requirement.environment)
        let environmentExists = FileManager.default.fileExists(atPath: envURL.path)
        if environmentExists {
            await condaManager.repairManagedLaunchers(environment: requirement.environment)
        }
        let missingExecutables = requirement.executables.filter { executable in
            if FileManager.default.isExecutableFile(
                atPath: envURL.appendingPathComponent("bin/\(executable)").path
            ) {
                return false
            }

            let fallbackPaths = requirement.fallbackExecutablePaths[executable] ?? []
            return !fallbackPaths.contains {
                FileManager.default.isExecutableFile(
                    atPath: envURL.appendingPathComponent($0).path
                )
            }
        }

        let smokeTestFailure: String?
        if missingExecutables.isEmpty && bootstrapReady, let smokeTest = requirement.smokeTest {
            smokeTestFailure = await runSmokeTest(
                smokeTest,
                for: requirement
            )
        } else {
            smokeTestFailure = nil
        }

        return PackToolStatus(
            requirement: requirement,
            environmentExists: environmentExists,
            missingExecutables: missingExecutables,
            smokeTestFailure: smokeTestFailure,
            storageUnavailablePath: nil
        )
    }

    private func unavailableToolStatuses(for pack: PluginPack, root: URL) -> [PackToolStatus] {
        pack.toolRequirements.map { requirement in
            PackToolStatus(
                requirement: requirement,
                environmentExists: false,
                missingExecutables: requirement.managedDatabaseID == nil ? requirement.executables : [],
                smokeTestFailure: nil,
                storageUnavailablePath: root.path
            )
        }
    }

    private func runSmokeTest(
        _ smokeTest: PackToolSmokeTest,
        for requirement: PackToolRequirement
    ) async -> String? {
        switch smokeTest.kind {
        case .command:
            let executable = smokeTest.executable ?? requirement.executables.first ?? requirement.id
            do {
                let result = try await condaManager.runTool(
                    name: executable,
                    arguments: smokeTest.arguments,
                    environment: requirement.environment,
                    timeout: smokeTest.timeoutSeconds
                )
                guard smokeTest.acceptedExitCodes.contains(result.exitCode) else {
                    logger.warning(
                        "Smoke test for '\(requirement.displayName, privacy: .public)' exited \(result.exitCode) with stderr: \(result.stderr, privacy: .public)"
                    )
                    return result.stderr.isEmpty
                        ? "\(requirement.displayName) exited with code \(result.exitCode)"
                        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if let requiredOutputSubstring = smokeTest.requiredOutputSubstring {
                    let combinedOutput = "\(result.stdout)\n\(result.stderr)"
                    guard combinedOutput.localizedCaseInsensitiveContains(requiredOutputSubstring) else {
                        return "\(requirement.displayName) did not report expected usage output"
                    }
                }
                return nil
            } catch {
                logger.error(
                    "Smoke test failed for '\(requirement.displayName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return error.localizedDescription
            }
        case .bbtoolsReformat:
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-bbtools-smoke-\(UUID().uuidString)", isDirectory: true)
            let inputURL = tempDirectory.appendingPathComponent("input.fastq")
            let outputURL = tempDirectory.appendingPathComponent("output.fastq")

            do {
                try FileManager.default.createDirectory(
                    at: tempDirectory,
                    withIntermediateDirectories: true
                )
                let reads = """
                @r1
                ACGT
                +
                IIII
                """
                try reads.write(to: inputURL, atomically: true, encoding: .utf8)

                defer { try? FileManager.default.removeItem(at: tempDirectory) }

                let result = try await condaManager.runTool(
                    name: smokeTest.executable ?? "reformat.sh",
                    arguments: [
                        "in=\(inputURL.path)",
                        "out=\(outputURL.path)",
                        "ow=t",
                    ],
                    environment: requirement.environment,
                    timeout: smokeTest.timeoutSeconds
                )
                guard result.exitCode == 0 else {
                    logger.warning(
                        "BBTools smoke test exited \(result.exitCode) with stderr: \(result.stderr, privacy: .public)"
                    )
                    return result.stderr.isEmpty
                        ? "\(requirement.displayName) exited with code \(result.exitCode)"
                        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard FileManager.default.fileExists(atPath: outputURL.path) else {
                    return "\(requirement.displayName) did not produce output"
                }
                return nil
            } catch {
                logger.error(
                    "BBTools smoke test failed for '\(requirement.displayName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return error.localizedDescription
            }
        }
    }

    private func runPostInstallHooks(
        for pack: PluginPack,
        installedEnvironments: Set<String>
    ) async {
        guard !pack.postInstallHooks.isEmpty else { return }

        for hook in pack.postInstallHooks {
            guard installedEnvironments.contains(hook.environment) else {
                continue
            }
            let envURL = await condaManager.environmentURL(named: hook.environment)
            guard FileManager.default.fileExists(atPath: envURL.path) else {
                logger.warning(
                    "Skipping hook '\(hook.description, privacy: .public)': environment '\(hook.environment, privacy: .public)' not installed"
                )
                continue
            }

            guard let tool = hook.command.first else { continue }
            let arguments = Array(hook.command.dropFirst())
            do {
                _ = try await condaManager.runTool(
                    name: tool,
                    arguments: arguments,
                    environment: hook.environment,
                    timeout: 600
                )
                logger.info(
                    "Hook '\(hook.description, privacy: .public)' completed successfully"
                )
            } catch {
                logger.error(
                    "Hook '\(hook.description, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
