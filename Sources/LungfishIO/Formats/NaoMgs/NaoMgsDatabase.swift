// NaoMgsDatabase.swift - SQLite-backed database for NAO-MGS virus hits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "NaoMgsDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func naoBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - NaoMgsDatabaseError

/// Errors from NAO-MGS database operations.
public enum NaoMgsDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open NAO-MGS database: \(msg)"
        case .createFailed(let msg): return "Failed to create NAO-MGS database: \(msg)"
        case .queryFailed(let msg): return "NAO-MGS database query failed: \(msg)"
        case .insertFailed(let msg): return "NAO-MGS database insert failed: \(msg)"
        }
    }
}

// MARK: - Result Types

/// A single row in the taxonomy table — one per (sample, taxon) pair.
public struct NaoMgsTaxonSummaryRow: Sendable {
    public let sample: String
    public let taxId: Int
    public let name: String
    public let hitCount: Int
    public let uniqueReadCount: Int
    public let avgIdentity: Double
    public let avgBitScore: Double
    public let avgEditDistance: Double
    public let pcrDuplicateCount: Int
    public let accessionCount: Int
    public let topAccessions: [String]  // decoded from JSON
}

/// Per-accession summary within a (sample, taxon) pair.
public struct NaoMgsAccessionSummary: Sendable {
    public let accession: String
    public let readCount: Int
    public let uniqueReadCount: Int
    public let estimatedRefLength: Int
    public let coverageFraction: Double
}

// MARK: - NaoMgsDatabase

