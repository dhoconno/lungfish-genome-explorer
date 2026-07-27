import Foundation

public struct GenotypeReviewableRowCatalog: Codable, Equatable, Sendable {
    public static let schemaID = "org.lungfish.genotype.reviewable-row-catalog"
    public static let schemaVersion = 1

    public enum RowKind: String, Codable, CaseIterable, Equatable, Sendable {
        case reference
        case provisionalExon2 = "provisional-exon-2"
        case candidate

        public var requiresStableID: Bool {
            self != .reference
        }
    }

    public struct Row: Codable, Equatable, Sendable {
        public let kind: RowKind
        public let callID: String
        public let displayName: String
        public let locus: String
        public let stableID: String?
        public let section: String
        public let sortKey: String
        public let supportBySample: [String: Int]

        public init(
            kind: RowKind,
            callID: String,
            displayName: String,
            locus: String,
            stableID: String?,
            section: String,
            sortKey: String,
            supportBySample: [String: Int]
        ) {
            self.kind = kind
            self.callID = callID
            self.displayName = displayName
            self.locus = locus
            self.stableID = stableID
            self.section = section
            self.sortKey = sortKey
            self.supportBySample = supportBySample
        }

        public var semanticIdentity: SemanticIdentity {
            SemanticIdentity(
                kind: kind,
                locus: locus,
                callID: callID,
                stableID: stableID
            )
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case callID = "call_id"
            case displayName = "display_name"
            case locus
            case stableID = "stable_id"
            case section
            case sortKey = "sort_key"
            case supportBySample = "support_by_sample"
        }
    }

    public struct SemanticIdentity: Hashable, Codable, Equatable, Sendable {
        public let kind: RowKind
        public let locus: String
        public let callID: String
        public let stableID: String?

        public init(kind: RowKind, locus: String, callID: String, stableID: String?) {
            self.kind = kind
            self.locus = locus
            self.callID = callID
            self.stableID = stableID
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case locus
            case callID = "call_id"
            case stableID = "stable_id"
        }
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case unsupportedSchema(id: String, version: Int)
        case invalidSample(String)
        case duplicateSample(String)
        case invalidRowField(row: Int, field: String)
        case nonCanonicalLocus(row: Int, value: String)
        case invalidStableID(row: Int, kind: RowKind)
        case evidenceRosterMismatch(row: Int, missing: [String], unexpected: [String])
        case negativeEvidence(row: Int, sample: String, value: Int)
        case duplicateSemanticIdentity(SemanticIdentity)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(id, version):
                return "Unsupported genotype reviewable-row catalog schema \(id) version \(version)."
            case let .invalidSample(sample):
                return "Invalid authoritative sample identity '\(sample)'."
            case let .duplicateSample(sample):
                return "Duplicate authoritative sample identity '\(sample)'."
            case let .invalidRowField(row, field):
                return "Reviewable row \(row) has an invalid \(field)."
            case let .nonCanonicalLocus(row, value):
                return "Reviewable row \(row) locus '\(value)' is not canonical."
            case let .invalidStableID(row, kind):
                return "Reviewable row \(row) has an invalid stable ID for kind \(kind.rawValue)."
            case let .evidenceRosterMismatch(row, missing, unexpected):
                return "Reviewable row \(row) evidence does not match the authoritative roster (missing: \(missing); unexpected: \(unexpected))."
            case let .negativeEvidence(row, sample, value):
                return "Reviewable row \(row) has negative evidence \(value) for sample \(sample)."
            case let .duplicateSemanticIdentity(identity):
                return "Duplicate reviewable-row semantic identity \(identity.kind.rawValue) \(identity.locus) \(identity.callID)."
            }
        }
    }

    public let schemaID: String
    public let schemaVersion: Int
    public let samples: [String]
    public let rows: [Row]

    public init(
        schemaID: String = Self.schemaID,
        schemaVersion: Int = Self.schemaVersion,
        samples: [String],
        rows: [Row]
    ) {
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        self.samples = samples
        self.rows = rows
    }

    @discardableResult
    public func validated() throws -> Self {
        guard schemaID == Self.schemaID, schemaVersion == Self.schemaVersion else {
            throw ValidationError.unsupportedSchema(id: schemaID, version: schemaVersion)
        }
        var roster = Set<String>()
        roster.reserveCapacity(samples.count)
        for sample in samples {
            guard Self.isCanonicalNonemptyIdentity(sample) else {
                throw ValidationError.invalidSample(sample)
            }
            guard roster.insert(sample).inserted else {
                throw ValidationError.duplicateSample(sample)
            }
        }

        var identities = Set<SemanticIdentity>()
        identities.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            for (field, value) in [
                ("call ID", row.callID),
                ("display name", row.displayName),
                ("locus", row.locus),
                ("section", row.section),
                ("sort key", row.sortKey),
            ] where !Self.isCanonicalNonemptyIdentity(value) {
                throw ValidationError.invalidRowField(row: index, field: field)
            }

            let canonicalLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(row.locus)
            guard canonicalLocus != "Unknown", canonicalLocus == row.locus else {
                throw ValidationError.nonCanonicalLocus(row: index, value: row.locus)
            }

            let stableIDIsValid = row.stableID.map(Self.isCanonicalNonemptyIdentity) ?? false
            if row.kind.requiresStableID ? !stableIDIsValid : row.stableID != nil {
                throw ValidationError.invalidStableID(row: index, kind: row.kind)
            }

            let evidenceSamples = Set(row.supportBySample.keys)
            guard evidenceSamples == roster else {
                throw ValidationError.evidenceRosterMismatch(
                    row: index,
                    missing: roster.subtracting(evidenceSamples).sorted(),
                    unexpected: evidenceSamples.subtracting(roster).sorted()
                )
            }
            for sample in samples {
                let value = row.supportBySample[sample]!
                guard value >= 0 else {
                    throw ValidationError.negativeEvidence(
                        row: index,
                        sample: sample,
                        value: value
                    )
                }
            }

            guard identities.insert(row.semanticIdentity).inserted else {
                throw ValidationError.duplicateSemanticIdentity(row.semanticIdentity)
            }
        }
        return self
    }

    private static func isCanonicalNonemptyIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case schemaVersion = "schema_version"
        case samples
        case rows
    }
}
