@preconcurrency import Foundation
import LungfishCore
import os.log

public enum PluginPackState: String, Sendable, Codable, Hashable {
    case ready
    case needsInstall
    case installing
    case failed
}
