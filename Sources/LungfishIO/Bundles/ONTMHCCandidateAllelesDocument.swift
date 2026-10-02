import Foundation

public struct ONTMHCCandidateAllelesDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let thresholds: ONTMHCCandidateThresholds
    public let inputs: [ONTMHCArtifactReference]
    public let evidence: [ONTMHCArtifactReference]
    public let sequenceFASTA: ONTMHCArtifactReference
    public let candidates: [ONTMHCCandidateRecord]
    public let observations: [ONTMHCCandidateObservation]

    public init(
        schemaVersion: Int,
        createdAt: String,
        thresholds: ONTMHCCandidateThresholds,
        inputs: [ONTMHCArtifactReference],
        evidence: [ONTMHCArtifactReference],
        sequenceFASTA: ONTMHCArtifactReference,
        candidates: [ONTMHCCandidateRecord],
        observations: [ONTMHCCandidateObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.thresholds = thresholds
        self.inputs = inputs
        self.evidence = evidence
        self.sequenceFASTA = sequenceFASTA
        self.candidates = candidates
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case thresholds
        case inputs
        case evidence
        case sequenceFASTA = "sequence_fasta"
        case candidates
        case observations
    }
}
