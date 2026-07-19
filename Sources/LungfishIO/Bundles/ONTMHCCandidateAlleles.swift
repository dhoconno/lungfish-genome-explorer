import Foundation

public struct ONTMHCArtifactReference: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64

    public init(path: String, sha256: String, sizeBytes: Int64) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case sizeBytes = "size_bytes"
    }
}

public struct ONTMHCBAMArtifactPair: Codable, Equatable, Sendable {
    public let bam: ONTMHCArtifactReference
    public let bai: ONTMHCArtifactReference

    public init(bam: ONTMHCArtifactReference, bai: ONTMHCArtifactReference) {
        self.bam = bam
        self.bai = bai
    }

    private enum CodingKeys: String, CodingKey {
        case bam
        case bai
    }
}

public struct ONTMHCCandidateArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let reciprocalEvidence: ONTMHCBAMArtifactPair?
    public let candidateJSON: ONTMHCArtifactReference?
    public let candidateFASTA: ONTMHCArtifactReference?
    public let unnameableJSON: ONTMHCArtifactReference?
    public let unnameableFASTA: ONTMHCArtifactReference?

    public init(
        schemaVersion: Int,
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        reciprocalEvidence: ONTMHCBAMArtifactPair?,
        candidateJSON: ONTMHCArtifactReference?,
        candidateFASTA: ONTMHCArtifactReference?,
        unnameableJSON: ONTMHCArtifactReference?,
        unnameableFASTA: ONTMHCArtifactReference?
    ) {
        self.schemaVersion = schemaVersion
        self.genotypingEvidence = genotypingEvidence
        self.reciprocalEvidence = reciprocalEvidence
        self.candidateJSON = candidateJSON
        self.candidateFASTA = candidateFASTA
        self.unnameableJSON = unnameableJSON
        self.unnameableFASTA = unnameableFASTA
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case genotypingEvidence = "genotyping_evidence"
        case reciprocalEvidence = "reciprocal_evidence"
        case candidateJSON = "candidate_json"
        case candidateFASTA = "candidate_fasta"
        case unnameableJSON = "unnameable_json"
        case unnameableFASTA = "unnameable_fasta"
    }
}
