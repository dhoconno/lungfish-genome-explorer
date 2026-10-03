@preconcurrency import Foundation

public enum PluginPackKind: String, Sendable, Codable, Hashable {
    case requiredSetup
    case optionalTools
}
