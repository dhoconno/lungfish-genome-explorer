import Foundation

public struct ONTMHCCandidateSourceIdentityDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let rawSequenceFASTA: ONTMHCArtifactReference
    public let records: [ONTMHCCandidateSourceIdentityRecord]

    public init(
        schemaVersion: Int,
        createdAt: String,
        rawSequenceFASTA: ONTMHCArtifactReference,
        records: [ONTMHCCandidateSourceIdentityRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.rawSequenceFASTA = rawSequenceFASTA
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case rawSequenceFASTA = "raw_sequence_fasta"
        case records
    }
}
