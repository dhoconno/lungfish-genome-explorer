import Foundation
import LungfishIO

public struct FullLengthONTMHCCandidateCluster: Equatable, Sendable {
    public let stableClusterID: String
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let sequenceLength: Int
    public let observations: [ONTMHCCandidateObservation]
    public let alignments: [FullLengthONTMHCCandidateAlignment]

    public init(
        stableClusterID: String,
        fastaRecordID: String,
        sequenceSHA256: String,
        sequenceLength: Int,
        observations: [ONTMHCCandidateObservation],
        alignments: [FullLengthONTMHCCandidateAlignment]
    ) {
        self.stableClusterID = stableClusterID
        self.fastaRecordID = fastaRecordID
        self.sequenceSHA256 = sequenceSHA256
        self.sequenceLength = sequenceLength
        self.observations = observations
        self.alignments = alignments
    }
}
