@preconcurrency import Foundation
import LungfishCore
import os.log

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

    /// This status with its pack metadata (name, description, category)
    /// replaced by `current`. Cached and persisted snapshots carry the pack
    /// definition of the build that wrote them; readiness still applies after
    /// an app update when the tool requirements are unchanged, but the words
    /// on the card must come from the running build's definition.
    public func rebound(to current: PluginPack) -> PluginPackStatus {
        guard current != pack else { return self }
        return PluginPackStatus(
            pack: current,
            state: state,
            toolStatuses: toolStatuses,
            failureMessage: failureMessage
        )
    }
}
