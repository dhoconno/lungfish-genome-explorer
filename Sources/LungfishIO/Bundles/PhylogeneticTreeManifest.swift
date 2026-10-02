import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let bundleKind: String
    public let identifier: String
    public let name: String
    public let createdAt: Date
    public let sourceFormat: String
    public let sourceFileName: String
    public let treeCount: Int
    public let primaryTreeID: String
    public let isRooted: Bool
    public let tipCount: Int
    public let internalNodeCount: Int
    public let branchLengthUnit: String?
    public let dateScale: String?
    public let warnings: [String]
    public let capabilities: [String]
    public let checksums: [String: String]
    public let fileSizes: [String: Int64]
}
