import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

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
            "Nucleotide Sequence", "Putative Amino Acid Translation", "Translation Status",
            "Internal Evidence Reference",
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
                row.nucleotideSequence.map { .init($0) } ?? .blank,
                row.putativeAminoAcidTranslation.map { .init($0) } ?? .blank,
                .init(row.translationStatus.rawValue),
                row.internalEvidenceReference.map { .init($0) } ?? .blank,
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
        guard row.recordCategory == .candidate || row.recordCategory == .candidateIncomplete else {
            return nil
        }
        switch (row.classificationOrReason, row.supportClass) {
        case (ONTMHCCandidateClassification.novel.rawValue, ONTMHCCandidateSupportClass.shared.rawValue):
            return .sharedNovel
        case (ONTMHCCandidateClassification.novel.rawValue, _):
            return .singletonNovel
        case (ONTMHCCandidateClassification.extension.rawValue, ONTMHCCandidateSupportClass.shared.rawValue):
            return .sharedExtension
        case (ONTMHCCandidateClassification.extension.rawValue, _):
            return .singletonExtension
        case (ONTMHCCandidateClassification.partialExtension.rawValue, ONTMHCCandidateSupportClass.shared.rawValue):
            return .sharedExtension
        case (ONTMHCCandidateClassification.partialExtension.rawValue, _):
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
