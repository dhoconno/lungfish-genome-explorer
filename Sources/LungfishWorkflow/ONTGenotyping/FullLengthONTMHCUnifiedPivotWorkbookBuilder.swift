import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCUnifiedPivotWorkbookBuilder {
    static func buildWorkbookCells(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        knownAlleleDisplayNames: [String: String]
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        let unifiedMetadataColumnCount = 12
        let headerRows = buildAnalystHeaderCells(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        ).map { row -> [FullLengthONTMHCWorkbookCell] in
            let legacyMetadata = Array(row.prefix(3))
            let sampleValues = Array(row.dropFirst(3))
            return legacyMetadata
                + Array(
                    repeating: FullLengthONTMHCWorkbookCell.blank,
                    count: unifiedMetadataColumnCount - legacyMetadata.count
                )
                + sampleValues
        }
        let table = buildCells(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: samples.map(\.sample),
            knownAlleleDisplayNames: knownAlleleDisplayNames
        )
        let separatorWidth = max(
            headerRows.map(\.count).max() ?? 0,
            table.map(\.count).max() ?? 0
        )
        return headerRows
            + [Array(repeating: FullLengthONTMHCWorkbookCell.blank, count: separatorWidth)]
            + table
    }

    static func buildAnalystHeaderCells(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        FullLengthONTMHCPivotWorkbookBuilder.buildHeaderRows(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        ).map { row in
            let label = row.first ?? ""
            return row.enumerated().map { columnIndex, value in
                analystHeaderCell(label: label, columnIndex: columnIndex, value: value)
            }
        }
    }

    private static func analystHeaderCell(
        label: String,
        columnIndex: Int,
        value: String
    ) -> FullLengthONTMHCWorkbookCell {
        switch label {
        case "Mapped Read Count" where columnIndex == 2:
            return decimalMetricCell(value)
        case "Mapped Read Count" where columnIndex >= 1:
            return integerMetricCell(value)
        case "total_read_count" where columnIndex >= 3:
            return integerMetricCell(value)
        case "percent_reads_unmapped" where columnIndex >= 3:
            return decimalMetricCell(value)
        default:
            return FullLengthONTMHCWorkbookCell(value)
        }
    }

    private static func integerMetricCell(_ value: String) -> FullLengthONTMHCWorkbookCell {
        guard let integer = Int(value) else { return FullLengthONTMHCWorkbookCell(value) }
        return FullLengthONTMHCWorkbookCell(integer)
    }

    private static func decimalMetricCell(_ value: String) -> FullLengthONTMHCWorkbookCell {
        guard let decimal = Double(value) else { return FullLengthONTMHCWorkbookCell(value) }
        return FullLengthONTMHCWorkbookCell(decimal)
    }

    static func buildCells(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        sampleOrder: [String],
        knownAlleleDisplayNames: [String: String] = [:]
    ) -> [[FullLengthONTMHCWorkbookCell]] {
        let tintsByStableID = Dictionary(uniqueKeysWithValues: projection.candidateRows.map {
            ($0.stableClusterID, $0.tintCategory)
        } + projection.unnameableRows.compactMap { row in
            row.candidateInterpretation.map {
                (row.stableClusterID, incompleteCandidateTint(
                    classification: $0.classification,
                    supportClass: row.supportClass
                ))
            }
        })
        return buildRows(
            reportRows: reportRows,
            projection: projection,
            sampleOrder: sampleOrder,
            knownAlleleDisplayNames: knownAlleleDisplayNames
        ).enumerated().map { rowIndex, row in
            let tint = rowIndex == 0 || row.count < 3 ? nil : tintsByStableID[row[1]]
            return row.enumerated().map { columnIndex, value in
                if rowIndex > 0, columnIndex >= 9 {
                    if value.isEmpty { return .blank }
                    if let number = Int(value) { return FullLengthONTMHCWorkbookCell(number) }
                }
                return FullLengthONTMHCWorkbookCell(value, tint: columnIndex == 2 ? tint : nil)
            }
        }
    }

    static func buildRows(
        reportRows: [FullLengthONTMHCReportRow],
        projection: FullLengthONTMHCWorkbookProjection,
        sampleOrder: [String],
        knownAlleleDisplayNames: [String: String] = [:]
    ) -> [[String]] {
        let sampleNames = completeSampleOrder(
            sampleOrder,
            reportRows: reportRows,
            candidateRows: projection.candidateRows,
            unnameableRows: projection.unnameableRows
        )
        var rows = [[
            "call_type",
            "call_id",
            "display_name",
            "stable_cluster_id",
            "locus",
            "classification",
            "support_class",
            "closest_reference",
            "match_class",
            "occurrence_count",
            "sample_count",
            "total_cluster_reads",
        ] + sampleNames]
        var dataRows: [[String]] = []

        let knownCounts = reportRows.reduce(into: [String: [String: Int]]()) { counts, row in
            counts[row.genotype, default: [:]][row.sample, default: 0] += row.passedUniqueReads
        }
        for callID in knownCounts.keys.sorted(by: localizedStandardLessThan) {
            let counts = knownCounts[callID] ?? [:]
            let total = counts.values.reduce(0, +)
            let displayName = knownAlleleDisplayNames[callID]
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? callID
            dataRows.append([
                "known-allele",
                callID,
                displayName,
                "",
                "",
                "known",
                "",
                displayName,
                "exact",
                String(counts.values.filter { $0 > 0 }.count),
                String(counts.values.filter { $0 > 0 }.count),
                String(total),
            ] + sampleNames.map { sample in
                guard let count = counts[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        for candidate in projection.candidateRows {
            dataRows.append([
                "candidate-\(candidate.classification)",
                candidate.stableClusterID,
                candidate.provisionalName,
                candidate.stableClusterID,
                candidate.locus,
                candidate.classification,
                candidate.supportClass,
                candidate.closestReferenceName,
                candidate.classification,
                String(candidate.occurrenceCount),
                String(candidate.independentSampleCount),
                String(candidate.totalClusterReads),
            ] + sampleNames.map { sample in
                guard let count = candidate.readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        for row in projection.unnameableRows {
            guard let interpretation = row.candidateInterpretation else { continue }
            dataRows.append([
                "candidate-incomplete",
                row.stableClusterID,
                interpretation.provisionalName,
                row.stableClusterID,
                interpretation.locus,
                interpretation.classification.rawValue,
                row.supportClass,
                interpretation.closestReferenceName,
                ONTMHCUnnameableReason.incompleteReferenceSpan.rawValue,
                String(row.occurrenceCount),
                String(row.independentSampleCount),
                String(row.totalClusterReads),
            ] + sampleNames.map { sample in
                guard let count = row.readsBySample[sample], count > 0 else { return "" }
                return String(count)
            })
        }

        dataRows.sort { lhs, rhs in
            MHCAlleleDisplayOrder.compare(
                lhs[2],
                rhs[2],
                lhsStableID: lhs[3].isEmpty ? lhs[1] : lhs[3],
                rhsStableID: rhs[3].isEmpty ? rhs[1] : rhs[3]
            ) == .orderedAscending
        }
        rows.append(contentsOf: dataRows)

        return rows
    }

    private static func completeSampleOrder(
        _ sampleOrder: [String],
        reportRows: [FullLengthONTMHCReportRow],
        candidateRows: [FullLengthONTMHCCandidateWorkbookRow],
        unnameableRows: [FullLengthONTMHCUnnameableWorkbookRow]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sample in sampleOrder where seen.insert(sample).inserted {
            result.append(sample)
        }
        let missing = Set(
            reportRows.map(\.sample)
                + candidateRows.flatMap { Array($0.readsBySample.keys) }
                + unnameableRows.compactMap { row in
                    row.candidateInterpretation == nil ? nil : Array(row.readsBySample.keys)
                }.flatMap { $0 }
        )
            .subtracting(seen)
            .sorted(by: localizedStandardLessThan)
        result.append(contentsOf: missing)
        return result
    }

    private static func localizedStandardLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func incompleteCandidateTint(
        classification: ONTMHCCandidateClassification,
        supportClass: String
    ) -> FullLengthONTMHCWorkbookTintCategory {
        switch (classification, supportClass == ONTMHCCandidateSupportClass.shared.rawValue) {
        case (.novel, true): .sharedNovel
        case (.novel, false): .singletonNovel
        case (.extension, true): .sharedExtension
        case (.extension, false): .singletonExtension
        case (.partialExtension, true): .sharedExtension
        case (.partialExtension, false): .singletonExtension
        }
    }
}
