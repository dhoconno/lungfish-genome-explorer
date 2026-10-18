// VariantDatabase+RowsByID.swift - Reads variants by row id for the annotation table export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

extension VariantDatabase {
    /// The most row ids one statement binds, well under SQLite's default limit of 32,766 parameters.
    static let rowsByIDChunkSize = 500

    /// The variants with these row ids, in the order given (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 5).
    ///
    /// `bundle export-annotation-table` reads the rows the table showed by the identities in its selection file. An id
    /// that names no row is left out, and a repeated id returns its row each time. The read throws on an interrupted or
    /// failed statement, as `queryForTableExport` does, so an export never writes a partial table.
    public func variantsForExport(rowIDs: [Int64]) throws -> [VariantDatabaseRecord] {
        guard let db else { throw VariantDatabaseError.openFailed("Database handle is nil") }
        let unique = Array(Set(rowIDs)).sorted()
        var byID: [Int64: VariantDatabaseRecord] = [:]
        for chunkStart in stride(from: 0, to: unique.count, by: Self.rowsByIDChunkSize) {
            let ids = unique[chunkStart..<min(chunkStart + Self.rowsByIDChunkSize, unique.count)]
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, "
                + "info, sample_count FROM variants WHERE id IN (\(placeholders))"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw VariantDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            for (offset, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(offset + 1), id)
            }
            for record in try readVariantRowsThrowing(stmt: statement) {
                if let id = record.id { byID[id] = record }
            }
        }
        return rowIDs.compactMap { byID[$0] }
    }
}
