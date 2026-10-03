@preconcurrency import Foundation
import LungfishCore
import os.log

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
