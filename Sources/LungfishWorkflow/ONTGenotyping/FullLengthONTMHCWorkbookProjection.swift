import CryptoKit
import Foundation
import LungfishIO

enum FullLengthONTMHCWorkbookTintCategory: String, CaseIterable, Codable, Equatable, Sendable {
    case sharedNovel
    case singletonNovel
    case sharedExtension
    case singletonExtension
}

enum FullLengthONTMHCWorkbookCellValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int)
    case decimal(Double)
    case blank
}

struct FullLengthONTMHCWorkbookCell: Codable, Equatable, Sendable {
    let value: FullLengthONTMHCWorkbookCellValue
    let tint: FullLengthONTMHCWorkbookTintCategory?

    init(_ text: String, tint: FullLengthONTMHCWorkbookTintCategory? = nil) {
        value = .text(text)
        self.tint = tint
    }

    init(_ integer: Int) {
        value = .integer(integer)
        tint = nil
    }

    init(_ decimal: Double) {
        value = .decimal(decimal)
        tint = nil
    }

    static let blank = FullLengthONTMHCWorkbookCell(value: .blank, tint: nil)

    private init(value: FullLengthONTMHCWorkbookCellValue, tint: FullLengthONTMHCWorkbookTintCategory?) {
        self.value = value
        self.tint = tint
    }
}

enum FullLengthONTMHCWorkbookProjectionError: Error, LocalizedError, Equatable, Sendable {
    case duplicateStableClusterID(String)
    case recordAppearsInBothDocuments(String)
    case observationWithoutRecord(String)
    case duplicateObservation(stableClusterID: String, sampleID: String, readGroupID: String)
    case observationSummaryMismatch(stableClusterID: String, field: String, expected: Int, actual: Int)
    case invalidUnmatchedArtifactIdentity(stableClusterID: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .duplicateStableClusterID(let id):
            "Duplicate stable MHC cluster ID in workbook projection: \(id)."
        case .recordAppearsInBothDocuments(let id):
            "Stable MHC cluster ID appears in both candidate and un-nameable documents: \(id)."
        case .observationWithoutRecord(let id):
            "Workbook observation does not have a candidate or un-nameable record: \(id)."
        case .duplicateObservation(let id, let sample, let readGroup):
            "Duplicate MHC workbook observation for \(id), sample \(sample), read group \(readGroup)."
        case .observationSummaryMismatch(let id, let field, let expected, let actual):
            "MHC workbook projection summary mismatch for \(id) (\(field)): expected \(expected), found \(actual)."
        case .invalidUnmatchedArtifactIdentity(let id, let detail):
            "Invalid unmatched MHC artifact identity for \(id): \(detail)."
        }
    }
}

enum FullLengthONTMHCUnmatchedRecordCategory: String, Codable, Equatable, Sendable {
    case candidate
    case unnameable = "un-nameable"
}

enum FullLengthONTMHCTranslationStatus: String, Codable, Equatable, Sendable {
    case fullLength = "full-length"
    case pseudogene
    case incompleteUnresolved = "incomplete/unresolved"
}

struct FullLengthONTMHCNormalizedUnmatchedRow: Codable, Equatable, Sendable {
    let recordCategory: FullLengthONTMHCUnmatchedRecordCategory
    let stableClusterID: String
    let provisionalAlleleName: String?
    let locus: String?
    let classificationOrReason: String
    let closestReferenceAllele: String?
    let closestReferenceRawID: String?
    let extensionOf: [String]
    let snpCount: Int?
    let insertedBases: Int?
    let deletedBases: Int?
    let longGapBases: Int?
    let comparableBases: Int?
    let failedMetrics: [String: Double]
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let nucleotideSequence: String
    let utrTrimmedNucleotideSequence: String?
    let putativeAminoAcidTranslation: String?
    let translationStatus: FullLengthONTMHCTranslationStatus

    enum CodingKeys: String, CodingKey {
        case recordCategory = "record_category"
        case stableClusterID = "stable_cluster_id"
        case provisionalAlleleName = "provisional_allele_name"
        case locus
        case classificationOrReason = "classification_or_reason"
        case closestReferenceAllele = "closest_reference_allele"
        case closestReferenceRawID = "closest_reference_raw_id"
        case extensionOf = "extension_of"
        case snpCount = "snp_count"
        case insertedBases = "inserted_bases"
        case deletedBases = "deleted_bases"
        case longGapBases = "long_gap_bases"
        case comparableBases = "comparable_bases"
        case failedMetrics = "failed_metrics"
        case supportClass = "support_class"
        case independentSampleCount = "independent_sample_count"
        case occurrenceCount = "occurrence_count"
        case totalClusterReads = "total_cluster_reads"
        case supportingSampleIDs = "supporting_sample_ids"
        case readsBySample = "reads_by_sample"
        case fastaRecordID = "fasta_record_id"
        case sequenceSHA256 = "sequence_sha256"
        case nucleotideSequence = "nucleotide_sequence"
        case utrTrimmedNucleotideSequence = "utr_trimmed_nucleotide_sequence"
        case putativeAminoAcidTranslation = "putative_amino_acid_translation"
        case translationStatus = "translation_status"
    }
}

