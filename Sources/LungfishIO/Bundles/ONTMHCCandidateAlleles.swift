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

public enum ONTMHCCandidateClassification: String, Codable, Sendable {
    case novel
    case `extension`
}

public enum ONTMHCCandidateSupportClass: String, Codable, Sendable {
    case singleton
    case shared
}

public enum ONTMHCUnnameableReason: String, Codable, Sendable {
    case noAlignment = "no-alignment"
    case insufficientAlignedBases = "insufficient-aligned-bases"
    case insufficientCoverage = "insufficient-coverage"
    case insufficientIdentity = "insufficient-identity"
    case unresolvedLocus = "unresolved-locus"
    case ambiguousReferenceClass = "ambiguous-reference-class"
}

public enum ONTMHCCandidateModelError: Error, LocalizedError, Equatable, Sendable {
    case invalidMinimumAlignedBases(Int)
    case invalidMinimumIdentity(Double)
    case invalidMinimumShorterCoverage(Double)
    case invalidMinimumIntronGapBases(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMinimumAlignedBases(let value):
            return "Minimum aligned bases must be greater than zero; received \(value)."
        case .invalidMinimumIdentity(let value):
            return "Minimum identity must be finite and between zero and one; received \(value)."
        case .invalidMinimumShorterCoverage(let value):
            return "Minimum shorter-sequence coverage must be finite and between zero and one; received \(value)."
        case .invalidMinimumIntronGapBases(let value):
            return "Minimum intron gap bases must be greater than zero; received \(value)."
        }
    }
}

public struct ONTMHCCandidateThresholds: Codable, Equatable, Sendable {
    public let minimumAlignedBases: Int
    public let minimumIdentity: Double
    public let minimumShorterCoverage: Double
    public let minimumIntronGapBases: Int

    public static let defaults = ONTMHCCandidateThresholds(
        validatedMinimumAlignedBases: 1_000,
        minimumIdentity: 0.75,
        minimumShorterCoverage: 0.70,
        minimumIntronGapBases: 20
    )

    public init(
        minimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) throws {
        try Self.validate(
            minimumAlignedBases: minimumAlignedBases,
            minimumIdentity: minimumIdentity,
            minimumShorterCoverage: minimumShorterCoverage,
            minimumIntronGapBases: minimumIntronGapBases
        )
        self.init(
            validatedMinimumAlignedBases: minimumAlignedBases,
            minimumIdentity: minimumIdentity,
            minimumShorterCoverage: minimumShorterCoverage,
            minimumIntronGapBases: minimumIntronGapBases
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumAlignedBases: container.decode(Int.self, forKey: .minimumAlignedBases),
            minimumIdentity: container.decode(Double.self, forKey: .minimumIdentity),
            minimumShorterCoverage: container.decode(Double.self, forKey: .minimumShorterCoverage),
            minimumIntronGapBases: container.decode(Int.self, forKey: .minimumIntronGapBases)
        )
    }

    private init(
        validatedMinimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) {
        self.minimumAlignedBases = validatedMinimumAlignedBases
        self.minimumIdentity = minimumIdentity
        self.minimumShorterCoverage = minimumShorterCoverage
        self.minimumIntronGapBases = minimumIntronGapBases
    }

    private static func validate(
        minimumAlignedBases: Int,
        minimumIdentity: Double,
        minimumShorterCoverage: Double,
        minimumIntronGapBases: Int
    ) throws {
        guard minimumAlignedBases > 0 else {
            throw ONTMHCCandidateModelError.invalidMinimumAlignedBases(minimumAlignedBases)
        }
        guard minimumIdentity.isFinite, minimumIdentity > 0, minimumIdentity <= 1 else {
            throw ONTMHCCandidateModelError.invalidMinimumIdentity(minimumIdentity)
        }
        guard minimumShorterCoverage.isFinite,
              minimumShorterCoverage > 0,
              minimumShorterCoverage <= 1 else {
            throw ONTMHCCandidateModelError.invalidMinimumShorterCoverage(minimumShorterCoverage)
        }
        guard minimumIntronGapBases > 0 else {
            throw ONTMHCCandidateModelError.invalidMinimumIntronGapBases(minimumIntronGapBases)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case minimumAlignedBases = "minimum_aligned_bases"
        case minimumIdentity = "minimum_identity"
        case minimumShorterCoverage = "minimum_shorter_coverage"
        case minimumIntronGapBases = "minimum_intron_gap_bases"
    }
}

public struct ONTMHCEvidenceLocator: Codable, Equatable, Sendable {
    public let bamPath: String
    public let queryName: String
    public let referenceName: String
    public let readGroupID: String?
    public let referenceStart: Int
    public let cigar: String

