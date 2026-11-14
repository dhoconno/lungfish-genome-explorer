// RNASeqResultTables.swift - The tables of an RNA-seq result and their tab-separated text (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The reader parses and the writer prints these tables with the same code, so a table the writer publishes is the
// table the reader returns. An empty cell is a fact the files do not state, which a reader shows as Not recorded.

import Foundation

/// A count table loaded whole: one row a feature, one column a sample.
public struct RNASeqCountTable: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var id: String
        public var counts: [Double]

        public init(id: String, counts: [Double]) {
            self.id = id
            self.counts = counts
        }
    }

    public var sampleIDs: [String]
    public var rows: [Row]

    public init(sampleIDs: [String], rows: [Row]) {
        self.sampleIDs = sampleIDs
        self.rows = rows
    }

    /// Tab-separated text, the header `feature_id` then the sample ids. A whole count prints as an integer.
    public func tsvData() throws -> Data {
        var lines = [try (["feature_id"] + sampleIDs).map(RNASeqTSV.cell).joined(separator: "\t")]
        for row in rows {
            guard row.counts.count == sampleIDs.count else {
                throw RNASeqResultError.invalidTable(path: row.id, reason: "its row holds \(row.counts.count) counts for \(sampleIDs.count) samples")
            }
            lines.append(try ([RNASeqTSV.cell(row.id)] + row.counts.map(RNASeqTSV.number)).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public init(tsv data: Data, path: String) throws {
        let table = try RNASeqTSV.parse(data, path: path)
        guard !table.header.isEmpty else { throw RNASeqResultError.invalidTable(path: path, reason: "it has no header") }
        sampleIDs = Array(table.header.dropFirst())
        rows = try table.rows.enumerated().map { index, cells in
            guard cells.count == table.header.count else {
                throw RNASeqResultError.invalidTable(path: path, reason: "line \(index + 2) holds \(cells.count) cells and the header \(table.header.count)")
            }
            let counts = try cells.dropFirst().map { cell -> Double in
                guard let value = Double(cell), value.isFinite else {
                    throw RNASeqResultError.invalidTable(path: path, reason: "line \(index + 2) holds \"\(cell)\", which is no count")
                }
                return value
            }
            return Row(id: cells[0], counts: counts)
        }
    }
}

/// One row of `samples.tsv`. A nil field is Not recorded.
public struct RNASeqSampleRecord: Equatable, Sendable {
    public var id: String
    public var animal: String?
    public var species: String?
    public var origin: String?
    public var group: String?
    public var runs: [String]
    /// The sample's folder under `source/`, which the writer sets.
    public var sourceFolder: String?

    public init(
        id: String, animal: String? = nil, species: String? = nil, origin: String? = nil, group: String? = nil,
        runs: [String] = [], sourceFolder: String? = nil
    ) {
        self.id = id
        self.animal = animal
        self.species = species
        self.origin = origin
        self.group = group
        self.runs = runs
        self.sourceFolder = sourceFolder
    }

    static let columns = ["sample_id", "animal", "species", "origin", "group", "runs", "source_folder"]

    public static func tsvData(_ records: [RNASeqSampleRecord]) throws -> Data {
        var lines = [columns.joined(separator: "\t")]
        for r in records {
            let cells = [r.id, r.animal ?? "", r.species ?? "", r.origin ?? "", r.group ?? "", r.runs.joined(separator: ","), r.sourceFolder ?? ""]
            lines.append(try cells.map(RNASeqTSV.cell).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func records(tsv data: Data, path: String) throws -> [RNASeqSampleRecord] {
        let table = try RNASeqTSV.parse(data, path: path)
        guard table.header.contains("sample_id") else { throw RNASeqResultError.invalidTable(path: path, reason: "it has no sample_id column") }
        return table.rows.map { row in
            RNASeqSampleRecord(
                id: table.value(row, "sample_id") ?? "", animal: table.value(row, "animal"), species: table.value(row, "species"),
                origin: table.value(row, "origin"), group: table.value(row, "group"),
                runs: (table.value(row, "runs") ?? "").split(separator: ",").map(String.init), sourceFolder: table.value(row, "source_folder"))
        }
    }
}

/// One row of `genes.tsv`. A nil field is Not recorded.
public struct RNASeqGeneRecord: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var biotype: String?
    public var contig: String?
    public var length: Int?
    public var notHost: Bool?
    public var mask: String?
    public var unreliable: String?

    public init(
        id: String, name: String? = nil, biotype: String? = nil, contig: String? = nil, length: Int? = nil,
        notHost: Bool? = nil, mask: String? = nil, unreliable: String? = nil
    ) {
        self.id = id
        self.name = name
        self.biotype = biotype
        self.contig = contig
        self.length = length
        self.notHost = notHost
        self.mask = mask
        self.unreliable = unreliable
    }

    public static let columns = ["gene_id", "name", "biotype", "contig", "length", "not_host", "mask", "unreliable"]

    public static func tsvData(_ records: [RNASeqGeneRecord]) throws -> Data {
        var lines = [columns.joined(separator: "\t")]
        for r in records {
            let flag = r.notHost.map { $0 ? "true" : "false" } ?? ""
            let cells = [r.id, r.name ?? "", r.biotype ?? "", r.contig ?? "", r.length.map(String.init) ?? "", flag, r.mask ?? "", r.unreliable ?? ""]
            lines.append(try cells.map(RNASeqTSV.cell).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func records(tsv data: Data, path: String) throws -> [RNASeqGeneRecord] {
        let table = try RNASeqTSV.parse(data, path: path)
        guard table.header.contains("gene_id") else { throw RNASeqResultError.invalidTable(path: path, reason: "it has no gene_id column") }
        return try table.rows.enumerated().map { index, row -> RNASeqGeneRecord in
            let flag = table.value(row, "not_host")?.lowercased()
            guard flag == nil || flag == "true" || flag == "false" else {
                throw RNASeqResultError.invalidTable(path: path, reason: "line \(index + 2) holds \"\(flag ?? "")\" in not_host, which is neither true nor false")
            }
            return RNASeqGeneRecord(
                id: table.value(row, "gene_id") ?? "", name: table.value(row, "name"), biotype: table.value(row, "biotype"),
                contig: table.value(row, "contig"), length: table.value(row, "length").flatMap { Int($0) },
                notHost: flag.map { $0 == "true" }, mask: table.value(row, "mask"), unreliable: table.value(row, "unreliable"))
        }
    }
}

/// `quality/samples.quality.tsv`: the quality numbers of the tool's own files, one row a sample. The header is `sample_id` and
/// then the columns the caller names. A nil value is Not recorded and prints as an empty cell.
public struct RNASeqQualityTable: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var sample: String
        /// One value for each of the table's columns.
        public var values: [String?]

        public init(sample: String, values: [String?]) {
            self.sample = sample
            self.values = values
        }
    }

    public static let path = "quality/samples.quality.tsv"

    public var columns: [String]
    public var rows: [Row]

    public init(columns: [String], rows: [Row]) {
        self.columns = columns
        self.rows = rows
    }

    public func tsvData() throws -> Data {
        var lines = [try (["sample_id"] + columns).map(RNASeqTSV.cell).joined(separator: "\t")]
        for row in rows {
            guard row.values.count == columns.count else {
                throw RNASeqResultError.invalidTable(path: Self.path, reason: "the row of \(row.sample) holds \(row.values.count) values for \(columns.count) columns")
            }
            lines.append(try ([row.sample] + row.values.map { $0 ?? "" }).map(RNASeqTSV.cell).joined(separator: "\t"))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public init(tsv data: Data, path: String) throws {
        let table = try RNASeqTSV.parse(data, path: path)
        guard table.header.first == "sample_id" else { throw RNASeqResultError.invalidTable(path: path, reason: "its first column is not sample_id") }
        columns = Array(table.header.dropFirst())
        rows = try table.rows.enumerated().map { index, cells in
            guard cells.count == table.header.count else {
                throw RNASeqResultError.invalidTable(path: path, reason: "line \(index + 2) holds \(cells.count) cells and the header \(table.header.count)")
            }
            return Row(sample: cells[0], values: cells.dropFirst().map { cell -> String? in cell.isEmpty ? nil : cell })
        }
    }
}

/// Tab-separated text, shared by the reader and the writer.
enum RNASeqTSV {
    struct Table {
        var header: [String]
        var rows: [[String]]

        /// The cell of `column` in `row`, nil when the column or the cell is missing or empty.
        func value(_ row: [String], _ column: String) -> String? {
            guard let index = header.firstIndex(of: column), index < row.count, !row[index].isEmpty else { return nil }
            return row[index]
        }
    }

    static func parse(_ data: Data, path: String) throws -> Table {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RNASeqResultError.invalidTable(path: path, reason: "it is not UTF-8 text")
        }
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard let header = lines.first else { throw RNASeqResultError.invalidTable(path: path, reason: "it has no header line") }
        return Table(header: header, rows: Array(lines.dropFirst()))
    }

    static func cell(_ text: String) throws -> String {
        guard !text.contains(where: { $0 == "\t" || $0.isNewline }) else {
            throw RNASeqResultError.invalidTable(path: text, reason: "a tab or a line break cannot go in a table cell")
        }
        return text
    }

    static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw RNASeqResultError.invalidTable(path: "counts", reason: "a count is not a finite number") }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }
}
