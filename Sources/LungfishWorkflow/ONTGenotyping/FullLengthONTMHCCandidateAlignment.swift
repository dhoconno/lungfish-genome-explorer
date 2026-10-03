import Foundation
import LungfishIO

public struct FullLengthONTMHCCandidateAlignment: Equatable, Sendable {
    public let reference: FullLengthONTMHCCandidateReferenceResolution
    public let cigar: String
    public let nm: Int?
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let evidence: ONTMHCEvidenceLocator
    public let isReverse: Bool

    public init(
        reference: FullLengthONTMHCCandidateReferenceResolution,
        cigar: String,
        nm: Int?,
        mappingQuality: Int,
        alignmentScore: Int,
        evidence: ONTMHCEvidenceLocator,
        isReverse: Bool = false
    ) {
        self.reference = reference
        self.cigar = cigar
        self.nm = nm
        self.mappingQuality = mappingQuality
        self.alignmentScore = alignmentScore
        self.evidence = evidence
        self.isReverse = isReverse
    }
}