    public init(
        bamPath: String,
        queryName: String,
        referenceName: String,
        readGroupID: String?,
        referenceStart: Int,
        cigar: String
    ) {
        self.bamPath = bamPath
        self.queryName = queryName
        self.referenceName = referenceName
        self.readGroupID = readGroupID
        self.referenceStart = referenceStart
        self.cigar = cigar
    }

    private enum CodingKeys: String, CodingKey {
        case bamPath = "bam_path"
        case queryName = "query_name"
        case referenceName = "reference_name"
        case readGroupID = "read_group_id"
        case referenceStart = "reference_start"
        case cigar
    }
}

public struct ONTMHCCandidateObservation: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let sampleID: String
    public let readGroupID: String
    public let sourceClusterIDs: [String]
    public let sourceClusterReadCounts: [String: Int]
    public let aggregatedSampleReadCount: Int
    public let evidence: [ONTMHCEvidenceLocator]

    public init(
        stableClusterID: String,
        sampleID: String,
        readGroupID: String,
        sourceClusterIDs: [String],
        sourceClusterReadCounts: [String: Int],
        aggregatedSampleReadCount: Int,
        evidence: [ONTMHCEvidenceLocator]
    ) {
        self.stableClusterID = stableClusterID
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.sourceClusterIDs = sourceClusterIDs
        self.sourceClusterReadCounts = sourceClusterReadCounts
        self.aggregatedSampleReadCount = aggregatedSampleReadCount
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case stableClusterID = "stable_cluster_id"
        case sampleID = "sample_id"
        case readGroupID = "read_group_id"
        case sourceClusterIDs = "source_cluster_ids"
        case sourceClusterReadCounts = "source_cluster_read_counts"
        case aggregatedSampleReadCount = "aggregated_sample_read_count"
        case evidence
    }
}

