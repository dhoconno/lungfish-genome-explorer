import Foundation

public struct ONTMHCCDNAExtensionInterpretation: Codable, Equatable, Sendable {
    public let rawReferenceID: String
    public let alleleName: String
    public let locus: String
    public let cDNAReferenceCoverage: Double
    public let clusterCoverage: Double
    public let leadingClusterFlankBases: Int
    public let trailingClusterFlankBases: Int
    public let largestClusterStructuralSegmentBases: Int
    public let largestCDNADeficitSegmentBases: Int
    public let snpSubstitutions: Int
    public let ordinaryIndelBases: Int
    public let isReverse: Bool
    public let alignmentScore: Int
    public let identity: Double

    public init(
        rawReferenceID: String,
        alleleName: String,
        locus: String,
        cDNAReferenceCoverage: Double,
        clusterCoverage: Double,
        leadingClusterFlankBases: Int,
        trailingClusterFlankBases: Int,
        largestClusterStructuralSegmentBases: Int,
        largestCDNADeficitSegmentBases: Int,
        snpSubstitutions: Int,
        ordinaryIndelBases: Int,
        isReverse: Bool,
        alignmentScore: Int,
        identity: Double
    ) {
        self.rawReferenceID = rawReferenceID
        self.alleleName = alleleName
        self.locus = locus
        self.cDNAReferenceCoverage = cDNAReferenceCoverage
        self.clusterCoverage = clusterCoverage
        self.leadingClusterFlankBases = leadingClusterFlankBases
        self.trailingClusterFlankBases = trailingClusterFlankBases
        self.largestClusterStructuralSegmentBases = largestClusterStructuralSegmentBases
        self.largestCDNADeficitSegmentBases = largestCDNADeficitSegmentBases
        self.snpSubstitutions = snpSubstitutions
        self.ordinaryIndelBases = ordinaryIndelBases
        self.isReverse = isReverse
        self.alignmentScore = alignmentScore
        self.identity = identity
    }

    private enum CodingKeys: String, CodingKey {
        case rawReferenceID = "raw_reference_id"
        case alleleName = "allele_name"
        case locus
        case cDNAReferenceCoverage = "cdna_reference_coverage"
        case clusterCoverage = "cluster_coverage"
        case leadingClusterFlankBases = "leading_cluster_flank_bases"
        case trailingClusterFlankBases = "trailing_cluster_flank_bases"
        case largestClusterStructuralSegmentBases = "largest_cluster_structural_segment_bases"
        case largestCDNADeficitSegmentBases = "largest_cdna_deficit_segment_bases"
        case snpSubstitutions = "snp_substitutions"
        case ordinaryIndelBases = "ordinary_indel_bases"
        case isReverse = "is_reverse"
        case alignmentScore = "alignment_score"
        case identity
    }
}
