// RNASeqCellsDatabase.swift - The read-only side of a single-cell result's cells.sqlite (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `cells.sqlite` is the per-cell summary of one streaming pass over each matrix of a `.lungfishrnaseq` result, which the
// tables page from (`docs/formats/rnaseq-bundle.md`, Single cell). Schema 1 holds `meta`, `samples`, `cells`, `features`,
// `genomes` and `cell_genomes`. The file opens read only, so reading never writes into the project, and a file whose
// `meta` schema is newer than this reader knows is refused with the manifest's words. `RNASeqCellsDatabaseWriter` writes it.

import Foundation
import SQLite3

public final class RNASeqCellsDatabase {
    public static let filename = "cells.sqlite"
    public static let currentSchemaVersion = 1

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