public struct ONTMHCCandidateRecord: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let provisionalName: String
    public let locus: String
    public let classification: ONTMHCCandidateClassification
    public let supportClass: ONTMHCCandidateSupportClass
    public let closestReferenceName: String
    public let closestReferenceClass: MHCReferenceMoleculeClass
    public let snpCount: Int
    public let insertedBases: Int
    public let deletedBases: Int
    public let longGapBases: Int
    public let comparableBases: Int
    public let shorterCoverage: Double
    public let identity: Double
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let independentSampleCount: Int
    public let occurrenceCount: Int
    public let totalClusterReads: Int
    public let supportingSampleIDs: [String]
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let selectedEvidence: ONTMHCEvidenceLocator

    public init(
        stableClusterID: String,
        provisionalName: String,
        locus: String,
        classification: ONTMHCCandidateClassification,
        supportClass: ONTMHCCandidateSupportClass,
        closestReferenceName: String,
        closestReferenceClass: MHCReferenceMoleculeClass,
        snpCount: Int,
        insertedBases: Int,
        deletedBases: Int,
        longGapBases: Int,
        comparableBases: Int,
        shorterCoverage: Double,
        identity: Double,
        mappingQuality: Int,
        alignmentScore: Int,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        supportingSampleIDs: [String],
        fastaRecordID: String,
        sequenceSHA256: String,
        selectedEvidence: ONTMHCEvidenceLocator
    ) {
        self.stableClusterID = stableClusterID
        self.provisionalName = provisionalName
        self.locus = locus
        self.classification = classification
        self.supportClass = supportClass
        self.closestReferenceName = closestReferenceName
        self.closestReferenceClass = closestReferenceClass
        self.snpCount = snpCount
        self.insertedBases = insertedBases
        self.deletedBases = deletedBases
        self.longGapBases = longGapBases
        self.comparableBases = comparableBases
        self.shorterCoverage = shorterCoverage
        self.identity = identity
        self.mappingQuality = mappingQuality
        self.alignmentScore = alignmentScore
        self.independentSampleCount = independentSampleCount
        self.occurrenceCount = occurrenceCount
        self.totalClusterReads = totalClusterReads
        self.supportingSampleIDs = supportingSampleIDs
        self.fastaRecordID = fastaRecordID
        self.sequenceSHA256 = sequenceSHA256
        self.selectedEvidence = selectedEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case stableClusterID = "stable_cluster_id"
        case provisionalName = "provisional_name"
        case locus
        case classification
        case supportClass = "support_class"
        case closestReferenceName = "closest_reference_name"
        case closestReferenceClass = "closest_reference_class"
        case snpCount = "snp_count"
        case insertedBases = "inserted_bases"
        case deletedBases = "deleted_bases"
        case longGapBases = "long_gap_bases"
        case comparableBases = "comparable_bases"
        case shorterCoverage = "shorter_coverage"
        case identity
        case mappingQuality = "mapping_quality"
        case alignmentScore = "alignment_score"
        case independentSampleCount = "independent_sample_count"
        case occurrenceCount = "occurrence_count"
        case totalClusterReads = "total_cluster_reads"
        case supportingSampleIDs = "supporting_sample_ids"
        case fastaRecordID = "fasta_record_id"
        case sequenceSHA256 = "sequence_sha256"
        case selectedEvidence = "selected_evidence"
    }
}

public struct ONTMHCUnnameableRecord: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let reason: ONTMHCUnnameableReason
    public let failedMetrics: [String: Double]
    public let supportClass: ONTMHCCandidateSupportClass
    public let independentSampleCount: Int
    public let occurrenceCount: Int
    public let totalClusterReads: Int
    public let supportingSampleIDs: [String]
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let evidence: [ONTMHCEvidenceLocator]

    public init(
        stableClusterID: String,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        supportClass: ONTMHCCandidateSupportClass,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        supportingSampleIDs: [String],
        fastaRecordID: String,
        sequenceSHA256: String,
        evidence: [ONTMHCEvidenceLocator]
    ) {
        self.stableClusterID = stableClusterID
        self.reason = reason
        self.failedMetrics = failedMetrics
        self.supportClass = supportClass
        self.independentSampleCount = independentSampleCount
        self.occurrenceCount = occurrenceCount
        self.totalClusterReads = totalClusterReads
        self.supportingSampleIDs = supportingSampleIDs
        self.fastaRecordID = fastaRecordID
        self.sequenceSHA256 = sequenceSHA256
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case stableClusterID = "stable_cluster_id"
        case reason
        case failedMetrics = "failed_metrics"
        case supportClass = "support_class"
        case independentSampleCount = "independent_sample_count"
        case occurrenceCount = "occurrence_count"
        case totalClusterReads = "total_cluster_reads"
        case supportingSampleIDs = "supporting_sample_ids"
        case fastaRecordID = "fasta_record_id"
        case sequenceSHA256 = "sequence_sha256"
        case evidence
    }
}

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

public struct ONTMHCUnnameableClustersDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let thresholds: ONTMHCCandidateThresholds
    public let sequenceFASTA: ONTMHCArtifactReference
    public let clusters: [ONTMHCUnnameableRecord]
    public let observations: [ONTMHCCandidateObservation]

    public init(
        schemaVersion: Int,
        createdAt: String,
        thresholds: ONTMHCCandidateThresholds,
        sequenceFASTA: ONTMHCArtifactReference,
        clusters: [ONTMHCUnnameableRecord],
        observations: [ONTMHCCandidateObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.thresholds = thresholds
        self.sequenceFASTA = sequenceFASTA
        self.clusters = clusters
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case thresholds
        case sequenceFASTA = "sequence_fasta"
        case clusters
        case observations
    }
}
