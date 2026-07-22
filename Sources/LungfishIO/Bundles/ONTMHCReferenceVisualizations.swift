import CryptoKit
import Foundation

public struct ONTMHCReferenceVisualizationArtifacts: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordCount: Int
    public let recordsJSON: ONTMHCArtifactReference
    public let genBank: ONTMHCArtifactReference
    public let fasta: ONTMHCArtifactReference

    public init(
        schemaVersion: Int,
        recordCount: Int,
        recordsJSON: ONTMHCArtifactReference,
        genBank: ONTMHCArtifactReference,
        fasta: ONTMHCArtifactReference
    ) {
        self.schemaVersion = schemaVersion
        self.recordCount = recordCount
        self.recordsJSON = recordsJSON
        self.genBank = genBank
        self.fasta = fasta
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordCount = "record_count"
        case recordsJSON = "records_json"
        case genBank = "genbank"
        case fasta
    }
}

public enum ONTMHCReferenceVisualizationRole: String, Codable, Equatable, Sendable {
    case exactKnownCall = "exact_known_call"
    case closestNovelReference = "closest_novel_reference"
    case closestExtensionReference = "closest_extension_reference"
    case closestUnnameableReference = "closest_unnameable_reference"
}

public struct ONTMHCReferenceVisualizationRoleAssignment: Codable, Equatable, Sendable {
    public let role: ONTMHCReferenceVisualizationRole
    public let candidateStableClusterIDs: [String]

    public init(
        role: ONTMHCReferenceVisualizationRole,
        candidateStableClusterIDs: [String]
    ) {
        self.role = role
        self.candidateStableClusterIDs = candidateStableClusterIDs
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case candidateStableClusterIDs = "candidate_stable_cluster_ids"
    }
}

public struct ONTMHCReferenceVisualizationFeature: Codable, Equatable, Sendable {
    public let type: String
    public let start: Int
    public let end: Int
    public let strand: String
    public let sourceOrdinal: Int
    public let rawGenBankLocation: String?
    public let qualifiers: [String: [String]]

    public var interval: Range<Int> { start..<end }

    public init(
        type: String,
        start: Int,
        end: Int,
        strand: String,
        sourceOrdinal: Int,
        rawGenBankLocation: String?,
        qualifiers: [String: [String]]
    ) {
        self.type = type
        self.start = start
        self.end = end
        self.strand = strand
        self.sourceOrdinal = sourceOrdinal
        self.rawGenBankLocation = rawGenBankLocation
        self.qualifiers = qualifiers
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case start
        case end
        case strand
        case sourceOrdinal = "source_ordinal"
        case rawGenBankLocation = "raw_genbank_location"
        case qualifiers
    }
}

public struct ONTMHCReferenceVisualizationRecord: Codable, Equatable, Sendable {
    public let rawReferenceID: String
    public let sourceOrdinal: Int
    public let alleleName: String
    public let locus: String?
    public let sequence: String
    public let sequenceSHA256: String
    public let recordFields: [String: [String]]
    public let features: [ONTMHCReferenceVisualizationFeature]
    public let annotatedTranslation: String?
    public let genBankText: String
    public let fastaText: String
    public let roles: [ONTMHCReferenceVisualizationRoleAssignment]

    public init(
        rawReferenceID: String,
        sourceOrdinal: Int,
        alleleName: String,
        locus: String?,
        sequence: String,
        sequenceSHA256: String,
        recordFields: [String: [String]],
        features: [ONTMHCReferenceVisualizationFeature],
        annotatedTranslation: String?,
        genBankText: String,
        fastaText: String,
        roles: [ONTMHCReferenceVisualizationRoleAssignment]
    ) {
        self.rawReferenceID = rawReferenceID
        self.sourceOrdinal = sourceOrdinal
        self.alleleName = alleleName
        self.locus = locus
        self.sequence = sequence
        self.sequenceSHA256 = sequenceSHA256
        self.recordFields = recordFields
        self.features = features
        self.annotatedTranslation = annotatedTranslation
        self.genBankText = genBankText
        self.fastaText = fastaText
        self.roles = roles
    }

