import Foundation

/// Immutable, precomputed search fields shared by genotype viewport lenses.
///
/// Search reports each kind of hit independently. Consumers choose presentation
/// from `Result.mode`, whose required-field priority is sample, projected row,
/// then haplotype carrier. Annotation/comment text remains an independent
/// compatibility fallback and cannot mask a required-field allele match.
struct GenotypeSearchIndex: Sendable {
    struct SampleRecord: Equatable, Sendable {
        let stableID: String
        let identityAliases: [String]
        let metadata: [String: String]

        init(
            stableID: String,
            identityAliases: [String] = [],
            metadata: [String: String] = [:]
        ) {
            self.stableID = stableID
            self.identityAliases = identityAliases
            self.metadata = metadata
        }
    }

    struct ProjectedRowRecord: Equatable, Sendable {
        let id: GenotypeCandidateMatrixRowID
        let displayedAllele: String
        let rawGenotype: String
        let locus: String
        let stableClusterID: String?
        let visibleReferenceMetadata: [String: String]
        let carrierSampleIDs: Set<String>

        init(
            id: GenotypeCandidateMatrixRowID,
            displayedAllele: String,
            rawGenotype: String,
            locus: String,
            stableClusterID: String? = nil,
            visibleReferenceMetadata: [String: String] = [:],
            carrierSampleIDs: Set<String>
        ) {
            self.id = id
            self.displayedAllele = displayedAllele
            self.rawGenotype = rawGenotype
            self.locus = locus
            self.stableClusterID = stableClusterID
            self.visibleReferenceMetadata = visibleReferenceMetadata
            self.carrierSampleIDs = carrierSampleIDs
        }
    }

    struct AnnotationOrCommentRecord: Hashable, Sendable {
        enum Target: Hashable, Equatable, Sendable {
            case sample(String)
            case row(GenotypeCandidateMatrixRowID)
            case cell(rowID: GenotypeCandidateMatrixRowID, sampleID: String)
        }

        let target: Target
        let text: String

        init(target: Target, text: String) {
            self.target = target
            self.text = text
        }
    }

    struct HaplotypeCarrierRecord: Equatable, Sendable {
        let name: String
        let locus: String?
        let aliases: [String]
        let carrierSampleIDs: Set<String>

        init(
            name: String,
            locus: String? = nil,
            aliases: [String] = [],
            carrierSampleIDs: Set<String>
        ) {
            self.name = name
            self.locus = locus
            self.aliases = aliases
            self.carrierSampleIDs = carrierSampleIDs
        }
    }

    enum Mode: Equatable, Sendable {
        case none
        case sample
        case projectedRow
        case haplotypeCarrier
    }

    struct Result: Equatable, Sendable {
        let mode: Mode
        let sampleIdentityAndMetadataIDs: Set<String>
        let projectedRowIDs: Set<GenotypeCandidateMatrixRowID>
        let alleleCarrierSampleIDs: Set<String>
        let annotationAndCommentSampleIDs: Set<String>
        let annotationAndCommentRowIDs: Set<GenotypeCandidateMatrixRowID>
        let annotationAndCommentCarrierSampleIDs: Set<String>
        let haplotypeCarrierSampleIDs: Set<String>

        static let empty = Self(
            mode: .none,
            sampleIdentityAndMetadataIDs: [],
            projectedRowIDs: [],
            alleleCarrierSampleIDs: [],
            annotationAndCommentSampleIDs: [],
            annotationAndCommentRowIDs: [],
            annotationAndCommentCarrierSampleIDs: [],
            haplotypeCarrierSampleIDs: []
        )

        /// Sample matches that participate in sample-priority routing.
        var allSamplePriorityIDs: Set<String> {
            sampleIdentityAndMetadataIDs.union(annotationAndCommentSampleIDs)
        }

        /// Row matches that participate in projected-row routing.
        var allProjectedRowPriorityIDs: Set<GenotypeCandidateMatrixRowID> {
            projectedRowIDs.union(annotationAndCommentRowIDs)
        }
    }

    let sampleRecordCount: Int
    let projectedRowRecordCount: Int
    let annotationAndCommentRecordCount: Int
    let haplotypeRecordCount: Int

    private let samples: [IndexedSample]
    private let projectedRows: [IndexedProjectedRow]
    private let annotationsAndComments: [IndexedAnnotationOrComment]
    private let haplotypeCarriers: [IndexedHaplotypeCarrier]

    init(
        samples: [SampleRecord],
        projectedRows: [ProjectedRowRecord],
        annotationsAndComments: [AnnotationOrCommentRecord],
        hasHaplotypingResult: Bool,
        haplotypeCarriers: () -> [HaplotypeCarrierRecord] = { [] }
    ) {
        self.samples = samples.map { sample in
            var fields = [sample.stableID]
            fields.append(contentsOf: sample.identityAliases)
            fields.append(contentsOf: Self.metadataFields(sample.metadata))
            return IndexedSample(
                stableID: sample.stableID,
                fields: fields.map(IndexedField.init)
            )
        }
        self.projectedRows = projectedRows.map { row in
            var fields = [
                row.displayedAllele,
                row.rawGenotype,
                row.locus,
            ]
            if let stableClusterID = row.stableClusterID {
                fields.append(stableClusterID)
            }
            fields.append(contentsOf: Self.metadataFields(row.visibleReferenceMetadata))
            return IndexedProjectedRow(
                id: row.id,
                fields: fields.map(IndexedField.init),
                carrierSampleIDs: row.carrierSampleIDs
            )
        }
        self.annotationsAndComments = annotationsAndComments.map {
            IndexedAnnotationOrComment(
                target: $0.target,
                field: IndexedField($0.text)
            )
        }
        if hasHaplotypingResult {
            self.haplotypeCarriers = haplotypeCarriers().map { record in
                var fields = [record.name]
                if let locus = record.locus {
                    fields.append(locus)
                    fields.append("\(record.name)@\(locus)")
                    fields.append("\(record.name):\(locus)")
                }
                fields.append(contentsOf: record.aliases)
                return IndexedHaplotypeCarrier(
                    fields: fields.map(IndexedField.init),
                    carrierSampleIDs: record.carrierSampleIDs
                )
            }
        } else {
            self.haplotypeCarriers = []
        }

        sampleRecordCount = self.samples.count
        projectedRowRecordCount = self.projectedRows.count
        annotationAndCommentRecordCount = self.annotationsAndComments.count
        haplotypeRecordCount = self.haplotypeCarriers.count
    }

