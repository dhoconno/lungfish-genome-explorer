// RNASeqCellsDatabase.swift - The read-only side of a single-cell result's cells.sqlite (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `cells.sqlite` is the per-cell summary of one streaming pass over each matrix of a `.lungfishrnaseq` result, which the
// tables page from (`docs/formats/rnaseq-bundle.md`, Single cell). Schema 1 holds `meta`, `samples`, `cells`, `features`,
// `genomes` and `cell_genomes`, and schema 2 adds the not-host tables of lane RS-NOTHOST, which a schema 1 file reads as
// empty. The file opens read only, so reading never writes into the project, and a file whose `meta` schema is newer
// than this reader knows is refused with the manifest's words. `RNASeqCellsDatabaseWriter` writes it.

import Foundation
import SQLite3

public final class RNASeqCellsDatabase {
    public static let filename = "cells.sqlite"
    public static let currentSchemaVersion = 2

    public struct Sample: Equatable, Sendable {
        public var sample: Int
        public var name: String
        public var matrix: String
        public var cells: Int
        public var features: Int
        public var entries: Int
    }

    public struct Cell: Equatable, Sendable {
        public var cell: Int
        public var sample: Int
        public var column: Int
        public var barcode: String
        public var umis: Int
        public var genes: Int
    }

    public struct Feature: Equatable, Sendable {
        public var feature: Int
        public var id: String
        public var name: String
        public var type: String
        public var genome: Int?
        public var total: Int
        public var cells: Int
    }

    public struct CellGenome: Equatable, Sendable {
        public var cell: Int
        public var genome: Int
        public var umis: Int
        public var genes: Int
    }

    // Schema 2: the not-host pass of `docs/formats/rnaseq-bundle.md`, Not-host RNA. A record of 0 is the extra's figure
    // over its records.

    public struct NotHostExtra: Equatable, Sendable {
        public var extra: Int, name: String, kind: String, mask: String?, maskWords: String
        public init(extra: Int, name: String, kind: String, mask: String?, maskWords: String) {
            (self.extra, self.name, self.kind, self.mask, self.maskWords) = (extra, name, kind, mask, maskWords)
        }
    }

    public struct NotHostRecord: Equatable, Sendable {
        public var record: Int, extra: Int, name: String, length: Int
        public init(record: Int, extra: Int, name: String, length: Int) {
            (self.record, self.extra, self.name, self.length) = (record, extra, name, length)
        }
    }

    public struct AmbientPool: Equatable, Sendable {
        public var sample: Int, barcodesWithUMI: Int, poolBarcodes: Int, firstRank: Int?, lastRank: Int?
        public var umiMin: Int?, umiMax: Int?, umis: Int, words: String
        public init(sample: Int, barcodesWithUMI: Int, poolBarcodes: Int, firstRank: Int?, lastRank: Int?, umiMin: Int?, umiMax: Int?, umis: Int, words: String) {
            (self.sample, self.barcodesWithUMI, self.poolBarcodes, self.firstRank, self.lastRank) = (sample, barcodesWithUMI, poolBarcodes, firstRank, lastRank)
            (self.umiMin, self.umiMax, self.umis, self.words) = (umiMin, umiMax, umis, words)
        }
    }

    public struct AmbientPoolCount: Equatable, Sendable {
        public var sample: Int, extra: Int, record: Int, umis: Int, maskedUMIs: Int, rate: Double?
        public init(sample: Int, extra: Int, record: Int, umis: Int, maskedUMIs: Int, rate: Double?) {
            (self.sample, self.extra, self.record, self.umis, self.maskedUMIs, self.rate) = (sample, extra, record, umis, maskedUMIs, rate)
        }
    }

    public struct NotHostBarcode: Equatable, Sendable {
        public var sample: Int, barcode: String, cell: Int?, rawUMIs: Int, inPool: Bool
        public init(sample: Int, barcode: String, cell: Int?, rawUMIs: Int, inPool: Bool) {
            (self.sample, self.barcode, self.cell, self.rawUMIs, self.inPool) = (sample, barcode, cell, rawUMIs, inPool)
        }
    }

