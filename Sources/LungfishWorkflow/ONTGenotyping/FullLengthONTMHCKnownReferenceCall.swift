import Foundation
import LungfishIO

public struct FullLengthONTMHCKnownReferenceCall: Equatable, Sendable {
    public let reference: MHCReferenceRecord
    public let cigar: String
    public let nm: Int?
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let comparableBases: Int
    public let matchedBases: Int
    public let insertedBases: Int
    public let deletedBases: Int
    public let nonIntronIndelBases: Int
    public let longGapBases: Int
    public let shorterCoverage: Double
    public let identity: Double
    public let evidence: ONTMHCEvidenceLocator
}