    func search(_ text: String) -> Result {
        guard let query = Query(text) else { return .empty }

        var sampleIDs = Set<String>()
        for sample in samples where sample.fields.contains(where: { $0.matches(query) }) {
            sampleIDs.insert(sample.stableID)
        }

        var rowIDs = Set<GenotypeCandidateMatrixRowID>()
        var alleleCarrierSampleIDs = Set<String>()
        for row in projectedRows where row.fields.contains(where: { $0.matches(query) }) {
            rowIDs.insert(row.id)
            alleleCarrierSampleIDs.formUnion(row.carrierSampleIDs)
        }

        var annotationSampleIDs = Set<String>()
        var annotationRowIDs = Set<GenotypeCandidateMatrixRowID>()
        for annotation in annotationsAndComments where annotation.field.matches(query) {
            switch annotation.target {
            case let .sample(sampleID):
                annotationSampleIDs.insert(sampleID)
            case let .row(rowID):
                annotationRowIDs.insert(rowID)
            case let .cell(rowID, sampleID):
                annotationSampleIDs.insert(sampleID)
                annotationRowIDs.insert(rowID)
            }
        }
        let carriersByRowID = Dictionary(
            projectedRows.map { ($0.id, $0.carrierSampleIDs) },
            uniquingKeysWith: { existing, latest in existing.union(latest) }
        )
        let annotationCarrierSampleIDs = annotationRowIDs.reduce(into: Set<String>()) {
            carriers, rowID in
            carriers.formUnion(carriersByRowID[rowID] ?? [])
        }

        var haplotypeCarrierSampleIDs = Set<String>()
        for haplotype in haplotypeCarriers
        where haplotype.fields.contains(where: { $0.matches(query) }) {
            haplotypeCarrierSampleIDs.formUnion(haplotype.carrierSampleIDs)
        }

        let mode: Mode
        if !sampleIDs.isEmpty {
            mode = .sample
        } else if !rowIDs.isEmpty {
            mode = .projectedRow
        } else if !haplotypeCarrierSampleIDs.isEmpty {
            mode = .haplotypeCarrier
        } else if !annotationSampleIDs.isEmpty {
            mode = .sample
        } else if !annotationRowIDs.isEmpty {
            mode = .projectedRow
        } else {
            mode = .none
        }

        return Result(
            mode: mode,
            sampleIdentityAndMetadataIDs: sampleIDs,
            projectedRowIDs: rowIDs,
            alleleCarrierSampleIDs: alleleCarrierSampleIDs,
            annotationAndCommentSampleIDs: annotationSampleIDs,
            annotationAndCommentRowIDs: annotationRowIDs,
            annotationAndCommentCarrierSampleIDs: annotationCarrierSampleIDs,
            haplotypeCarrierSampleIDs: haplotypeCarrierSampleIDs
        )
    }

    private static func metadataFields(_ metadata: [String: String]) -> [String] {
        metadata.flatMap { key, value in
            [
                key,
                value,
                "\(key):\(value)",
                "\(key)=\(value)",
            ]
        }
    }
}

private extension GenotypeSearchIndex {
    struct Query: Sendable {
        let folded: String
        let normalized: String?

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let retained = GenotypeSearchIndex.retainedLetterAndDecimalDigitCount(trimmed)
            guard retained > 0 else { return nil }
            folded = GenotypeSearchIndex.folded(trimmed)
            normalized = retained >= 3
                ? GenotypeSearchIndex.normalized(trimmed)
                : nil
        }
    }

    struct IndexedField: Sendable {
        let folded: String
        let normalized: String

        init(_ value: String) {
            folded = GenotypeSearchIndex.folded(value)
            normalized = GenotypeSearchIndex.normalized(value)
        }

        func matches(_ query: Query) -> Bool {
            if folded.contains(query.folded) {
                return true
            }
            guard let queryNormalized = query.normalized,
                  !queryNormalized.isEmpty else {
                return false
            }
            return normalized.contains(queryNormalized)
        }
    }

    struct IndexedSample: Sendable {
        let stableID: String
        let fields: [IndexedField]
    }

    struct IndexedProjectedRow: Sendable {
        let id: GenotypeCandidateMatrixRowID
        let fields: [IndexedField]
        let carrierSampleIDs: Set<String>
    }

    struct IndexedAnnotationOrComment: Sendable {
        let target: AnnotationOrCommentRecord.Target
        let field: IndexedField
    }

    struct IndexedHaplotypeCarrier: Sendable {
        let fields: [IndexedField]
        let carrierSampleIDs: Set<String>
    }

    static func folded(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.uppercased()
    }

    static func normalized(_ value: String) -> String {
        let retained = value.precomposedStringWithCanonicalMapping.unicodeScalars
            .filter {
                CharacterSet.letters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
            }
            .map(String.init)
            .joined()
        return retained.uppercased()
    }

    static func retainedLetterAndDecimalDigitCount(_ value: String) -> Int {
        value.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        }
    }
}
