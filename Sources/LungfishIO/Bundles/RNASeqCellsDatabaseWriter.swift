// RNASeqCellsDatabaseWriter.swift - Writes cells.sqlite schema 1 in a result's stage (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Only `RNASeqResultWriter` calls this, inside its staging folder, so a published result never changes
// (`docs/formats/rnaseq-bundle.md`, The one writer). Every row goes in one transaction, the unique index on a sample's
// barcodes is built after the inserts, and SQLite's default rollback journal and full sync make the commit durable before
// the stage is renamed into place. The tables are those of `docs/formats/rnaseq-bundle.md`, Single cell.

import Foundation
import SQLite3

public final class RNASeqCellsDatabaseWriter {
    static let schema = [
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE samples (sample INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, matrix TEXT NOT NULL, cells INTEGER NOT NULL, features INTEGER NOT NULL, entries INTEGER NOT NULL)",
        "CREATE TABLE cells (cell INTEGER PRIMARY KEY, sample INTEGER NOT NULL, \"column\" INTEGER NOT NULL, barcode TEXT NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL)",
        "CREATE TABLE features (feature INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL, genome INTEGER, total INTEGER NOT NULL, cells INTEGER NOT NULL)",
        "CREATE TABLE genomes (genome INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)",
        "CREATE TABLE cell_genomes (cell INTEGER NOT NULL, genome INTEGER NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL, PRIMARY KEY (cell, genome)) WITHOUT ROWID",
    ]

    private var db: OpaquePointer?
    private let url: URL

    /// Creates `url`, which must not exist, with the tables of schema 1 and an open transaction.
    public init(url: URL) throws {
        self.url = url
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Self.failure("it already exists") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Self.failure("SQLite could not create it")
        }
        db = handle
        do {
            for statement in Self.schema + ["BEGIN"] { try exec(statement) }
            try setMeta("schema_version", String(RNASeqCellsDatabase.currentSchemaVersion))
        } catch {
            abandon()
            throw error
        }
    }

    deinit { abandon() }

    public func setMeta(_ key: String, _ value: String) throws {
        try insert("INSERT INTO meta (key, value) VALUES (?, ?)", rows: 1) { statement, _ in
            bind(statement, 1, key)
            bind(statement, 2, value)
        }
    }

    public func addGenomes(_ names: [String]) throws {
        try insert("INSERT INTO genomes (genome, name) VALUES (?, ?)", rows: names.count) { statement, index in
            sqlite3_bind_int64(statement, 1, Int64(index + 1))
            bind(statement, 2, names[index])
        }
    }

    public func addSample(_ sample: Int, name: String, matrix: String, size: MatrixMarketSize) throws {
        try insert("INSERT INTO samples (sample, name, matrix, cells, features, entries) VALUES (?, ?, ?, ?, ?, ?)", rows: 1) { statement, _ in
            sqlite3_bind_int64(statement, 1, Int64(sample))
            bind(statement, 2, name)
            bind(statement, 3, matrix)
            sqlite3_bind_int64(statement, 4, Int64(size.columns))
            sqlite3_bind_int64(statement, 5, Int64(size.rows))
            sqlite3_bind_int64(statement, 6, Int64(size.entries))
        }
    }

    /// One row a barcode of `sample`, numbered from `firstCell`, with its column from 1.
    public func addCells(sample: Int, firstCell: Int, barcodes: [String], umis: [UInt64], genes: [UInt32]) throws {
        try insert("INSERT INTO cells (cell, sample, \"column\", barcode, umis, genes) VALUES (?, ?, ?, ?, ?, ?)", rows: barcodes.count) { statement, index in
            sqlite3_bind_int64(statement, 1, Int64(firstCell + index))
            sqlite3_bind_int64(statement, 2, Int64(sample))
            sqlite3_bind_int64(statement, 3, Int64(index + 1))
            bind(statement, 4, barcodes[index])
            sqlite3_bind_int64(statement, 5, Int64(umis[index]))
            sqlite3_bind_int64(statement, 6, Int64(genes[index]))
        }
    }

    /// One row a cell of a sample for the genome numbered `genome`, zeros included.
    public func addCellGenomes(firstCell: Int, genome: Int, umis: [UInt64], genes: [UInt32]) throws {
        try insert("INSERT INTO cell_genomes (cell, genome, umis, genes) VALUES (?, ?, ?, ?)", rows: umis.count) { statement, index in
            sqlite3_bind_int64(statement, 1, Int64(firstCell + index))
            sqlite3_bind_int64(statement, 2, Int64(genome))
            sqlite3_bind_int64(statement, 3, Int64(umis[index]))
            sqlite3_bind_int64(statement, 4, Int64(genes[index]))
        }
    }

    /// One row a feature, numbered from 1 as its row in the matrix.
    public func addFeatures(ids: [String], names: [String], types: [String], genomes: [Int?], totals: [UInt64], cells: [UInt32]) throws {
        try insert("INSERT INTO features (feature, id, name, type, genome, total, cells) VALUES (?, ?, ?, ?, ?, ?, ?)", rows: ids.count) { statement, index in
            sqlite3_bind_int64(statement, 1, Int64(index + 1))
            bind(statement, 2, ids[index])
            bind(statement, 3, names[index])
            bind(statement, 4, types[index])
            if let genome = genomes[index] { sqlite3_bind_int64(statement, 5, Int64(genome)) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_int64(statement, 6, Int64(totals[index]))
            sqlite3_bind_int64(statement, 7, Int64(cells[index]))
        }
    }

    /// Builds the unique index on a sample's barcodes, commits and closes the file.
    public func finish() throws {
        do {
            try exec("CREATE UNIQUE INDEX cells_sample_barcode ON cells (sample, barcode)")
        } catch {
            abandon()
            throw RNASeqResultError.invalidTable(path: RNASeqCellsDatabase.filename, reason: "a barcode appears twice in one sample's barcodes")
        }
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
        .unreadableFile(path: RNASeqCellsDatabase.filename, reason: reason)
    }

    private func exec(_ sql: String) throws {
        guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Self.failure(db.map { String(cString: sqlite3_errmsg($0)) } ?? "it is closed")
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransientDestructor)
    }

    private func insert(_ sql: String, rows: Int, _ fill: (OpaquePointer, Int) -> Void) throws {
        guard let db else { throw Self.failure("it is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.failure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for index in 0..<rows {
            fill(statement, index)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.failure(String(cString: sqlite3_errmsg(db))) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }
}
