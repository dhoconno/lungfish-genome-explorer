// STARCountTableReader.swift - The readers of STAR's ReadsPerGene.out.tab and of featureCounts' table with its
// .summary, and the check of their gene ids against the set's genes (Phase 5.3 lane EX-ADOPT M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One `ReadsPerGene.out.tab` of STAR `--quantMode GeneCounts`: its four `N_` lines and each gene's three counts, in file
/// order. Column 2 is the unstranded count, column 3 counts read 1 on the gene's strand and column 4 read 2 on it.
package struct STARGeneCounts: Sendable, Equatable {
    package struct Line: Sendable, Equatable {
        package var id: String
        /// Columns 2, 3 and 4.
        package var counts: [Int]
    }

    /// `N_unmapped`, `N_multimapping`, `N_noFeature` and `N_ambiguous`, in that order.
    package var totals: [Line]
    package var genes: [Line]

    /// The gene-row sum of column 3 over the gene-row sums of columns 3 and 4, or nil when both are 0 (ruling
    /// BIO-ADOPT-M5-Q1 item 5).
    package var strandShare: Double? {
        let (third, fourth) = genes.reduce((0, 0)) { ($0.0 + $1.counts[1], $0.1 + $1.counts[2]) }
        return third + fourth == 0 ? nil : Double(third) / Double(third + fourth)
    }
}

/// One featureCounts table of one BAM with its `.summary`, in file order.
package struct FeatureCountsTable: Sendable, Equatable {
    package struct Row: Sendable, Equatable {
        package var id: String
        package var count: Int
    }

    /// The `# Program` line, as featureCounts wrote it.
    package var program: String
    /// The BAM of the count column, as the header names it.
    package var bam: String
    package var genes: [Row]
    /// Each row of the `.summary`, `Assigned` and each `Unassigned_` reason.
    package var summary: [Row]
}

/// A table the adopt cannot read as counts, in words that name the file and what it should hold.
package struct STARCountTableError: Error, LocalizedError, Equatable {
    package let message: String
    package var errorDescription: String? { message }
}