enum FullLengthONTMHCUnmatchedWorksheetBuilder {
    static func buildCells(
        rows: [FullLengthONTMHCNormalizedUnmatchedRow],
        sampleOrder requestedSampleOrder: [String]
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        let sampleOrder = completeSampleOrder(requestedSampleOrder, rows: rows)
        let header = [
            "Record Category", "Stable Cluster ID", "Provisional Allele Name", "Locus",
            "Classification or Reason", "Closest Reference Allele", "Closest Reference Raw ID", "Extension Of",
            "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases", "Comparable Bases",
            "Failed Metrics", "Support Class", "Independent Sample Count", "Occurrence Count",
            "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256",
            "Full-Length FASTA Sequence", "UTR-Trimmed FASTA Sequence",
            "Putative Amino Acid Translation", "Translation Status",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in rows.sorted(by: rowLess) {
            let tint = tintCategory(for: row)
            var cells: [FullLengthONTMHCWorkbookCell] = [
                .init(row.recordCategory.rawValue),
                .init(row.stableClusterID),
                row.provisionalAlleleName.map { .init($0, tint: tint) } ?? .blank,
                row.locus.map { .init($0) } ?? .blank,
                .init(row.classificationOrReason),
                row.closestReferenceAllele.map { .init($0) } ?? .blank,
                row.closestReferenceRawID.map { .init($0) } ?? .blank,
                .init(row.extensionOf.joined(separator: ";")),
                row.snpCount.map { .init($0) } ?? .blank,
                row.insertedBases.map { .init($0) } ?? .blank,
                row.deletedBases.map { .init($0) } ?? .blank,
                row.longGapBases.map { .init($0) } ?? .blank,
                row.comparableBases.map { .init($0) } ?? .blank,
                .init(metricText(row.failedMetrics)),
                .init(row.supportClass),
                .init(row.independentSampleCount),
                .init(row.occurrenceCount),
                .init(row.totalClusterReads),
                .init(row.supportingSampleIDs.joined(separator: ";")),
                .init(row.fastaRecordID),
                .init(row.sequenceSHA256),
                .init(row.nucleotideSequence),
                row.utrTrimmedNucleotideSequence.map { .init($0) } ?? .blank,
                row.putativeAminoAcidTranslation.map { .init($0) } ?? .blank,
                .init(row.translationStatus.rawValue),
            ]
            cells.append(contentsOf: sampleOrder.map { sample in
                row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
            })
            result.append(cells)
        }
        return result
    }

    private static func completeSampleOrder(
        _ requested: [String],
        rows: [FullLengthONTMHCNormalizedUnmatchedRow]
    ) -> [String] {
        var seen = Set<String>()
        var result = requested.filter { seen.insert($0).inserted }
        result.append(contentsOf: Set(rows.flatMap { $0.readsBySample.keys })
            .subtracting(seen)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        return result
    }

    private static func rowLess(
        _ lhs: FullLengthONTMHCNormalizedUnmatchedRow,
        _ rhs: FullLengthONTMHCNormalizedUnmatchedRow
    ) -> Bool {
        MHCAlleleDisplayOrder.compare(
            lhs.provisionalAlleleName ?? "",
            rhs.provisionalAlleleName ?? "",
            lhsStableID: lhs.stableClusterID,
            rhsStableID: rhs.stableClusterID
        ) == .orderedAscending
    }

    private static func tintCategory(
        for row: FullLengthONTMHCNormalizedUnmatchedRow
    ) -> FullLengthONTMHCWorkbookTintCategory? {
        guard row.recordCategory == .candidate else { return nil }
        switch (row.classificationOrReason, row.supportClass) {
        case (ONTMHCCandidateClassification.novel.rawValue, ONTMHCCandidateSupportClass.shared.rawValue):
            return .sharedNovel
        case (ONTMHCCandidateClassification.novel.rawValue, _):
            return .singletonNovel
        case (ONTMHCCandidateClassification.extension.rawValue, ONTMHCCandidateSupportClass.shared.rawValue):
            return .sharedExtension
        case (ONTMHCCandidateClassification.extension.rawValue, _):
            return .singletonExtension
        default:
            return nil
        }
    }

    private static func metricText(_ metrics: [String: Double]) -> String {
        metrics.keys.sorted().map { key in
            let value = metrics[key] ?? 0
            let text = value.rounded() == value ? String(Int64(value)) : String(value)
            return "\(key)=\(text)"
        }.joined(separator: ";")
    }
}

struct FullLengthONTMHCCandidateWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let provisionalName: String
    let locus: String
    let classification: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    let bamPath: String
    let queryName: String
    let referenceName: String
    let readGroupID: String?
    let referenceStart: Int
    let cigar: String
    let closestReferenceName: String
    let extensionOf: [String]
    let closestReferenceClass: String
    let snpCount: Int
    let insertedBases: Int
    let deletedBases: Int
    let longGapBases: Int
    let comparableBases: Int
    let shorterCoverage: Double
    let identity: Double
    let mappingQuality: Int
    let alignmentScore: Int
    let tintCategory: FullLengthONTMHCWorkbookTintCategory
}

struct FullLengthONTMHCUnnameableWorkbookRow: Equatable, Sendable {
    let stableClusterID: String
    let reason: String
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let failedMetrics: [String: Double]
    let reciprocalHitSummary: ONTMHCReciprocalQueryHitSummary
    let selectedEvidence: ONTMHCEvidenceLocator?
    let evidence: [ONTMHCEvidenceLocator]
}

struct FullLengthONTMHCWorkbookProjection: Equatable, Sendable {
    let sampleOrder: [String]
    let candidateRows: [FullLengthONTMHCCandidateWorkbookRow]
    let unnameableRows: [FullLengthONTMHCUnnameableWorkbookRow]
    private let candidateSchemaVersion: Int
    private let unnameableSchemaVersion: Int

