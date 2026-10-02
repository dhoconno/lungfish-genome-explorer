import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeNormalizedNode: Codable, Sendable, Equatable {
    public let id: String
    public let rawLabel: String?
    public let displayLabel: String
    public let parentID: String?
    public let childIDs: [String]
    public let isTip: Bool
    public let branchLength: Double?
    public let cumulativeDivergence: Double?
    public let metadata: [String: String]
    public let support: PhylogeneticTreeSupport?
    public let descendantTipCount: Int

    public func replacingDisplayLabel(_ label: String) -> PhylogeneticTreeNormalizedNode {
        PhylogeneticTreeNormalizedNode(
            id: id,
            rawLabel: rawLabel,
            displayLabel: label,
            parentID: parentID,
            childIDs: childIDs,
            isTip: isTip,
            branchLength: branchLength,
            cumulativeDivergence: cumulativeDivergence,
            metadata: metadata,
            support: support,
            descendantTipCount: descendantTipCount
        )
    }
}
