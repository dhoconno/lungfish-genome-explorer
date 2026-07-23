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
    public let candidateGenBank: ONTMHCArtifactReference?
    public let unnameableJSON: ONTMHCArtifactReference?
    public let unnameableFASTA: ONTMHCArtifactReference?
    public let unnameableGenBank: ONTMHCArtifactReference?
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
            unnameableJSON: unnameableJSON,
            unnameableFASTA: unnameableFASTA,
            unnameableGenBank: nil,
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
        unnameableJSON: ONTMHCArtifactReference?,
        unnameableFASTA: ONTMHCArtifactReference?,
        unnameableGenBank: ONTMHCArtifactReference? = nil,
        rawUnmatchedFASTA: ONTMHCArtifactReference? = nil,
        sourceIdentityMap: ONTMHCArtifactReference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.genotypingEvidence = genotypingEvidence
        self.reciprocalEvidence = reciprocalEvidence
        self.candidateJSON = candidateJSON
        self.candidateFASTA = candidateFASTA
        self.candidateGenBank = candidateGenBank
        self.unnameableJSON = unnameableJSON
        self.unnameableFASTA = unnameableFASTA
        self.unnameableGenBank = unnameableGenBank
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
        case unnameableJSON = "unnameable_json"
        case unnameableFASTA = "unnameable_fasta"
        case unnameableGenBank = "unnameable_genbank"
        case rawUnmatchedFASTA = "raw_unmatched_fasta"
        case sourceIdentityMap = "source_identity_map"
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
    case incompleteReferenceSpan = "incomplete-reference-span"
    case referenceCanonicalizationUnavailable = "reference-canonicalization-unavailable"
    case unresolvedLocus = "unresolved-locus"
    case ambiguousReferenceClass = "ambiguous-reference-class"
}

public struct ONTMHCCandidateSourceIdentityRecord: Codable, Equatable, Sendable {
    public let rawStableClusterID: String
    public let rawSequenceSHA256: String
    public let rawSequenceLength: Int
    public let canonicalStableClusterID: String?
    public let canonicalSequenceSHA256: String?
    public let trimStart: Int?
    public let trimEnd: Int?
    public let referenceReadiness: String
    public let classification: String
    public let sampleIDs: [String]
    public let isRepresentative: Bool

    public init(
        rawStableClusterID: String,
        rawSequenceSHA256: String,
        rawSequenceLength: Int,
        canonicalStableClusterID: String? = nil,
        canonicalSequenceSHA256: String? = nil,
        trimStart: Int? = nil,
        trimEnd: Int? = nil,
        referenceReadiness: String,
        classification: String = "unavailable",
        sampleIDs: [String] = [],
        isRepresentative: Bool = false
    ) {
        self.rawStableClusterID = rawStableClusterID
        self.rawSequenceSHA256 = rawSequenceSHA256
        self.rawSequenceLength = rawSequenceLength
        self.canonicalStableClusterID = canonicalStableClusterID
        self.canonicalSequenceSHA256 = canonicalSequenceSHA256
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.referenceReadiness = referenceReadiness
        self.classification = classification
        self.sampleIDs = sampleIDs
        self.isRepresentative = isRepresentative
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rawStableClusterID: try container.decode(String.self, forKey: .rawStableClusterID),
            rawSequenceSHA256: try container.decode(String.self, forKey: .rawSequenceSHA256),
            rawSequenceLength: try container.decode(Int.self, forKey: .rawSequenceLength),
            canonicalStableClusterID: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalStableClusterID
            ),
            canonicalSequenceSHA256: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalSequenceSHA256
            ),
            trimStart: try container.decodeIfPresent(Int.self, forKey: .trimStart),
            trimEnd: try container.decodeIfPresent(Int.self, forKey: .trimEnd),
            referenceReadiness: try container.decode(
                String.self,
                forKey: .referenceReadiness
            ),
            classification: try container.decodeIfPresent(
                String.self,
                forKey: .classification
            ) ?? "unavailable",
            sampleIDs: try container.decodeIfPresent([String].self, forKey: .sampleIDs) ?? [],
            isRepresentative: try container.decodeIfPresent(
                Bool.self,
                forKey: .isRepresentative
            ) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case rawStableClusterID = "raw_stable_cluster_id"
        case rawSequenceSHA256 = "raw_sequence_sha256"
        case rawSequenceLength = "raw_sequence_length"
        case canonicalStableClusterID = "canonical_stable_cluster_id"
        case canonicalSequenceSHA256 = "canonical_sequence_sha256"
        case trimStart = "trim_start"
        case trimEnd = "trim_end"
        case referenceReadiness = "reference_readiness"
        case classification
        case sampleIDs = "sample_ids"
        case isRepresentative = "is_representative"
    }
}

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

public enum ONTMHCCandidateModelError: Error, LocalizedError, Equatable, Sendable {
    case invalidMinimumAlignedBases(Int)
    case invalidMinimumIdentity(Double)
    case invalidMinimumShorterCoverage(Double)
    case invalidMinimumIntronGapBases(Int)
    case invalidHitSummary(kind: String, field: String, value: String)

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
        case .invalidHitSummary(let kind, let field, let value):
            return "Invalid \(kind) hit summary \(field): \(value)."
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

public struct ONTMHCGenotypingTargetHitSummary: Codable, Equatable, Sendable {
    public let bamPath: String
    public let targetName: String
    public let alignmentCount: Int
    public let queryAlignmentCounts: [String: Int]
    public let exactMatchQueryNames: [String]
    public let closestMatchQueryNames: [String]
    public let cdnaExtensionInterpretations: [ONTMHCCDNAExtensionInterpretation]

