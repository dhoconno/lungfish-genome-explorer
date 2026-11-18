// RNASeqQualitySummary.swift - The quality numbers of a bulk RNA-seq result (Phase 5.4 lane RS-BULK-VIEW M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq quality` prints these numbers and the quality view of the app shows them, so the view computes
// none of its own (program plan 5.4). Each number comes from the result's own files after `verifyChecksums`: the
// tool's numbers from `quality/samples.quality.tsv` as written, and the shares from the default count table, summed in
// decimal so that no sum is rounded. Nothing is written.

import Foundation
import LungfishIO

/// Why `rnaseq quality` reads no numbers from a folder. Each one comes before any number is read.
public enum RNASeqQualityRefusal: Error, Equatable, LocalizedError, Sendable {
    case singleCell(name: String)
    case checksumsDiffer(name: String, files: [String])
    case noCountTable(name: String)
    case notHostDisagrees(name: String, listed: Int, flagged: Int)
    case unreadable(name: String, words: String)

    public var errorDescription: String? {
        switch self {
        case .singleCell(let name):
            return "\(name) is a single-cell result, whose numbers for each cell are in its cells.sqlite. "
                + "rnaseq quality reads the count table of a bulk result. Run rnaseq pseudobulk to sum its cells into a bulk result."
        case .checksumsDiffer(let name, let files):
            let what = files.count == 1
                ? "Its file \(files[0]) no longer matches the sha256 the result lists"
                : "Its files \(RNASeqPseudobulkRefusal.list(files)) no longer match the sha256 values the result lists"
            return "The RNA-seq result \(name) changed after LGE wrote it. \(what), so its numbers are not the ones LGE recorded. "
                + "Restore the file from a copy, or import or count the data again."
        case .noCountTable(let name):
            return "\(name) lists no default count table, so it holds no counts to read. Import or count the data again."
        case .notHostDisagrees(let name, let listed, let flagged):
            return "The RNA-seq result \(name) lists \(listed) not-host features in its manifest and flags \(flagged) in genes.tsv, "
                + "so LGE cannot tell which rows are host genes. Count the reads again with LGE, or import the result again."
        case .unreadable(let name, let words):
            return "\(name) cannot be read. \(words)"
        }
    }
}