/// SQLite-backed storage for NAO-MGS virus hits and taxon summaries.
///
/// Provides fast random-access queries for taxonomy browsing and detail views.
/// Created once during import, then opened read-only for all subsequent access.
///
/// Thread-safe via `@unchecked Sendable` — the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class NaoMgsDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing NAO-MGS database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``NaoMgsDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw NaoMgsDatabaseError.openFailed(msg)
        }
        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil) // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened NAO-MGS database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Create New Database

    /// Creates a new NAO-MGS database from parsed virus hits.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all hits,
    /// builds indices, and computes taxon summaries via SQL aggregation.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - hits: Parsed virus hits to insert.
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: An `NaoMgsDatabase` opened read-only on the new file.
    /// - Throws: ``NaoMgsDatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> NaoMgsDatabase {
        // Delete existing file
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw NaoMgsDatabaseError.createFailed(msg)
        }

        // Performance pragmas for bulk import
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: db)
            progress?(0.05, "Schema created")

            try bulkInsertHits(db: db, hits: hits, progress: progress)
            progress?(0.70, "Building indices...")

            try createIndices(db: db)
            progress?(0.80, "Computing taxon summaries...")

            try computeTaxonSummaries(db: db)
            progress?(0.95, "Finalizing...")

            sqlite3_close(db)
            logger.info("Created NAO-MGS database with \(hits.count) hits at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try NaoMgsDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER NOT NULL,
            cigar TEXT NOT NULL,
            read_sequence TEXT NOT NULL,
            read_quality TEXT NOT NULL,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER NOT NULL,
            query_length INTEGER NOT NULL,
            is_reverse_complement INTEGER NOT NULL,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL NOT NULL
        );

        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            avg_identity REAL NOT NULL,
            avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL,
            pcr_duplicate_count INTEGER NOT NULL,
            accession_count INTEGER NOT NULL,
            top_accessions_json TEXT NOT NULL,
            PRIMARY KEY (sample, tax_id)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert

    private static func bulkInsertHits(
        db: OpaquePointer,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !hits.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO virus_hits (
            sample, seq_id, tax_id, subject_seq_id, subject_title,
            ref_start, cigar, read_sequence, read_quality,
            percent_identity, bit_score, e_value, edit_distance,
            query_length, is_reverse_complement, pair_status,
            fragment_length, best_alignment_score
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw NaoMgsDatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = hits.count
        let reportInterval = max(1, total / 20) // ~5% increments

        for (i, hit) in hits.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            naoBindText(stmt, 1, hit.sample)
            naoBindText(stmt, 2, hit.seqId)
            sqlite3_bind_int64(stmt, 3, Int64(hit.taxId))
            naoBindText(stmt, 4, hit.subjectSeqId)
            naoBindText(stmt, 5, hit.subjectTitle)
            sqlite3_bind_int64(stmt, 6, Int64(hit.refStart))
            naoBindText(stmt, 7, hit.cigar)
            naoBindText(stmt, 8, hit.readSequence)
            naoBindText(stmt, 9, hit.readQuality)
            sqlite3_bind_double(stmt, 10, hit.percentIdentity)
            sqlite3_bind_double(stmt, 11, hit.bitScore)
            sqlite3_bind_double(stmt, 12, hit.eValue)
            sqlite3_bind_int(stmt, 13, Int32(hit.editDistance))
            sqlite3_bind_int(stmt, 14, Int32(hit.queryLength))
            sqlite3_bind_int(stmt, 15, hit.isReverseComplement ? 1 : 0)
            naoBindText(stmt, 16, hit.pairStatus)
            sqlite3_bind_int(stmt, 17, Int32(hit.fragmentLength))
            sqlite3_bind_double(stmt, 18, hit.bestAlignmentScore)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw NaoMgsDatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.65 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting hits \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.insertFailed("Commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            "CREATE INDEX idx_hits_sample_taxon_accession ON virus_hits(sample, tax_id, subject_seq_id)",
            "CREATE INDEX idx_hits_taxon_accession ON virus_hits(tax_id, subject_seq_id)",
            "CREATE INDEX idx_hits_sample ON virus_hits(sample)",
            "CREATE INDEX idx_summaries_sample ON taxon_summaries(sample)",
            "CREATE INDEX idx_summaries_hitcount ON taxon_summaries(sample, hit_count DESC)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    // MARK: - Taxon Summary Computation

    private static func computeTaxonSummaries(db: OpaquePointer) throws {
        // Step 1: Insert basic aggregates with placeholder unique_read_count=0
        let insertAgg = """
        INSERT INTO taxon_summaries (
            sample, tax_id, name, hit_count, unique_read_count,
            avg_identity, avg_bit_score, avg_edit_distance,
            pcr_duplicate_count, accession_count, top_accessions_json
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
            '[]'
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
                SELECT DISTINCT subject_seq_id, ref_start, is_reverse_complement, query_length
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
        SELECT subject_seq_id, COUNT(DISTINCT ref_start || '|' || is_reverse_complement || '|' || query_length) as ucount
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

    // MARK: - Queries

    /// Returns the total number of virus hits, optionally filtered by sample names.
    ///
    /// - Parameter samples: If non-nil, only count hits from these samples.
    /// - Returns: Total hit count.
    public func totalHitCount(samples: [String]? = nil) throws -> Int {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql: String
        if let samples, !samples.isEmpty {
            let placeholders = samples.map { _ in "?" }.joined(separator: ",")
            sql = "SELECT COUNT(*) FROM virus_hits WHERE sample IN (\(placeholders))"
        } else {
            sql = "SELECT COUNT(*) FROM virus_hits"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        // Bind sample parameters if filtering
        if let samples, !samples.isEmpty {
            for (i, sample) in samples.enumerated() {
                naoBindText(stmt, Int32(i + 1), sample)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NaoMgsDatabaseError.queryFailed("COUNT query returned no rows")
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Sample Queries

    /// Returns all distinct samples with their hit counts.
    ///
    /// - Returns: Array of (sample, hitCount) tuples ordered by sample name.
    public func fetchSamples() throws -> [(sample: String, hitCount: Int)] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, COUNT(*) as hit_count FROM virus_hits GROUP BY sample ORDER BY sample"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(sample: String, hitCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let hitCount = Int(sqlite3_column_int64(stmt, 1))
            results.append((sample, hitCount))
        }
        return results
    }

    // MARK: - Taxon Summary Queries

    /// Returns taxon summary rows, optionally filtered by sample names.
    ///
    /// - Parameter samples: If non-nil and non-empty, only return rows for these samples.
    /// - Returns: Array of ``NaoMgsTaxonSummaryRow`` sorted by hit count descending.
    public func fetchTaxonSummaryRows(samples: [String]? = nil) throws -> [NaoMgsTaxonSummaryRow] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql: String
        if let samples, !samples.isEmpty {
            let placeholders = samples.map { _ in "?" }.joined(separator: ",")
            sql = "SELECT * FROM taxon_summaries WHERE sample IN (\(placeholders)) ORDER BY hit_count DESC"
        } else {
            sql = "SELECT * FROM taxon_summaries ORDER BY hit_count DESC"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        if let samples, !samples.isEmpty {
            for (i, sample) in samples.enumerated() {
                naoBindText(stmt, Int32(i + 1), sample)
            }
        }

        var rows: [NaoMgsTaxonSummaryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let taxId = Int(sqlite3_column_int64(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let hitCount = Int(sqlite3_column_int64(stmt, 3))
            let uniqueReadCount = Int(sqlite3_column_int64(stmt, 4))
            let avgIdentity = sqlite3_column_double(stmt, 5)
            let avgBitScore = sqlite3_column_double(stmt, 6)
            let avgEditDistance = sqlite3_column_double(stmt, 7)
            let pcrDuplicateCount = Int(sqlite3_column_int64(stmt, 8))
            let accessionCount = Int(sqlite3_column_int64(stmt, 9))
            let topAccessionsJSON = String(cString: sqlite3_column_text(stmt, 10))

            // Decode top_accessions_json
            let topAccessions: [String]
            if let data = topAccessionsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                topAccessions = parsed
            } else {
                topAccessions = []
            }

            rows.append(NaoMgsTaxonSummaryRow(
                sample: sample,
                taxId: taxId,
                name: name,
                hitCount: hitCount,
                uniqueReadCount: uniqueReadCount,
                avgIdentity: avgIdentity,
                avgBitScore: avgBitScore,
                avgEditDistance: avgEditDistance,
                pcrDuplicateCount: pcrDuplicateCount,
                accessionCount: accessionCount,
                topAccessions: topAccessions
            ))
        }
        return rows
    }

    // MARK: - Accession Summary Queries

    /// Returns per-accession statistics for a given sample and taxon.
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    /// - Returns: Array of ``NaoMgsAccessionSummary`` sorted by read count descending.
    public func fetchAccessionSummaries(sample: String, taxId: Int) throws -> [NaoMgsAccessionSummary] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        SELECT
            subject_seq_id,
            COUNT(*) as read_count,
            (SELECT COUNT(*) FROM (
                SELECT DISTINCT ref_start, is_reverse_complement, query_length
                FROM virus_hits v2
                WHERE v2.sample = ? AND v2.tax_id = ? AND v2.subject_seq_id = virus_hits.subject_seq_id
            )) as unique_read_count,
            MAX(ref_start + query_length) as estimated_ref_length,
            COUNT(DISTINCT ref_start) as distinct_positions
        FROM virus_hits
        WHERE sample = ? AND tax_id = ?
        GROUP BY subject_seq_id
        ORDER BY read_count DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        naoBindText(stmt, 1, sample)
        sqlite3_bind_int64(stmt, 2, Int64(taxId))
        naoBindText(stmt, 3, sample)
        sqlite3_bind_int64(stmt, 4, Int64(taxId))

        var results: [NaoMgsAccessionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let accession = String(cString: sqlite3_column_text(stmt, 0))
            let readCount = Int(sqlite3_column_int64(stmt, 1))
            let uniqueReadCount = Int(sqlite3_column_int64(stmt, 2))
            let estimatedRefLength = Int(sqlite3_column_int64(stmt, 3))
            let distinctPositions = Int(sqlite3_column_int64(stmt, 4))
            let coverageFraction = estimatedRefLength > 0
                ? Double(distinctPositions) / Double(estimatedRefLength)
                : 0.0

            results.append(NaoMgsAccessionSummary(
                accession: accession,
                readCount: readCount,
                uniqueReadCount: uniqueReadCount,
                estimatedRefLength: estimatedRefLength,
                coverageFraction: coverageFraction
            ))
        }
        return results
    }

    // MARK: - Read Queries

    /// Returns aligned reads for a specific accession within a sample and taxon.
    ///
    /// Converts raw virus hit rows into ``AlignedRead`` objects suitable for
    /// the alignment viewer.
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    ///   - accession: The accession (subject_seq_id).
    ///   - maxReads: Maximum number of reads to return (default 500).
    /// - Returns: Array of ``AlignedRead`` objects.
    public func fetchReadsForAccession(
        sample: String,
        taxId: Int,
        accession: String,
        maxReads: Int = 500
    ) throws -> [AlignedRead] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        SELECT seq_id, subject_seq_id, ref_start, cigar, read_sequence, read_quality,
               is_reverse_complement, bit_score, edit_distance, fragment_length
        FROM virus_hits
        WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        naoBindText(stmt, 1, sample)
        sqlite3_bind_int64(stmt, 2, Int64(taxId))
        naoBindText(stmt, 3, accession)
        sqlite3_bind_int(stmt, 4, Int32(maxReads))

        var reads: [AlignedRead] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seqId = String(cString: sqlite3_column_text(stmt, 0))
            let subjectSeqId = String(cString: sqlite3_column_text(stmt, 1))
            let refStart = Int(sqlite3_column_int64(stmt, 2))
            let cigarStr = String(cString: sqlite3_column_text(stmt, 3))
            let readSequence = String(cString: sqlite3_column_text(stmt, 4))
            let readQuality = String(cString: sqlite3_column_text(stmt, 5))
            let isRC = sqlite3_column_int(stmt, 6) != 0
            let bitScore = sqlite3_column_double(stmt, 7)
            let editDist = Int(sqlite3_column_int(stmt, 8))
            let fragLength = Int(sqlite3_column_int(stmt, 9))

            let flag: UInt16 = isRC ? 0x10 : 0
            let mapq = min(UInt8(bitScore / 5.0), 60)
            let cigar = CIGAROperation.parse(cigarStr) ?? []
            let qualities = readQuality.unicodeScalars.map { UInt8($0.value) - 33 }

            reads.append(AlignedRead(
                name: seqId,
                flag: flag,
                chromosome: subjectSeqId,
                position: refStart,
                mapq: mapq,
                cigar: cigar,
                sequence: readSequence,
                qualities: qualities,
                insertSize: fragLength,
                editDistance: editDist
            ))
        }
        return reads
    }
}
