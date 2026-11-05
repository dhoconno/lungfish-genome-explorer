// TaxTriageDatabase+ReadCount.swift - What a TaxTriage row's Reads count, and the mark that says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

extension TaxTriageDatabase {
    /// Metadata key naming what `lungfish build-db taxtriage` counted for each row's Reads.
    public static let readCountMetadataKey = "read_count"
    /// Reads keep the report's # Reads Aligned, and Unique Reads count the BAM over every reference of the organism
    /// (3.2 lane TTREADS, BIO ruling F1).
    public static let currentReadCount = "odr_reads_aligned"

    /// True for the metadata of a build whose Reads were BAM counts, on the first reference alone before 3.2, so a
    /// segmented virus could read 0.
    static func readCountIsStale(_ metadata: [String: String]) -> Bool {
        metadata[readCountMetadataKey] != currentReadCount
    }

    /// Records in the database at `url` that its read counts are current. The build calls it once its count pass has
    /// ended, so a database that a kill left between the publish and the pass does not read as current.
    ///
    /// - Throws: ``TaxTriageDatabaseError/createFailed(_:)`` when the file cannot be opened or written.
    public static func markReadsCounted(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw TaxTriageDatabaseError.createFailed("Cannot open \(url.lastPathComponent) to record its read count")
        }
        defer { sqlite3_close(db) }
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('\(readCountMetadataKey)', '\(currentReadCount)')"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TaxTriageDatabaseError.createFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
