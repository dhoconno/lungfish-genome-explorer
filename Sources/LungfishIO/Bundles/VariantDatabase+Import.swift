// VariantDatabase+Import.swift - Resume import + EAV materialization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Resume Interrupted Import

    /// Read a metadata value from an existing variant database without opening
    /// a full `VariantDatabase` instance.
    /// Returns `nil` if the database doesn't exist, can't be opened, or lacks the key.
    public static func metadataValue(at dbURL: URL, key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return readMetadataValue(db, key: key)
    }

    /// Read the `import_state` value from an existing variant database.
    /// Returns `nil` if the database doesn't exist or has no `import_state` key.
    public static func importState(at dbURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return readMetadataValue(db, key: "import_state")
    }

    /// Check whether a database file at the given URL contains a `variants` table.
    /// Used as a fallback when `importState` returns nil (e.g. corrupted metadata)
    /// to detect a partial import that may be recoverable.
    public static func hasVariantsTable(at dbURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='variants'", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    /// Returns ordered chromosome IDs from VCF `##contig` header lines.
    ///
    /// This only reads the VCF header and stops at `#CHROM` (or first variant line).
    /// Returns an empty list when `##contig` lines are absent.
    public static func contigsInVCFHeader(
        url: URL,
        maxChromosomes: Int = 512
    ) throws -> [String] {
        try readContigsFromVCFHeader(url: url, maxChromosomes: maxChromosomes)
    }

    /// Merges a chromosome-scoped import database into an existing destination import DB.
    ///
    /// Expects both databases to use the v3 schema produced by `createFromVCF`.
    /// Variant row IDs from `sourceDBURL` are offset and appended so genotype/info
    /// foreign-key relationships remain intact.
    ///
    /// - Returns: Number of variants appended from source.
    @discardableResult
    public static func mergeImportedDatabase(
        into destinationDBURL: URL,
        from sourceDBURL: URL
    ) throws -> Int {
        var destDB: OpaquePointer?
        guard sqlite3_open(destinationDBURL.path, &destDB) == SQLITE_OK, let destDB else {
            let msg = destDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destDB)
            throw VariantDatabaseError.createFailed("Failed to open destination database for merge: \(msg)")
        }
        defer { sqlite3_close(destDB) }

        func exec(_ sql: String, on db: OpaquePointer, context: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &err)
            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                throw VariantDatabaseError.createFailed("\(context): \(msg)")
            }
        }

        // Ensure merge writes are deterministic and low-overhead.
        sqlite3_exec(destDB, "PRAGMA foreign_keys = OFF", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA journal_mode = DELETE", nil, nil, nil)

        let sourceAlias = "srcmerge"
        let escapedSourcePath = sourceDBURL.path.replacingOccurrences(of: "'", with: "''")
        try exec("ATTACH DATABASE '\(escapedSourcePath)' AS \(sourceAlias)", on: destDB, context: "Attach source DB")
        defer {
            sqlite3_exec(destDB, "DETACH DATABASE \(sourceAlias)", nil, nil, nil)
        }

        // Profile consistency check.
        let destSkipInfo = readMetadataValue(destDB, key: "skip_variant_info")
        let sourceSkipInfo = readAttachedMetadataValue(db: destDB, alias: sourceAlias, key: "skip_variant_info")
        if destSkipInfo != sourceSkipInfo {
            throw VariantDatabaseError.invalidSchema(
                "Cannot merge databases with different skip_variant_info modes (\(destSkipInfo ?? "nil") vs \(sourceSkipInfo ?? "nil"))"
            )
        }

        let appendedVariants = attachedVariantCount(db: destDB, alias: sourceAlias)
        if appendedVariants == 0 {
            return 0
        }

        let existingMaxID = maxVariantID(db: destDB)

        try exec("BEGIN TRANSACTION", on: destDB, context: "Begin merge transaction")
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(destDB, "ROLLBACK", nil, nil, nil)
            }
        }

        try exec(
            """
            INSERT INTO variants (
                id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            )
            SELECT
                id + \(existingMaxID), chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            FROM \(sourceAlias).variants
            """,
            on: destDB,
            context: "Merge variants"
        )

        try exec(
            """
            INSERT INTO genotypes (
                variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
            )
            SELECT
                variant_id + \(existingMaxID), sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
            FROM \(sourceAlias).genotypes
            """,
            on: destDB,
            context: "Merge genotypes"
        )

        try exec(
            """
            INSERT OR REPLACE INTO samples (name, display_name, source_file, metadata)
            SELECT name, display_name, source_file, metadata
            FROM \(sourceAlias).samples
            """,
            on: destDB,
            context: "Merge samples"
        )

        if destSkipInfo != "true" {
            try exec(
                """
                INSERT OR REPLACE INTO variant_info (variant_id, key, value)
                SELECT variant_id + \(existingMaxID), key, value
                FROM \(sourceAlias).variant_info
                """,
                on: destDB,
                context: "Merge variant_info"
            )
        }

        try exec(
            """
            INSERT OR REPLACE INTO variant_info_defs (key, type, number, description)
            SELECT key, type, number, description
            FROM \(sourceAlias).variant_info_defs
            """,
            on: destDB,
            context: "Merge variant_info_defs"
        )

        // Merge contig length metadata.
        let mergedContigs = mergeContigLengthsJSON(
            lhs: readMetadataValue(destDB, key: "contig_lengths"),
            rhs: readAttachedMetadataValue(db: destDB, alias: sourceAlias, key: "contig_lengths")
        )
        if let mergedContigs {
            Self.insertMetadataRow(destDB, key: "contig_lengths", value: mergedContigs, replace: true)
        }

        // Token cache tables are import-time snapshots; invalidate so stale caches
        // are not used after appending additional chromosome partitions.
        try exec("DROP TABLE IF EXISTS _tok_pass", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_snv", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_indel", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_qual30", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_dp10", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_rare", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_clinvar", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_bio_hi", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _high_impact", on: destDB, context: "Drop token cache table")

        // Keep import state resumable and import count accurate.
        let totalCount = currentVariantCount(destDB)
        Self.insertMetadataRow(destDB, key: "import_variant_count", value: "\(totalCount)", replace: true)
        Self.insertMetadataRow(destDB, key: "import_state", value: "indexing", replace: true)
        Self.insertMetadataRow(destDB, key: "import_partition_mode", value: "helper-subprocess-per-chromosome", replace: true)

        // Keep AUTOINCREMENT sequence aligned with appended explicit IDs.
        try exec(
            """
            INSERT OR REPLACE INTO sqlite_sequence(name, seq)
            VALUES ('variants', (SELECT COALESCE(MAX(id), 0) FROM variants))
            """,
            on: destDB,
            context: "Update sqlite_sequence"
        )

        try exec("COMMIT", on: destDB, context: "Commit merge transaction")
        committed = true
        _ = sqlite3_db_release_memory(destDB)
        sqlite3_exec(destDB, "PRAGMA shrink_memory", nil, nil, nil)

        return appendedVariants
    }

    /// Resume an interrupted VCF import by creating any missing indexes.
    ///
    /// When `createFromVCF` is killed (e.g. by the OOM killer) the database may
    /// contain all variant data but lack some or all indexes.  This method reads
    /// `import_state` from `db_metadata`, determines which indexes already exist,
    /// and creates the missing ones with conservative memory settings.
    ///
    /// - Returns: The variant count from the database, or 0 if unknown.
    @discardableResult
    public static func resumeImport(
        existingDBURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(existingDBURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Failed to open database for resume: \(msg)")
        }
        defer { sqlite3_close(db) }

        let state = readMetadataValue(db, key: "import_state")
        guard state == "indexing" else {
            switch state {
            case "complete":
                return currentVariantCount(db)
            case "inserting":
                // At this stage we cannot know whether all variant rows were inserted.
                // Resuming by only building indexes can silently produce truncated DBs.
                throw VariantDatabaseError.invalidSchema(
                    "Cannot resume while import_state is 'inserting'; restart full import from source VCF"
                )
            case nil:
                throw VariantDatabaseError.invalidSchema(
                    "Cannot resume with missing import_state metadata; restart full import from source VCF"
                )
            default:
                throw VariantDatabaseError.invalidSchema("Cannot resume: import_state is '\(state ?? "nil")'")
            }
        }

        variantDBLogger.info("resumeImport: Resuming from state '\(state ?? "nil")', building missing indexes")

        // Conservative PRAGMAs for index creation.
        sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = 1", nil, nil, nil)
        sqlite3_soft_heap_limit64(256 * 1024 * 1024)

        // Determine which indexes already exist.
        let existingIndexes = listExistingIndexes(db)

        // If variant_info was skipped during import, don't try to create its indexes.
        let skipVariantInfo = readMetadataValue(db, key: "skip_variant_info") == "true"
        let applicableIndexes = skipVariantInfo
            ? allIndexStatements.filter { !$0.name.contains("variant_info") }
            : allIndexStatements
        let neededIndexes = applicableIndexes.filter { !existingIndexes.contains($0.name) }
        if neededIndexes.isEmpty {
            variantDBLogger.info("resumeImport: All indexes already exist")
            sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)
            return currentVariantCount(db)
        }

        for (i, (name, sql)) in neededIndexes.enumerated() {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }
            let fraction = Double(i) / Double(neededIndexes.count)
            progressHandler?(fraction, "Creating index \(i + 1) of \(neededIndexes.count) (\(name))...")
            try createRequiredIndex(db: db, name: name, sql: sql, context: "resumeImport")
            sqlite3_exec(db, "INSERT OR REPLACE INTO db_metadata VALUES ('idx_\(name)', 'created')", nil, nil, nil)
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
        }

        sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)
        let count = currentVariantCount(db)
        progressHandler?(1.0, "Resume complete (\(count) variants)")
        variantDBLogger.info("resumeImport: Complete, \(count) variants")
        return count
    }

    static func currentVariantCount(_ db: OpaquePointer) -> Int {
        if let metadataCount = readMetadataValue(db, key: "import_variant_count"),
           let parsed = Int(metadataCount),
           parsed >= 0 {
            return parsed
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func maxVariantID(db: OpaquePointer) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM variants", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    static func attachedVariantCount(db: OpaquePointer, alias: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(alias).variants"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func readAttachedMetadataValue(db: OpaquePointer, alias: String, key: String) -> String? {
        let sql = "SELECT value FROM \(alias).db_metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        variantDBBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    static func mergeContigLengthsJSON(lhs: String?, rhs: String?) -> String? {
        func parse(_ json: String?) -> [String: Int64] {
            guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            var result: [String: Int64] = [:]
            for (key, value) in raw {
                if let n = value as? NSNumber {
                    result[key] = n.int64Value
                } else if let s = value as? String, let n = Int64(s) {
                    result[key] = n
                }
            }
            return result
        }

        var merged = parse(lhs)
        for (key, value) in parse(rhs) {
            if merged[key] == nil {
                merged[key] = value
            }
        }
        guard !merged.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged.mapValues { NSNumber(value: $0) },
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Inserts or replaces a key-value pair in db_metadata using parameterized binding
    /// to prevent SQL injection from user-controlled values (filenames, chromosome names, etc).
    @discardableResult
    static func insertMetadataRow(_ db: OpaquePointer, key: String, value: String, replace: Bool = false) -> Bool {
        let sql = replace
            ? "INSERT OR REPLACE INTO db_metadata VALUES (?, ?)"
            : "INSERT INTO db_metadata VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        variantDBBindText(stmt, 1, key)
        variantDBBindText(stmt, 2, value)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    static func readMetadataValue(_ db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM db_metadata WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        variantDBBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    static func listExistingIndexes(_ db: OpaquePointer) -> Set<String> {
        var result = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'index'", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                result.insert(String(cString: cStr))
            }
        }
        return result
    }

    static func createRequiredIndex(
        db: OpaquePointer?,
        name: String,
        sql: String,
        context: String
    ) throws {
        var idxErr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &idxErr)
        if rc == SQLITE_OK {
            return
        }

        let message: String
        if let idxErr {
            message = String(cString: idxErr)
            sqlite3_free(idxErr)
        } else if let db {
            message = String(cString: sqlite3_errmsg(db))
        } else {
            message = "SQLite error \(rc)"
        }
        throw VariantDatabaseError.createFailed("\(context): failed to create index '\(name)': \(message)")
    }

    // MARK: - Post-Import EAV Materialization

    /// Materializes the `variant_info` EAV table from raw INFO strings stored in
    /// `variants.info`.  Designed for databases created with the `ultraLowMemory`
    /// profile where `skipVariantInfo` was true.
    ///
    /// Runs in bounded memory: reads variants in batches by rowid cursor, parses
    /// each INFO string, and batch-inserts into `variant_info`.  Progress is
    /// tracked in `db_metadata` for independent resumability.
    ///
    /// After all rows are materialized, populates `variant_info_defs` with inferred
    /// field definitions, creates the `variant_info` indexes, and clears the
    /// `skip_variant_info` flag so downstream code switches to EAV queries.
    ///
    /// - Parameters:
    ///   - existingDBURL: URL to the existing variant database
    ///   - progressHandler: Optional progress callback (fraction, message)
    ///   - shouldCancel: Optional cancellation check
    /// - Returns: Number of EAV rows inserted
    @discardableResult
    public static func materializeVariantInfo(
        existingDBURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(existingDBURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Failed to open database for materialization: \(msg)")
        }
        defer { sqlite3_close(db) }

        // Preconditions.
        let importState = readMetadataValue(db, key: "import_state")
        guard importState == "complete" else {
            throw VariantDatabaseError.invalidSchema(
                "Cannot materialize: import_state is '\(importState ?? "nil")' (expected 'complete')")
        }
        let skipFlag = readMetadataValue(db, key: "skip_variant_info")
        guard skipFlag == "true" else {
            // Not a skipVariantInfo database — EAV was already populated during import.
            return 0
        }
        // Idempotent: if already materialized, return immediately.
        if readMetadataValue(db, key: "materialize_state") == "complete" {
            return 0
        }

        // Conservative PRAGMAs for bounded memory.
        sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = 1", nil, nil, nil)
        sqlite3_soft_heap_limit64(256 * 1024 * 1024)

        // Resume point: read cursor from previous run if any.
        let lastIdStr = readMetadataValue(db, key: "materialize_last_variant_id")
        var lastProcessedId: Int64 = Int64(lastIdStr ?? "0") ?? 0

        // Total variant count for progress reporting (MAX(id) is O(1) on rowid).
        var maxIdStmt: OpaquePointer?
        defer { sqlite3_finalize(maxIdStmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(id) FROM variants", -1, &maxIdStmt, nil) == SQLITE_OK,
              sqlite3_step(maxIdStmt) == SQLITE_ROW else {
            throw VariantDatabaseError.createFailed("Failed to query MAX(id) for materialization")
        }
        let maxId = sqlite3_column_int64(maxIdStmt, 0)
        sqlite3_finalize(maxIdStmt)
        maxIdStmt = nil

        guard maxId > 0 else {
            // Empty database — nothing to materialize.
            Self.insertMetadataRow(db, key: "materialize_state", value: "complete", replace: true)
            sqlite3_exec(db, "UPDATE db_metadata SET value = 'false' WHERE key = 'skip_variant_info'", nil, nil, nil)
            return 0
        }

        // Mark state.
        Self.insertMetadataRow(db, key: "materialize_state", value: "materializing", replace: true)

        variantDBLogger.info("materializeVariantInfo: Starting from id \(lastProcessedId), maxId \(maxId)")
        progressHandler?(0.0, "Materializing INFO fields...")

        // Prepare statements.
        let selectSQL = """
            SELECT id, info FROM variants
            WHERE id > ? AND info IS NOT NULL AND info != '.'
            ORDER BY id ASC
            LIMIT 5000
            """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare SELECT for materialization")
        }
        defer { sqlite3_finalize(selectStmt) }

        let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
        var insertInfoStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare INSERT for materialization")
        }
        defer { sqlite3_finalize(insertInfoStmt) }

        var totalEAVRows = 0
        var distinctKeys = Set<String>()
        var infoValueSamples: [String: [String]] = [:]

        // Batch loop.
        while true {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            sqlite3_reset(selectStmt)
            sqlite3_bind_int64(selectStmt, 1, lastProcessedId)

            var batchCount = 0
            var batchLastId: Int64 = lastProcessedId

            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let variantId = sqlite3_column_int64(selectStmt, 0)
                guard let infoCStr = sqlite3_column_text(selectStmt, 1) else { continue }
                let infoString = String(cString: infoCStr)

                let parsed = parseRawINFOString(infoString)
                for (key, value) in parsed {
                    sqlite3_reset(insertInfoStmt)
                    sqlite3_bind_int64(insertInfoStmt, 1, variantId)
                    variantDBBindText(insertInfoStmt, 2, key)
                    variantDBBindText(insertInfoStmt, 3, value)
                    sqlite3_step(insertInfoStmt)
                    totalEAVRows += 1
                    distinctKeys.insert(key)
                    if infoValueSamples[key, default: []].count < 50 {
                        infoValueSamples[key, default: []].append(value)
                    }
                }

                batchLastId = variantId
                batchCount += 1
            }

            // No more rows — exit loop.
            if batchCount == 0 {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                break
            }

            // Update cursor and commit.
            lastProcessedId = batchLastId
            Self.insertMetadataRow(db, key: "materialize_last_variant_id", value: "\(lastProcessedId)", replace: true)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            // Release memory.
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)

            // Progress.
            let fraction = min(0.90, Double(lastProcessedId) / Double(maxId) * 0.90)
            progressHandler?(fraction, "Materializing INFO fields (\(totalEAVRows) rows)...")
        }

        variantDBLogger.info("materializeVariantInfo: Inserted \(totalEAVRows) EAV rows, \(distinctKeys.count) distinct keys")

        // Populate variant_info_defs from discovered keys.
        progressHandler?(0.90, "Recording INFO field definitions...")
        let insertDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, '.', 'Inferred from data')"
        var insertDefStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertDefSQL, -1, &insertDefStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare info_defs INSERT for materialization")
        }
        defer { sqlite3_finalize(insertDefStmt) }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for key in distinctKeys.sorted() {
            sqlite3_reset(insertDefStmt)
            variantDBBindText(insertDefStmt, 1, key)
            variantDBBindText(insertDefStmt, 2, inferInfoType(from: infoValueSamples[key] ?? []))
            sqlite3_step(insertDefStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        // Create variant_info indexes.
        progressHandler?(0.92, "Creating variant_info indexes...")
        let variantInfoIndexes = allIndexStatements.filter { $0.name.contains("variant_info") }
        for (i, (name, sql)) in variantInfoIndexes.enumerated() {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }
            let indexProgress = 0.92 + (Double(i) / Double(max(1, variantInfoIndexes.count))) * 0.06
            progressHandler?(indexProgress, "Creating index \(name)...")
            try createRequiredIndex(db: db, name: name, sql: sql, context: "materializeVariantInfo")
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
        }

        // Finalize: mark complete, clear cursor, flip skip flag.
        Self.insertMetadataRow(db, key: "materialize_state", value: "complete", replace: true)
        sqlite3_exec(db, "DELETE FROM db_metadata WHERE key = 'materialize_last_variant_id'", nil, nil, nil)
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'false' WHERE key = 'skip_variant_info'", nil, nil, nil)

        progressHandler?(1.0, "Materialization complete (\(totalEAVRows) INFO rows, \(distinctKeys.count) keys)")
        variantDBLogger.info("materializeVariantInfo: Complete — \(totalEAVRows) rows, \(distinctKeys.count) keys")
        return totalEAVRows
    }

}
