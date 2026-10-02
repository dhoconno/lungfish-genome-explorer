import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeNormalizedTree: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let treeID: String
    public let rooted: Bool
    public let nodes: [PhylogeneticTreeNormalizedNode]
}
