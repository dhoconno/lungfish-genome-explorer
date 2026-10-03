import Foundation
import LungfishIO

public enum FullLengthONTMHCCandidateReferenceResolution: Equatable, Sendable {
    case resolved(MHCReferenceRecord)
    case unresolvedLocus(referenceName: String, sequenceLength: Int)
    case ambiguousReferenceClass(referenceName: String, locus: String, sequenceLength: Int)

    /// Exact reference identity expected in the reciprocal BAM's RNAME field.
    /// Resolved catalog records use their FASTA sequence ID, not the biological
    /// allele label used for provisional naming and localized ranking.
    public var referenceName: String {
        switch self {
        case .resolved(let record): record.sequenceID
        case .unresolvedLocus(let referenceName, _): referenceName
        case .ambiguousReferenceClass(let referenceName, _, _): referenceName
        }
    }

    var sequenceLength: Int {
        switch self {
        case .resolved(let record): record.sequenceLength
        case .unresolvedLocus(_, let sequenceLength): sequenceLength
        case .ambiguousReferenceClass(_, _, let sequenceLength): sequenceLength
        }
    }

    var resolvedRecord: MHCReferenceRecord? {
        guard case .resolved(let record) = self else { return nil }
        return record
    }
}
