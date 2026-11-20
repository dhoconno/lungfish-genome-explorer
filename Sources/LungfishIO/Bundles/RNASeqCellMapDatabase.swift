// RNASeqCellMapDatabase.swift - cellmap.sqlite schema 1, its codings and its writer (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `cellmap.sqlite` holds every number the embedding view of a cell map shows (`docs/formats/rnaseq-cell-map.md`,
// cellmap.sqlite). Only `RNASeqResultWriter` writes it, inside its staging folder, in one transaction, as
// `RNASeqCellsDatabaseWriter` writes `cells.sqlite`. The pure codings of `gene_values`, the nearest-rank bounds, the label
// order and the one label-table serializer live here, so the writer, the reader and the tests share them. The reader is
// `RNASeqCellMapDatabase` in `RNASeqCellMapDatabase+Read.swift`.

import Foundation
import SQLite3

public enum RNASeqCellMap {
    public static let filename = "cellmap.sqlite"
    public static let currentSchemaVersion = 1
    /// The formula `meta.normalisation` holds and the record names.
    public static let normalisationFormula = "log1p(10000 * UMIs / cell Gene Expression UMIs)"
    /// The header of every label table, `labels/<set>.tsv` and the selection table alike.
    public static let labelTableHeader = "sample\tbarcode\tlabel"

    static let schema = [
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE samples (sample INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, cells INTEGER NOT NULL)",
        "CREATE TABLE cells (cell INTEGER PRIMARY KEY, sample INTEGER NOT NULL, barcode TEXT NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL)",
        // BIO's blocker B1 on the format page: every feature of the parent, of every type, which the gene picker reads,
        // since `genes.tsv` keeps no feature number or type. A `gene_values.feature` is a row of it.
        "CREATE TABLE features (feature INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL, total INTEGER NOT NULL, cells INTEGER NOT NULL)",
        "CREATE TABLE embeddings (embedding INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, dimensions INTEGER NOT NULL, method TEXT, source TEXT NOT NULL, source_file TEXT NOT NULL, other_counts INTEGER NOT NULL, cells INTEGER NOT NULL)",
        "CREATE TABLE embedding_cells (embedding INTEGER NOT NULL, sample INTEGER NOT NULL, drawn INTEGER NOT NULL, left_out INTEGER NOT NULL, PRIMARY KEY (embedding, sample)) WITHOUT ROWID",
        "CREATE TABLE coordinates (embedding INTEGER NOT NULL, dimension INTEGER NOT NULL, cell INTEGER NOT NULL, value REAL NOT NULL, PRIMARY KEY (embedding, dimension, cell)) WITHOUT ROWID",
        "CREATE TABLE label_sets (label_set INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, source TEXT NOT NULL, source_file TEXT NOT NULL, labels INTEGER NOT NULL, \"table\" TEXT NOT NULL)",
        "CREATE TABLE labels (label_set INTEGER NOT NULL, label INTEGER NOT NULL, name TEXT NOT NULL, cells INTEGER NOT NULL, PRIMARY KEY (label_set, label)) WITHOUT ROWID",
        "CREATE TABLE label_counts (label_set INTEGER NOT NULL, label INTEGER NOT NULL, sample INTEGER NOT NULL, cells INTEGER NOT NULL, PRIMARY KEY (label_set, label, sample)) WITHOUT ROWID",
        "CREATE TABLE label_set_samples (label_set INTEGER NOT NULL, sample INTEGER NOT NULL, labelled INTEGER NOT NULL, unlabelled INTEGER NOT NULL, PRIMARY KEY (label_set, sample)) WITHOUT ROWID",
        // Not on the format page's list (CM-KIND Findings): the label of each labelled cell, which the view colours by
        // and the label form of the membership function reads. A cell with no label has no row.
        "CREATE TABLE cell_labels (label_set INTEGER NOT NULL, cell INTEGER NOT NULL, label INTEGER NOT NULL, PRIMARY KEY (label_set, cell)) WITHOUT ROWID",
        "CREATE TABLE gene_values (feature INTEGER PRIMARY KEY, cells INTEGER NOT NULL, cell_ids BLOB NOT NULL, umis BLOB NOT NULL, normalised BLOB NOT NULL, umis_minimum INTEGER NOT NULL, umis_maximum INTEGER NOT NULL, umis_p99 INTEGER NOT NULL, normalised_minimum REAL NOT NULL, normalised_maximum REAL NOT NULL, normalised_p99 REAL NOT NULL)",
        "CREATE TABLE not_host_extras (extra INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL)",
        "CREATE TABLE cell_not_host (cell INTEGER NOT NULL, extra INTEGER NOT NULL, umis INTEGER NOT NULL, flag TEXT NOT NULL, PRIMARY KEY (cell, extra)) WITHOUT ROWID",
        "CREATE TABLE flag_counts (extra INTEGER NOT NULL, sample INTEGER NOT NULL, flag TEXT NOT NULL, cells INTEGER NOT NULL, PRIMARY KEY (extra, sample, flag)) WITHOUT ROWID",
        "CREATE TABLE value_bounds (value TEXT NOT NULL, extra INTEGER NOT NULL, minimum REAL NOT NULL, maximum REAL NOT NULL, p99 REAL NOT NULL, PRIMARY KEY (value, extra)) WITHOUT ROWID",
    ]

