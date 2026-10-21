// Kraken2Database+SampleMetadataCache.swift - The sample metadata cache of kraken2.sqlite, written only on a difference
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

extension Kraken2Database {
    /// Brings `sample_metadata_cache` in line with `store`. See ``refreshSampleMetadataCache(records:)``.
    ///
    /// - Returns: Whether the database file was written.
    @discardableResult
    public func refreshSampleMetadataCache(store: SampleMetadataStore) throws -> Bool {
        try refreshSampleMetadataCache(records: store.records)
    }

    /// Brings `sample_metadata_cache` in line with `records` and writes the file only when they differ.
    ///
    /// Opening a result hands the viewer its sample metadata each time, and the cache already holds those rows after
    /// the first open. Rewriting identical rows still changes the file's bytes, since SQLite counts every commit in
    /// the file header, so a record that named the database by its digest no longer matched after the next open
    /// (Phase 2.13 lane 13.35, M865). The rows are read first, and the table is rewritten only when they differ from
    /// `records` or the table is missing.
    ///
    /// - Parameter records: Each matched sample's metadata, field by field.
    /// - Returns: Whether the database file was written.
    @discardableResult
    public func refreshSampleMetadataCache(records: [String: [String: String]]) throws -> Bool {
        let wanted = records.filter { !$0.value.isEmpty }
        if let cached = cachedSampleMetadata(), cached == wanted { return false }
        try rewriteSampleMetadataCache(records: records)
        return true
    }

    /// The rows now in `sample_metadata_cache`, sample by sample, or `nil` when the table is missing or unreadable.
    /// A separate read-only connection reads them, so nothing here writes to the file.
    private func cachedSampleMetadata() -> [String: [String: String]]? {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(handle) }
        guard opened == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT sample, field, value FROM sample_metadata_cache"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var cached: [String: [String: String]] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let sample = sqlite3_column_text(statement, 0),
                  let field = sqlite3_column_text(statement, 1),
                  let value = sqlite3_column_text(statement, 2) else { return nil }
            cached[String(cString: sample), default: [:]][String(cString: field)] = String(cString: value)
            step = sqlite3_step(statement)
        }
        // A step that ends on SQLITE_BUSY, SQLITE_IOERR or SQLITE_CORRUPT has not read the whole table, so the rows so
        // far are not the cache and the table counts as unreadable, which is a difference.
        return step == SQLITE_DONE ? cached : nil
    }
}
