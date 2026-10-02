import Foundation

public struct ONTMHCCandidateThresholds: Codable, Equatable, Sendable {
    public let minimumAlignedBases: Int
    public let minimumIdentity: Double
    public let minimumShorterCoverage: Double
    public let minimumIntronGapBases: Int

    public static let defaults = ONTMHCCandidateThresholds(
        validatedMinimumAlignedBases: 1_000,
        minimumIdentity: 0.75,
        minimumShorterCoverage: 0.70,
        minimumIntronGapBases: 20
    )

    public init(
        minimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) throws {
        try Self.validate(
            minimumAlignedBases: minimumAlignedBases,
            minimumIdentity: minimumIdentity,
            minimumShorterCoverage: minimumShorterCoverage,
            minimumIntronGapBases: minimumIntronGapBases
        )
        self.init(
            validatedMinimumAlignedBases: minimumAlignedBases,
            minimumIdentity: minimumIdentity,
            minimumShorterCoverage: minimumShorterCoverage,
            minimumIntronGapBases: minimumIntronGapBases
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumAlignedBases: container.decode(Int.self, forKey: .minimumAlignedBases),
            minimumIdentity: container.decode(Double.self, forKey: .minimumIdentity),
            minimumShorterCoverage: container.decode(Double.self, forKey: .minimumShorterCoverage),
            minimumIntronGapBases: container.decode(Int.self, forKey: .minimumIntronGapBases)
        )
    }

    private init(
        validatedMinimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) {
        self.minimumAlignedBases = validatedMinimumAlignedBases
        self.minimumIdentity = minimumIdentity
        self.minimumShorterCoverage = minimumShorterCoverage
        self.minimumIntronGapBases = minimumIntronGapBases
    }

    private static func validate(
        minimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) throws {
        guard minimumAlignedBases > 0 else {
            throw ONTMHCCandidateModelError.invalidMinimumAlignedBases(minimumAlignedBases)
        }
        guard minimumIdentity.isFinite, minimumIdentity > 0, minimumIdentity <= 1 else {
            throw ONTMHCCandidateModelError.invalidMinimumIdentity(minimumIdentity)
        }
        guard minimumShorterCoverage.isFinite,
              minimumShorterCoverage > 0,
              minimumShorterCoverage <= 1 else {
            throw ONTMHCCandidateModelError.invalidMinimumShorterCoverage(minimumShorterCoverage)
        }
        guard minimumIntronGapBases > 0 else {
            throw ONTMHCCandidateModelError.invalidMinimumIntronGapBases(minimumIntronGapBases)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case minimumAlignedBases = "minimum_aligned_bases"
        case minimumIdentity = "minimum_identity"
        case minimumShorterCoverage = "minimum_shorter_coverage"
        case minimumIntronGapBases = "minimum_intron_gap_bases"
    }
}
