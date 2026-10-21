// VariantDatabase+Bookmarks.swift - Variant bookmark CRUD
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

extension VariantDatabase {

    // MARK: - Variant Bookmarks

    /// Reports whether the `variant_bookmarks` table exists, and never writes.
    ///
    /// The viewer opens every variant database of a displayed bundle read-write and the drawer then
    /// asks each one for its bookmarks. A read must leave the bytes of `variants/calls.db` alone, so
    /// this only asks `sqlite_master` and `createBookmarkTableIfNeeded()` is the one place that runs
    /// the `CREATE`. While the cached flag is false the question is asked again, so a table that
    /// another handle or process creates later (a bookmark toggled in a second window) is seen.
    func bookmarkTableExists() -> Bool {
        guard let db else { return false }
        if hasBookmarkTable { return true }
        hasBookmarkTable = VariantDatabase.tableExists(db: db, name: "variant_bookmarks")
        return hasBookmarkTable
    }

    /// Creates the `variant_bookmarks` table when it is missing.
    /// Only `toggleBookmark` calls this, since a bookmark write is the one thing that may add the
    /// table. A read-only handle never creates it.
    func createBookmarkTableIfNeeded() {
        guard let db, !bookmarkTableExists(), isReadOnly == false else { return }
        let sql = """
            CREATE TABLE IF NOT EXISTS variant_bookmarks (
                variant_id INTEGER PRIMARY KEY,
                flag_type TEXT DEFAULT 'star',
                note TEXT DEFAULT '',
                created_at TEXT DEFAULT (datetime('now'))
            )
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return }
        hasBookmarkTable = true
    }

    /// Toggles a bookmark on a variant. Returns the new bookmarked state.
    @discardableResult
    public func toggleBookmark(variantId: Int64, flag: String = "star") -> Bool {
        createBookmarkTableIfNeeded()
        guard let db, hasBookmarkTable else { return false }
        if isBookmarked(variantId: variantId) {
            removeBookmark(variantId: variantId)
            return false
        } else {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO variant_bookmarks (variant_id, flag_type) VALUES (?, ?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, variantId)
                variantDBBindText(stmt, 2, flag)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return true
        }
    }

    /// Returns true if the given variant is bookmarked.
    public func isBookmarked(variantId: Int64) -> Bool {
        guard bookmarkTableExists(), let db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM variant_bookmarks WHERE variant_id = ?"
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, variantId)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        return false
    }

    /// Returns all bookmarked variant IDs.
    public func bookmarkedVariantIds() -> Set<Int64> {
        guard bookmarkTableExists(), let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT variant_id FROM variant_bookmarks"
        defer { sqlite3_finalize(stmt) }
        var ids = Set<Int64>()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.insert(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    /// Returns all bookmarks with their notes.
    public func allBookmarks() -> [(variantId: Int64, flag: String, note: String, createdAt: String)] {
        guard bookmarkTableExists(), let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT variant_id, flag_type, note, created_at FROM variant_bookmarks ORDER BY created_at DESC"
        defer { sqlite3_finalize(stmt) }
        var results: [(variantId: Int64, flag: String, note: String, createdAt: String)] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let vid = sqlite3_column_int64(stmt, 0)
                let flag = sqlite3_column_text(stmt, 1).map(String.init(cString:)) ?? "star"
                let note = sqlite3_column_text(stmt, 2).map(String.init(cString:)) ?? ""
                let created = sqlite3_column_text(stmt, 3).map(String.init(cString:)) ?? ""
                results.append((vid, flag, note, created))
            }
        }
        return results
    }

    /// Removes a bookmark. Without the table there is no bookmark to remove, so this does nothing.
    public func removeBookmark(variantId: Int64) {
        guard bookmarkTableExists(), let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM variant_bookmarks WHERE variant_id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, variantId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Returns variant records for all bookmarked variants using a JOIN (efficient).
    public func bookmarkedVariants() -> [VariantDatabaseRecord] {
        guard bookmarkTableExists(), let db else { return [] }

        let sql = """
            SELECT v.id, v.chromosome, v.position, v.end_pos, v.variant_id, v.ref, v.alt, \
            v.variant_type, v.quality, v.filter, v.info, v.sample_count \
            FROM variants v \
            INNER JOIN variant_bookmarks b ON v.id = b.variant_id \
            ORDER BY v.chromosome, v.position
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        return readVariantRows(stmt: stmt!)
    }

    /// Updates the note on a bookmark. Without the table there is no bookmark to annotate, so this does nothing.
    public func updateBookmarkNote(variantId: Int64, note: String) {
        guard bookmarkTableExists(), let db else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE variant_bookmarks SET note = ? WHERE variant_id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            variantDBBindText(stmt, 1, note)
            sqlite3_bind_int64(stmt, 2, variantId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

}