    init(
        candidateDocument: ONTMHCCandidateAllelesDocument,
        unnameableDocument: ONTMHCUnnameableClustersDocument,
        sampleOrder requestedSampleOrder: [String]
    ) throws {
        candidateSchemaVersion = candidateDocument.schemaVersion
        unnameableSchemaVersion = unnameableDocument.schemaVersion
        let candidateIDs = try Self.uniqueIDs(candidateDocument.candidates.map(\.stableClusterID))
        let unnameableIDs = try Self.uniqueIDs(unnameableDocument.clusters.map(\.stableClusterID))
        if let overlap = candidateIDs.intersection(unnameableIDs).sorted(by: Self.less).first {
            throw FullLengthONTMHCWorkbookProjectionError.recordAppearsInBothDocuments(overlap)
        }
        let allIDs = candidateIDs.union(unnameableIDs)
        let observations = candidateDocument.observations + unnameableDocument.observations
        if let orphan = observations.map(\.stableClusterID).first(where: { !allIDs.contains($0) }) {
            throw FullLengthONTMHCWorkbookProjectionError.observationWithoutRecord(orphan)
        }
        let observationsByID = try Self.observationsByStableID(observations)

        var seenSamples = Set<String>()
        var resolvedSampleOrder = requestedSampleOrder.filter { seenSamples.insert($0).inserted }
        let missingSamples = Set(observations.map(\.sampleID)).subtracting(seenSamples).sorted(by: Self.less)
        resolvedSampleOrder.append(contentsOf: missingSamples)
        sampleOrder = resolvedSampleOrder

        candidateRows = try candidateDocument.candidates.sorted { Self.less($0.stableClusterID, $1.stableClusterID) }.map { record in
            let grouped = observationsByID[record.stableClusterID] ?? []
            let reads = Self.readsBySample(grouped)
            try Self.validateSummary(
                stableClusterID: record.stableClusterID,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                observations: grouped,
                readsBySample: reads
            )
            return FullLengthONTMHCCandidateWorkbookRow(
                stableClusterID: record.stableClusterID,
                provisionalName: record.provisionalName,
                locus: record.locus,
                classification: record.classification.rawValue,
                supportClass: record.supportClass.rawValue,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                supportingSampleIDs: record.supportingSampleIDs,
                readsBySample: reads,
                fastaRecordID: record.fastaRecordID,
                sequenceSHA256: record.sequenceSHA256,
                reciprocalHitSummary: record.reciprocalHitSummary,
                bamPath: record.selectedEvidence.bamPath,
                queryName: record.selectedEvidence.queryName,
                referenceName: record.selectedEvidence.referenceName,
                readGroupID: record.selectedEvidence.readGroupID,
                referenceStart: record.selectedEvidence.referenceStart,
                cigar: record.selectedEvidence.cigar,
                closestReferenceName: record.closestReferenceName,
                extensionOf: record.extensionOf,
                closestReferenceClass: record.closestReferenceClass.rawValue,
                snpCount: record.snpCount,
                insertedBases: record.insertedBases,
                deletedBases: record.deletedBases,
                longGapBases: record.longGapBases,
                comparableBases: record.comparableBases,
                shorterCoverage: record.shorterCoverage,
                identity: record.identity,
                mappingQuality: record.mappingQuality,
                alignmentScore: record.alignmentScore,
                tintCategory: Self.tint(classification: record.classification, support: record.supportClass)
            )
        }
        unnameableRows = try unnameableDocument.clusters.sorted { Self.less($0.stableClusterID, $1.stableClusterID) }.map { record in
            let grouped = observationsByID[record.stableClusterID] ?? []
            let reads = Self.readsBySample(grouped)
            try Self.validateSummary(
                stableClusterID: record.stableClusterID,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                observations: grouped,
                readsBySample: reads
            )
            return FullLengthONTMHCUnnameableWorkbookRow(
                stableClusterID: record.stableClusterID,
                reason: record.reason.rawValue,
                supportClass: record.supportClass.rawValue,
                independentSampleCount: record.independentSampleCount,
                occurrenceCount: record.occurrenceCount,
                totalClusterReads: record.totalClusterReads,
                supportingSampleIDs: record.supportingSampleIDs,
                readsBySample: reads,
                fastaRecordID: record.fastaRecordID ?? "",
                sequenceSHA256: record.sequenceSHA256 ?? "",
                failedMetrics: record.failedMetrics,
                reciprocalHitSummary: record.reciprocalHitSummary,
                selectedEvidence: record.selectedEvidence,
                evidence: record.evidence.sorted(by: Self.evidenceLess)
            )
        }
    }

    func normalizedUnmatchedRows(
        candidateFASTARecords: [FullLengthONTMHCClusterFASTARecord],
        unnameableFASTARecords: [FullLengthONTMHCClusterFASTARecord],
        candidateGenBankRecords: [GenBankRecord],
        unnameableGenBankRecords: [GenBankRecord],
        knownAlleleDisplayNames: [String: String] = [:]
    ) throws -> [FullLengthONTMHCNormalizedUnmatchedRow] {
        let candidateArtifacts = try Self.unmatchedArtifacts(
            expectedStableIDs: Set(candidateRows.map(\.stableClusterID)),
            documentSequenceSHA256ByStableID: Dictionary(
                uniqueKeysWithValues: candidateRows.map { ($0.stableClusterID, $0.sequenceSHA256) }
            ),
            fastaRecords: candidateFASTARecords,
            genBankRecords: candidateGenBankRecords,
            category: .candidate
        )
        let exportableUnnameableRows = try unnameableRows.filter { row in
            guard row.fastaRecordID.isEmpty == row.sequenceSHA256.isEmpty else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: row.stableClusterID,
                    detail: "document external FASTA identity and checksum are not paired"
                )
            }
            return !row.fastaRecordID.isEmpty
        }
        let unnameableArtifacts = try Self.unmatchedArtifacts(
            expectedStableIDs: Set(exportableUnnameableRows.map(\.stableClusterID)),
            documentSequenceSHA256ByStableID: Dictionary(
                uniqueKeysWithValues: exportableUnnameableRows.map {
                    ($0.stableClusterID, $0.sequenceSHA256)
                }
            ),
            fastaRecords: unnameableFASTARecords,
            genBankRecords: unnameableGenBankRecords,
            category: .unnameable
        )

