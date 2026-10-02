import Foundation

public struct ONTMHCUnnameableClustersDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let thresholds: ONTMHCCandidateThresholds
    public let inputs: [ONTMHCArtifactReference]
    public let evidence: [ONTMHCArtifactReference]
    public let sequenceFASTA: ONTMHCArtifactReference
    public let clusters: [ONTMHCUnnameableRecord]
    public let observations: [ONTMHCCandidateObservation]

    public init(
        schemaVersion: Int,
        createdAt: String,
        thresholds: ONTMHCCandidateThresholds,
        inputs: [ONTMHCArtifactReference] = [],
        evidence: [ONTMHCArtifactReference] = [],
        sequenceFASTA: ONTMHCArtifactReference,
        clusters: [ONTMHCUnnameableRecord],
        observations: [ONTMHCCandidateObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.thresholds = thresholds
        self.inputs = inputs
        self.evidence = evidence
        self.sequenceFASTA = sequenceFASTA
        self.clusters = clusters
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case thresholds
        case inputs
        case evidence
        case sequenceFASTA = "sequence_fasta"
        case clusters
        case observations
    }
}
