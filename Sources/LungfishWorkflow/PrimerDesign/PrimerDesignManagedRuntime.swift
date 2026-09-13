import Foundation

/// Uses the same pinned installer and readiness checks as Plugin Manager.
/// Optional tool preparation happens before capturing scientific input snapshots.
enum PrimerDesignManagedRuntime {
    typealias Progress = @Sendable (Double, String) -> Void
    typealias Preparer = @Sendable (Progress?) async throws -> Lease

    struct Lease: Sendable {
        let environmentURL: URL
        let lock: CondaEnvironmentMutationLock
        func release() { lock.release() }
    }

    struct Unavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(
        toolID: String,
        statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
        progress: Progress? = nil
    ) async throws {
        try Task.checkCancellation()
        guard let pack = PluginPack.builtInPack(id: "pcr-primer-design"),
              let requirement = pack.toolRequirements.first(where: { $0.id == toolID }) else {
            throw Unavailable(message: "The selected primer design tool is missing from the dependency manifest.")
        }
        progress?(0, "Checking \(requirement.displayName) runtime…")
        await statusProvider.invalidateVisibleStatusesCache()
        let status = try await selectedStatus(toolID: toolID, pack: pack, statusProvider: statusProvider)
        guard !status.isReady || !status.environmentExists else { return }
        progress?(0, "Preparing \(requirement.displayName) \(requirement.version ?? "")…")
        try await statusProvider.install(pack: pack, requirementIDs: [toolID]) { event in
            let fraction = event.overallFraction.isFinite ? min(1, max(0, event.overallFraction)) : 0
            progress?(0.04 * fraction, event.message)
        }
        try Task.checkCancellation()
        await statusProvider.invalidateVisibleStatusesCache()
        let verified = try await selectedStatus(toolID: toolID, pack: pack, statusProvider: statusProvider)
        guard verified.isReady, verified.environmentExists else {
            throw Unavailable(message: "\(requirement.displayName) could not be prepared: \(verified.smokeTestFailure ?? verified.statusText)")
        }
        progress?(0.04, "\(requirement.displayName) runtime ready")
    }

    static func prepareAndAcquire(toolID: String, progress: Progress?) async throws -> Lease {
        // Freeze the root for installation, locking, and execution. A later storage
        // preference change cannot send the command outside its protected runtime.
        let root = await CondaManager.shared.rootPrefix
        let manager = CondaManager(rootPrefix: root)
        let provider = PluginPackStatusService(condaManager: manager)
        try await prepare(toolID: toolID, statusProvider: provider, progress: progress)
        guard let pack = PluginPack.builtInPack(id: "pcr-primer-design"),
              let requirement = pack.toolRequirements.first(where: { $0.id == toolID }) else {
            throw Unavailable(message: "The selected primer design tool is unavailable.")
        }
        let lock = try await CondaEnvironmentMutationLock.acquireCancellable(root: root, environment: requirement.environment) { message in
            progress?(0.04, message)
        }
        do {
            try Task.checkCancellation()
            await provider.invalidateVisibleStatusesCache()
            let status = try await selectedStatus(toolID: toolID, pack: pack, statusProvider: provider)
            guard status.isReady, status.environmentExists else {
                throw Unavailable(message: "\(requirement.displayName) changed while waiting to run: \(status.smokeTestFailure ?? status.statusText)")
            }
            return Lease(environmentURL: await manager.environmentURL(named: requirement.environment), lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    private static func selectedStatus(toolID: String, pack: PluginPack, statusProvider: any PluginPackStatusProviding) async throws -> PackToolStatus {
        let status = await statusProvider.status(for: pack)
        try Task.checkCancellation()
        guard let selected = status.toolStatuses.first(where: { $0.requirement.id == toolID }) else {
            throw Unavailable(message: "The selected primer design runtime could not be checked.")
        }
        if let path = selected.storageUnavailablePath {
            throw Unavailable(message: "Managed primer design storage is unavailable: \(path)")
        }
        return selected
    }
}
