// NaoMgsDatabase+Merge.swift - Staged summary merge path for NAO-MGS database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension NaoMgsDatabase {

    /// Creates a summary-only NAO-MGS database by merging staged per-sample databases.
    ///
    /// Copies `taxon_summaries`, `accession_summaries`, and `reference_lengths`
    /// from each stage database. `virus_hits` rows are intentionally not copied.
    ///
    /// - Parameters:
    ///   - url: Path for the merged SQLite database file.
    ///   - stageInputs: Per-sample stage databases and bundle-relative BAM metadata.
    public static func createMergedSummaryDatabase(
        at url: URL,
        from stageInputs: [NaoMgsStageDatabaseInput]
    ) throws {
        try? FileManager.default.removeItem(at: url)

        var mergedDB: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &mergedDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let mergedDB else {
            let msg = mergedDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(mergedDB)
            throw NaoMgsDatabaseError.createFailed(msg)
        }

        sqlite3_exec(mergedDB, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA cache_size = -65536", nil, nil, nil)
        sqlite3_exec(mergedDB, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: mergedDB)
            try ClassifierSQLiteDatabaseSupport.markBuildState(
                ClassifierSQLiteDatabaseSupport.buildStateBuilding,
                db: mergedDB
            )
            try mergeStageSummaries(into: mergedDB, from: stageInputs)
            try createIndices(db: mergedDB)
            try ClassifierSQLiteDatabaseSupport.finalizeSuccessfulBuild(
                db: mergedDB,
                requiredTables: Self.requiredTables,
                requiredIndexes: Self.buildRequiredIndexes
            )

            sqlite3_close(mergedDB)
            naoMgsDatabaseLogger.info("Created merged NAO-MGS summary database from \(stageInputs.count) staged samples at \(url.lastPathComponent)")
        } catch {
            sqlite3_close(mergedDB)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Merges staged summary databases into a freshly created summary-only database.
    private static func mergeStageSummaries(
        into mergedDB: OpaquePointer,
        from stageInputs: [NaoMgsStageDatabaseInput]
    ) throws {
        let insertTaxonSQL = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json,
            bam_path, bam_index_path
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let insertAccessionSQL = """
        INSERT INTO accession_summaries (
            sample, tax_id, accession, read_count, unique_read_count,
            reference_length, covered_base_pairs, coverage_fraction
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        let insertReadNameSQL = """
        INSERT OR IGNORE INTO taxon_read_names (
            sample, tax_id, seq_id
        ) VALUES (?, ?, ?)
        """
        let insertSampleHitCountSQL = """
        INSERT INTO sample_hit_counts (
            sample, hit_count
        ) VALUES (?, ?)
        """
        let mergeReferenceLengthSQL = """
        INSERT INTO reference_lengths (accession, length)
        VALUES (?, ?)
        ON CONFLICT(accession) DO UPDATE
        SET length = MAX(reference_lengths.length, excluded.length)
        """

        var insertTaxonStmt: OpaquePointer?
        var insertAccessionStmt: OpaquePointer?
        var insertReadNameStmt: OpaquePointer?
        var insertSampleHitCountStmt: OpaquePointer?
        var mergeReferenceLengthStmt: OpaquePointer?

        guard sqlite3_prepare_v2(mergedDB, insertTaxonSQL, -1, &insertTaxonStmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.createFailed("Merged taxon insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertAccessionSQL, -1, &insertAccessionStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            throw NaoMgsDatabaseError.createFailed("Merged accession insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertReadNameSQL, -1, &insertReadNameStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            throw NaoMgsDatabaseError.createFailed("Merged read-name insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, insertSampleHitCountSQL, -1, &insertSampleHitCountStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            throw NaoMgsDatabaseError.createFailed("Merged sample-hit insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        guard sqlite3_prepare_v2(mergedDB, mergeReferenceLengthSQL, -1, &mergeReferenceLengthStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            sqlite3_finalize(insertSampleHitCountStmt)
            throw NaoMgsDatabaseError.createFailed("Merged reference length insert prepare failed: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }
        defer {
            sqlite3_finalize(insertTaxonStmt)
            sqlite3_finalize(insertAccessionStmt)
            sqlite3_finalize(insertReadNameStmt)
            sqlite3_finalize(insertSampleHitCountStmt)
            sqlite3_finalize(mergeReferenceLengthStmt)
        }

        guard sqlite3_exec(mergedDB, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.createFailed("Failed to start merged summary transaction: \(String(cString: sqlite3_errmsg(mergedDB)))")
        }

        do {
            for stageInput in stageInputs {
                let taxonCount = try appendStageTaxonSummaries(from: stageInput, into: mergedDB, insertStmt: insertTaxonStmt)
                let accessionCount = try appendStageAccessionSummaries(from: stageInput, into: mergedDB, insertStmt: insertAccessionStmt)
                try appendStageTaxonReadNames(from: stageInput, into: mergedDB, insertStmt: insertReadNameStmt)
                try appendStageSampleHitCounts(from: stageInput, into: mergedDB, insertStmt: insertSampleHitCountStmt)
                try mergeStageReferenceLengths(from: stageInput, into: mergedDB, insertStmt: mergeReferenceLengthStmt)

                guard taxonCount > 0 else {
                    throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no taxon summaries for sample \(stageInput.sample)")
                }
                guard accessionCount > 0 else {
                    throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no accession summaries for sample \(stageInput.sample)")
                }
            }
            try refreshAccessionSummaryReferenceLengths(db: mergedDB)

            guard sqlite3_exec(mergedDB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Failed to commit merged summary transaction: \(String(cString: sqlite3_errmsg(mergedDB)))")
            }
        } catch {
            sqlite3_exec(mergedDB, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func appendStageTaxonSummaries(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws -> Int {
        let selectSQL = """
        SELECT tax_id, name, hit_count, unique_read_count,
               avg_identity, avg_bit_score, avg_edit_distance,
               pcr_duplicate_count, accession_count, top_accessions_json
        FROM taxon_summaries
        WHERE sample = ?
        """
        return try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage taxon select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            var insertedCount = 0
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))
                sqlite3_bind_int64(insertStmt, 4, sqlite3_column_int64(selectStmt, 2))
                sqlite3_bind_int64(insertStmt, 5, sqlite3_column_int64(selectStmt, 3))
                sqlite3_bind_double(insertStmt, 6, sqlite3_column_double(selectStmt, 4))
                sqlite3_bind_double(insertStmt, 7, sqlite3_column_double(selectStmt, 5))
                sqlite3_bind_double(insertStmt, 8, sqlite3_column_double(selectStmt, 6))
                sqlite3_bind_int64(insertStmt, 9, sqlite3_column_int64(selectStmt, 7))
                sqlite3_bind_int64(insertStmt, 10, sqlite3_column_int64(selectStmt, 8))
                naoBindText(insertStmt, 11, String(cString: sqlite3_column_text(selectStmt, 9)))
                naoBindText(insertStmt, 12, stageInput.bamRelativePath)
                if let bamIndexRelativePath = stageInput.bamIndexRelativePath {
                    naoBindText(insertStmt, 13, bamIndexRelativePath)
                } else {
                    sqlite3_bind_null(insertStmt, 13)
                }

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged taxon insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
                insertedCount += 1
            }
            return insertedCount
        }
    }

    private static func appendStageAccessionSummaries(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws -> Int {
        let selectSQL = """
        SELECT tax_id, accession, read_count, unique_read_count,
               reference_length, covered_base_pairs, coverage_fraction
        FROM accession_summaries
        WHERE sample = ?
        """
        return try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage accession select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            var insertedCount = 0
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))
                sqlite3_bind_int64(insertStmt, 4, sqlite3_column_int64(selectStmt, 2))
                sqlite3_bind_int64(insertStmt, 5, sqlite3_column_int64(selectStmt, 3))
                sqlite3_bind_int64(insertStmt, 6, sqlite3_column_int64(selectStmt, 4))
                sqlite3_bind_int64(insertStmt, 7, sqlite3_column_int64(selectStmt, 5))
                sqlite3_bind_double(insertStmt, 8, sqlite3_column_double(selectStmt, 6))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged accession insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
                insertedCount += 1
            }
            return insertedCount
        }
    }

    private static func mergeStageReferenceLengths(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = "SELECT accession, length FROM reference_lengths"
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage reference length select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)

                naoBindText(insertStmt, 1, String(cString: sqlite3_column_text(selectStmt, 0)))
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 1))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged reference length insert failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
            }
        }
    }

    private static func appendStageTaxonReadNames(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = """
        SELECT tax_id, seq_id
        FROM taxon_read_names
        WHERE sample = ?
        """
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage read-name select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)
                naoBindText(insertStmt, 1, stageInput.sample)
                sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))
                naoBindText(insertStmt, 3, String(cString: sqlite3_column_text(selectStmt, 1)))

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw NaoMgsDatabaseError.createFailed("Merged read-name insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
                }
            }
        }
    }

    private static func appendStageSampleHitCounts(
        from stageInput: NaoMgsStageDatabaseInput,
        into mergedDB: OpaquePointer,
        insertStmt: OpaquePointer?
    ) throws {
        let selectSQL = """
        SELECT hit_count
        FROM sample_hit_counts
        WHERE sample = ?
        """
        try withReadOnlySQLiteDatabase(at: stageInput.databaseURL) { stageDB in
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(stageDB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw NaoMgsDatabaseError.createFailed("Stage sample-hit select prepare failed for \(stageInput.databaseURL.lastPathComponent): \(String(cString: sqlite3_errmsg(stageDB)))")
            }
            defer { sqlite3_finalize(selectStmt) }

            naoBindText(selectStmt, 1, stageInput.sample)
            guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                throw NaoMgsDatabaseError.createFailed("Staged database \(stageInput.databaseURL.lastPathComponent) contributed no sample hit count for sample \(stageInput.sample)")
            }

            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)
            naoBindText(insertStmt, 1, stageInput.sample)
            sqlite3_bind_int64(insertStmt, 2, sqlite3_column_int64(selectStmt, 0))

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw NaoMgsDatabaseError.createFailed("Merged sample-hit insert failed for sample \(stageInput.sample): \(String(cString: sqlite3_errmsg(mergedDB)))")
            }
        }
    }

    private static func withReadOnlySQLiteDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw NaoMgsDatabaseError.openFailed("Failed to open staged database \(url.lastPathComponent): \(msg)")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }
}
