import Foundation

public struct ONTMHCCandidateArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let reciprocalEvidence: ONTMHCBAMArtifactPair?
    public let candidateJSON: ONTMHCArtifactReference?
    public let candidateFASTA: ONTMHCArtifactReference?
    public let candidateGenBank: ONTMHCArtifactReference?
    public let candidateEMBL: ONTMHCArtifactReference?
    public let unnameableJSON: ONTMHCArtifactReference?
    public let unnameableFASTA: ONTMHCArtifactReference?
    public let unnameableGenBank: ONTMHCArtifactReference?
    public let unnameableEMBL: ONTMHCArtifactReference?
    public let rawUnmatchedFASTA: ONTMHCArtifactReference?
    public let sourceIdentityMap: ONTMHCArtifactReference?

    public init(
        schemaVersion: Int,
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        reciprocalEvidence: ONTMHCBAMArtifactPair?,
        candidateJSON: ONTMHCArtifactReference?,
        candidateFASTA: ONTMHCArtifactReference?,
        unnameableJSON: ONTMHCArtifactReference?,
        unnameableFASTA: ONTMHCArtifactReference?
    ) {
        self.init(
            schemaVersion: schemaVersion,
            genotypingEvidence: genotypingEvidence,
            reciprocalEvidence: reciprocalEvidence,
            candidateJSON: candidateJSON,
            candidateFASTA: candidateFASTA,
            candidateGenBank: nil,
            candidateEMBL: nil,
            unnameableJSON: unnameableJSON,
            unnameableFASTA: unnameableFASTA,
            unnameableGenBank: nil,
            unnameableEMBL: nil,
            rawUnmatchedFASTA: nil,
            sourceIdentityMap: nil
        )
    }

    public init(
        schemaVersion: Int,
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        reciprocalEvidence: ONTMHCBAMArtifactPair?,
        candidateJSON: ONTMHCArtifactReference?,
        candidateFASTA: ONTMHCArtifactReference?,
        candidateGenBank: ONTMHCArtifactReference? = nil,
        candidateEMBL: ONTMHCArtifactReference? = nil,
        unnameableJSON: ONTMHCArtifactReference?,
        unnameableFASTA: ONTMHCArtifactReference?,
        unnameableGenBank: ONTMHCArtifactReference? = nil,
        unnameableEMBL: ONTMHCArtifactReference? = nil,
        rawUnmatchedFASTA: ONTMHCArtifactReference? = nil,
        sourceIdentityMap: ONTMHCArtifactReference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.genotypingEvidence = genotypingEvidence
        self.reciprocalEvidence = reciprocalEvidence
        self.candidateJSON = candidateJSON
        self.candidateFASTA = candidateFASTA
        self.candidateGenBank = candidateGenBank
        self.candidateEMBL = candidateEMBL
        self.unnameableJSON = unnameableJSON
        self.unnameableFASTA = unnameableFASTA
        self.unnameableGenBank = unnameableGenBank
        self.unnameableEMBL = unnameableEMBL
        self.rawUnmatchedFASTA = rawUnmatchedFASTA
        self.sourceIdentityMap = sourceIdentityMap
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case genotypingEvidence = "genotyping_evidence"
        case reciprocalEvidence = "reciprocal_evidence"
        case candidateJSON = "candidate_json"
        case candidateFASTA = "candidate_fasta"
        case candidateGenBank = "candidate_genbank"
        case candidateEMBL = "candidate_embl"
        case unnameableJSON = "unnameable_json"
        case unnameableFASTA = "unnameable_fasta"
        case unnameableGenBank = "unnameable_genbank"
        case unnameableEMBL = "unnameable_embl"
        case rawUnmatchedFASTA = "raw_unmatched_fasta"
        case sourceIdentityMap = "source_identity_map"
    }
}
