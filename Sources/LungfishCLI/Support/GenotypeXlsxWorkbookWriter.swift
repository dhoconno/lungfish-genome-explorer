import Foundation
import LungfishCore
import LungfishIO

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

    /// Delimiter exports intentionally retain their historical fallback from
    /// genotype tokens. This builder is never consumed by an XLSX route.
    enum MatrixBuilder {
        static func build(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar? = nil
        ) -> Matrix {
            if let analysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
                for: result,
                sidecar: sidecar
            ) {
                return buildFromAnalysis(analysis)
            }
            return buildFromCalls(samples: result.samples)
        }

        private static func buildFromAnalysis(
            _ analysis: GenotypeHaplotypeAnalysis
        ) -> Matrix {
            let loci = orderedLoci(analysis.samples.flatMap { $0.calls.map(\.locus) })
            let rows = analysis.samples.map { sample -> MatrixRow in
                let calls = Dictionary(
                    uniqueKeysWithValues: sample.calls.map { ($0.locus, $0) }
                )
                var cells: [MatrixCell] = []
                for locus in loci {
                    guard let call = calls[locus] else {
                        cells += [.absent, .absent]
                        continue
                    }
                    cells += [cell(for: call.haplotype1), cell(for: call.haplotype2)]
                }
                return .init(sample: sample.sample, cells: cells)
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

        private static func cell(for name: String) -> MatrixCell {
            if name.isEmpty || name == "-" { return .absent }
            if name.hasPrefix("ERR:") { return .error(name) }
            return .haplotype(
                name,
                HaplotypeColorToken.assigned(forName: name).canonicalIndex
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