    private enum CodingKeys: String, CodingKey {
        case rawReferenceID = "raw_reference_id"
        case sourceOrdinal = "source_ordinal"
        case alleleName = "allele_name"
        case locus
        case sequence
        case sequenceSHA256 = "sequence_sha256"
        case recordFields = "record_fields"
        case features
        case annotatedTranslation = "annotated_translation"
        case genBankText = "genbank_text"
        case fastaText = "fasta_text"
        case roles
    }
}

public enum ONTMHCReferenceVisualizationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case descriptorRecordCountMismatch(expected: Int, actual: Int)
    case emptyRawReferenceID(sourceOrdinal: Int)
    case duplicateRawReferenceID(String)
    case emptyRoles(rawReferenceID: String)
    case emptyCandidateStableClusterID(rawReferenceID: String)
    case ambiguousCandidateStableClusterID(String)
    case sequenceChecksumMismatch(rawReferenceID: String, expected: String, actual: String)
    case featureOutOfBounds(
        rawReferenceID: String,
        featureSourceOrdinal: Int,
        start: Int,
        end: Int,
        sequenceLength: Int
    )

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "MHC reference visualization schema \(version) is unsupported; expected schema 1."
        case .descriptorRecordCountMismatch(let expected, let actual):
            return "The MHC reference visualization descriptor declares \(expected) records, but the validated document contains \(actual)."
        case .emptyRawReferenceID(let sourceOrdinal):
            return "MHC reference visualization record \(sourceOrdinal) has an empty raw reference ID."
        case .duplicateRawReferenceID(let rawReferenceID):
            return "MHC reference visualization contains duplicate raw reference ID \(rawReferenceID)."
        case .emptyRoles(let rawReferenceID):
            return "MHC reference visualization record \(rawReferenceID) has no role assignments."
        case .emptyCandidateStableClusterID(let rawReferenceID):
            return "MHC reference visualization record \(rawReferenceID) has an empty candidate stable cluster ID."
        case .ambiguousCandidateStableClusterID(let stableClusterID):
            return "MHC reference visualization candidate stable cluster ID \(stableClusterID) is assigned to multiple raw references."
        case .sequenceChecksumMismatch(let rawReferenceID, let expected, let actual):
            return "MHC reference visualization record \(rawReferenceID) declares sequence SHA-256 \(expected), but its sequence hashes to \(actual)."
        case .featureOutOfBounds(
            let rawReferenceID,
            let featureSourceOrdinal,
            let start,
            let end,
            let sequenceLength
        ):
            return "MHC reference visualization record \(rawReferenceID) feature \(featureSourceOrdinal) interval \(start)..<\(end) is outside its \(sequenceLength)-base sequence."
        }
    }
}

public struct ONTMHCReferenceVisualizationArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let records: [ONTMHCReferenceVisualizationRecord]
    public let recordsByRawReferenceID: [String: ONTMHCReferenceVisualizationRecord]
    public let recordsByKnownCallGenotype: [String: ONTMHCReferenceVisualizationRecord]
    public let recordsByCandidateStableClusterID: [String: ONTMHCReferenceVisualizationRecord]

    public init(schemaVersion: Int, records: [ONTMHCReferenceVisualizationRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.recordsByRawReferenceID = Self.makeIndex(records)
        self.recordsByKnownCallGenotype = Self.makeKnownCallIndex(records)
        self.recordsByCandidateStableClusterID = Self.makeCandidateStableClusterIndex(records)
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw ONTMHCReferenceVisualizationError.unsupportedSchemaVersion(schemaVersion)
        }

        var rawReferenceIDs: Set<String> = []
        var rawReferenceIDByCandidateStableClusterID: [String: String] = [:]
        for record in records {
            guard !record.rawReferenceID.isEmpty else {
                throw ONTMHCReferenceVisualizationError.emptyRawReferenceID(
                    sourceOrdinal: record.sourceOrdinal
                )
            }
            guard rawReferenceIDs.insert(record.rawReferenceID).inserted else {
                throw ONTMHCReferenceVisualizationError.duplicateRawReferenceID(record.rawReferenceID)
            }
            guard !record.roles.isEmpty else {
                throw ONTMHCReferenceVisualizationError.emptyRoles(rawReferenceID: record.rawReferenceID)
            }
            for stableClusterID in record.roles.flatMap(\.candidateStableClusterIDs) {
                guard !stableClusterID.isEmpty else {
                    throw ONTMHCReferenceVisualizationError.emptyCandidateStableClusterID(
                        rawReferenceID: record.rawReferenceID
                    )
                }
                if let existingRawReferenceID = rawReferenceIDByCandidateStableClusterID[stableClusterID],
                   existingRawReferenceID != record.rawReferenceID {
                    throw ONTMHCReferenceVisualizationError.ambiguousCandidateStableClusterID(
                        stableClusterID
                    )
                }
                rawReferenceIDByCandidateStableClusterID[stableClusterID] = record.rawReferenceID
            }

            let checksum = SHA256.hash(data: Data(record.sequence.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            guard checksum == record.sequenceSHA256.lowercased() else {
                throw ONTMHCReferenceVisualizationError.sequenceChecksumMismatch(
                    rawReferenceID: record.rawReferenceID,
                    expected: record.sequenceSHA256,
                    actual: checksum
                )
            }

            let sequenceLength = record.sequence.count
            for feature in record.features {
                guard feature.start >= 0,
                      feature.start < feature.end,
                      feature.end <= sequenceLength else {
                    throw ONTMHCReferenceVisualizationError.featureOutOfBounds(
                        rawReferenceID: record.rawReferenceID,
                        featureSourceOrdinal: feature.sourceOrdinal,
                        start: feature.start,
                        end: feature.end,
                        sequenceLength: sequenceLength
                    )
                }
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            records: try container.decode([ONTMHCReferenceVisualizationRecord].self, forKey: .records)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
    }

    private static func makeIndex(
        _ records: [ONTMHCReferenceVisualizationRecord]
    ) -> [String: ONTMHCReferenceVisualizationRecord] {
        var index: [String: ONTMHCReferenceVisualizationRecord] = [:]
        index.reserveCapacity(records.count)
        for record in records {
            index[record.rawReferenceID] = record
        }
        return index
    }

    private static func makeKnownCallIndex(
        _ records: [ONTMHCReferenceVisualizationRecord]
    ) -> [String: ONTMHCReferenceVisualizationRecord] {
        var index = makeIndex(records)
        var aliases: [String: ONTMHCReferenceVisualizationRecord] = [:]
        var ambiguousAliases: Set<String> = []

        for record in records where record.roles.contains(where: { $0.role == .exactKnownCall }) {
            let alias = record.alleleName
            guard !alias.isEmpty, index[alias] == nil, !ambiguousAliases.contains(alias) else {
                continue
            }
            if aliases.removeValue(forKey: alias) != nil {
                ambiguousAliases.insert(alias)
            } else {
                aliases[alias] = record
            }
        }
        index.merge(aliases) { existing, _ in existing }
        return index
    }

    private static func makeCandidateStableClusterIndex(
        _ records: [ONTMHCReferenceVisualizationRecord]
    ) -> [String: ONTMHCReferenceVisualizationRecord] {
        var index: [String: ONTMHCReferenceVisualizationRecord] = [:]
        for record in records {
            for stableClusterID in record.roles.flatMap(\.candidateStableClusterIDs)
            where !stableClusterID.isEmpty {
                if index[stableClusterID]?.rawReferenceID == nil
                    || index[stableClusterID]?.rawReferenceID == record.rawReferenceID {
                    index[stableClusterID] = record
                }
            }
        }
        return index
    }
}
