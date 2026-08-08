// AnnotationDatabase+Mutation.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

/// Tells SQLite to copy the bound bytes immediately, rather than trusting the
/// caller to keep the pointer valid until sqlite3_step()/sqlite3_reset() (F38).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AnnotationDatabase {

    @discardableResult
    public func insertAnnotation(
        name: String,
        type: String,
        chromosome: String,
        start: Int,
        end: Int,
        strand: String,
        attributes: String?,
        geneName: String?,
        blockCount: Int? = nil,
        blockSizes: String? = nil,
        blockStarts: String? = nil
    ) throws -> Int64 {
        guard let db else { throw AnnotationDatabaseError.openFailed("Database is not open") }
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let sql = """
        INSERT INTO annotations (
            name, type, chromosome, start, end, strand, attributes,
            block_count, block_sizes, block_starts, gene_name
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (chromosome as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(start))
        sqlite3_bind_int64(stmt, 5, Int64(end))
        sqlite3_bind_text(stmt, 6, (strand as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let attributes {
            sqlite3_bind_text(stmt, 7, (attributes as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let blockCount {
            sqlite3_bind_int(stmt, 8, Int32(blockCount))
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let blockSizes {
            sqlite3_bind_text(stmt, 9, (blockSizes as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let blockStarts {
            sqlite3_bind_text(stmt, 10, (blockStarts as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if let geneName {
            sqlite3_bind_text(stmt, 11, (geneName as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AnnotationDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    @discardableResult
    public func updateAnnotation(
        rowID: Int64,
        name: String,
        type: String,
        chromosome: String,
        start: Int,
        end: Int,
        strand: String,
        attributes: String?,
        geneName: String?
    ) throws -> Bool {
        guard let db else { return false }
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let sql = """
        UPDATE annotations
        SET name = ?, type = ?, chromosome = ?, start = ?, end = ?, strand = ?, attributes = ?, gene_name = ?
        WHERE rowid = ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (chromosome as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(start))
        sqlite3_bind_int64(stmt, 5, Int64(end))
        sqlite3_bind_text(stmt, 6, (strand as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let attributes {
            sqlite3_bind_text(stmt, 7, (attributes as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if let geneName {
            sqlite3_bind_text(stmt, 8, (geneName as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int64(stmt, 9, rowID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AnnotationDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_changes(db) > 0
    }

    @discardableResult
    public func deleteAnnotations(rowIDs: [Int64]) throws -> Int {
        guard let db, !rowIDs.isEmpty else { return 0 }
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let sql = "DELETE FROM annotations WHERE rowid = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed(
                "Failed to begin annotation deletion transaction: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        var transactionOpen = true
        do {
            var deleted = 0
            var seenRowIDs: Set<Int64> = []
            let uniqueRowIDs = rowIDs.filter { seenRowIDs.insert($0).inserted }
            for rowID in uniqueRowIDs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, rowID)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw AnnotationDatabaseError.createFailed(
                        "Failed to delete annotation: \(String(cString: sqlite3_errmsg(db)))"
                    )
                }
                deleted += Int(sqlite3_changes(db))
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw AnnotationDatabaseError.createFailed(
                    "Failed to commit annotation deletion transaction: \(String(cString: sqlite3_errmsg(db)))"
                )
            }
            transactionOpen = false
            return deleted
        } catch {
            if transactionOpen {
                sqlite3_reset(stmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
            throw error
        }
    }
}