/// One row a sample. Every cell is the text the leaf prints, a number as its file or the decimal sum gives it, or words.
public struct RNASeqQualitySummary: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var sample: String
        /// The tool's `num_processed` as written, or the exact column sum of the default count table.
        public var librarySize: String
        /// Where ``librarySize`` comes from, such as `salmon num_processed` or `column sum of counts/genes.counts.tsv in reads`.
        public var librarySizeSource: String
        /// The tool's `percent_mapped` as written, or Not recorded.
        public var mappingRatePercent: String
        /// The detected library type as the quality table writes it, or Not recorded.
        public var libraryType: String
        /// The exact column sum of the default count table over every feature, which each share divides.
        public var counted: String
        public var rRNAPercent: String
        public var notHostPercent: String
        public var globinPercent: String

        /// The cells in the order of ``RNASeqQualitySummary/columns``.
        public var cells: [String] {
            [sample, librarySize, librarySizeSource, mappingRatePercent, libraryType, counted, rRNAPercent, notHostPercent, globinPercent]
        }
    }

    public static let columns = [
        "sample_id", "library_size", "library_size_source", "mapping_rate_percent", "library_type", "counted",
        "rrna_percent", "not_host_percent", "globin_percent",
    ]
    /// A host gene is an rRNA gene when its biotype in `genes.tsv` is one of these. Ensembl and GENCODE name the
    /// mitochondrial ones `Mt_rRNA`, and RefSeq names both kinds `rRNA`.
    public static let rRNABiotypes = ["rRNA", "Mt_rRNA"]
    public static let noRRNAGenesText = "no rRNA genes annotated"
    public static let noNotHostText = "no not-host features"
    public static let noCountsText = "no counts"
    public static var notRecordedText: String { RNASeqResultBundle.notRecordedText }

    public var name: String
    /// The path of the default count table in the result.
    public var countTable: String
    public var unit: RNASeqResultManifest.CountEntry.Unit
    /// The host genes the rRNA share sums, in the table's order.
    public var rRNAGenes: [String]
    /// The features of `notHost`, as the manifest lists them.
    public var notHostFeatures: [String]
    public var samples: [Sample]

    /// Checks, loads and sums the result at `url`. A single-cell result, a changed file or an unreadable folder is
    /// refused in words.
    public static func read(resultAt url: URL) throws -> RNASeqQualitySummary {
        try RNASeqQualitySummary(result: try loadVerified(url), label: url.lastPathComponent)
    }

    public init(result: RNASeqResult, label: String) throws {
        let table = try Self.defaultCountTable(of: result, label: label)
        let notHost = Set(result.manifest.notHost)
        let rRNA = Set(result.genes.filter { gene in
            !notHost.contains(gene.id) && gene.notHost != true && Self.rRNABiotypes.contains(gene.biotype ?? "")
        }.map(\.id))
        name = result.manifest.name
        countTable = table.entry.path
        unit = table.entry.unit
        rRNAGenes = table.table.rows.map(\.id).filter(rRNA.contains)
        notHostFeatures = result.manifest.notHost
        let source = "column sum of \(table.entry.path) in \(Self.unitWords(table.entry.unit))"
        // An import names no reference set, so its files hold no not_host flags and its empty notHost list is no finding.
        let noNotHost = result.manifest.referenceSet == nil ? Self.notRecordedText : Self.noNotHostText
        samples = table.table.sampleIDs.enumerated().map { index, sample in
            var total = Decimal(0)
            var onRRNA = Decimal(0)
            var onNotHost = Decimal(0)
            for row in table.table.rows where index < row.counts.count {
                let value = Self.decimal(row.counts[index])
                total += value
                if rRNA.contains(row.id) { onRRNA += value }
                if notHost.contains(row.id) { onNotHost += value }
            }
            let processed = Self.quality(result.quality, sample: sample, column: "num_processed")
            return Sample(
                sample: sample,
                librarySize: processed ?? Self.sumText(total),
                librarySizeSource: processed == nil ? source : "\(result.manifest.route.tool) num_processed",
                mappingRatePercent: Self.quality(result.quality, sample: sample, column: "percent_mapped") ?? Self.notRecordedText,
                libraryType: Self.quality(result.quality, sample: sample, column: "library_type") ?? Self.notRecordedText,
                counted: Self.sumText(total),
                rRNAPercent: rRNA.isEmpty ? Self.noRRNAGenesText : Self.percent(onRRNA, of: total),
                notHostPercent: notHost.isEmpty ? noNotHost : Self.percent(onNotHost, of: total),
                // No rule names the globin genes yet (lane RS-BULK-VIEW M1, a BIO row), so the share reads Not recorded.
                globinPercent: Self.notRecordedText)
        }
    }

    /// The line the text form prints before the table.
    public var caption: String {
        "Quality of \(name), with each share on the column sum of \(countTable) in \(Self.unitWords(unit))."
    }

    public func document() -> RNASeqQualityDocument {
        RNASeqQualityDocument(
            result: name, table: "samples",
            facts: [
                "countTable": countTable, "unit": unit.rawValue,
                "shareOf": "the column sum of \(countTable), every feature",
                "rRNA": "host genes whose biotype in genes.tsv is \(Self.rRNABiotypes.joined(separator: " or ")),\(rRNAGenes.count) in the table",
                "notHost": "the \(notHostFeatures.count) features that the manifest lists under notHost",
                "globin": Self.notRecordedText,
            ],
            columns: Self.columns, rows: samples.map(\.cells))
    }
}

// MARK: - Reading and numbers, shared with the correlation

extension RNASeqQualitySummary {
    /// The result at `url` after its checks: bulk, every listed file at its sha256, and `notHost` equal to the flags of
    /// `genes.tsv`. The modality is read first, so the matrices of a single-cell result are never hashed.
    public static func loadVerified(_ url: URL) throws -> RNASeqResult {
        let label = url.lastPathComponent
        do {
            guard try RNASeqResultBundle.loadManifest(from: url).modality == .bulk else {
                throw RNASeqQualityRefusal.singleCell(name: label)
            }
            var changed: [String] = []
            for mismatch in try RNASeqResultBundle.verifyChecksums(of: url) {
                let file = mismatch.actual == nil ? "\(mismatch.path) (missing)" : mismatch.path
                if !changed.contains(file) { changed.append(file) }
            }
            guard changed.isEmpty else { throw RNASeqQualityRefusal.checksumsDiffer(name: label, files: changed) }
            let result = try RNASeqResultBundle.load(from: url)
            let flagged = Set(result.genes.filter { $0.notHost == true }.map(\.id))
            guard flagged == Set(result.manifest.notHost) else {
                throw RNASeqQualityRefusal.notHostDisagrees(name: label, listed: result.manifest.notHost.count, flagged: flagged.count)
            }
            return result
        } catch let error as RNASeqResultError {
            throw RNASeqQualityRefusal.unreadable(name: label, words: error.localizedDescription)
        }
    }