    // MARK: - gene_values codings

    /// Appends `value` as unsigned LEB128, seven bits a byte from the lowest, the high bit set on every byte but the last.
    public static func appendLEB128(_ value: UInt64, to bytes: inout [UInt8]) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: rest) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    /// Reads unsigned LEB128 values until the bytes end. A value cut short or wider than 64 bits is refused.
    public static func decodeLEB128<Bytes: Swift.Collection>(_ bytes: Bytes) throws -> [UInt64] where Bytes.Element == UInt8 {
        var values: [UInt64] = []
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var open = false
        for byte in bytes {
            guard shift < 64 else { throw invalidBlob("a value is wider than 64 bits") }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                values.append(value)
                (value, shift, open) = (0, 0, false)
            } else {
                shift += 7
                open = true
            }
        }
        guard !open else { throw invalidBlob("its last value is cut short") }
        return values
    }

    /// The `cell_ids` blob: rising cell ids, each written as its difference from the one before, the first from 0.
    public static func encodeCellIDs<Cells: Swift.Sequence>(_ cells: Cells) -> [UInt8] where Cells.Element == UInt32 {
        var bytes: [UInt8] = []
        var previous: UInt32 = 0
        for cell in cells {
            appendLEB128(UInt64(cell - previous), to: &bytes)
            previous = cell
        }
        return bytes
    }

    public static func decodeCellIDs<Bytes: Swift.Collection>(_ bytes: Bytes) throws -> ContiguousArray<UInt32> where Bytes.Element == UInt8 {
        var cells = ContiguousArray<UInt32>()
        var previous: UInt64 = 0
        for delta in try decodeLEB128(bytes) {
            previous += delta
            guard previous <= UInt64(UInt32.max) else { throw invalidBlob("a cell id is past the range of cells") }
            cells.append(UInt32(previous))
        }
        return cells
    }

    /// The `normalised` blob: one little-endian IEEE 754 binary32 a cell.
    public static func encodeFloats<Values: Swift.Sequence>(_ values: Values) -> [UInt8] where Values.Element == Float {
        var bytes: [UInt8] = []
        for value in values {
            let bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: bits) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    public static func decodeFloats<Bytes: Swift.Collection>(_ bytes: Bytes) throws -> ContiguousArray<Float> where Bytes.Element == UInt8 {
        guard bytes.count % 4 == 0 else { throw invalidBlob("its length is not a whole number of float32 values") }
        var values = ContiguousArray<Float>()
        values.reserveCapacity(bytes.count / 4)
        var bits: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            bits |= UInt32(byte) << (8 * UInt32(offset % 4))
            if offset % 4 == 3 {
                values.append(Float(bitPattern: bits))
                bits = 0
            }
        }
        return values
    }

    /// The normalised value of 5.5 G1: the float32 rounding of the Double `log1p((umis / cellUMIs) * 10000)`, a division,
    /// then a multiplication, then the natural `log1p`, the order of Seurat 5.5.1's `LogNorm` that CM-TRUTH read.
    public static func normalised(umis: UInt64, cellUMIs: UInt64) -> Float {
        Float(log1p((Double(umis) / Double(cellUMIs)) * 10_000))
    }

    // MARK: - Bounds

    /// The nearest rank of the 99th percentile over `cells` values, `ceil(0.99 × cells)` counted from 1, in whole numbers
    /// so no rounding of 0.99 moves it.
    public static func p99Rank(cells: Int) -> Int {
        (99 * cells + 99) / 100
    }

    /// The minimum, maximum and nearest-rank p99 over `cells` cells, of which only those in `nonZero` hold a value and
    /// every other cell holds 0 (`docs/formats/rnaseq-cell-map.md`, Bounds). Nothing is interpolated.
    public static func bounds<Value: Comparable & Numeric>(nonZero: [Value], cells: Int) -> (minimum: Value, maximum: Value, p99: Value) {
        guard !nonZero.isEmpty, cells > 0 else { return (0, 0, 0) }
        let sorted = nonZero.sorted()
        let zeros = cells - sorted.count
        let rank = p99Rank(cells: cells)
        let p99 = rank <= zeros ? 0 : sorted[min(sorted.count, rank - zeros) - 1]
        return (zeros > 0 ? 0 : sorted[0], sorted[sorted.count - 1], p99)
    }

    // MARK: - Labels

    /// Code-point order, which UTF-8 byte order equals, as pseudobulk orders labels.
    public static func codePointOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// The label order of a set (`docs/formats/rnaseq-cell-map.md`, Labels). When every label is a decimal integer the
    /// labels go in numeric order, with code-point order between two that read as the same number, such as `1` and `01`.
    /// Otherwise they go in code-point order. Duplicates are dropped.
    public static func labelOrder(_ names: [String]) -> [String] {
        let unique = Array(Set(names))
        func digits(_ text: String) -> (negative: Bool, digits: Substring)? {
            let negative = text.hasPrefix("-")
            let body = negative ? text.dropFirst() : Substring(text)
            guard !body.isEmpty, body.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            let trimmed = body.drop { $0 == "0" }
            return (negative && !trimmed.isEmpty, trimmed)
        }
        let numbers = unique.map(digits)
        guard !unique.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return unique.sorted(by: codePointOrder) }
        func numericLess(_ a: (negative: Bool, digits: Substring), _ b: (negative: Bool, digits: Substring)) -> Bool? {
            if a.negative != b.negative { return a.negative }
            guard a.digits.count != b.digits.count || a.digits != b.digits else { return nil }
            let less = a.digits.count != b.digits.count ? a.digits.count < b.digits.count : a.digits.utf8.lexicographicallyPrecedes(b.digits.utf8)
            return a.negative ? !less : less
        }
        return zip(unique, numbers).sorted { left, right in
            numericLess(left.1!, right.1!) ?? codePointOrder(left.0, right.0)
        }.map(\.0)
    }

    /// The file name of a label set's table: each character outside `A`-`Z`, `a`-`z`, `0`-`9`, `.`, `_` and `-` written
    /// as `_`, and a leading `.` written as `_`.
    public static func labelTableFileName(_ setName: String) -> String {
        var name = String(setName.map { character -> Character in
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.isASCII else { return "_" }
            let value = scalar.value
            let plain = (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 46 || value == 95 || value == 45
            return plain ? character : "_"
        })
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name + ".tsv"
    }

    /// The one serializer of a label table: UTF-8 with no byte-order mark, the header, then one line a row in the order
    /// given, every line ending in one LF, nothing quoted.
    public static func labelTableData(_ rows: [(sample: String, barcode: String, label: String)]) -> Data {
        var text = labelTableHeader + "\n"
        for row in rows { text += "\(row.sample)\t\(row.barcode)\t\(row.label)\n" }
        return Data(text.utf8)
    }

    static func invalidBlob(_ reason: String) -> RNASeqResultError {
        .invalidTable(path: filename, reason: "a gene_values blob cannot be read, \(reason)")
    }
}