    public var queryEdgeCount: Int { queryAlignmentCounts.count }

    public init(
        bamPath: String,
        targetName: String,
        alignmentCount: Int,
        queryAlignmentCounts: [String: Int],
        exactMatchQueryNames: [String],
        closestMatchQueryNames: [String],
        cdnaExtensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = []
    ) throws {
        try Self.validate(
            bamPath: bamPath,
            targetName: targetName,
            alignmentCount: alignmentCount,
            queryAlignmentCounts: queryAlignmentCounts,
            exactMatchQueryNames: exactMatchQueryNames,
            closestMatchQueryNames: closestMatchQueryNames
        )
        self.bamPath = bamPath
        self.targetName = targetName
        self.alignmentCount = alignmentCount
        self.queryAlignmentCounts = queryAlignmentCounts
        self.exactMatchQueryNames = exactMatchQueryNames
        self.closestMatchQueryNames = closestMatchQueryNames
        self.cdnaExtensionInterpretations = cdnaExtensionInterpretations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bamPath: container.decode(String.self, forKey: .bamPath),
            targetName: container.decode(String.self, forKey: .targetName),
            alignmentCount: container.decode(Int.self, forKey: .alignmentCount),
            queryAlignmentCounts: container.decode([String: Int].self, forKey: .queryAlignmentCounts),
            exactMatchQueryNames: container.decode([String].self, forKey: .exactMatchQueryNames),
            closestMatchQueryNames: container.decode([String].self, forKey: .closestMatchQueryNames),
            cdnaExtensionInterpretations: container.decodeIfPresent(
                [ONTMHCCDNAExtensionInterpretation].self,
                forKey: .cdnaExtensionInterpretations
            ) ?? []
        )
    }

    fileprivate init(
        uncheckedBAMPath bamPath: String,
        targetName: String,
        alignmentCount: Int,
        queryAlignmentCounts: [String: Int],
        exactMatchQueryNames: [String],
        closestMatchQueryNames: [String],
        cdnaExtensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = []
    ) {
        self.bamPath = bamPath
        self.targetName = targetName
        self.alignmentCount = alignmentCount
        self.queryAlignmentCounts = queryAlignmentCounts
        self.exactMatchQueryNames = exactMatchQueryNames
        self.closestMatchQueryNames = closestMatchQueryNames
        self.cdnaExtensionInterpretations = cdnaExtensionInterpretations
    }

    private static func validate(
        bamPath: String,
        targetName: String,
        alignmentCount: Int,
        queryAlignmentCounts: [String: Int],
        exactMatchQueryNames: [String],
        closestMatchQueryNames: [String]
    ) throws {
        try validateHitSummary(
            kind: "genotyping target",
            bamPath: bamPath,
            identityField: "target_name",
            identity: targetName,
            alignmentCount: alignmentCount,
            edgeCounts: queryAlignmentCounts,
            exactNames: exactMatchQueryNames,
            closestNames: closestMatchQueryNames
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bamPath = "bam_path"
        case targetName = "target_name"
        case alignmentCount = "alignment_count"
        case queryAlignmentCounts = "query_alignment_counts"
        case exactMatchQueryNames = "exact_match_query_names"
        case closestMatchQueryNames = "closest_match_query_names"
        case cdnaExtensionInterpretations = "cdna_extension_interpretations"
    }
}

public struct ONTMHCReciprocalQueryHitSummary: Codable, Equatable, Sendable {
    public let bamPath: String
    public let queryName: String
    public let alignmentCount: Int
    public let targetAlignmentCounts: [String: Int]
    public let exactMatchTargetNames: [String]
    public let closestMatchTargetNames: [String]

    public var targetEdgeCount: Int { targetAlignmentCounts.count }

    public init(
        bamPath: String,
        queryName: String,
        alignmentCount: Int,
        targetAlignmentCounts: [String: Int],
        exactMatchTargetNames: [String],
        closestMatchTargetNames: [String]
    ) throws {
        try validateHitSummary(
            kind: "reciprocal query",
            bamPath: bamPath,
            identityField: "query_name",
            identity: queryName,
            alignmentCount: alignmentCount,
            edgeCounts: targetAlignmentCounts,
            exactNames: exactMatchTargetNames,
            closestNames: closestMatchTargetNames
        )
        self.bamPath = bamPath
        self.queryName = queryName
        self.alignmentCount = alignmentCount
        self.targetAlignmentCounts = targetAlignmentCounts
        self.exactMatchTargetNames = exactMatchTargetNames
        self.closestMatchTargetNames = closestMatchTargetNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bamPath: container.decode(String.self, forKey: .bamPath),
            queryName: container.decode(String.self, forKey: .queryName),
            alignmentCount: container.decode(Int.self, forKey: .alignmentCount),
            targetAlignmentCounts: container.decode([String: Int].self, forKey: .targetAlignmentCounts),
            exactMatchTargetNames: container.decode([String].self, forKey: .exactMatchTargetNames),
            closestMatchTargetNames: container.decode([String].self, forKey: .closestMatchTargetNames)
        )
    }

