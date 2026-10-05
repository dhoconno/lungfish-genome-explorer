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
    /// The single support value shown by default: UFBoot when the labels include it,
    /// otherwise the first typed value, otherwise the value guessed from the raw label.
    public let support: PhylogeneticTreeSupport?
    public let descendantTipCount: Int
    /// Typed values split from the node label against the manifest's support labels.
    /// Empty when the tree has no recorded labels or the label does not split cleanly.
    public let supportValues: [PhylogeneticTreeSupportValue]

    public init(
        id: String,
        rawLabel: String?,
        displayLabel: String,
        parentID: String?,
        childIDs: [String],
        isTip: Bool,
        branchLength: Double?,
        cumulativeDivergence: Double?,
        metadata: [String: String],
        support: PhylogeneticTreeSupport?,
        descendantTipCount: Int,
        supportValues: [PhylogeneticTreeSupportValue] = []
    ) {
        self.id = id
        self.rawLabel = rawLabel
        self.displayLabel = displayLabel
        self.parentID = parentID
        self.childIDs = childIDs
        self.isTip = isTip
        self.branchLength = branchLength
        self.cumulativeDivergence = cumulativeDivergence
        self.metadata = metadata
        self.support = support
        self.descendantTipCount = descendantTipCount
        self.supportValues = supportValues
    }

    private enum CodingKeys: String, CodingKey {
        case id, rawLabel, displayLabel, parentID, childIDs, isTip, branchLength
        case cumulativeDivergence, metadata, support, descendantTipCount, supportValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rawLabel = try container.decodeIfPresent(String.self, forKey: .rawLabel)
        displayLabel = try container.decode(String.self, forKey: .displayLabel)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        childIDs = try container.decode([String].self, forKey: .childIDs)
        isTip = try container.decode(Bool.self, forKey: .isTip)
        branchLength = try container.decodeIfPresent(Double.self, forKey: .branchLength)
        cumulativeDivergence = try container.decodeIfPresent(Double.self, forKey: .cumulativeDivergence)
        metadata = try container.decode([String: String].self, forKey: .metadata)
        support = try container.decodeIfPresent(PhylogeneticTreeSupport.self, forKey: .support)
        descendantTipCount = try container.decode(Int.self, forKey: .descendantTipCount)
        supportValues = try container.decodeIfPresent([PhylogeneticTreeSupportValue].self, forKey: .supportValues) ?? []
    }

    /// Bundles written before support labels existed have no `supportValues` key, and nodes
    /// without typed values still omit it, so their normalized JSON stays byte-identical.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(rawLabel, forKey: .rawLabel)
        try container.encode(displayLabel, forKey: .displayLabel)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encode(childIDs, forKey: .childIDs)
        try container.encode(isTip, forKey: .isTip)
        try container.encodeIfPresent(branchLength, forKey: .branchLength)
        try container.encodeIfPresent(cumulativeDivergence, forKey: .cumulativeDivergence)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(support, forKey: .support)
        try container.encode(descendantTipCount, forKey: .descendantTipCount)
        if !supportValues.isEmpty {
            try container.encode(supportValues, forKey: .supportValues)
        }
    }

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
            descendantTipCount: descendantTipCount,
            supportValues: supportValues
        )
    }
}
