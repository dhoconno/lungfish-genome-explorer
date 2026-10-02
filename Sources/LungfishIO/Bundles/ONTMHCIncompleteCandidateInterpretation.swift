import Foundation

/// A backward-compatible interpretation retained by legacy bundles that stored
/// a classified candidate in the un-nameable document because its reference
/// span was incomplete. New writers publish resolved observed sequences as
/// ordinary named candidates instead.
public struct ONTMHCIncompleteCandidateInterpretation: Codable, Equatable, Sendable {
    public let provisionalName: String
    public let locus: String
    public let classification: ONTMHCCandidateClassification
    public let closestReferenceName: String
    public let closestReferenceClass: MHCReferenceMoleculeClass
    public let snpCount: Int
    public let insertedBases: Int
    public let deletedBases: Int
    public let longGapBases: Int
    public let comparableBases: Int
    public let shorterCoverage: Double
    public let identity: Double
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let extensionOf: [String]
    public let provisionalNamingAmbiguous: Bool

    /// Observed substitutions and ordinary indel bases across the aligned span.
    /// Intron-sized cDNA fills are structural evidence rather than edit burden.
    public var observedDifferenceCount: Int {
        snpCount + max(0, insertedBases - longGapBases) + deletedBases
    }

    public init(candidate: ONTMHCCandidateRecord) {
        provisionalName = candidate.provisionalName
        locus = candidate.locus
        classification = candidate.classification
        closestReferenceName = candidate.closestReferenceName
        closestReferenceClass = candidate.closestReferenceClass
        snpCount = candidate.snpCount
        insertedBases = candidate.insertedBases
        deletedBases = candidate.deletedBases
        longGapBases = candidate.longGapBases
        comparableBases = candidate.comparableBases
        shorterCoverage = candidate.shorterCoverage
        identity = candidate.identity
        mappingQuality = candidate.mappingQuality
        alignmentScore = candidate.alignmentScore
        extensionOf = candidate.extensionOf
        provisionalNamingAmbiguous = candidate.provisionalNamingAmbiguous
    }

    private enum CodingKeys: String, CodingKey {
        case provisionalName = "provisional_name"
        case locus
        case classification
        case closestReferenceName = "closest_reference_name"
        case closestReferenceClass = "closest_reference_class"
        case snpCount = "snp_count"
        case insertedBases = "inserted_bases"
        case deletedBases = "deleted_bases"
        case longGapBases = "long_gap_bases"
        case comparableBases = "comparable_bases"
        case shorterCoverage = "shorter_coverage"
        case identity
        case mappingQuality = "mapping_quality"
        case alignmentScore = "alignment_score"
        case extensionOf = "extension_of"
        case provisionalNamingAmbiguous = "provisional_naming_ambiguous"
    }
}