    fileprivate init(
        uncheckedBAMPath bamPath: String,
        queryName: String,
        alignmentCount: Int,
        targetAlignmentCounts: [String: Int],
        exactMatchTargetNames: [String],
        closestMatchTargetNames: [String]
    ) {
        self.bamPath = bamPath
        self.queryName = queryName
        self.alignmentCount = alignmentCount
        self.targetAlignmentCounts = targetAlignmentCounts
        self.exactMatchTargetNames = exactMatchTargetNames
        self.closestMatchTargetNames = closestMatchTargetNames
    }

    private enum CodingKeys: String, CodingKey {
        case bamPath = "bam_path"
        case queryName = "query_name"
        case alignmentCount = "alignment_count"
        case targetAlignmentCounts = "target_alignment_counts"
        case exactMatchTargetNames = "exact_match_target_names"
        case closestMatchTargetNames = "closest_match_target_names"
    }
}

private func validateHitSummary(
    kind: String,
    bamPath: String,
    identityField: String,
    identity: String,
    alignmentCount: Int,
    edgeCounts: [String: Int],
    exactNames: [String],
    closestNames: [String]
) throws {
    func invalid(_ field: String, _ value: String) -> ONTMHCCandidateModelError {
        .invalidHitSummary(kind: kind, field: field, value: value)
    }
    guard !bamPath.isEmpty else { throw invalid("bam_path", "empty") }
    guard !identity.isEmpty else { throw invalid(identityField, "empty") }
    guard alignmentCount >= 0 else { throw invalid("alignment_count", String(alignmentCount)) }
    guard edgeCounts.keys.allSatisfy({ !$0.isEmpty }),
          edgeCounts.values.allSatisfy({ $0 > 0 }) else {
        throw invalid("alignment_counts", "names must be nonempty and counts must be positive")
    }
    var total = 0
    for count in edgeCounts.values {
        let sum = total.addingReportingOverflow(count)
        guard !sum.overflow else { throw invalid("alignment_counts", "integer overflow") }
        total = sum.partialValue
    }
    guard total == alignmentCount else {
        throw invalid("alignment_count", "\(alignmentCount) does not equal edge total \(total)")
    }
    for (field, names) in [("exact_match_names", exactNames), ("closest_match_names", closestNames)] {
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
            throw invalid(field, "names must be nonempty and unique")
        }
        guard Set(names).isSubset(of: Set(edgeCounts.keys)) else {
            throw invalid(field, "names must occur in alignment counts")
        }
    }
}

private struct ONTMHCEvidenceLocatorIdentity: Hashable {
    let bamPath: String
    let queryName: String
    let referenceName: String
    let readGroupID: String?
    let referenceStart: Int
    let cigar: String

    init(_ locator: ONTMHCEvidenceLocator) {
        bamPath = locator.bamPath
        queryName = locator.queryName
        referenceName = locator.referenceName
        readGroupID = locator.readGroupID
        referenceStart = locator.referenceStart
        cigar = locator.cigar
    }
}

private enum ONTMHCEvidenceWireShape: Equatable, Sendable {
    case legacyLocators
    case compactSummaries
}

