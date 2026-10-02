import Foundation

public struct ONTMHCCandidateSourceIdentityRecord: Codable, Equatable, Sendable {
    public let rawStableClusterID: String
    public let rawSequenceSHA256: String
    public let rawSequenceLength: Int
    public let canonicalStableClusterID: String?
    public let canonicalSequenceSHA256: String?
    public let trimStart: Int?
    public let trimEnd: Int?
    public let referenceReadiness: String
    public let classification: String
    public let sampleIDs: [String]
    public let isRepresentative: Bool

    public init(
        rawStableClusterID: String,
        rawSequenceSHA256: String,
        rawSequenceLength: Int,
        canonicalStableClusterID: String? = nil,
        canonicalSequenceSHA256: String? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil,
        referenceReadiness: String,
        classification: String = "unavailable",
        sampleIDs: [String] = [],
        isRepresentative: Bool = false
    ) {
        self.rawStableClusterID = rawStableClusterID
        self.rawSequenceSHA256 = rawSequenceSHA256
        self.rawSequenceLength = rawSequenceLength
        self.canonicalStableClusterID = canonicalStableClusterID
        self.canonicalSequenceSHA256 = canonicalSequenceSHA256
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.referenceReadiness = referenceReadiness
        self.classification = classification
        self.sampleIDs = sampleIDs
        self.isRepresentative = isRepresentative
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rawStableClusterID: try container.decode(String.self, forKey: .rawStableClusterID),
            rawSequenceSHA256: try container.decode(String.self, forKey: .rawSequenceSHA256),
            rawSequenceLength: try container.decode(Int.self, forKey: .rawSequenceLength),
            canonicalStableClusterID: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalStableClusterID
            ),
            canonicalSequenceSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalSequenceSHA256
            ),
            trimStart: try container.decodeIfPresent(Int.self, forKey: .trimStart),
            trimEnd: try container.decodeIfPresent(Int.self, forKey: .trimEnd),
            referenceReadiness: try container.decode(
                String.self,
                forKey: .referenceReadiness
            ),
            classification: try container.decodeIfPresent(
                String.self,
                forKey: .classification
            ) ?? "unavailable",
            sampleIDs: try container.decodeIfPresent([String].self, forKey: .sampleIDs) ?? [],
            isRepresentative: try container.decodeIfPresent(
                Bool.self,
                forKey: .isRepresentative
            ) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case rawStableClusterID = "raw_stable_cluster_id"
        case rawSequenceSHA256 = "raw_sequence_sha256"
        case rawSequenceLength = "raw_sequence_length"
        case canonicalStableClusterID = "canonical_stable_cluster_id"
        case canonicalSequenceSHA256 = "canonical_sequence_sha256"
        case trimStart = "trim_start"
        case trimEnd = "trim_end"
        case referenceReadiness = "reference_readiness"
        case classification
        case sampleIDs = "sample_ids"
        case isRepresentative = "is_representative"
    }
}
