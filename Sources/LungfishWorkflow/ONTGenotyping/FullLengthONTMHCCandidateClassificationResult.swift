import Foundation
import LungfishIO

public enum FullLengthONTMHCCandidateClassificationResult: Equatable, Sendable {
    case known([FullLengthONTMHCKnownReferenceCall])
    case candidate(ONTMHCCandidateRecord)
    case unnameable(ONTMHCUnnameableRecord)

    public var candidate: ONTMHCCandidateRecord? {
        guard case .candidate(let record) = self else { return nil }
        return record
    }
}