    public struct NotHostCount: Equatable, Sendable {
        public var sample: Int, barcode: String, extra: Int, record: Int, umis: Int, maskedUMIs: Int, umisNM01: Int, maskedUMIsNM01: Int
        public init(sample: Int, barcode: String, extra: Int, record: Int, umis: Int, maskedUMIs: Int, umisNM01: Int, maskedUMIsNM01: Int) {
            (self.sample, self.barcode, self.extra, self.record) = (sample, barcode, extra, record)
            (self.umis, self.maskedUMIs, self.umisNM01, self.maskedUMIsNM01) = (umis, maskedUMIs, umisNM01, maskedUMIsNM01)
        }
    }

    public struct NotHostCall: Equatable, Sendable {
        public var sample: Int, extra: Int, cell: Int, p: Double?, q: Double?, flag: String
        public init(sample: Int, extra: Int, cell: Int, p: Double?, q: Double?, flag: String) {
            (self.sample, self.extra, self.cell, self.p, self.q, self.flag) = (sample, extra, cell, p, q, flag)
        }
    }

    private var db: OpaquePointer?
    public let schemaVersion: Int

    public init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw RNASeqResultError.unreadableFile(path: Self.filename, reason: "SQLite could not open it")
        }
        db = handle
        let version: Int
        do {
            let found = try Self.rows(handle, "SELECT value FROM meta WHERE key = 'schema_version'") { Self.text($0, 0) }
            guard let text = found.first, let number = Int(text) else {
                throw RNASeqResultError.unreadableFile(path: Self.filename, reason: "its meta table holds no schema_version")
            }
            version = number
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
        guard version <= Self.currentSchemaVersion else {
            sqlite3_close(handle)
            db = nil
            throw RNASeqResultError.newerSchema(version)
        }
        schemaVersion = version
    }

    deinit { sqlite3_close(db) }

    public func meta() throws -> [String: String] {
        Dictionary(try query("SELECT key, value FROM meta") { (Self.text($0, 0), Self.text($0, 1)) }, uniquingKeysWith: { first, _ in first })
    }

    public func samples() throws -> [Sample] {
        try query("SELECT sample, name, matrix, cells, features, entries FROM samples ORDER BY sample") {
            Sample(sample: Self.int($0, 0), name: Self.text($0, 1), matrix: Self.text($0, 2),
                   cells: Self.int($0, 3), features: Self.int($0, 4), entries: Self.int($0, 5))
        }
    }

    public func cellCount() throws -> Int {
        try query("SELECT count(*) FROM cells") { Self.int($0, 0) }.first ?? 0
    }

    /// Cells in the order of their `cell` number, a page at a time.
    public func cells(offset: Int, limit: Int) throws -> [Cell] {
        try query("SELECT cell, sample, \"column\", barcode, umis, genes FROM cells ORDER BY cell LIMIT \(max(0, limit)) OFFSET \(max(0, offset))") {
            Cell(cell: Self.int($0, 0), sample: Self.int($0, 1), column: Self.int($0, 2), barcode: Self.text($0, 3),
                 umis: Self.int($0, 4), genes: Self.int($0, 5))
        }
    }

    public func features() throws -> [Feature] {
        try query("SELECT feature, id, name, type, genome, total, cells FROM features ORDER BY feature") {
            Feature(feature: Self.int($0, 0), id: Self.text($0, 1), name: Self.text($0, 2), type: Self.text($0, 3),
                    genome: sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : Self.int($0, 4),
                    total: Self.int($0, 5), cells: Self.int($0, 6))
        }
    }

    /// The genomes the person named, in the order of their numbers.
    public func genomes() throws -> [String] {
        try query("SELECT name FROM genomes ORDER BY genome") { Self.text($0, 0) }
    }

    public func cellGenomes() throws -> [CellGenome] {
        try query("SELECT cell, genome, umis, genes FROM cell_genomes ORDER BY cell, genome") {
            CellGenome(cell: Self.int($0, 0), genome: Self.int($0, 1), umis: Self.int($0, 2), genes: Self.int($0, 3))
        }
    }

    /// The not-host tables, each empty in a schema 1 file, which has none of them.
    public func notHostExtras() throws -> [NotHostExtra] {
        try schema2("SELECT extra, name, kind, mask, mask_words FROM not_host_extras ORDER BY extra") {
            NotHostExtra(extra: Self.int($0, 0), name: Self.text($0, 1), kind: Self.text($0, 2), mask: Self.optionalText($0, 3), maskWords: Self.text($0, 4))
        }
    }

    public func notHostRecords() throws -> [NotHostRecord] {
        try schema2("SELECT record, extra, name, length FROM not_host_records ORDER BY record") {
            NotHostRecord(record: Self.int($0, 0), extra: Self.int($0, 1), name: Self.text($0, 2), length: Self.int($0, 3))
        }
    }

    public func ambientPools() throws -> [AmbientPool] {
        try schema2("SELECT sample, barcodes_with_umi, pool_barcodes, first_rank, last_rank, umi_min, umi_max, umis, words FROM ambient_pools ORDER BY sample") {
            AmbientPool(sample: Self.int($0, 0), barcodesWithUMI: Self.int($0, 1), poolBarcodes: Self.int($0, 2), firstRank: Self.optionalInt($0, 3),
                        lastRank: Self.optionalInt($0, 4), umiMin: Self.optionalInt($0, 5), umiMax: Self.optionalInt($0, 6), umis: Self.int($0, 7), words: Self.text($0, 8))
        }
    }

    public func ambientPoolCounts() throws -> [AmbientPoolCount] {
        try schema2("SELECT sample, extra, record, umis, masked_umis, rate FROM ambient_pool_counts ORDER BY sample, extra, record") {
            AmbientPoolCount(sample: Self.int($0, 0), extra: Self.int($0, 1), record: Self.int($0, 2), umis: Self.int($0, 3), maskedUMIs: Self.int($0, 4),
                             rate: sqlite3_column_type($0, 5) == SQLITE_NULL ? nil : sqlite3_column_double($0, 5))
        }
    }

    public func notHostBarcodes() throws -> [NotHostBarcode] {
        try schema2("SELECT sample, barcode, cell, raw_umis, in_pool FROM not_host_barcodes ORDER BY sample, barcode") {
            NotHostBarcode(sample: Self.int($0, 0), barcode: Self.text($0, 1), cell: Self.optionalInt($0, 2), rawUMIs: Self.int($0, 3), inPool: Self.int($0, 4) != 0)
        }
    }

    public func notHostCounts() throws -> [NotHostCount] {
        try schema2("SELECT sample, barcode, extra, record, umis, masked_umis, umis_nm01, masked_umis_nm01 FROM not_host_counts ORDER BY sample, barcode, extra, record") {
            NotHostCount(sample: Self.int($0, 0), barcode: Self.text($0, 1), extra: Self.int($0, 2), record: Self.int($0, 3), umis: Self.int($0, 4),
                         maskedUMIs: Self.int($0, 5), umisNM01: Self.int($0, 6), maskedUMIsNM01: Self.int($0, 7))
        }
    }

    public func notHostCalls() throws -> [NotHostCall] {
        try schema2("SELECT sample, extra, cell, p, q, flag FROM not_host_calls ORDER BY sample, extra, cell") {
            NotHostCall(sample: Self.int($0, 0), extra: Self.int($0, 1), cell: Self.int($0, 2),
                        p: sqlite3_column_type($0, 3) == SQLITE_NULL ? nil : sqlite3_column_double($0, 3),
                        q: sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : sqlite3_column_double($0, 4), flag: Self.text($0, 5))
        }
    }

    private func schema2<T>(_ sql: String, _ make: (OpaquePointer) -> T) throws -> [T] {
        schemaVersion < 2 ? [] : try query(sql, make)
    }

    static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(statement, column)
    }

    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    private func query<T>(_ sql: String, _ make: (OpaquePointer) -> T) throws -> [T] {
        guard let db else { throw RNASeqResultError.unreadableFile(path: Self.filename, reason: "it is closed") }
        return try Self.rows(db, sql, make)
    }

    static func rows<T>(_ db: OpaquePointer, _ sql: String, _ make: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RNASeqResultError.unreadableFile(path: filename, reason: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var found: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return found }
            guard step == SQLITE_ROW else {
                throw RNASeqResultError.unreadableFile(path: filename, reason: String(cString: sqlite3_errmsg(db)))
            }
            found.append(make(statement))
        }
    }

    static func int(_ statement: OpaquePointer, _ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
