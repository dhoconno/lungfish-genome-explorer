import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Legacy name retained only for the CSV/TSV data-shaping helpers used by
/// `genotype export`. XLSX publication is exclusively owned by
/// `GenotypeExcelExportService`.
struct GenotypeXlsxWorkbookWriter: Sendable {
    struct MatrixRow: Equatable {
        let sample: String
        let cells: [MatrixCell]
    }

    struct MatrixCell: Equatable {
        let label: String
        let tokenIndex: Int

        static let absent = MatrixCell(label: "", tokenIndex: 0)

        static func error(_ label: String) -> MatrixCell {
            .init(label: label, tokenIndex: -1)
        }

        static func haplotype(_ label: String, _ tokenIndex: Int) -> MatrixCell {
            .init(label: label, tokenIndex: tokenIndex)
        }
    }

    struct Matrix: Equatable {
        let loci: [String]
        let rows: [MatrixRow]
    }

    /// Delimiter exports take their haplotype calls from the workbook's own
    /// resolution, so an analyst override or, under legacy precedence, a
    /// manual assignment reaches CSV and TSV exactly as it reaches the
    /// Haplotype Calls sheet (finding SF2). A result without an analysis keeps
    /// its historical allele-token table, which the user manual documents.
    /// This builder is never consumed by an XLSX route.
    enum MatrixBuilder {
        static func build(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar
        ) throws -> Matrix {
            guard let analysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
                for: result,
                sidecar: sidecar
            ) else {
                return buildFromCalls(samples: result.samples)
            }
            let calls = try GenotypeExcelSnapshotBuilder.effectiveCalls(
                result: result,
                sidecar: sidecar,
                authority: .init(analysis: analysis)
            )
            return buildFromEffectiveCalls(calls, sampleOrder: analysis.samples.map(\.sample))
        }

        /// One row per analysis sample and two cells per locus, each the
        /// workbook's Effective H1 or Effective H2 verbatim. An analyst's
        /// explicit absent second haplotype is therefore "-" here as it is
        /// there, and only an empty value is an empty cell.
        private static func buildFromEffectiveCalls(
            _ calls: [GenotypeWorkbookPresentation.Call],
            sampleOrder: [String]
        ) -> Matrix {
            let loci = orderedLoci(calls.map(\.locus))
            var callsBySample: [String: [String: GenotypeWorkbookPresentation.Call]] = [:]
            for call in calls {
                callsBySample[call.sampleID, default: [:]][call.locus] = call
            }
            let rows = sampleOrder.map { sample -> MatrixRow in
                var cells: [MatrixCell] = []
                for locus in loci {
                    guard let call = callsBySample[sample]?[locus] else {
                        cells += [.absent, .absent]
                        continue
                    }
                    cells += [effectiveCell(for: call.h1.effective), effectiveCell(for: call.h2.effective)]
                }
                return .init(sample: sample, cells: cells)
            }
            return .init(loci: loci, rows: rows)
        }

        private static func buildFromCalls(
            samples: [ONTGenotypeSampleResult]
        ) -> Matrix {
            let loci = orderedLoci(samples.flatMap { $0.calls.map(\.locusGroup) })
            let rows = samples.map { sample -> MatrixRow in
                var firstCallByLocus: [String: ONTGenotypeCall] = [:]
                for call in sample.calls where firstCallByLocus[call.locusGroup] == nil {
                    firstCallByLocus[call.locusGroup] = call
                }
                var cells: [MatrixCell] = []
                for locus in loci {
                    guard let call = firstCallByLocus[locus] else {
                        cells += [.absent, .absent]
                        continue
                    }
                    let tokens = call.haplotypeTokens
                    cells.append(tokens.first.map(cell(for:)) ?? .haplotype(call.genotype, 0))
                    cells.append(tokens.count > 1 ? cell(for: tokens[1]) : .absent)
                }
                return .init(sample: sample.sample, cells: cells)
            }
            return .init(loci: loci, rows: rows)
        }

        /// The genotype-only table keeps its historical reading of "-" as an
        /// empty cell.
        private static func cell(for name: String) -> MatrixCell {
            name == "-" ? .absent : effectiveCell(for: name)
        }

        private static func effectiveCell(for value: String) -> MatrixCell {
            if value.isEmpty { return .absent }
            if value.hasPrefix("ERR:") { return .error(value) }
            return .haplotype(
                value,
                HaplotypeColorToken.assigned(forName: value).canonicalIndex
            )
        }

        private static func orderedLoci(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }
    }

    static func resolvedSampleColumns(
        for projection: GenotypeViewProjection
    ) -> [String] {
        projection.sampleColumns
    }

    static func renderDelimited(
        _ projection: GenotypeViewProjection,
        separator: String
    ) -> String {
        var lines: [String] = []
        let totalHeader = projection.includeTotalReads == true ? ["Total reads"] : []
        lines.append(
            delimitedRow(
                ["Locus", "Row"] + projection.sampleColumns + totalHeader,
                separator: separator
            )
        )
        for row in projection.rows {
            let totals = projection.includeTotalReads == true
                ? [String(row.cells.prefix(projection.sampleColumns.count)
                    .compactMap(Int.init).reduce(0, +))]
                : []
            lines.append(
                delimitedRow(
                    [row.locus ?? "", row.label] + row.cells + totals,
                    separator: separator
                )
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderDelimited(_ matrix: Matrix, separator: String) -> String {
        var header = ["Sample"]
        for locus in matrix.loci {
            header += ["\(locus) H1", "\(locus) H2"]
        }
        let lines = [delimitedRow(header, separator: separator)]
            + matrix.rows.map {
                delimitedRow([$0.sample] + $0.cells.map(\.label), separator: separator)
            }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func delimitedRow(
        _ fields: [String],
        separator: String
    ) -> String {
        fields.map { field in
            let quoted = field.contains(separator) || field.contains("\"")
                || field.contains("\n") || field.contains("\r")
            guard quoted else { return field }
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: separator)
    }
}