package enum STARCountTableReader {
    /// STAR's four `N_` lines, in the order it writes them.
    package static let geneCountsTotals = ["N_unmapped", "N_multimapping", "N_noFeature", "N_ambiguous"]
    static let featureCountsHeader = ["Geneid", "Chr", "Start", "End", "Strand", "Length"]
    static let programPrefix = "# Program:featureCounts"

    /// `ReadsPerGene.out.tab` at `url`. `label` names the file to a person, such as `star/ReadsPerGene.out.tab of the
    /// sample S1`. A file of another shape is refused in words that say what STAR writes.
    package static func readGeneCounts(_ url: URL, label: String) throws -> STARGeneCounts {
        func refuse(_ problem: String) -> STARCountTableError {
            STARCountTableError(message: "The file \(label) is not STAR's ReadsPerGene.out.tab: \(problem). STAR writes four "
                + "lines N_unmapped, N_multimapping, N_noFeature and N_ambiguous, then one gene a line, each with three counts.")
        }
        let lines = try textLines(url)
        var totals: [STARGeneCounts.Line] = []
        var genes: [STARGeneCounts.Line] = []
        var seen = Set<String>()
        for (index, text) in lines.enumerated() {
            let cells = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == 4 else { throw refuse("line \(index + 1) holds \(cells.count) columns, not 4") }
            let counts = try cells.dropFirst().map { cell -> Int in
                guard let value = Int(cell), value >= 0 else { throw refuse("line \(index + 1) holds \"\(cell)\" where a count is") }
                return value
            }
            let line = STARGeneCounts.Line(id: cells[0], counts: counts)
            if index < geneCountsTotals.count {
                guard line.id == geneCountsTotals[index] else {
                    throw refuse("line \(index + 1) starts \"\(line.id)\", not \(geneCountsTotals[index])")
                }
                totals.append(line)
            } else {
                guard !line.id.isEmpty, !line.id.hasPrefix("N_") else { throw refuse("line \(index + 1) names no gene") }
                guard seen.insert(line.id).inserted else { throw refuse("the gene \(line.id) is on two lines") }
                genes.append(line)
            }
        }
        guard !genes.isEmpty else { throw refuse("it holds no gene line") }
        return STARGeneCounts(totals: totals, genes: genes)
    }

    /// featureCounts' `table` with its `summary`, each of one BAM. Either of another shape is refused in words that say
    /// what featureCounts writes, and a summary of another BAM in words that name both.
    package static func readFeatureCounts(table: URL, summary: URL, label: String, summaryLabel: String) throws -> FeatureCountsTable {
        func refuse(_ problem: String) -> STARCountTableError {
            STARCountTableError(message: "The file \(label) is not a featureCounts table of one BAM: \(problem). featureCounts "
                + "writes a # Program line, the header Geneid, Chr, Start, End, Strand, Length and the BAM, then one gene a "
                + "line with its count.")
        }
        let lines = try textLines(table)
        guard let program = lines.first, program.hasPrefix(programPrefix) else {
            throw refuse("its first line is not featureCounts' # Program line")
        }
        guard lines.count > 1 else { throw refuse("it holds no header") }
        let header = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard header.count == featureCountsHeader.count + 1, Array(header.prefix(featureCountsHeader.count)) == featureCountsHeader else {
            throw refuse("its header is \"\(header.joined(separator: " "))\"")
        }
        var genes: [FeatureCountsTable.Row] = []
        var seen = Set<String>()
        for (index, text) in lines.enumerated().dropFirst(2) {
            let cells = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == header.count else { throw refuse("line \(index + 1) holds \(cells.count) columns, not \(header.count)") }
            guard let count = Int(cells[cells.count - 1]), count >= 0 else {
                throw refuse("line \(index + 1) holds \"\(cells[cells.count - 1])\" where a count is")
            }
            guard !cells[0].isEmpty else { throw refuse("line \(index + 1) names no gene") }
            guard seen.insert(cells[0]).inserted else { throw refuse("the gene \(cells[0]) is on two lines") }
            genes.append(.init(id: cells[0], count: count))
        }
        guard !genes.isEmpty else { throw refuse("it holds no gene line") }
        let bam = header[header.count - 1]
        return FeatureCountsTable(
            program: program, bam: bam, genes: genes, summary: try readSummary(summary, bam: bam, label: summaryLabel, table: label))
    }

    /// The `.summary` of the table of `bam`: the header `Status` and that BAM, then one status a line, `Assigned` among them.
    private static func readSummary(_ url: URL, bam: String, label: String, table: String) throws -> [FeatureCountsTable.Row] {
        func refuse(_ problem: String) -> STARCountTableError {
            STARCountTableError(message: "The file \(label) is not the .summary of \(table): \(problem). featureCounts writes "
                + "the header Status and the table's BAM, then one status a line with its count, Assigned among them.")
        }
        let lines = try textLines(url)
        guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init),
              header.count == 2, header[0] == "Status" else {
            throw refuse("its first line is not the header Status and one BAM")
        }
        guard header[1] == bam else { throw refuse("it counts \(header[1]), and the table counts \(bam)") }
        let rows = try lines.enumerated().dropFirst().map { index, text -> FeatureCountsTable.Row in
            let cells = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == 2, !cells[0].isEmpty, let count = Int(cells[1]), count >= 0 else {
                throw refuse("line \(index + 1) is not a status and its count")
            }
            return .init(id: cells[0], count: count)
        }
        guard rows.contains(where: { $0.id == "Assigned" }) else { throw refuse("it holds no Assigned line") }
        return rows
    }

    /// The genes of the set's `derived/genes.tsv` whose `length` is above 0, in file order: the genes with exons in
    /// `derived/genes.gtf`, which STAR and featureCounts list (BIO-COUNTING-GTF item 5).
    package static func countedGenes(genesTSV url: URL) throws -> [String] {
        let lines = try textLines(url)
        let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) ?? []
        guard let id = header.firstIndex(of: "gene_id"), let length = header.firstIndex(of: "length") else {
            throw STARCountTableError(message: "The set's \(url.lastPathComponent) has no gene_id and length columns.")
        }
        return lines.dropFirst().compactMap { text in
            let cells = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count > max(id, length), let bases = Int(cells[length]), bases > 0 else { return nil }
            return cells[id]
        }
    }

    /// The table's gene ids are the set's counted genes, or the table is refused in words that name the set, the number
    /// missing and the number extra with the first three of each, and say what a table of another GTF would do.
    package static func checkGenes(_ ids: [String], label: String, setID: String, setGenes: [String]) throws {
        let (table, set) = (Set(ids), Set(setGenes))
        let missing = setGenes.filter { !table.contains($0) }
        let extra = ids.filter { !set.contains($0) }
        guard !missing.isEmpty || !extra.isEmpty else { return }
        func firstThree(_ list: [String]) -> String {
            " (" + list.prefix(3).joined(separator: ", ") + (list.count > 3 ? " and \(list.count - 3) more" : "") + ")"
        }
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("\(missing.count) of the set's \(setGenes.count) genes with a length above 0 \(missing.count == 1 ? "is" : "are") "
                + "missing\(firstThree(missing))")
        }
        if !extra.isEmpty {
            parts.append("\(extra.count) \(extra.count == 1 ? "id is" : "ids are") not the set's\(firstThree(extra))")
        }
        throw STARCountTableError(message: "The genes of \(label) are not the genes of the set \(setID): "
            + parts.joined(separator: ", and ") + ". It was counted on a GTF other than the set's derived/genes.gtf, so its "
            + "genes would read 0 where the reads are. Make the plan again with this version of Lungfish, run it, and adopt "
            + "the folder it returns.")
    }

    /// Each line of a text file but a last empty one.
    private static func textLines(_ url: URL) throws -> [String] {
        var lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}
