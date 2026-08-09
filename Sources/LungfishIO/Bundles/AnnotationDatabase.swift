// AnnotationDatabase.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

/// Logger for annotation database operations
let dbLogger = Logger(subsystem: LogSubsystem.io, category: "AnnotationDatabase")

/// Tells SQLite to copy bound bytes immediately, rather than trusting the caller to
/// keep the pointer valid until sqlite3_step()/sqlite3_reset() (F38). Shared across all
/// AnnotationDatabase+*.swift files so every `sqlite3_bind_text` call in this file family
/// uses the same non-nil, copying destructor. Now an alias for the single
/// module-wide `sqliteTransientDestructor` (F53, round-2) -- kept under its original
/// name here rather than mass-renaming every AnnotationDatabase+*.swift call site.
let annotationDatabaseSQLiteTransient = sqliteTransientDestructor

// MARK: - AnnotationDatabase (Reader)

/// Reads annotation metadata from a SQLite database embedded in a .lungfishref bundle.
///
/// The database is created during bundle building and provides instant search/filter
/// over annotation names, types, and coordinates without scanning BigBed R-trees.
///
/// Schema (v4):
/// ```sql
/// CREATE TABLE annotations (
///     name TEXT NOT NULL,
///     type TEXT NOT NULL,
///     chromosome TEXT NOT NULL,
///     start INTEGER NOT NULL,
///     end INTEGER NOT NULL,
///     strand TEXT NOT NULL DEFAULT '.',
///     attributes TEXT,
///     block_count INTEGER,
///     block_sizes TEXT,
///     block_starts TEXT,
///     gene_name TEXT
/// );
/// ```
public final class AnnotationDatabase: @unchecked Sendable {

    public struct ColumnFilterClause: Sendable {
        public let key: String
        public let op: String
        public let value: String

        public init(key: String, op: String, value: String) {
            self.key = key
            self.op = op
            self.value = value
        }
    }

    private static let expectedSchemaVersion = 4
    private static let requiredAnnotationColumns: Set<String> = [
        "name", "type", "chromosome", "start", "end", "strand",
        "attributes", "block_count", "block_sizes", "block_starts", "gene_name"
    ]

    var db: OpaquePointer?
    /// Serializes every operation using the shared SQLite connection. The lock
    /// also keeps transactions and connection-local temporary state atomic.
    let connectionLock = NSLock()
    #if DEBUG
    /// Test-only synchronization seam invoked while `connectionLock` is held.
    private(set) var scopePreparationTestHook: (@Sendable () -> Void)?

    func setScopePreparationTestHook(_ hook: (@Sendable () -> Void)?) {
        connectionLock.lock()
        scopePreparationTestHook = hook
        connectionLock.unlock()
    }
    #endif
    private let url: URL
    public var databaseURL: URL { url }

    /// Opens an existing annotation database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file
    /// - Throws: If the database cannot be opened
    public convenience init(url: URL) throws {
        try self.init(url: url, readWrite: false)
    }

    /// Opens an existing annotation database.
    ///
    /// - Parameters:
    ///   - url: URL to the SQLite database file
    ///   - readWrite: Open with write permissions when mutations are required
    /// - Throws: If the database cannot be opened
    public init(url: URL, readWrite: Bool) throws {
        self.url = url
        let flags = (readWrite ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw AnnotationDatabaseError.openFailed(msg)
        }
        guard let db else {
            throw AnnotationDatabaseError.openFailed("Database handle is nil")
        }

        try Self.validateSchema(db: db)

        dbLogger.info("Opened annotation database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func validateSchema(db: OpaquePointer) throws {
        guard tableExists(db: db, name: "annotations") else {
            throw AnnotationDatabaseError.invalidSchema("Missing required table: annotations")
        }
        guard tableExists(db: db, name: "db_metadata") else {
            throw AnnotationDatabaseError.invalidSchema("Missing required table: db_metadata")
        }
        let columns = columnsForTable(db: db, table: "annotations")
        guard requiredAnnotationColumns.isSubset(of: columns) else {
            let missing = requiredAnnotationColumns.subtracting(columns).sorted().joined(separator: ", ")
            throw AnnotationDatabaseError.invalidSchema("annotations table missing required columns: \(missing)")
        }
        guard let version = schemaVersion(db: db) else {
            throw AnnotationDatabaseError.invalidSchema("Missing db_metadata schema_version")
        }
        guard version == expectedSchemaVersion else {
            throw AnnotationDatabaseError.invalidSchema(
                "Unsupported schema_version \(version); expected \(expectedSchemaVersion)"
            )
        }
    }

    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, annotationDatabaseSQLiteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnsForTable(db: OpaquePointer, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cStr))
            }
        }
        return columns
    }

    private static func schemaVersion(db: OpaquePointer) -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM db_metadata WHERE key='schema_version' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return Int(String(cString: cStr))
    }

    /// Decodes a single stepped `annotations` row (columns 0-11 in the canonical
    /// `rowid, name, type, chromosome, start, end, strand, attributes, block_count,
    /// block_sizes, block_starts, gene_name` order) into an `AnnotationDatabaseRecord`.
    static func decodeRecord(_ stmt: OpaquePointer?) -> AnnotationDatabaseRecord {
        let rowID = sqlite3_column_int64(stmt, 0)
        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let chrom = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let start = Int(sqlite3_column_int64(stmt, 4))
        let end = Int(sqlite3_column_int64(stmt, 5))
        let strand = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "."
        let attributes = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let blockCount = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 8)) : nil
        let blockSizes = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let blockStarts = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let geneName = sqlite3_column_text(stmt, 11).map { String(cString: $0) }

        return AnnotationDatabaseRecord(
            rowID: rowID, name: name, type: type, chromosome: chrom,
            start: start, end: end, strand: strand,
            attributes: attributes,
            blockCount: blockCount,
            blockSizes: blockSizes,
            blockStarts: blockStarts,
            geneName: geneName
        )
    }
}
