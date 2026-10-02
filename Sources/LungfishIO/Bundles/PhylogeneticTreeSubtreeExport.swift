import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeSubtreeExport: Sendable, Equatable {
    public let selectedNodeID: String
    public let selectedLabel: String
    public let newick: String
    public let descendantTipCount: Int
}
