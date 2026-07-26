import Foundation

public struct ONTGenotypeAlignmentArtifactManifest: Codable, Equatable, Sendable {
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let reciprocalEvidence: ONTMHCBAMArtifactPair?

    public init(
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        reciprocalEvidence: ONTMHCBAMArtifactPair?
    ) {
        self.genotypingEvidence = genotypingEvidence
        self.reciprocalEvidence = reciprocalEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case genotypingEvidence = "genotyping_evidence"
        case reciprocalEvidence = "reciprocal_evidence"
    }
}

public struct ONTGenotypeProvisionalExon2ArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogJSON: ONTMHCArtifactReference
    public let sequencesFASTA: ONTMHCArtifactReference

    public init(
        schemaVersion: Int,
        catalogJSON: ONTMHCArtifactReference,
        sequencesFASTA: ONTMHCArtifactReference
    ) {
        self.schemaVersion = schemaVersion
        self.catalogJSON = catalogJSON
        self.sequencesFASTA = sequencesFASTA
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case catalogJSON = "catalog_json"
        case sequencesFASTA = "sequences_fasta"
    }
}

public struct ONTGenotypeProvisionalExon2Document: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let records: [ONTGenotypeProvisionalExon2Record]

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        records: [ONTGenotypeProvisionalExon2Record]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }
}

public struct ONTGenotypeProvisionalExon2Record: Codable, Equatable, Sendable {
    public let genotype: String
    public let locus: String
    public let fastaRecordID: String
    public let sequenceLength: Int
    public let sequenceSHA256: String
    public let sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]

    public init(
        genotype: String,
        locus: String,
        fastaRecordID: String,
        sequenceLength: Int,
        sequenceSHA256: String,
        sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]
    ) {
        self.genotype = genotype
        self.locus = locus
        self.fastaRecordID = fastaRecordID
        self.sequenceLength = sequenceLength
        self.sequenceSHA256 = sequenceSHA256
        self.sampleSupport = sampleSupport
    }

    private enum CodingKeys: String, CodingKey {
        case genotype
        case locus
        case fastaRecordID = "fasta_record_id"
        case sequenceLength = "sequence_length"
        case sequenceSHA256 = "sequence_sha256"
        case sampleSupport = "sample_support"
    }
}

public struct ONTGenotypeProvisionalExon2SampleSupport: Codable, Equatable, Sendable {
    public let sample: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int

    public init(sample: String, passedAlignments: Int, passedUniqueReads: Int) {
        self.sample = sample
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
    }

    private enum CodingKeys: String, CodingKey {
        case sample
        case passedAlignments = "passed_alignments"
        case passedUniqueReads = "passed_unique_reads"
    }
}
