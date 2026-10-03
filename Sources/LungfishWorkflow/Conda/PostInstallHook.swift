@preconcurrency import Foundation

public struct PostInstallHook: Sendable, Codable, Hashable {
    public let description: String
    public let environment: String
    public let command: [String]
    public let requiresNetwork: Bool
    public let refreshIntervalDays: Int?
    public let estimatedDownloadSize: String?

    public init(
        description: String,
        environment: String,
        command: [String],
        requiresNetwork: Bool = true,
        refreshIntervalDays: Int? = nil,
        estimatedDownloadSize: String? = nil
    ) {
        self.description = description
        self.environment = environment
        self.command = command
        self.requiresNetwork = requiresNetwork
        self.refreshIntervalDays = refreshIntervalDays
        self.estimatedDownloadSize = estimatedDownloadSize
    }
}
