import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeSupport: Codable, Sendable, Equatable {
    public let rawValue: String
    public let interpretation: String
}