/// Writes `cellmap.sqlite` in a cell map's stage. Every row goes in one transaction, and the default rollback journal and
/// full sync make the commit durable before the stage is renamed into place.
public final class RNASeqCellMapDatabaseWriter {
    public enum Value {
        case int(Int64), real(Double), text(String), blob([UInt8]), null
    }

    private var db: OpaquePointer?

    /// Creates `url`, which must not exist, with the tables of schema 1 and an open transaction.
    public init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Self.failure("it already exists") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Self.failure("SQLite could not create it")
        }
        db = handle
        do {
            for statement in RNASeqCellMap.schema + ["BEGIN"] { try exec(statement) }
            try setMeta("schema_version", String(RNASeqCellMap.currentSchemaVersion))
            try setMeta("normalisation", RNASeqCellMap.normalisationFormula)
        } catch {
            abandon()
            throw error
        }
    }

    deinit { abandon() }

    public func setMeta(_ key: String, _ value: String) throws {
        try insert("meta", ["key", "value"], rows: 1) { _ in [.text(key), .text(value)] }
    }

    public func addSamples(_ rows: [(sample: Int, name: String, cells: Int)]) throws {
        try insert("samples", ["sample", "name", "cells"], rows: rows.count) { [.int(Int64(rows[$0].sample)), .text(rows[$0].name), .int(Int64(rows[$0].cells))] }
    }

    /// One row a cell of the parent, numbered from `firstCell`.
    public func addCells(firstCell: Int, samples: [Int32], barcodes: [String], umis: [UInt64], genes: [UInt32]) throws {
        try insert("cells", ["cell", "sample", "barcode", "umis", "genes"], rows: barcodes.count) { index in
            [.int(Int64(firstCell + index)), .int(Int64(samples[index])), .text(barcodes[index]), .int(Int64(umis[index])), .int(Int64(genes[index]))]
        }
    }

    /// One row a feature of the parent, as its `features` table holds it.
    public func addFeatures(_ rows: [(feature: Int, id: String, name: String, type: String, total: Int, cells: Int)]) throws {
        try insert("features", ["feature", "id", "name", "type", "total", "cells"], rows: rows.count) { index in
            let row = rows[index]
            return [.int(Int64(row.feature)), .text(row.id), .text(row.name), .text(row.type), .int(Int64(row.total)), .int(Int64(row.cells))]
        }
    }

    public func addEmbedding(_ embedding: Int, name: String, dimensions: Int, method: String?, source: String, sourceFile: String, otherCounts: Bool, cells: Int) throws {
        try insert("embeddings", ["embedding", "name", "dimensions", "method", "source", "source_file", "other_counts", "cells"], rows: 1) { _ in
            [.int(Int64(embedding)), .text(name), .int(Int64(dimensions)), method.map { .text($0) } ?? .null, .text(source), .text(sourceFile),
             .int(otherCounts ? 1 : 0), .int(Int64(cells))]
        }
    }

    public func addEmbeddingCells(_ embedding: Int, sample: Int, drawn: Int, leftOut: Int) throws {
        try insert("embedding_cells", ["embedding", "sample", "drawn", "left_out"], rows: 1) { _ in
            [.int(Int64(embedding)), .int(Int64(sample)), .int(Int64(drawn)), .int(Int64(leftOut))]
        }
    }

    /// One dimension of an embedding, a value for each cell in `cells`, in cell order.
    public func addCoordinates(_ embedding: Int, dimension: Int, cells: [Int32], values: (Int) -> Double) throws {
        try insert("coordinates", ["embedding", "dimension", "cell", "value"], rows: cells.count) { index in
            [.int(Int64(embedding)), .int(Int64(dimension)), .int(Int64(cells[index])), .real(values(index))]
        }
    }

    public func addLabelSet(_ labelSet: Int, name: String, source: String, sourceFile: String, labels: [(name: String, cells: Int)], table: String) throws {
        try insert("label_sets", ["label_set", "name", "source", "source_file", "labels", "\"table\""], rows: 1) { _ in
            [.int(Int64(labelSet)), .text(name), .text(source), .text(sourceFile), .int(Int64(labels.count)), .text(table)]
        }
        try insert("labels", ["label_set", "label", "name", "cells"], rows: labels.count) { index in
            [.int(Int64(labelSet)), .int(Int64(index + 1)), .text(labels[index].name), .int(Int64(labels[index].cells))]
        }
    }

    public func addLabelCount(_ labelSet: Int, label: Int, sample: Int, cells: Int) throws {
        try insert("label_counts", ["label_set", "label", "sample", "cells"], rows: 1) { _ in
            [.int(Int64(labelSet)), .int(Int64(label)), .int(Int64(sample)), .int(Int64(cells))]
        }
    }

    public func addLabelSetSample(_ labelSet: Int, sample: Int, labelled: Int, unlabelled: Int) throws {
        try insert("label_set_samples", ["label_set", "sample", "labelled", "unlabelled"], rows: 1) { _ in
            [.int(Int64(labelSet)), .int(Int64(sample)), .int(Int64(labelled)), .int(Int64(unlabelled))]
        }
    }

    public func addCellLabels(_ labelSet: Int, cells: [Int32], labels: [Int32]) throws {
        try insert("cell_labels", ["label_set", "cell", "label"], rows: cells.count) { index in
            [.int(Int64(labelSet)), .int(Int64(cells[index])), .int(Int64(labels[index]))]
        }
    }

    public struct GeneValuesRow {
        public var feature: Int
        public var cells: Int
        public var cellIDs: [UInt8]
        public var umis: [UInt8]
        public var normalised: [UInt8]
        public var umisBounds: (minimum: UInt64, maximum: UInt64, p99: UInt64)
        public var normalisedBounds: (minimum: Float, maximum: Float, p99: Float)

        public init(feature: Int, cells: Int, cellIDs: [UInt8], umis: [UInt8], normalised: [UInt8],
                    umisBounds: (minimum: UInt64, maximum: UInt64, p99: UInt64), normalisedBounds: (minimum: Float, maximum: Float, p99: Float)) {
            (self.feature, self.cells, self.cellIDs, self.umis, self.normalised) = (feature, cells, cellIDs, umis, normalised)
            (self.umisBounds, self.normalisedBounds) = (umisBounds, normalisedBounds)
        }
    }

    public func addGeneValues(_ row: GeneValuesRow) throws {
        let columns = ["feature", "cells", "cell_ids", "umis", "normalised", "umis_minimum", "umis_maximum", "umis_p99",
                       "normalised_minimum", "normalised_maximum", "normalised_p99"]
        try insert("gene_values", columns, rows: 1) { _ in
            [.int(Int64(row.feature)), .int(Int64(row.cells)), .blob(row.cellIDs), .blob(row.umis), .blob(row.normalised),
             .int(Int64(row.umisBounds.minimum)), .int(Int64(row.umisBounds.maximum)), .int(Int64(row.umisBounds.p99)),
             .real(Double(row.normalisedBounds.minimum)), .real(Double(row.normalisedBounds.maximum)), .real(Double(row.normalisedBounds.p99))]
        }
    }

    public func addNotHostExtra(_ extra: Int, name: String, kind: String) throws {
        try insert("not_host_extras", ["extra", "name", "kind"], rows: 1) { _ in [.int(Int64(extra)), .text(name), .text(kind)] }
    }

    public func addCellNotHost(cell: Int, extra: Int, umis: Int, flag: String) throws {
        try insert("cell_not_host", ["cell", "extra", "umis", "flag"], rows: 1) { _ in
            [.int(Int64(cell)), .int(Int64(extra)), .int(Int64(umis)), .text(flag)]
        }
    }

    public func addFlagCount(extra: Int, sample: Int, flag: String, cells: Int) throws {
        try insert("flag_counts", ["extra", "sample", "flag", "cells"], rows: 1) { _ in
            [.int(Int64(extra)), .int(Int64(sample)), .text(flag), .int(Int64(cells))]
        }
    }

    public func addValueBounds(_ value: String, extra: Int, minimum: Double, maximum: Double, p99: Double) throws {
        try insert("value_bounds", ["value", "extra", "minimum", "maximum", "p99"], rows: 1) { _ in
            [.text(value), .int(Int64(extra)), .real(minimum), .real(maximum), .real(p99)]
        }
    }

    /// Commits and closes the file.
    public func finish() throws {
        try exec("COMMIT")
        guard sqlite3_close(db) == SQLITE_OK else { throw Self.failure("SQLite could not close it") }
        db = nil
    }

    /// Closes the file without a commit. The caller removes the stage that holds it.
    public func abandon() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    private static func failure(_ reason: String) -> RNASeqResultError {
        .unreadableFile(path: RNASeqCellMap.filename, reason: reason)
    }

    private func exec(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Self.failure(db.map { String(cString: sqlite3_errmsg($0)) } ?? "it is closed")
        }
    }

    private func insert(_ table: String, _ columns: [String], rows: Int, _ row: (Int) -> [Value]) throws {
        guard let db else { throw Self.failure("it is closed") }
        let sql = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.failure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for index in 0..<rows {
            for (position, value) in row(index).enumerated() {
                let column = Int32(position + 1)
                switch value {
                case .int(let number): sqlite3_bind_int64(statement, column, number)
                case .real(let number): sqlite3_bind_double(statement, column, number)
                case .text(let text): sqlite3_bind_text(statement, column, text, -1, sqliteTransientDestructor)
                case .blob(let bytes):
                    // An empty blob binds as a zero-length blob and never as NULL.
                    bytes.withUnsafeBytes { buffer in
                        _ = sqlite3_bind_blob(statement, column, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buffer.count), sqliteTransientDestructor)
                    }
                case .null: sqlite3_bind_null(statement, column)
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.failure(String(cString: sqlite3_errmsg(db))) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }
}
