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

public struct ONTGenotypeProvisionalExon2Sequence: Codable, Equatable, Sendable {
    public let genotype: String
    public let locus: String
    public let sequence: String
    public let sequenceSHA256: String
    public let sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]

    public init(
        genotype: String,
        locus: String,
        sequence: String,
        sequenceSHA256: String,
        sampleSupport: [ONTGenotypeProvisionalExon2SampleSupport]
    ) {
        self.genotype = genotype
        self.locus = locus
        self.sequence = sequence
        self.sequenceSHA256 = sequenceSHA256
        self.sampleSupport = sampleSupport
    }

    public var designation: String { "Provisional exon 2" }
}

public struct ONTGenotypeProvisionalExon2ArtifactURLs: Codable, Equatable, Sendable {
    public static let empty = ONTGenotypeProvisionalExon2ArtifactURLs(
        catalogJSON: nil,
        sequencesFASTA: nil
    )

    public let catalogJSON: URL?
    public let sequencesFASTA: URL?

    public init(catalogJSON: URL?, sequencesFASTA: URL?) {
        self.catalogJSON = catalogJSON?.standardizedFileURL
        self.sequencesFASTA = sequencesFASTA?.standardizedFileURL
    }
}

public enum ONTGenotypeScientificArtifactError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProvisionalExon2Schema(Int)
    case malformedProvisionalExon2JSON(String)
    case duplicateProvisionalGenotype(String)
    case invalidProvisionalGenotype(String)
    case unobservedProvisionalGenotype(String)
    case duplicateFASTARecord(String)
    case unexpectedFASTARecords
    case missingFASTARecord(String)
    case sequenceLengthMismatch(String)
    case sequenceChecksumMismatch(String)
    case locusMismatch(String)
    case sampleSupportMismatch(String)
    case conflictingAlignmentDeclarations

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvisionalExon2Schema(let version):
            return "Unsupported Provisional exon 2 schema version \(version)."
        case .malformedProvisionalExon2JSON(let detail):
            return "The Provisional exon 2 catalog is malformed: \(detail)"
        case .duplicateProvisionalGenotype(let genotype):
            return "The Provisional exon 2 catalog contains duplicate genotype '\(genotype)'."
        case .invalidProvisionalGenotype(let genotype):
            return "The Provisional exon 2 catalog contains a genotype without an exact _nov identifier: \(genotype)."
        case .unobservedProvisionalGenotype(let genotype):
            return "The Provisional exon 2 catalog genotype was not observed in this result: \(genotype)."
        case .duplicateFASTARecord(let recordID):
            return "The Provisional exon 2 FASTA contains duplicate record '\(recordID)'."
        case .unexpectedFASTARecords:
            return "The Provisional exon 2 JSON and FASTA record sets do not agree."
        case .missingFASTARecord(let recordID):
            return "The Provisional exon 2 FASTA is missing record '\(recordID)'."
        case .sequenceLengthMismatch(let genotype):
            return "The Provisional exon 2 sequence length does not match the catalog for \(genotype)."
        case .sequenceChecksumMismatch(let genotype):
            return "The Provisional exon 2 sequence checksum does not match the catalog for \(genotype)."
        case .locusMismatch(let genotype):
            return "The Provisional exon 2 locus does not match observed calls for \(genotype)."
        case .sampleSupportMismatch(let genotype):
            return "The Provisional exon 2 sample support does not match observed calls for \(genotype)."
        case .conflictingAlignmentDeclarations:
            return "The generic and full-length alignment evidence declarations disagree."
        }
    }
}