        let candidates = try candidateRows.map { row -> FullLengthONTMHCNormalizedUnmatchedRow in
            guard row.fastaRecordID == row.stableClusterID else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: row.stableClusterID,
                    detail: "document FASTA record ID is \(row.fastaRecordID)"
                )
            }
            let artifact = candidateArtifacts[row.stableClusterID]!
            return FullLengthONTMHCNormalizedUnmatchedRow(
                recordCategory: .candidate,
                stableClusterID: row.stableClusterID,
                provisionalAlleleName: row.provisionalName,
                locus: row.locus,
                classificationOrReason: row.classification,
                closestReferenceAllele: row.closestReferenceName,
                closestReferenceRawID: row.referenceName,
                extensionOf: row.extensionOf,
                snpCount: row.snpCount,
                insertedBases: row.insertedBases,
                deletedBases: row.deletedBases,
                longGapBases: row.longGapBases,
                comparableBases: row.comparableBases,
                failedMetrics: [:],
                supportClass: row.supportClass,
                independentSampleCount: row.independentSampleCount,
                occurrenceCount: row.occurrenceCount,
                totalClusterReads: row.totalClusterReads,
                supportingSampleIDs: row.supportingSampleIDs,
                readsBySample: row.readsBySample,
                fastaRecordID: row.fastaRecordID,
                sequenceSHA256: row.sequenceSHA256,
                nucleotideSequence: artifact.sequence,
                utrTrimmedNucleotideSequence: artifact.utrTrimmedSequence,
                putativeAminoAcidTranslation: artifact.translation,
                translationStatus: artifact.status
            )
        }
        let unnameable = try unnameableRows.map { row -> FullLengthONTMHCNormalizedUnmatchedRow in
            let artifact: UnmatchedArtifact
            if row.fastaRecordID.isEmpty {
                guard unnameableSchemaVersion >= 4 else {
                    throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                        stableClusterID: row.stableClusterID,
                        detail: "document external FASTA identity is missing"
                    )
                }
                artifact = UnmatchedArtifact(
                    sequence: "",
                    utrTrimmedSequence: nil,
                    translation: nil,
                    status: .incompleteUnresolved
                )
            } else {
                guard row.fastaRecordID == row.stableClusterID else {
                    throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                        stableClusterID: row.stableClusterID,
                        detail: "document FASTA record ID is \(row.fastaRecordID)"
                    )
                }
                artifact = unnameableArtifacts[row.stableClusterID]!
            }
            let deterministicSummaryReference = row.reciprocalHitSummary.closestMatchTargetNames.count == 1
                ? row.reciprocalHitSummary.closestMatchTargetNames.first
                : nil
            let closestReferenceRawID = row.selectedEvidence?.referenceName ?? deterministicSummaryReference
            return FullLengthONTMHCNormalizedUnmatchedRow(
                recordCategory: .unnameable,
                stableClusterID: row.stableClusterID,
                provisionalAlleleName: nil,
                locus: nil,
                classificationOrReason: row.reason,
                closestReferenceAllele: closestReferenceRawID.flatMap { knownAlleleDisplayNames[$0] },
                closestReferenceRawID: closestReferenceRawID,
                extensionOf: [],
                snpCount: nil,
                insertedBases: nil,
                deletedBases: nil,
                longGapBases: nil,
                comparableBases: nil,
                failedMetrics: row.failedMetrics,
                supportClass: row.supportClass,
                independentSampleCount: row.independentSampleCount,
                occurrenceCount: row.occurrenceCount,
                totalClusterReads: row.totalClusterReads,
                supportingSampleIDs: row.supportingSampleIDs,
                readsBySample: row.readsBySample,
                fastaRecordID: row.fastaRecordID,
                sequenceSHA256: row.sequenceSHA256,
                nucleotideSequence: artifact.sequence,
                utrTrimmedNucleotideSequence: nil,
                putativeAminoAcidTranslation: artifact.translation,
                translationStatus: artifact.status
            )
        }
        return candidates + unnameable
    }

    var candidateWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        if candidateSchemaVersion >= 2 {
            return compactCandidateWorksheetRows
        }
        let header = [
            "Stable Cluster ID", "Provisional Name", "Locus", "Classification", "Support Class",
            "Independent Sample Count", "Occurrence Count", "Total Cluster Reads", "Supporting Sample IDs",
            "FASTA Record ID", "Sequence SHA-256", "BAM Path", "Query Name", "Reference Name",
            "Read Group ID", "Reference Start", "CIGAR", "Closest Reference Name", "Closest Reference Class",
            "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases", "Comparable Bases",
            "Shorter Coverage", "Identity", "Mapping Quality", "Alignment Score",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in candidateRows {
            var cells: [FullLengthONTMHCWorkbookCell] = [
                .init(row.stableClusterID), .init(row.provisionalName, tint: row.tintCategory), .init(row.locus),
                .init(row.classification), .init(row.supportClass), .init(row.independentSampleCount),
                .init(row.occurrenceCount), .init(row.totalClusterReads), .init(row.supportingSampleIDs.joined(separator: ";")),
                .init(row.fastaRecordID), .init(row.sequenceSHA256), .init(row.bamPath), .init(row.queryName),
                .init(row.referenceName), row.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                .init(row.referenceStart), .init(row.cigar), .init(row.closestReferenceName),
                .init(row.closestReferenceClass), .init(row.snpCount), .init(row.insertedBases),
                .init(row.deletedBases), .init(row.longGapBases), .init(row.comparableBases),
                .init(row.shorterCoverage), .init(row.identity), .init(row.mappingQuality), .init(row.alignmentScore),
            ]
            cells.append(contentsOf: sampleOrder.map { sample in
                row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
            })
            result.append(cells)
        }
        return result
    }

    var unnameableWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        if unnameableSchemaVersion >= 2 {
            return compactUnnameableWorksheetRows
        }
        let header = [
            "Stable Cluster ID", "Reason", "Support Class", "Independent Sample Count", "Occurrence Count",
            "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256", "Failed Metrics",
            "Evidence Ordinal", "Evidence Count", "Evidence BAM Path", "Evidence Query Name", "Evidence Reference Name",
            "Evidence Read Group ID", "Evidence Reference Start", "Evidence CIGAR",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in unnameableRows {
            let evidenceRows: [(ordinal: Int?, locator: ONTMHCEvidenceLocator?)] = row.evidence.isEmpty
                ? [(nil, nil)]
                : row.evidence.enumerated().map { ($0.offset + 1, $0.element) }
            for evidenceRow in evidenceRows {
                let locator = evidenceRow.locator
                var cells: [FullLengthONTMHCWorkbookCell] = [
                    .init(row.stableClusterID), .init(row.reason), .init(row.supportClass),
                    .init(row.independentSampleCount), .init(row.occurrenceCount), .init(row.totalClusterReads),
                    .init(row.supportingSampleIDs.joined(separator: ";")), .init(row.fastaRecordID),
                    .init(row.sequenceSHA256), .init(Self.metricText(row.failedMetrics)),
                    evidenceRow.ordinal.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                    .init(row.evidence.count),
                    locator.map { .init($0.bamPath) } ?? .blank,
                    locator.map { .init($0.queryName) } ?? .blank,
                    locator.map { .init($0.referenceName) } ?? .blank,
                    locator?.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                    locator.map { .init($0.referenceStart) } ?? .blank,
                    locator.map { .init($0.cigar) } ?? .blank,
                ]
                cells.append(contentsOf: sampleOrder.map { sample in
                    row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
                })
                result.append(cells)
            }
        }
        return result
    }

    private var compactCandidateWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        let header = [
            "Stable Cluster ID", "Provisional Name", "Locus", "Classification", "Support Class",
            "Independent Sample Count", "Occurrence Count", "Total Cluster Reads", "Supporting Sample IDs",
            "FASTA Record ID", "Sequence SHA-256", "Reciprocal BAM Path", "Reciprocal Query Name",
            "Reciprocal Alignment Count", "Reciprocal Target Count", "Reciprocal Target Alignment Counts",
            "Exact Match Target Names", "Closest Match Target Names", "Selected Evidence BAM Path",
            "Selected Evidence Query Name", "Selected Evidence Reference Name", "Selected Evidence Read Group ID",
            "Selected Evidence Reference Start", "Selected Evidence CIGAR", "Closest Reference Name",
            "Closest Reference Class", "SNP Count", "Inserted Bases", "Deleted Bases", "Long Gap Bases",
            "Comparable Bases", "Shorter Coverage", "Identity", "Mapping Quality", "Alignment Score",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in candidateRows {
            let summary = row.reciprocalHitSummary
            var cells: [FullLengthONTMHCWorkbookCell] = [
                .init(row.stableClusterID), .init(row.provisionalName, tint: row.tintCategory), .init(row.locus),
                .init(row.classification), .init(row.supportClass), .init(row.independentSampleCount),
                .init(row.occurrenceCount), .init(row.totalClusterReads), .init(row.supportingSampleIDs.joined(separator: ";")),
                .init(row.fastaRecordID), .init(row.sequenceSHA256), .init(summary.bamPath), .init(summary.queryName),
                .init(summary.alignmentCount), .init(summary.targetEdgeCount),
                .init(Self.countText(summary.targetAlignmentCounts)),
                .init(summary.exactMatchTargetNames.sorted(by: Self.less).joined(separator: ";")),
                .init(summary.closestMatchTargetNames.sorted(by: Self.less).joined(separator: ";")),
                .init(row.bamPath), .init(row.queryName), .init(row.referenceName),
                row.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                .init(row.referenceStart), .init(row.cigar), .init(row.closestReferenceName),
                .init(row.closestReferenceClass), .init(row.snpCount), .init(row.insertedBases),
                .init(row.deletedBases), .init(row.longGapBases), .init(row.comparableBases),
                .init(row.shorterCoverage), .init(row.identity), .init(row.mappingQuality), .init(row.alignmentScore),
            ]
            cells.append(contentsOf: sampleOrder.map { sample in
                row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
            })
            result.append(cells)
        }
        return result
    }

    private var compactUnnameableWorksheetRows: [[FullLengthONTMHCWorkbookCell]] {
        let header = [
            "Stable Cluster ID", "Reason", "Support Class", "Independent Sample Count", "Occurrence Count",
            "Total Cluster Reads", "Supporting Sample IDs", "FASTA Record ID", "Sequence SHA-256", "Failed Metrics",
            "Reciprocal BAM Path", "Reciprocal Query Name", "Reciprocal Alignment Count", "Reciprocal Target Count",
            "Reciprocal Target Alignment Counts", "Exact Match Target Names", "Closest Match Target Names",
            "Selected Evidence BAM Path", "Selected Evidence Query Name", "Selected Evidence Reference Name",
            "Selected Evidence Read Group ID", "Selected Evidence Reference Start", "Selected Evidence CIGAR",
        ] + sampleOrder.map { "Sample Reads: \($0)" }
        var result = [header.map { FullLengthONTMHCWorkbookCell($0) }]
        for row in unnameableRows {
            let summary = row.reciprocalHitSummary
            let selected = row.selectedEvidence
            var cells: [FullLengthONTMHCWorkbookCell] = [
                .init(row.stableClusterID), .init(row.reason), .init(row.supportClass),
                .init(row.independentSampleCount), .init(row.occurrenceCount), .init(row.totalClusterReads),
                .init(row.supportingSampleIDs.joined(separator: ";")), .init(row.fastaRecordID),
                .init(row.sequenceSHA256), .init(Self.metricText(row.failedMetrics)), .init(summary.bamPath),
                .init(summary.queryName), .init(summary.alignmentCount), .init(summary.targetEdgeCount),
                .init(Self.countText(summary.targetAlignmentCounts)),
                .init(summary.exactMatchTargetNames.sorted(by: Self.less).joined(separator: ";")),
                .init(summary.closestMatchTargetNames.sorted(by: Self.less).joined(separator: ";")),
                selected.map { .init($0.bamPath) } ?? .blank,
                selected.map { .init($0.queryName) } ?? .blank,
                selected.map { .init($0.referenceName) } ?? .blank,
                selected?.readGroupID.map { FullLengthONTMHCWorkbookCell($0) } ?? .blank,
                selected.map { .init($0.referenceStart) } ?? .blank,
                selected.map { .init($0.cigar) } ?? .blank,
            ]
            cells.append(contentsOf: sampleOrder.map { sample in
                row.readsBySample[sample].map { FullLengthONTMHCWorkbookCell($0) } ?? .blank
            })
            result.append(cells)
        }
        return result
    }

    func enrichingLegacyUnmatchedRows(_ rows: [[String]]) -> [[String]] {
        guard !rows.isEmpty else { return rows }
        let metadataHeader = [
            "provisional_name", "candidate_locus", "candidate_classification", "candidate_support_class",
            "candidate_snp_count", "candidate_inserted_bases", "candidate_deleted_bases",
            "candidate_long_gap_bases", "candidate_closest_reference", "un_nameable_reason",
        ]
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidateRows.map { ($0.stableClusterID, $0) })
        let unnameableByID = Dictionary(uniqueKeysWithValues: unnameableRows.map { ($0.stableClusterID, $0) })
        let legacyHeader = rows[0]
        var result = [Self.inserting(metadataHeader, afterFirstCellOf: legacyHeader)]
        result.append(contentsOf: rows.dropFirst().map { row in
            let id = row.first ?? ""
            let metadata: [String]
            let authoritativeRow: [String]
            if let candidate = candidatesByID[id] {
                metadata = [
                    candidate.provisionalName, candidate.locus, candidate.classification, candidate.supportClass,
                    String(candidate.snpCount), String(candidate.insertedBases), String(candidate.deletedBases),
                    String(candidate.longGapBases), candidate.closestReferenceName, "",
                ]
                authoritativeRow = Self.authoritativeLegacyRow(
                    row,
                    header: legacyHeader,
                    candidate: candidate
                )
            } else if let unnameable = unnameableByID[id] {
                metadata = ["", "", "un-nameable", unnameable.supportClass, "", "", "", "", "", unnameable.reason]
                authoritativeRow = Self.authoritativeLegacyRow(
                    row,
                    header: legacyHeader,
                    unnameable: unnameable
                )
            } else {
                metadata = Array(repeating: "", count: metadataHeader.count)
                authoritativeRow = Self.normalizingLegacyLabels(row, header: legacyHeader)
            }
            return Self.inserting(metadata, afterFirstCellOf: authoritativeRow)
        })
        return result
    }

    private static func uniqueIDs(_ ids: [String]) throws -> Set<String> {
        var result = Set<String>()
        for id in ids where !result.insert(id).inserted {
            throw FullLengthONTMHCWorkbookProjectionError.duplicateStableClusterID(id)
        }
        return result
    }

    private struct UnmatchedArtifact {
        let sequence: String
        let utrTrimmedSequence: String?
        let translation: String?
        let status: FullLengthONTMHCTranslationStatus
    }

    private static func unmatchedArtifacts(
        expectedStableIDs: Set<String>,
        documentSequenceSHA256ByStableID: [String: String],
        fastaRecords: [FullLengthONTMHCClusterFASTARecord],
        genBankRecords: [GenBankRecord],
        category: FullLengthONTMHCUnmatchedRecordCategory
    ) throws -> [String: UnmatchedArtifact] {
        var fastaByID: [String: FullLengthONTMHCClusterFASTARecord] = [:]
        for record in fastaRecords {
            guard expectedStableIDs.contains(record.name) else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: record.name,
                    detail: "unexpected \(category.rawValue) FASTA record"
                )
            }
            guard fastaByID.updateValue(record, forKey: record.name) == nil else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: record.name,
                    detail: "duplicate \(category.rawValue) FASTA record"
                )
            }
        }
        var genBankByID: [String: GenBankRecord] = [:]
        for record in genBankRecords {
            let sourceFeatures = record.annotations.filter { $0.type == .source }
            let stableID = sourceFeatures.count == 1
                ? sourceFeatures[0].qualifier("stable_cluster_id") ?? record.sequence.name
                : record.sequence.name
            guard expectedStableIDs.contains(stableID) else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "unexpected \(category.rawValue) GenBank record"
                )
            }
            guard genBankByID.updateValue(record, forKey: stableID) == nil else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "duplicate \(category.rawValue) GenBank record"
                )
            }
        }

        var result: [String: UnmatchedArtifact] = [:]
        for stableID in expectedStableIDs {
            guard let fasta = fastaByID[stableID] else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "missing \(category.rawValue) FASTA record"
                )
            }
            guard let genBank = genBankByID[stableID] else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "missing \(category.rawValue) GenBank record"
                )
            }
            let genBankSequence = genBank.sequence.asString().uppercased()
            let fastaSequence = fasta.sequence.uppercased()
            let computedSequenceSHA256 = SHA256.hash(data: Data(fastaSequence.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            guard documentSequenceSHA256ByStableID[stableID]?.lowercased() == computedSequenceSHA256 else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "document sequence SHA-256 does not match the FASTA sequence"
                )
            }
            if let accession = genBank.accession, accession != stableID {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "GenBank accession is \(accession)"
                )
            }
            guard genBank.locus.name == stableID
                || (genBank.locus.name.count >= 16 && stableID.hasPrefix(genBank.locus.name)) else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "GenBank locus is \(genBank.locus.name)"
                )
            }
            let sourceFeatures = genBank.annotations.filter { $0.type == .source }
            guard sourceFeatures.count == 1,
                  sourceFeatures[0].qualifier("stable_cluster_id") == stableID else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "GenBank source stable_cluster_id is missing or inconsistent"
                )
            }
            guard sourceFeatures[0].qualifier("sequence_sha256")?.lowercased()
                == computedSequenceSHA256 else {
                throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                    stableClusterID: stableID,
                    detail: "GenBank source sequence SHA-256 does not match the FASTA sequence"
                )
            }
            if category == .candidate,
               Self.hasCandidateTrimMetadata(sourceFeatures[0]) {
                try Self.validateCroppedCandidateGenBank(
                    stableID: stableID,
                    fastaSequence: fastaSequence,
                    genBankSequence: genBankSequence,
                    source: sourceFeatures[0]
                )
            } else {
                guard genBankSequence == fastaSequence else {
                    throw FullLengthONTMHCWorkbookProjectionError.invalidUnmatchedArtifactIdentity(
                        stableClusterID: stableID,
                        detail: "FASTA and GenBank sequences differ"
                    )
                }
            }
            let cdsFeatures = genBank.annotations.filter { $0.type == .cds }
            let translation = cdsFeatures.count == 1
                ? cdsFeatures[0].qualifier("translation")?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let usableTranslation = translation.flatMap { $0.isEmpty ? nil : $0 }
            let sourceStatus = sourceFeatures[0].qualifier("translation_status")
                .flatMap(FullLengthONTMHCTranslationStatus.init(rawValue:))
            result[stableID] = UnmatchedArtifact(
                sequence: fasta.sequence,
                utrTrimmedSequence: category == .candidate ? genBank.sequence.asString() : nil,
                translation: usableTranslation,
                status: usableTranslation == nil ? .incompleteUnresolved : sourceStatus ?? .incompleteUnresolved
            )
        }
        return result
    }

    private static func hasCandidateTrimMetadata(_ source: SequenceAnnotation) -> Bool {
        [
            "original_sequence_length", "trim_start", "trim_end", "genbank_sequence_sha256",
            "trim_status", "reference_readiness_status",
        ].contains { source.qualifier($0) != nil }
    }

    private static func validateCroppedCandidateGenBank(
        stableID: String,
        fastaSequence: String,
        genBankSequence: String,
        source: SequenceAnnotation
    ) throws {
        func invalid(_ detail: String) -> FullLengthONTMHCWorkbookProjectionError {
            .invalidUnmatchedArtifactIdentity(stableClusterID: stableID, detail: detail)
        }
        guard let originalLengthText = source.qualifier("original_sequence_length"),
              let originalLength = Int(originalLengthText),
              originalLength == fastaSequence.count else {
            throw invalid("candidate trim original length does not match the FASTA sequence")
        }
        guard let startText = source.qualifier("trim_start"),
              let endText = source.qualifier("trim_end"),
              let start = Int(startText), let end = Int(endText),
              start >= 1, end >= start, end <= fastaSequence.count else {
            throw invalid("candidate trim bounds are invalid for the FASTA sequence")
        }
        guard let trimStatus = source.qualifier("trim_status"), !trimStatus.isEmpty,
              let readiness = source.qualifier("reference_readiness_status"), !readiness.isEmpty else {
            throw invalid("candidate trim status or reference readiness status is missing")
        }
        let declaredSubstring = String(fastaSequence.dropFirst(start - 1).prefix(end - start + 1))
        guard genBankSequence == declaredSubstring else {
            throw invalid("GenBank sequence does not match the declared FASTA substring")
        }
        let computedGenBankSHA256 = SHA256.hash(data: Data(genBankSequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard source.qualifier("genbank_sequence_sha256")?.lowercased()
            == computedGenBankSHA256 else {
            throw invalid("GenBank sequence SHA-256 does not match the cropped ORIGIN")
        }
    }

    private static func observationsByStableID(
        _ observations: [ONTMHCCandidateObservation]
    ) throws -> [String: [ONTMHCCandidateObservation]] {
        var seen = Set<String>()
        for observation in observations {
            let key = [observation.stableClusterID, observation.sampleID, observation.readGroupID].joined(separator: "\0")
            guard seen.insert(key).inserted else {
                throw FullLengthONTMHCWorkbookProjectionError.duplicateObservation(
                    stableClusterID: observation.stableClusterID,
                    sampleID: observation.sampleID,
                    readGroupID: observation.readGroupID
                )
            }
        }
        return Dictionary(grouping: observations, by: \.stableClusterID)
    }

    private static func readsBySample(_ observations: [ONTMHCCandidateObservation]) -> [String: Int] {
        observations.reduce(into: [:]) { $0[$1.sampleID, default: 0] += $1.aggregatedSampleReadCount }
    }

    private static func validateSummary(
        stableClusterID: String,
        independentSampleCount: Int,
        occurrenceCount: Int,
        totalClusterReads: Int,
        observations: [ONTMHCCandidateObservation],
        readsBySample: [String: Int]
    ) throws {
        let checks = [
            ("independent_sample_count", independentSampleCount, readsBySample.values.filter { $0 > 0 }.count),
            ("occurrence_count", occurrenceCount, observations.reduce(0) { $0 + $1.sourceClusterIDs.count }),
            ("total_cluster_reads", totalClusterReads, readsBySample.values.reduce(0, +)),
        ]
        if let mismatch = checks.first(where: { $0.1 != $0.2 }) {
            throw FullLengthONTMHCWorkbookProjectionError.observationSummaryMismatch(
                stableClusterID: stableClusterID,
                field: mismatch.0,
                expected: mismatch.1,
                actual: mismatch.2
            )
        }
    }

    private static func tint(
        classification: ONTMHCCandidateClassification,
        support: ONTMHCCandidateSupportClass
    ) -> FullLengthONTMHCWorkbookTintCategory {
        switch (classification, support) {
        case (.novel, .shared): .sharedNovel
        case (.novel, .singleton): .singletonNovel
        case (.extension, .shared): .sharedExtension
        case (.extension, .singleton): .singletonExtension
        }
    }

    private static func metricText(_ metrics: [String: Double]) -> String {
        metrics.keys.sorted(by: less).map { key in "\(key)=\(metrics[key]!)" }.joined(separator: ";")
    }

    private static func countText(_ counts: [String: Int]) -> String {
        counts.keys.sorted(by: less).map { key in "\(key)=\(counts[key]!)" }.joined(separator: ";")
    }

    private static func inserting(_ values: [String], afterFirstCellOf row: [String]) -> [String] {
        guard let first = row.first else { return values }
        return [first] + values + row.dropFirst()
    }

    private static func authoritativeLegacyRow(
        _ row: [String],
        header: [String],
        candidate: FullLengthONTMHCCandidateWorkbookRow
    ) -> [String] {
        replacingLegacyFields(in: row, header: header) { field, original in
            switch field {
            case "match_source": "reciprocal-minimap2"
            case "closest_match_id": candidate.provisionalName
            case "closest_reference", "closest_reference_name": candidate.closestReferenceName
            case "match_class": candidate.classification
            case "nucleotides_different", "snp_differences": String(candidate.snpCount)
            case "indel_bases": String(candidate.insertedBases + candidate.deletedBases)
            case "aligned_bases": String(candidate.comparableBases)
            case "score": String(candidate.alignmentScore)
            case "percent_identity": decimalText(candidate.identity * 100)
            case "query_coverage": decimalText(candidate.shorterCoverage * 100)
            case "evalue", "bitscore": ""
            default: original
            }
        }
    }

    private static func authoritativeLegacyRow(
        _ row: [String],
        header: [String],
        unnameable: FullLengthONTMHCUnnameableWorkbookRow
    ) -> [String] {
        replacingLegacyFields(in: row, header: header) { field, original in
            switch field {
            case "match_source": "reciprocal-unnameable"
            case "match_class": "un-nameable"
            case "closest_match_id", "closest_reference", "closest_reference_name", "nucleotides_different", "snp_differences",
                 "indel_bases", "aligned_bases", "score", "percent_identity", "query_coverage", "evalue", "bitscore": ""
            default: original
            }
        }
    }

    private static func normalizingLegacyLabels(_ row: [String], header: [String]) -> [String] {
        let originalMatchID = header.firstIndex(of: "closest_match_id").flatMap { row.indices.contains($0) ? row[$0] : nil }
        return replacingLegacyFields(in: row, header: header) { field, original in
            if field == "match_class", let originalMatchID {
                if originalMatchID.range(of: #"_0SNP$"#, options: .regularExpression) != nil { return "exact" }
                if originalMatchID.range(of: #"_[1-9][0-9]*SNP$"#, options: .regularExpression) != nil { return "novel" }
                if originalMatchID.hasSuffix("_extension") { return "extension" }
            }
            switch field {
            case "closest_match_id", "closest_reference", "closest_reference_name":
                return normalizedLegacyLabel(original)
            default:
                return original
            }
        }
    }

    private static func replacingLegacyFields(
        in row: [String],
        header: [String],
        transform: (_ field: String, _ value: String) -> String
    ) -> [String] {
        row.enumerated().map { index, value in
            transform(header.indices.contains(index) ? header[index] : "", value)
        }
    }

    private static func normalizedLegacyLabel(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "_extension", with: "_ext")
        guard let regex = try? NSRegularExpression(pattern: #"_([0-9]+)SNP"#) else { return result }
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let fullRange = Range(match.range(at: 0), in: result),
              let countRange = Range(match.range(at: 1), in: result),
              let count = Int(result[countRange]) {
            result.replaceSubrange(fullRange, with: count == 0 ? "" : "_\(count)nt_nov")
        }
        return result
    }

    private static func decimalText(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func evidenceLess(_ lhs: ONTMHCEvidenceLocator, _ rhs: ONTMHCEvidenceLocator) -> Bool {
        let left = [lhs.bamPath, lhs.queryName, lhs.referenceName, lhs.readGroupID ?? "", String(lhs.referenceStart), lhs.cigar]
        let right = [rhs.bamPath, rhs.queryName, rhs.referenceName, rhs.readGroupID ?? "", String(rhs.referenceStart), rhs.cigar]
        for (a, b) in zip(left, right) where a != b { return less(a, b) }
        return false
    }

    private static func less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
