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
        /// The allele columns of each locus, in `loci` order, for the
        /// full-length genotype-only table. Nil for the H1 and H2 layout.
        var alleleColumnCounts: [Int]? = nil

        /// The header of each cell column after `Sample`.
        var cellHeaders: [String] {
            guard let alleleColumnCounts else {
                return loci.flatMap { ["\($0) H1", "\($0) H2"] }
            }
            return zip(loci, alleleColumnCounts).flatMap { locus, count in
                (1...max(count, 1)).map { "\(locus) allele \($0)" }
            }
        }
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
                if result.manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue {
                    return buildFromFullLengthCalls(samples: result.samples)
                }
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

        /// A full-length result calls several alleles per gene locus once each
        /// call takes the locus of its reference record (N9), so one H1 cell
        /// per locus would drop all but one of them. This table writes every
        /// unique call, one numbered allele column per call, up to the most
        /// any sample has at that locus. A sample's alleles are ordered by
        /// passed unique reads, most first, then by genotype name.
        private static func buildFromFullLengthCalls(
            samples: [ONTGenotypeSampleResult]
        ) -> Matrix {
            let callsBySample = samples.map { sample in
                Dictionary(grouping: ONTGenotypeCall.uniqueOccurrences(sample.calls), by: \.locusGroup)
                    .mapValues { calls in
                        calls.sorted {
                            if $0.passedUniqueReads != $1.passedUniqueReads {
                                return $0.passedUniqueReads > $1.passedUniqueReads
                            }
                            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
                        }
                    }
            }
            let loci = orderedLoci(callsBySample.flatMap(\.keys))
            let counts = loci.map { locus in
                callsBySample.map { $0[locus]?.count ?? 0 }.max() ?? 0
            }
            let rows = zip(samples, callsBySample).map { sample, callsByLocus -> MatrixRow in
                var cells: [MatrixCell] = []
                for (locus, count) in zip(loci, counts) {
                    let calls = callsByLocus[locus] ?? []
                    cells += calls.map { call in
                        call.haplotypeTokens.first.map(cell(for:)) ?? .haplotype(call.genotype, 0)
                    }
                    cells += Array(repeating: .absent, count: count - calls.count)
                }
                return .init(sample: sample.sample, cells: cells)
            }
            return .init(loci: loci, rows: rows, alleleColumnCounts: counts)
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
        let header = ["Sample"] + matrix.cellHeaders
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
