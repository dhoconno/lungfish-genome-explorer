@preconcurrency import Foundation

public enum PluginPackManifestError: Error, CustomStringConvertible {
    case missingPackTool(packID: String, id: String)

    public var description: String {
        switch self {
        case let .missingPackTool(packID, id):
            return "Manifest has no packTools entry for \(packID)/\(id)"
        }
    }
}
