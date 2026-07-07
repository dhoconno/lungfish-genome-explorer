// NaoMgsDatabase+Summaries.swift - Taxon/accession summary computation for NAO-MGS database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension NaoMgsDatabase {

    // MARK: - Taxon Summary Computation

    static func computeTaxonSummaries(db: OpaquePointer) throws {
        // Step 1: Insert basic aggregates with placeholder unique_read_count=0
        let insertAgg = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json,
            bam_path, bam_index_path
        )
        SELECT
            sample,
            tax_id,
            MIN(subject_title),
            COUNT(*),
            0,
            AVG(percent_identity),
            AVG(bit_score),
            AVG(edit_distance),
            0,
            COUNT(DISTINCT subject_seq_id),
            '[]',
            NULL,
            NULL
        FROM virus_hits
        GROUP BY sample, tax_id
        """
        guard sqlite3_exec(db, insertAgg, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Summary aggregation failed: \(msg)")
        }

        // Step 2: Update unique_read_count via distinct alignment signatures
        let updateUnique = """
        UPDATE taxon_summaries SET unique_read_count = (
            SELECT COUNT(*) FROM (
                SELECT DISTINCT subject_seq_id, ref_start, is_reverse_complement, query_length,
                       IFNULL(ref_start_rev, -1), IFNULL(is_reverse_complement_rev, -1), IFNULL(query_length_rev, -1)
                FROM virus_hits
                WHERE virus_hits.sample = taxon_summaries.sample
                  AND virus_hits.tax_id = taxon_summaries.tax_id
            )
        )
        """
        guard sqlite3_exec(db, updateUnique, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Unique read count update failed: \(msg)")
        }

        // Step 3: pcr_duplicate_count = hit_count - unique_read_count
        let updateDups = """
        UPDATE taxon_summaries SET pcr_duplicate_count = hit_count - unique_read_count
        """
        guard sqlite3_exec(db, updateDups, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("PCR duplicate count update failed: \(msg)")
        }

        // Step 4: Compute top 5 accessions per (sample, tax_id)
        try computeTopAccessions(db: db)
    }

    private static func computeTopAccessions(db: OpaquePointer) throws {
        // Query all (sample, tax_id) pairs
        let pairSQL = "SELECT sample, tax_id FROM taxon_summaries"
        var pairStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, pairSQL, -1, &pairStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions pair query failed: \(msg)")
        }
        defer { sqlite3_finalize(pairStmt) }

        var pairs: [(sample: String, taxId: Int)] = []
        while sqlite3_step(pairStmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(pairStmt, 0))
            let taxId = Int(sqlite3_column_int64(pairStmt, 1))
            pairs.append((sample, taxId))
        }

        // For each pair, compute top 5 accessions by unique read count
        let topSQL = """
        SELECT subject_seq_id,
               COUNT(DISTINCT
                    CAST(ref_start AS TEXT) || '|' ||
                    CAST(is_reverse_complement AS TEXT) || '|' ||
                    CAST(query_length AS TEXT) || '|' ||
                    IFNULL(CAST(ref_start_rev AS TEXT), '') || '|' ||
                    IFNULL(CAST(is_reverse_complement_rev AS TEXT), '') || '|' ||
                    IFNULL(CAST(query_length_rev AS TEXT), '')
               ) as ucount
        FROM virus_hits
        WHERE sample = ? AND tax_id = ?
        GROUP BY subject_seq_id
        ORDER BY ucount DESC
        LIMIT 5
        """
        var topStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, topSQL, -1, &topStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions query failed: \(msg)")
        }
        defer { sqlite3_finalize(topStmt) }

        let updateSQL = "UPDATE taxon_summaries SET top_accessions_json = ? WHERE sample = ? AND tax_id = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Top accessions update prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(updateStmt) }

        for pair in pairs {
            sqlite3_reset(topStmt)
            sqlite3_clear_bindings(topStmt)
            naoBindText(topStmt, 1, pair.sample)
            sqlite3_bind_int64(topStmt, 2, Int64(pair.taxId))

            var accessions: [String] = []
            while sqlite3_step(topStmt) == SQLITE_ROW {
                let acc = String(cString: sqlite3_column_text(topStmt, 0))
                accessions.append(acc)
            }

            // Encode as JSON array
            let jsonData = try JSONSerialization.data(withJSONObject: accessions)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            naoBindText(updateStmt, 1, jsonString)
            naoBindText(updateStmt, 2, pair.sample)
            sqlite3_bind_int64(updateStmt, 3, Int64(pair.taxId))

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.createFailed("Top accessions update failed: \(msg)")
            }
        }
    }

    // MARK: - Accession Summary Pre-Computation

    /// Returns the set of columns present in the given table.
    private static func columnNames(in table: String, db: OpaquePointer) -> Set<String> {
        var names = Set<String>()
        var stmt: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: namePtr))
            }
        }
        return names
    }

    /// Pre-computes per-accession statistics (read count, unique reads, coverage)
    /// and stores them in the `accession_summaries` table. This replaces the
    /// expensive N+1 pileup queries that previously ran at display time.
    static func computeAccessionSummaries(db: OpaquePointer) throws {
        let virusHitColumns = columnNames(in: "virus_hits", db: db)
        let hasRefStartRev = virusHitColumns.contains("ref_start_rev")
        let hasQueryLengthRev = virusHitColumns.contains("query_length_rev")
        let hasIsReverseComplementRev = virusHitColumns.contains("is_reverse_complement_rev")

        let refStartRevExpr = hasRefStartRev ? "IFNULL(ref_start_rev, -1)" : "-1"
        let queryLengthRevExpr = hasQueryLengthRev ? "IFNULL(query_length_rev, -1)" : "-1"
        let isReverseComplementRevExpr = hasIsReverseComplementRev ? "IFNULL(is_reverse_complement_rev, -1)" : "-1"
        let maxRefEndExpr: String
        if hasRefStartRev && hasQueryLengthRev {
            maxRefEndExpr = "IFNULL(vh.ref_start_rev + IFNULL(vh.query_length_rev, 0), 0)"
        } else {
            maxRefEndExpr = "0"
        }

        // Step 1: Insert read_count, unique_read_count, and reference_length per (sample, tax_id, accession)
        let insertSQL = """
        INSERT INTO accession_summaries (
            sample, tax_id, accession, read_count, unique_read_count,
            reference_length, covered_base_pairs, coverage_fraction
        )
        SELECT
            vh.sample,
            vh.tax_id,
            vh.subject_seq_id,
            COUNT(*) as read_count,
            (SELECT COUNT(*) FROM (
                SELECT DISTINCT ref_start, is_reverse_complement, query_length,
                       \(refStartRevExpr), \(isReverseComplementRevExpr), \(queryLengthRevExpr)
                FROM virus_hits v2
                WHERE v2.sample = vh.sample AND v2.tax_id = vh.tax_id AND v2.subject_seq_id = vh.subject_seq_id
            )) as unique_read_count,
            COALESCE(
                (SELECT length FROM reference_lengths WHERE accession = vh.subject_seq_id),
                MAX(MAX(
                    vh.ref_start + vh.query_length,
                    \(maxRefEndExpr)
                ))
            ) as reference_length,
            0,
            0.0
        FROM virus_hits vh
        GROUP BY vh.sample, vh.tax_id, vh.subject_seq_id
        """
        guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Accession summary insert failed: \(msg)")
        }

        // Step 2: Compute pileup coverage for each accession via interval merging.
        // We iterate all (sample, tax_id, accession) groups and compute covered base pairs.
        let groupSQL = "SELECT sample, tax_id, accession, reference_length FROM accession_summaries"
        var groupStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, groupSQL, -1, &groupStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Accession summary group query failed: \(msg)")
        }
        defer { sqlite3_finalize(groupStmt) }

        var groups: [(sample: String, taxId: Int, accession: String, refLength: Int)] = []
        while sqlite3_step(groupStmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(groupStmt, 0))
            let taxId = Int(sqlite3_column_int64(groupStmt, 1))
            let accession = String(cString: sqlite3_column_text(groupStmt, 2))
            let refLength = Int(sqlite3_column_int64(groupStmt, 3))
            groups.append((sample, taxId, accession, refLength))
        }

        let pileupSQL = """
        SELECT ref_start, query_length, ref_start_rev, query_length_rev
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        """
        let legacyPileupSQL = """
        SELECT ref_start, query_length
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        """
        let updateSQL = "UPDATE accession_summaries SET covered_base_pairs = ?, coverage_fraction = ? WHERE sample = ? AND tax_id = ? AND accession = ?"

        var pileupStmt: OpaquePointer?
        let pileupSQLToUse = (hasRefStartRev && hasQueryLengthRev) ? pileupSQL : legacyPileupSQL
        guard sqlite3_prepare_v2(db, pileupSQLToUse, -1, &pileupStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Pileup query prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(pileupStmt) }

        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Coverage update prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(updateStmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for group in groups {
            sqlite3_reset(pileupStmt)
            sqlite3_clear_bindings(pileupStmt)
            naoBindText(pileupStmt, 1, group.sample)
            sqlite3_bind_int64(pileupStmt, 2, Int64(group.taxId))
            naoBindText(pileupStmt, 3, group.accession)

            var intervals: [(start: Int, end: Int)] = []
            while sqlite3_step(pileupStmt) == SQLITE_ROW {
                let refStart = Int(sqlite3_column_int64(pileupStmt, 0))
                let queryLen = Int(sqlite3_column_int64(pileupStmt, 1))
                intervals.append((start: refStart, end: refStart + queryLen))
                if hasRefStartRev && hasQueryLengthRev && sqlite3_column_type(pileupStmt, 2) != SQLITE_NULL {
                    let refStartRev = Int(sqlite3_column_int64(pileupStmt, 2))
                    let queryLenRev = sqlite3_column_type(pileupStmt, 3) == SQLITE_NULL
                        ? 0
                        : Int(sqlite3_column_int64(pileupStmt, 3))
                    if queryLenRev > 0 {
                        intervals.append((start: refStartRev, end: refStartRev + queryLenRev))
                    }
                }
            }

            let coveredBP = computeCoveredBasePairs(intervals)
            let coverageFraction = group.refLength > 0
                ? min(1.0, Double(coveredBP) / Double(group.refLength))
                : 0.0

            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            sqlite3_bind_int64(updateStmt, 1, Int64(coveredBP))
            sqlite3_bind_double(updateStmt, 2, coverageFraction)
            naoBindText(updateStmt, 3, group.sample)
            sqlite3_bind_int64(updateStmt, 4, Int64(group.taxId))
            naoBindText(updateStmt, 5, group.accession)
            sqlite3_step(updateStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Updates `accession_summaries.reference_length` and `coverage_fraction`
    /// from the `reference_lengths` table. Call after storing FASTA-derived
    /// reference lengths so the accession display uses real genome lengths
    /// instead of alignment extents.
    public func refreshAccessionSummaryReferenceLengths() throws {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        try Self.refreshAccessionSummaryReferenceLengths(db: db)
    }

    static func refreshAccessionSummaryReferenceLengths(db: OpaquePointer) throws {
        let sql = """
        UPDATE accession_summaries
        SET reference_length = (
                SELECT rl.length FROM reference_lengths rl
                WHERE rl.accession = accession_summaries.accession
            ),
            coverage_fraction = CASE
                WHEN (SELECT rl.length FROM reference_lengths rl
                      WHERE rl.accession = accession_summaries.accession) > 0
                THEN MIN(1.0, CAST(covered_base_pairs AS REAL)
                     / (SELECT rl.length FROM reference_lengths rl
                        WHERE rl.accession = accession_summaries.accession))
                ELSE coverage_fraction
            END
        WHERE accession IN (SELECT accession FROM reference_lengths)
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Failed to refresh accession summary reference lengths: \(msg)")
        }
    }
}
