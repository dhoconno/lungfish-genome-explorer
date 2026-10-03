@preconcurrency import Foundation
import LungfishCore
import os.log

public protocol PluginPackStatusProviding: Sendable {
    func visibleStatuses() async -> [PluginPackStatus]
    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus]
    func status(for pack: PluginPack) async -> PluginPackStatus
    func status(forPackID packID: String) async -> PluginPackStatus?
    func invalidateVisibleStatusesCache() async
    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws
    func install(
        pack: PluginPack,
        requirementIDs: Set<String>,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws
}

public extension PluginPackStatusProviding {
    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus] {
        let statuses = await visibleStatuses()
        guard !includeExperimental else { return statuses }
        return statuses.filter { !$0.pack.isExperimental }
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return await status(for: pack)
    }

    /// Providers must opt into scoped recovery; a whole-pack fallback could
    /// replace unrelated environments while preparing a single workflow.
    func install(
        pack: PluginPack,
        requirementIDs: Set<String>,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        throw PluginPackStatusServiceError.selectedRequirementInstallUnsupported
    }
}