    /// The default count table, of genes when the result has one and else of transcripts, as an import of salmon
    /// folders with no `--tx2gene` holds.
    public static func defaultCountTable(of result: RNASeqResult, label: String) throws -> RNASeqResult.CountTable {
        let defaults = result.counts.filter { $0.entry.column == .default }
        guard let table = defaults.first(where: { $0.entry.rows == .gene }) ?? defaults.first(where: { $0.entry.rows == .transcript }) else {
            throw RNASeqQualityRefusal.noCountTable(name: label)
        }
        return table
    }

    public static func unitWords(_ unit: RNASeqResultManifest.CountEntry.Unit) -> String {
        switch unit {
        case .reads: return "reads"
        case .pairs: return "read pairs"
        case .umis: return "UMIs"
        case .estimated: return "estimated counts"
        }
    }

    /// The quality cell of `sample` in `column` as written, nil when the table, the row or the cell is missing.
    static func quality(_ table: RNASeqQualityTable?, sample: String, column: String) -> String? {
        guard let table, let index = table.columns.firstIndex(of: column),
              let row = table.rows.first(where: { $0.sample == sample }), index < row.values.count else { return nil }
        return row.values[index]
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// A count as the decimal its text in the table names. The writer prints a whole count as an integer and any other
    /// as Swift's shortest text, so a sum of these decimals is the sum of the printed numbers, with no rounding.
    static func decimal(_ value: Double) -> Decimal {
        if value == value.rounded(), abs(value) < 1e15 { return Decimal(Int64(value)) }
        return Decimal(string: "\(value)", locale: posix) ?? Decimal(value)
    }

    /// A decimal sum as text, rounded half up to 6 decimals and without trailing zeros. The writer sums the transcripts
    /// of a gene in doubles and prints the result with the noise of that sum (5.7379999999999995 for the 5.738 that
    /// salmon measured), so the exact sum of the printed cells reads 4829448.9820000000172139 for 4829448.982. No count
    /// tool prints more than 6 decimals, so no printed digit is lost.
    static func sumText(_ value: Decimal) -> String {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 6, .plain)
        NSDecimalCompact(&rounded)
        return rounded.description
    }

    /// `part` as a percent of `total`, in the plain digits of the nearest double.
    static func percent(_ part: Decimal, of total: Decimal) -> String {
        guard total > 0 else { return noCountsText }
        return plainDigits(NSDecimalNumber(decimal: part).doubleValue * 100 / NSDecimalNumber(decimal: total).doubleValue)
    }

    /// The shortest text that reads back as `value`, in plain digits with no exponent, such as 0.00001 for 1e-05.
    public static func plainDigits(_ value: Double) -> String {
        guard value.isFinite, let decimal = Decimal(string: "\(value)", locale: posix) else { return "\(value)" }
        return decimal.description
    }
}

/// What `lungfish-cli rnaseq quality --format json` prints (schema `rnaseq-quality`). Each cell is the text of the TSV,
/// so the two forms hold the same digits.
public struct RNASeqQualityDocument: Codable, Equatable, Sendable {
    public static let schemaID = "rnaseq-quality"

    public var schemaVersion: Int
    public var result: String
    /// `samples` or `correlation`.
    public var table: String
    /// The count table, its unit and the rule of each share, or the measure, the transform and the genes.
    public var facts: [String: String]
    public var columns: [String]
    public var rows: [[String]]

    public init(schemaVersion: Int = 1, result: String, table: String, facts: [String: String], columns: [String], rows: [[String]]) {
        self.schemaVersion = schemaVersion
        self.result = result
        self.table = table
        self.facts = facts
        self.columns = columns
        self.rows = rows
    }

    /// The table as tab-separated text, a header and one line a row.
    public func tsvText() -> String {
        ([columns] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