public struct ONTMHCCandidateObservation: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let sourceSequenceClusterID: String
    public let sampleID: String
    public let readGroupID: String
    public let sourceClusterIDs: [String]
    public let sourceClusterReadCounts: [String: Int]
    public let aggregatedSampleReadCount: Int
    public let genotypingHitSummaries: [ONTMHCGenotypingTargetHitSummary]
    /// Retained only when decoding or constructing schema-version 1 records.
    public let evidence: [ONTMHCEvidenceLocator]
    private let evidenceWireShape: ONTMHCEvidenceWireShape

    public var genotypingAlignmentCount: Int {
        genotypingHitSummaries.reduce(0) { $0 + $1.alignmentCount }
    }

    public var genotypingEdgeCount: Int {
        genotypingHitSummaries.reduce(0) { $0 + $1.queryEdgeCount }
    }

    public init(
        stableClusterID: String,
        sampleID: String,
        readGroupID: String,
        sourceClusterIDs: [String],
        sourceClusterReadCounts: [String: Int],
        aggregatedSampleReadCount: Int,
        genotypingHitSummaries: [ONTMHCGenotypingTargetHitSummary]
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterID: stableClusterID,
            sampleID: sampleID,
            readGroupID: readGroupID,
            sourceClusterIDs: sourceClusterIDs,
            sourceClusterReadCounts: sourceClusterReadCounts,
            aggregatedSampleReadCount: aggregatedSampleReadCount,
            genotypingHitSummaries: genotypingHitSummaries
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterID: String,
        sampleID: String,
        readGroupID: String,
        sourceClusterIDs: [String],
        sourceClusterReadCounts: [String: Int],
        aggregatedSampleReadCount: Int,
        genotypingHitSummaries: [ONTMHCGenotypingTargetHitSummary]
    ) {
        self.stableClusterID = stableClusterID
        self.sourceSequenceClusterID = sourceSequenceClusterID
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.sourceClusterIDs = sourceClusterIDs
        self.sourceClusterReadCounts = sourceClusterReadCounts
        self.aggregatedSampleReadCount = aggregatedSampleReadCount
        self.genotypingHitSummaries = genotypingHitSummaries
        self.evidence = []
        self.evidenceWireShape = .compactSummaries
    }

    public init(
        stableClusterID: String,
        sampleID: String,
        readGroupID: String,
        sourceClusterIDs: [String],
        sourceClusterReadCounts: [String: Int],
        aggregatedSampleReadCount: Int,
        evidence: [ONTMHCEvidenceLocator]
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterID: stableClusterID,
            sampleID: sampleID,
            readGroupID: readGroupID,
            sourceClusterIDs: sourceClusterIDs,
            sourceClusterReadCounts: sourceClusterReadCounts,
            aggregatedSampleReadCount: aggregatedSampleReadCount,
            evidence: evidence
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterID: String,
        sampleID: String,
        readGroupID: String,
        sourceClusterIDs: [String],
        sourceClusterReadCounts: [String: Int],
        aggregatedSampleReadCount: Int,
        evidence: [ONTMHCEvidenceLocator]
    ) {
        self.stableClusterID = stableClusterID
        self.sourceSequenceClusterID = sourceSequenceClusterID
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.sourceClusterIDs = sourceClusterIDs
        self.sourceClusterReadCounts = sourceClusterReadCounts
        self.aggregatedSampleReadCount = aggregatedSampleReadCount
        self.genotypingHitSummaries = Self.legacyHitSummaries(evidence)
        self.evidence = evidence
        self.evidenceWireShape = .legacyLocators
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stableClusterID = try container.decode(String.self, forKey: .stableClusterID)
        let sampleID = try container.decode(String.self, forKey: .sampleID)
        let readGroupID = try container.decode(String.self, forKey: .readGroupID)
        let sourceClusterIDs = try container.decode([String].self, forKey: .sourceClusterIDs)
        let sourceClusterReadCounts = try container.decode([String: Int].self, forKey: .sourceClusterReadCounts)
        let aggregatedSampleReadCount = try container.decode(Int.self, forKey: .aggregatedSampleReadCount)
        if container.contains(.genotypingHitSummaries) {
            self.init(
                stableClusterID: stableClusterID,
                sourceSequenceClusterID: try container.decodeIfPresent(
                    String.self,
                    forKey: .sourceSequenceClusterID
                ) ?? stableClusterID,
                sampleID: sampleID,
                readGroupID: readGroupID,
                sourceClusterIDs: sourceClusterIDs,
                sourceClusterReadCounts: sourceClusterReadCounts,
                aggregatedSampleReadCount: aggregatedSampleReadCount,
                genotypingHitSummaries: try container.decode(
                    [ONTMHCGenotypingTargetHitSummary].self,
                    forKey: .genotypingHitSummaries
                )
            )
        } else {
            self.init(
                stableClusterID: stableClusterID,
                sourceSequenceClusterID: try container.decodeIfPresent(
                    String.self,
                    forKey: .sourceSequenceClusterID
                ) ?? stableClusterID,
                sampleID: sampleID,
                readGroupID: readGroupID,
                sourceClusterIDs: sourceClusterIDs,
                sourceClusterReadCounts: sourceClusterReadCounts,
                aggregatedSampleReadCount: aggregatedSampleReadCount,
                evidence: try container.decodeIfPresent(
                    [ONTMHCEvidenceLocator].self,
                    forKey: .evidence
                ) ?? []
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableClusterID, forKey: .stableClusterID)
        try container.encode(sourceSequenceClusterID, forKey: .sourceSequenceClusterID)
        try container.encode(sampleID, forKey: .sampleID)
        try container.encode(readGroupID, forKey: .readGroupID)
        try container.encode(sourceClusterIDs, forKey: .sourceClusterIDs)
        try container.encode(sourceClusterReadCounts, forKey: .sourceClusterReadCounts)
        try container.encode(aggregatedSampleReadCount, forKey: .aggregatedSampleReadCount)
        switch evidenceWireShape {
        case .legacyLocators:
            try container.encode(evidence, forKey: .evidence)
        case .compactSummaries:
            try container.encode(genotypingHitSummaries, forKey: .genotypingHitSummaries)
        }
    }

    private static func legacyHitSummaries(
        _ evidence: [ONTMHCEvidenceLocator]
    ) -> [ONTMHCGenotypingTargetHitSummary] {
        struct Target: Hashable {
            let bamPath: String
            let name: String
        }
        let unique = Dictionary(
            evidence.map { (ONTMHCEvidenceLocatorIdentity($0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        let grouped = Dictionary(grouping: unique) {
            Target(bamPath: $0.bamPath, name: $0.referenceName)
        }
        return grouped.map { target, locators in
            let counts = Dictionary(grouping: locators, by: \.queryName).mapValues(\.count)
            return ONTMHCGenotypingTargetHitSummary(
                uncheckedBAMPath: target.bamPath,
                targetName: target.name,
                alignmentCount: locators.count,
                queryAlignmentCounts: counts,
                exactMatchQueryNames: [],
                closestMatchQueryNames: []
            )
        }.sorted {
            [$0.bamPath, $0.targetName].lexicographicallyPrecedes([$1.bamPath, $1.targetName])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case stableClusterID = "stable_cluster_id"
        case sourceSequenceClusterID = "source_sequence_cluster_id"
        case sampleID = "sample_id"
        case readGroupID = "read_group_id"
        case sourceClusterIDs = "source_cluster_ids"
        case sourceClusterReadCounts = "source_cluster_read_counts"
        case aggregatedSampleReadCount = "aggregated_sample_read_count"
        case genotypingHitSummaries = "genotyping_hit_summaries"
        case evidence
    }
}

public struct ONTMHCCDNAExtensionInterpretation: Codable, Equatable, Sendable {
    public let rawReferenceID: String
    public let alleleName: String
    public let locus: String
    public let cDNAReferenceCoverage: Double
    public let clusterCoverage: Double
    public let leadingClusterFlankBases: Int
    public let trailingClusterFlankBases: Int
    public let largestClusterStructuralSegmentBases: Int
    public let largestCDNADeficitSegmentBases: Int
    public let snpSubstitutions: Int
    public let ordinaryIndelBases: Int
    public let isReverse: Bool
    public let alignmentScore: Int
    public let identity: Double

    public init(
        rawReferenceID: String,
        alleleName: String,
        locus: String,
        cDNAReferenceCoverage: Double,
        clusterCoverage: Double,
        leadingClusterFlankBases: Int,
        trailingClusterFlankBases: Int,
        largestClusterStructuralSegmentBases: Int,
        largestCDNADeficitSegmentBases: Int,
        snpSubstitutions: Int,
        ordinaryIndelBases: Int,
        isReverse: Bool,
        alignmentScore: Int,
        identity: Double
    ) {
        self.rawReferenceID = rawReferenceID
        self.alleleName = alleleName
        self.locus = locus
        self.cDNAReferenceCoverage = cDNAReferenceCoverage
        self.clusterCoverage = clusterCoverage
        self.leadingClusterFlankBases = leadingClusterFlankBases
        self.trailingClusterFlankBases = trailingClusterFlankBases
        self.largestClusterStructuralSegmentBases = largestClusterStructuralSegmentBases
        self.largestCDNADeficitSegmentBases = largestCDNADeficitSegmentBases
        self.snpSubstitutions = snpSubstitutions
        self.ordinaryIndelBases = ordinaryIndelBases
        self.isReverse = isReverse
        self.alignmentScore = alignmentScore
        self.identity = identity
    }

    private enum CodingKeys: String, CodingKey {
        case rawReferenceID = "raw_reference_id"
        case alleleName = "allele_name"
        case locus
        case cDNAReferenceCoverage = "cdna_reference_coverage"
        case clusterCoverage = "cluster_coverage"
        case leadingClusterFlankBases = "leading_cluster_flank_bases"
        case trailingClusterFlankBases = "trailing_cluster_flank_bases"
        case largestClusterStructuralSegmentBases = "largest_cluster_structural_segment_bases"
        case largestCDNADeficitSegmentBases = "largest_cdna_deficit_segment_bases"
        case snpSubstitutions = "snp_substitutions"
        case ordinaryIndelBases = "ordinary_indel_bases"
        case isReverse = "is_reverse"
        case alignmentScore = "alignment_score"
        case identity
    }
}

public struct ONTMHCCandidateRecord: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let sourceSequenceClusterIDs: [String]
    public let representativeSourceSequenceClusterID: String
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
    public let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    public let selectedEvidence: ONTMHCEvidenceLocator
    public let selectedAlignmentIsReverse: Bool?
    /// Every compatible cDNA allele relationship retained for an extension.
    public let extensionOf: [String]
    public let extensionInterpretations: [ONTMHCCDNAExtensionInterpretation]
    public let provisionalNamingAmbiguous: Bool

    public var reciprocalAlignmentCount: Int { reciprocalHitSummary.alignmentCount }
    public var reciprocalEdgeCount: Int { reciprocalHitSummary.targetEdgeCount }

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
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: [stableClusterID],
            representativeSourceSequenceClusterID: stableClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterIDs: [String],
        representativeSourceSequenceClusterID: String,
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
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: sourceSequenceClusterIDs,
            representativeSourceSequenceClusterID: representativeSourceSequenceClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: nil,
            extensionOf: []
        )
    }

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
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool? = nil,
        extensionOf: [String] = [],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = [],
        provisionalNamingAmbiguous: Bool = false
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: [stableClusterID],
            representativeSourceSequenceClusterID: stableClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: selectedAlignmentIsReverse,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterIDs: [String],
        representativeSourceSequenceClusterID: String,
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
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool? = nil,
        extensionOf: [String] = [],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = [],
        provisionalNamingAmbiguous: Bool = false
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: sourceSequenceClusterIDs,
            representativeSourceSequenceClusterID: representativeSourceSequenceClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: selectedAlignmentIsReverse,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous,
            initialize: ()
        )
    }

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
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: [stableClusterID],
            representativeSourceSequenceClusterID: stableClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: selectedEvidence
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterIDs: [String],
        representativeSourceSequenceClusterID: String,
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
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: sourceSequenceClusterIDs,
            representativeSourceSequenceClusterID: representativeSourceSequenceClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: nil
        )
    }

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
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool? = nil,
        extensionOf: [String] = [],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = [],
        provisionalNamingAmbiguous: Bool = false
    ) {
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: [stableClusterID],
            representativeSourceSequenceClusterID: stableClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: selectedAlignmentIsReverse,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous
        )
    }

    public init(
        stableClusterID: String,
        sourceSequenceClusterIDs: [String],
        representativeSourceSequenceClusterID: String,
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
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool? = nil,
        extensionOf: [String] = [],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation] = [],
        provisionalNamingAmbiguous: Bool = false
    ) {
        let resolvedRepresentativeSourceSequenceClusterID =
            representativeSourceSequenceClusterID
        let reciprocalHitSummary = ONTMHCReciprocalQueryHitSummary(
            uncheckedBAMPath: selectedEvidence.bamPath,
            queryName: resolvedRepresentativeSourceSequenceClusterID,
            alignmentCount: 1,
            targetAlignmentCounts: [selectedEvidence.referenceName: 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: [selectedEvidence.referenceName]
        )
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: sourceSequenceClusterIDs,
            representativeSourceSequenceClusterID: resolvedRepresentativeSourceSequenceClusterID,
            provisionalName: provisionalName,
            locus: locus,
            classification: classification,
            supportClass: supportClass,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: closestReferenceClass,
            snpCount: snpCount,
            insertedBases: insertedBases,
            deletedBases: deletedBases,
            longGapBases: longGapBases,
            comparableBases: comparableBases,
            shorterCoverage: shorterCoverage,
            identity: identity,
            mappingQuality: mappingQuality,
            alignmentScore: alignmentScore,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: selectedAlignmentIsReverse,
            extensionOf: extensionOf,
            extensionInterpretations: extensionInterpretations,
            provisionalNamingAmbiguous: provisionalNamingAmbiguous,
            initialize: ()
        )
    }

    private init(
        stableClusterID: String,
        sourceSequenceClusterIDs: [String]? = nil,
        representativeSourceSequenceClusterID: String? = nil,
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
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator,
        selectedAlignmentIsReverse: Bool?,
        extensionOf: [String],
        extensionInterpretations: [ONTMHCCDNAExtensionInterpretation],
        provisionalNamingAmbiguous: Bool,
        initialize: Void
    ) {
        self.stableClusterID = stableClusterID
        self.sourceSequenceClusterIDs = sourceSequenceClusterIDs ?? [stableClusterID]
        self.representativeSourceSequenceClusterID =
            representativeSourceSequenceClusterID ?? stableClusterID
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
        self.reciprocalHitSummary = reciprocalHitSummary
        self.selectedEvidence = selectedEvidence
        self.selectedAlignmentIsReverse = selectedAlignmentIsReverse
        self.extensionOf = extensionOf
        self.extensionInterpretations = extensionInterpretations
        self.provisionalNamingAmbiguous = provisionalNamingAmbiguous
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stableClusterID = try container.decode(String.self, forKey: .stableClusterID)
        let selectedEvidence = try container.decode(ONTMHCEvidenceLocator.self, forKey: .selectedEvidence)
        let reciprocalHitSummary = try container.decodeIfPresent(
            ONTMHCReciprocalQueryHitSummary.self,
            forKey: .reciprocalHitSummary
        ) ?? ONTMHCReciprocalQueryHitSummary(
            uncheckedBAMPath: selectedEvidence.bamPath,
            queryName: stableClusterID,
            alignmentCount: 1,
            targetAlignmentCounts: [selectedEvidence.referenceName: 1],
            exactMatchTargetNames: [],
            closestMatchTargetNames: [selectedEvidence.referenceName]
        )
        self.init(
            stableClusterID: stableClusterID,
            sourceSequenceClusterIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .sourceSequenceClusterIDs
            ) ?? [stableClusterID],
            representativeSourceSequenceClusterID: try container.decodeIfPresent(
                String.self,
                forKey: .representativeSourceSequenceClusterID
            ) ?? stableClusterID,
            provisionalName: try container.decode(String.self, forKey: .provisionalName),
            locus: try container.decode(String.self, forKey: .locus),
            classification: try container.decode(ONTMHCCandidateClassification.self, forKey: .classification),
            supportClass: try container.decode(ONTMHCCandidateSupportClass.self, forKey: .supportClass),
            closestReferenceName: try container.decode(String.self, forKey: .closestReferenceName),
            closestReferenceClass: try container.decode(MHCReferenceMoleculeClass.self, forKey: .closestReferenceClass),
            snpCount: try container.decode(Int.self, forKey: .snpCount),
            insertedBases: try container.decode(Int.self, forKey: .insertedBases),
            deletedBases: try container.decode(Int.self, forKey: .deletedBases),
            longGapBases: try container.decode(Int.self, forKey: .longGapBases),
            comparableBases: try container.decode(Int.self, forKey: .comparableBases),
            shorterCoverage: try container.decode(Double.self, forKey: .shorterCoverage),
            identity: try container.decode(Double.self, forKey: .identity),
            mappingQuality: try container.decode(Int.self, forKey: .mappingQuality),
            alignmentScore: try container.decode(Int.self, forKey: .alignmentScore),
            independentSampleCount: try container.decode(Int.self, forKey: .independentSampleCount),
            occurrenceCount: try container.decode(Int.self, forKey: .occurrenceCount),
            totalClusterReads: try container.decode(Int.self, forKey: .totalClusterReads),
            supportingSampleIDs: try container.decode([String].self, forKey: .supportingSampleIDs),
            fastaRecordID: try container.decode(String.self, forKey: .fastaRecordID),
            sequenceSHA256: try container.decode(String.self, forKey: .sequenceSHA256),
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: try container.decodeIfPresent(
                Bool.self,
                forKey: .selectedAlignmentIsReverse
            ),
            extensionOf: try container.decodeIfPresent([String].self, forKey: .extensionOf) ?? [],
            extensionInterpretations: try container.decodeIfPresent(
                [ONTMHCCDNAExtensionInterpretation].self,
                forKey: .extensionInterpretations
            ) ?? [],
            provisionalNamingAmbiguous: try container.decodeIfPresent(
                Bool.self,
                forKey: .provisionalNamingAmbiguous
            ) ?? false,
            initialize: ()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableClusterID, forKey: .stableClusterID)
        try container.encode(sourceSequenceClusterIDs, forKey: .sourceSequenceClusterIDs)
        try container.encode(
            representativeSourceSequenceClusterID,
            forKey: .representativeSourceSequenceClusterID
        )
        try container.encode(provisionalName, forKey: .provisionalName)
        try container.encode(locus, forKey: .locus)
        try container.encode(classification, forKey: .classification)
        try container.encode(supportClass, forKey: .supportClass)
        try container.encode(closestReferenceName, forKey: .closestReferenceName)
        try container.encode(closestReferenceClass, forKey: .closestReferenceClass)
        try container.encode(snpCount, forKey: .snpCount)
        try container.encode(insertedBases, forKey: .insertedBases)
        try container.encode(deletedBases, forKey: .deletedBases)
        try container.encode(longGapBases, forKey: .longGapBases)
        try container.encode(comparableBases, forKey: .comparableBases)
        try container.encode(shorterCoverage, forKey: .shorterCoverage)
        try container.encode(identity, forKey: .identity)
        try container.encode(mappingQuality, forKey: .mappingQuality)
        try container.encode(alignmentScore, forKey: .alignmentScore)
        try container.encode(independentSampleCount, forKey: .independentSampleCount)
        try container.encode(occurrenceCount, forKey: .occurrenceCount)
        try container.encode(totalClusterReads, forKey: .totalClusterReads)
        try container.encode(supportingSampleIDs, forKey: .supportingSampleIDs)
        try container.encode(fastaRecordID, forKey: .fastaRecordID)
        try container.encode(sequenceSHA256, forKey: .sequenceSHA256)
        try container.encode(reciprocalHitSummary, forKey: .reciprocalHitSummary)
        try container.encode(selectedEvidence, forKey: .selectedEvidence)
        try container.encodeIfPresent(selectedAlignmentIsReverse, forKey: .selectedAlignmentIsReverse)
        try container.encode(extensionOf, forKey: .extensionOf)
        try container.encode(extensionInterpretations, forKey: .extensionInterpretations)
        try container.encode(provisionalNamingAmbiguous, forKey: .provisionalNamingAmbiguous)
    }

    private enum CodingKeys: String, CodingKey {
        case stableClusterID = "stable_cluster_id"
        case sourceSequenceClusterIDs = "source_sequence_cluster_ids"
        case representativeSourceSequenceClusterID = "representative_source_sequence_cluster_id"
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
        case reciprocalHitSummary = "reciprocal_hit_summary"
        case selectedEvidence = "selected_evidence"
        case selectedAlignmentIsReverse = "selected_alignment_is_reverse"
        case extensionOf = "extension_of"
        case extensionInterpretations = "extension_interpretations"
        case provisionalNamingAmbiguous = "provisional_naming_ambiguous"
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
    public let fastaRecordID: String?
    public let sequenceSHA256: String?
    public let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    public let selectedEvidence: ONTMHCEvidenceLocator?
    public let selectedAlignmentIsReverse: Bool?
    /// Retained only when decoding or constructing schema-version 1 records.
    public let evidence: [ONTMHCEvidenceLocator]
    private let evidenceWireShape: ONTMHCEvidenceWireShape

    public var reciprocalAlignmentCount: Int { reciprocalHitSummary.alignmentCount }
    public var reciprocalEdgeCount: Int { reciprocalHitSummary.targetEdgeCount }

    public init(
        stableClusterID: String,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        supportClass: ONTMHCCandidateSupportClass,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        supportingSampleIDs: [String],
        fastaRecordID: String? = nil,
        sequenceSHA256: String? = nil,
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator?
    ) {
        self.init(
            stableClusterID: stableClusterID,
            reason: reason,
            failedMetrics: failedMetrics,
            supportClass: supportClass,
            independentSampleCount: independentSampleCount,
            occurrenceCount: occurrenceCount,
            totalClusterReads: totalClusterReads,
            supportingSampleIDs: supportingSampleIDs,
            fastaRecordID: fastaRecordID,
            sequenceSHA256: sequenceSHA256,
            reciprocalHitSummary: reciprocalHitSummary,
            selectedEvidence: selectedEvidence,
            selectedAlignmentIsReverse: nil
        )
    }

    public init(
        stableClusterID: String,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        supportClass: ONTMHCCandidateSupportClass,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        supportingSampleIDs: [String],
        fastaRecordID: String? = nil,
        sequenceSHA256: String? = nil,
        reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary,
        selectedEvidence: ONTMHCEvidenceLocator?,
        selectedAlignmentIsReverse: Bool? = nil
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
        self.reciprocalHitSummary = reciprocalHitSummary
        self.selectedEvidence = selectedEvidence
        self.selectedAlignmentIsReverse = selectedAlignmentIsReverse
        self.evidence = []
        self.evidenceWireShape = .compactSummaries
    }

    public init(
        stableClusterID: String,
        reason: ONTMHCUnnameableReason,
        failedMetrics: [String: Double],
        supportClass: ONTMHCCandidateSupportClass,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        supportingSampleIDs: [String],
        fastaRecordID: String? = nil,
        sequenceSHA256: String? = nil,
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
        self.reciprocalHitSummary = Self.legacyHitSummary(
            stableClusterID: stableClusterID,
            evidence: evidence
        )
        self.selectedEvidence = nil
        self.selectedAlignmentIsReverse = nil
        self.evidence = evidence
        self.evidenceWireShape = .legacyLocators
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stableClusterID = try container.decode(String.self, forKey: .stableClusterID)
        let reason = try container.decode(ONTMHCUnnameableReason.self, forKey: .reason)
        let failedMetrics = try container.decode([String: Double].self, forKey: .failedMetrics)
        let supportClass = try container.decode(ONTMHCCandidateSupportClass.self, forKey: .supportClass)
        let independentSampleCount = try container.decode(Int.self, forKey: .independentSampleCount)
        let occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
        let totalClusterReads = try container.decode(Int.self, forKey: .totalClusterReads)
        let supportingSampleIDs = try container.decode([String].self, forKey: .supportingSampleIDs)
        let fastaRecordID = try container.decodeIfPresent(String.self, forKey: .fastaRecordID)
        let sequenceSHA256 = try container.decodeIfPresent(String.self, forKey: .sequenceSHA256)
        if container.contains(.reciprocalHitSummary) {
            self.init(
                stableClusterID: stableClusterID,
                reason: reason,
                failedMetrics: failedMetrics,
                supportClass: supportClass,
                independentSampleCount: independentSampleCount,
                occurrenceCount: occurrenceCount,
                totalClusterReads: totalClusterReads,
                supportingSampleIDs: supportingSampleIDs,
                fastaRecordID: fastaRecordID,
                sequenceSHA256: sequenceSHA256,
                reciprocalHitSummary: try container.decode(
                    ONTMHCReciprocalQueryHitSummary.self,
                    forKey: .reciprocalHitSummary
                ),
                selectedEvidence: try container.decodeIfPresent(
                    ONTMHCEvidenceLocator.self,
                    forKey: .selectedEvidence
                ),
                selectedAlignmentIsReverse: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .selectedAlignmentIsReverse
                )
            )
        } else {
            self.init(
                stableClusterID: stableClusterID,
                reason: reason,
                failedMetrics: failedMetrics,
                supportClass: supportClass,
                independentSampleCount: independentSampleCount,
                occurrenceCount: occurrenceCount,
                totalClusterReads: totalClusterReads,
                supportingSampleIDs: supportingSampleIDs,
                fastaRecordID: fastaRecordID,
                sequenceSHA256: sequenceSHA256,
                evidence: try container.decodeIfPresent(
                    [ONTMHCEvidenceLocator].self,
                    forKey: .evidence
                ) ?? []
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableClusterID, forKey: .stableClusterID)
        try container.encode(reason, forKey: .reason)
        try container.encode(failedMetrics, forKey: .failedMetrics)
        try container.encode(supportClass, forKey: .supportClass)
        try container.encode(independentSampleCount, forKey: .independentSampleCount)
        try container.encode(occurrenceCount, forKey: .occurrenceCount)
        try container.encode(totalClusterReads, forKey: .totalClusterReads)
        try container.encode(supportingSampleIDs, forKey: .supportingSampleIDs)
        try container.encodeIfPresent(fastaRecordID, forKey: .fastaRecordID)
        try container.encodeIfPresent(sequenceSHA256, forKey: .sequenceSHA256)
        switch evidenceWireShape {
        case .legacyLocators:
            try container.encode(evidence, forKey: .evidence)
        case .compactSummaries:
            try container.encode(reciprocalHitSummary, forKey: .reciprocalHitSummary)
            try container.encodeIfPresent(selectedEvidence, forKey: .selectedEvidence)
            try container.encodeIfPresent(selectedAlignmentIsReverse, forKey: .selectedAlignmentIsReverse)
        }
    }

    private static func legacyHitSummary(
        stableClusterID: String,
        evidence: [ONTMHCEvidenceLocator]
    ) -> ONTMHCReciprocalQueryHitSummary {
        let unique = Dictionary(
            evidence.map { (ONTMHCEvidenceLocatorIdentity($0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        let targetCounts = Dictionary(grouping: unique, by: \.referenceName).mapValues(\.count)
        return ONTMHCReciprocalQueryHitSummary(
            uncheckedBAMPath: unique.first?.bamPath ?? "",
            queryName: stableClusterID,
            alignmentCount: unique.count,
            targetAlignmentCounts: targetCounts,
            exactMatchTargetNames: [],
            closestMatchTargetNames: []
        )
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
        case reciprocalHitSummary = "reciprocal_hit_summary"
        case selectedEvidence = "selected_evidence"
        case selectedAlignmentIsReverse = "selected_alignment_is_reverse"
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
