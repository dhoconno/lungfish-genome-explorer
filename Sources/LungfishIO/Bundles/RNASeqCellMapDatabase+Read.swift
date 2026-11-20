// RNASeqCellMapDatabase+Read.swift - The read-only side of a cell map's cellmap.sqlite (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The reader is a `Sendable` value that holds only the file's URL. Each call opens its own read-only handle and closes it
// before it returns, so no handle crosses threads (SWIFT OBJECT 3). A long read checks for cancellation inside its step
// loop and throws `CancellationError`, and nothing calls `sqlite3_interrupt` on a shared handle. Reading never writes into
// the project, and a file whose `meta` schema is newer than this reader knows is refused with the manifest's words, as a
// newer `cells.sqlite` is (`docs/formats/rnaseq-cell-map.md`, Schemas 1 and 2).

import Foundation
import SQLite3

public struct RNASeqCellMapDatabase: Sendable {
    public struct Sample: Equatable, Sendable {
        public var sample: Int, name: String, cells: Int
    }

    public struct Cell: Equatable, Sendable {
        public var cell: Int, sample: Int, barcode: String, umis: Int, genes: Int
    }

    /// A feature of the parent, of any type. Only a feature of type Gene Expression has a `gene_values` row.
    public struct Feature: Equatable, Sendable {
        public var feature: Int, id: String, name: String, type: String, total: Int, cells: Int
    }

    public struct Embedding: Equatable, Sendable {
        public var embedding: Int, name: String, dimensions: Int, method: String?, source: String, sourceFile: String
        public var otherCounts: Bool, cells: Int
    }

    public struct EmbeddingCells: Equatable, Sendable {
        public var embedding: Int, sample: Int, drawn: Int, leftOut: Int
    }

    public struct Label: Equatable, Sendable {
        public var label: Int, name: String, cells: Int
    }

    public struct LabelCount: Equatable, Sendable {
        public var label: Int, sample: Int, cells: Int
    }

    public struct LabelSetSample: Equatable, Sendable {
        public var sample: Int, labelled: Int, unlabelled: Int
    }

    /// A label set with its counts as stored. The legend reads these and counts nothing.
    public struct LabelSet: Equatable, Sendable {
        public var labelSet: Int, name: String, source: String, sourceFile: String, table: String
        public var labels: [Label]
        public var counts: [LabelCount]
        public var samples: [LabelSetSample]
    }

    public enum GeneUnit: String, Sendable, CaseIterable { case umis, normalised }

    /// One gene's cells with a count, rising, and their values in the unit asked, with that unit's bounds over every cell
    /// of the map, zeros included.
    public struct GeneValues: Equatable, Sendable {
        public enum Values: Equatable, Sendable {
            case umis(ContiguousArray<UInt32>)
            case normalised(ContiguousArray<Float32>)
        }

        public var feature: Int
        public var cells: ContiguousArray<UInt32>
        public var values: Values
        public var minimum: Double, maximum: Double, p99: Double

        /// The values as Float32 for drawing. A UMI count is a whole number, which Float32 holds exactly below 2^24.
        public var floats: ContiguousArray<Float32> {
            switch values {
            case .umis(let umis): return ContiguousArray(umis.map { Float32($0) })
            case .normalised(let values): return values
            }
        }
    }

    public struct ValueBound: Equatable, Sendable {
        public var value: String, extra: Int, minimum: Double, maximum: Double, p99: Double
    }

    public struct NotHostExtra: Equatable, Sendable {
        public var extra: Int, name: String, kind: String
    }

    public struct CellNotHost: Equatable, Sendable {
        public var cell: Int, extra: Int, umis: Int, flag: String
    }

    public struct FlagCount: Equatable, Sendable {
        public var extra: Int, sample: Int, flag: String, cells: Int
    }

    public let url: URL
    public let schemaVersion: Int

    /// Opens `url` once to read its `meta` schema, which must be one this reader knows, and closes it.
    public init(url: URL) throws {
        self.url = url
        let found = try Self.withHandle(url) { db in
            try Self.rows(db, "SELECT value FROM meta WHERE key = 'schema_version'", []) { Self.text($0, 0) }
        }
        guard let text = found.first, let version = Int(text) else {
            throw RNASeqResultError.unreadableFile(path: RNASeqCellMap.filename, reason: "its meta table holds no schema_version")
        }
        guard version <= RNASeqCellMap.currentSchemaVersion else { throw RNASeqResultError.newerSchema(version) }
        schemaVersion = version
    }

    public func meta() throws -> [String: String] {
        Dictionary(try query("SELECT key, value FROM meta") { (Self.text($0, 0), Self.text($0, 1)) }, uniquingKeysWith: { first, _ in first })
    }

    public func samples() throws -> [Sample] {
        try query("SELECT sample, name, cells FROM samples ORDER BY sample") { Sample(sample: Self.int($0, 0), name: Self.text($0, 1), cells: Self.int($0, 2)) }
    }

    /// Every cell of the parent, the cells of the map.
    public func cellCount() throws -> Int {
        try query("SELECT count(*) FROM cells") { Self.int($0, 0) }.first ?? 0
    }

    /// One cell by its id, for hover. Nil for an id the map does not hold.
    public func cell(id: Int) throws -> Cell? {
        try query("SELECT cell, sample, barcode, umis, genes FROM cells WHERE cell = ?", [.int(Int64(id))]) {
            Cell(cell: Self.int($0, 0), sample: Self.int($0, 1), barcode: Self.text($0, 2), umis: Self.int($0, 3), genes: Self.int($0, 4))
        }.first
    }

    /// The UMIs and genes of every cell in cell order, from one ordered read of `cells` (5.5 V4), so the view colours by
    /// either without a read for each cell. A cell the table does not hold reads 0.
    public func cellTotals() throws -> (umis: ContiguousArray<UInt32>, genes: ContiguousArray<UInt32>) {
        try Self.withHandle(url) { db in
            let count = try Self.rows(db, "SELECT count(*) FROM cells", []) { Self.int($0, 0) }.first ?? 0
            var umis = ContiguousArray<UInt32>(repeating: 0, count: count)
            var genes = ContiguousArray<UInt32>(repeating: 0, count: count)
            try Self.step(db, "SELECT cell, umis, genes FROM cells ORDER BY cell", []) { statement in
                let cell = Self.int(statement, 0)
                guard cell >= 1, cell <= count else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: "the cells table names the cell \(cell), which the map does not hold")
                }
                umis[cell - 1] = UInt32(clamping: Self.int(statement, 1))
                genes[cell - 1] = UInt32(clamping: Self.int(statement, 2))
            }
            return (umis, genes)
        }
    }

    /// Every feature of the parent in feature order, which the gene picker lists by id and by name.
    public func features() throws -> [Feature] {
        try query("SELECT feature, id, name, type, total, cells FROM features ORDER BY feature") {
            Feature(feature: Self.int($0, 0), id: Self.text($0, 1), name: Self.text($0, 2), type: Self.text($0, 3), total: Self.int($0, 4), cells: Self.int($0, 5))
        }
    }

    public func embeddings() throws -> [Embedding] {
        try query("SELECT embedding, name, dimensions, method, source, source_file, other_counts, cells FROM embeddings ORDER BY embedding") {
            Embedding(embedding: Self.int($0, 0), name: Self.text($0, 1), dimensions: Self.int($0, 2), method: Self.optionalText($0, 3),
                      source: Self.text($0, 4), sourceFile: Self.text($0, 5), otherCounts: Self.int($0, 6) != 0, cells: Self.int($0, 7))
        }
    }

    public func embeddingCells() throws -> [EmbeddingCells] {
        try query("SELECT embedding, sample, drawn, left_out FROM embedding_cells ORDER BY embedding, sample") {
            EmbeddingCells(embedding: Self.int($0, 0), sample: Self.int($0, 1), drawn: Self.int($0, 2), leftOut: Self.int($0, 3))
        }
    }

    /// Dimensions 1 and 2 of `embedding` in one ordered read, as Float32 in cell order, NaN for a cell left out (5.5 V4).
    /// Each REAL is converted once by `Float(_:)`, round to nearest.
    public func coordinates(embedding: Int) throws -> (x: ContiguousArray<Float32>, y: ContiguousArray<Float32>) {
        try Self.withHandle(url) { db in
            let count = try Self.rows(db, "SELECT count(*) FROM cells", []) { Self.int($0, 0) }.first ?? 0
            var x = ContiguousArray<Float32>(repeating: .nan, count: count)
            var y = ContiguousArray<Float32>(repeating: .nan, count: count)
            try Self.step(db, "SELECT dimension, cell, value FROM coordinates WHERE embedding = ? AND dimension <= 2 ORDER BY dimension, cell",
                          [.int(Int64(embedding))]) { statement in
                let cell = Self.int(statement, 1)
                guard cell >= 1, cell <= count else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: "the coordinates name the cell \(cell), which the map does not hold")
                }
                let value = Float32(sqlite3_column_double(statement, 2))
                if Self.int(statement, 0) == 1 { x[cell - 1] = value } else { y[cell - 1] = value }
            }
            return (x, y)
        }
    }

    public func labelSets() throws -> [LabelSet] {
        try Self.withHandle(url) { db in
            let sets = try Self.rows(db, "SELECT label_set, name, source, source_file, \"table\" FROM label_sets ORDER BY label_set", []) {
                LabelSet(labelSet: Self.int($0, 0), name: Self.text($0, 1), source: Self.text($0, 2), sourceFile: Self.text($0, 3), table: Self.text($0, 4),
                         labels: [], counts: [], samples: [])
            }
            return try sets.map { found in
                var set = found
                let key: [RNASeqCellMapDatabaseWriter.Value] = [.int(Int64(set.labelSet))]
                set.labels = try Self.rows(db, "SELECT label, name, cells FROM labels WHERE label_set = ? ORDER BY label", key) {
                    Label(label: Self.int($0, 0), name: Self.text($0, 1), cells: Self.int($0, 2))
                }
                set.counts = try Self.rows(db, "SELECT label, sample, cells FROM label_counts WHERE label_set = ? ORDER BY label, sample", key) {
                    LabelCount(label: Self.int($0, 0), sample: Self.int($0, 1), cells: Self.int($0, 2))
                }
                set.samples = try Self.rows(db, "SELECT sample, labelled, unlabelled FROM label_set_samples WHERE label_set = ? ORDER BY sample", key) {
                    LabelSetSample(sample: Self.int($0, 0), labelled: Self.int($0, 1), unlabelled: Self.int($0, 2))
                }
                return set
            }
        }
    }

    /// The label of every cell of `labelSet` in cell order, 0 for a cell with no label in the set.
    public func cellLabels(labelSet: Int) throws -> ContiguousArray<UInt32> {
        try Self.withHandle(url) { db in
            let count = try Self.rows(db, "SELECT count(*) FROM cells", []) { Self.int($0, 0) }.first ?? 0
            var labels = ContiguousArray<UInt32>(repeating: 0, count: count)
            try Self.step(db, "SELECT cell, label FROM cell_labels WHERE label_set = ? ORDER BY cell", [.int(Int64(labelSet))]) { statement in
                let cell = Self.int(statement, 0)
                guard cell >= 1, cell <= count else {
                    throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: "a label names the cell \(cell), which the map does not hold")
                }
                labels[cell - 1] = UInt32(clamping: Self.int(statement, 1))
            }
            return labels
        }
    }

    /// The one row of `feature`, its cells and the blob of `unit` decoded, with that unit's bounds. Nil when the map holds
    /// no row for the feature, as for a feature of a type other than Gene Expression (5.5 G1).
    public func geneValues(feature: Int, unit: GeneUnit) throws -> GeneValues? {
        let blob = unit == .umis ? "umis" : "normalised"
        let sql = "SELECT cells, cell_ids, \(blob), \(blob)_minimum, \(blob)_maximum, \(blob)_p99 FROM gene_values WHERE feature = ?"
        let found = try query(sql, [.int(Int64(feature))]) { statement -> (Int, [UInt8], [UInt8], Double, Double, Double) in
            (Self.int(statement, 0), Self.blob(statement, 1), Self.blob(statement, 2),
             sqlite3_column_double(statement, 3), sqlite3_column_double(statement, 4), sqlite3_column_double(statement, 5))
        }
        guard let row = found.first else { return nil }
        let cells = try RNASeqCellMap.decodeCellIDs(row.1)
        let values: GeneValues.Values
        switch unit {
        case .umis:
            values = .umis(ContiguousArray(try RNASeqCellMap.decodeLEB128(row.2).map { value -> UInt32 in
                guard value <= UInt64(UInt32.max) else { throw RNASeqCellMap.invalidBlob("a UMI count is past 32 bits") }
                return UInt32(value)
            }))
        case .normalised:
            values = .normalised(try RNASeqCellMap.decodeFloats(row.2))
        }
        let valueCount: Int
        switch values {
        case .umis(let umis): valueCount = umis.count
        case .normalised(let floats): valueCount = floats.count
        }
        guard cells.count == row.0, valueCount == row.0 else {
            throw RNASeqCellMap.invalidBlob("feature \(feature) lists \(row.0) cells and its blobs hold \(cells.count) ids and \(valueCount) values")
        }
        return GeneValues(feature: feature, cells: cells, values: values, minimum: row.3, maximum: row.4, p99: row.5)
    }

    /// The features with a `gene_values` row, rising.
    public func geneValueFeatures() throws -> [Int] {
        try query("SELECT feature FROM gene_values ORDER BY feature") { Self.int($0, 0) }
    }

    public func valueBounds() throws -> [ValueBound] {
        try query("SELECT value, extra, minimum, maximum, p99 FROM value_bounds ORDER BY value, extra") {
            ValueBound(value: Self.text($0, 0), extra: Self.int($0, 1), minimum: sqlite3_column_double($0, 2),
                       maximum: sqlite3_column_double($0, 3), p99: sqlite3_column_double($0, 4))
        }
    }

    public func notHostExtras() throws -> [NotHostExtra] {
        try query("SELECT extra, name, kind FROM not_host_extras ORDER BY extra") { NotHostExtra(extra: Self.int($0, 0), name: Self.text($0, 1), kind: Self.text($0, 2)) }
    }

    /// The rows of `extra`, in cell order. A cell without a row reads 0 and not flagged.
    public func cellNotHost(extra: Int) throws -> [CellNotHost] {
        try query("SELECT cell, extra, umis, flag FROM cell_not_host WHERE extra = ? ORDER BY cell", [.int(Int64(extra))]) {
            CellNotHost(cell: Self.int($0, 0), extra: Self.int($0, 1), umis: Self.int($0, 2), flag: Self.text($0, 3))
        }
    }

    public func flagCounts() throws -> [FlagCount] {
        try query("SELECT extra, sample, flag, cells FROM flag_counts ORDER BY extra, sample, flag") {
            FlagCount(extra: Self.int($0, 0), sample: Self.int($0, 1), flag: Self.text($0, 2), cells: Self.int($0, 3))
        }
    }

    // MARK: - One handle a call

    private func query<T>(_ sql: String, _ bindings: [RNASeqCellMapDatabaseWriter.Value] = [], _ make: (OpaquePointer) throws -> T) throws -> [T] {
        try Self.withHandle(url) { try Self.rows($0, sql, bindings, make) }
    }

    static func withHandle<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw RNASeqResultError.unreadableFile(path: RNASeqCellMap.filename, reason: "SQLite could not open it")
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    static func rows<T>(_ db: OpaquePointer, _ sql: String, _ bindings: [RNASeqCellMapDatabaseWriter.Value], _ make: (OpaquePointer) throws -> T) throws -> [T] {
        var found: [T] = []
        try step(db, sql, bindings) { found.append(try make($0)) }
        return found
    }

    /// Runs `sql` and hands each row to `row`. Every 4,096 rows it checks for cancellation, so a superseded read stops at
    /// its next check on its own handle.
    static func step(_ db: OpaquePointer, _ sql: String, _ bindings: [RNASeqCellMapDatabaseWriter.Value], _ row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RNASeqResultError.unreadableFile(path: RNASeqCellMap.filename, reason: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (position, value) in bindings.enumerated() {
            let column = Int32(position + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, column, number)
            case .real(let number): sqlite3_bind_double(statement, column, number)
            case .text(let text): sqlite3_bind_text(statement, column, text, -1, sqliteTransientDestructor)
            case .blob, .null: sqlite3_bind_null(statement, column)
            }
        }
        var count = 0
        while true {
            if count & 0xFFF == 0 { try Task.checkCancellation() }
            count += 1
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else {
                throw RNASeqResultError.unreadableFile(path: RNASeqCellMap.filename, reason: String(cString: sqlite3_errmsg(db)))
            }
            try row(statement)
        }
    }

    static func int(_ statement: OpaquePointer, _ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) -> [UInt8] {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let base = sqlite3_column_blob(statement, column) else { return [] }
        return Array(UnsafeRawBufferPointer(start: base, count: count))
    }
}
