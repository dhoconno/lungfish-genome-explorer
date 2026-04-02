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
public struct NaoMgsTaxonSummaryRow: Codable, Sendable {
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
    public let referenceLength: Int
    public let coveredBasePairs: Int
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
        // Schema migration: ensure reference_lengths table exists (added post-initial release)
        let tableCheck = "SELECT name FROM sqlite_master WHERE type='table' AND name='reference_lengths'"
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, tableCheck, -1, &checkStmt, nil) == SQLITE_OK {
            if sqlite3_step(checkStmt) != SQLITE_ROW {
                // Table doesn't exist — reopen read-write briefly to create it
                sqlite3_finalize(checkStmt)
                sqlite3_close(db)
                self.db = nil

                var rwDB: OpaquePointer?
                if sqlite3_open_v2(url.path, &rwDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                    sqlite3_exec(rwDB, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
                    sqlite3_close(rwDB)
                }

                // Reopen read-only
                let rc2 = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
                guard rc2 == SQLITE_OK else {
                    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                    sqlite3_close(db)
                    self.db = nil
                    throw NaoMgsDatabaseError.openFailed(msg)
                }
            } else {
                sqlite3_finalize(checkStmt)
            }
        } else {
            sqlite3_finalize(checkStmt)
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

        CREATE TABLE reference_lengths (
            accession TEXT PRIMARY KEY,
            length INTEGER NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Sample Name Normalization

    /// Strips Illumina sequencing metadata (`_S{index}_L{lane}`) from sample names.
    ///
    /// NAO-MGS sample names include Illumina lane/index suffixes like `_S2_L001`.
    /// Stripping these produces the biological sample identity, allowing reads from
    /// multiple lanes/indices to aggregate under one logical sample.
    private static func normalizeSampleName(_ raw: String) -> String {
        if let range = raw.range(of: #"_S\d+_L\d+.*$"#, options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        return raw
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

            naoBindText(stmt, 1, normalizeSampleName(hit.sample))
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

    // MARK: - Taxon Name Updates

    /// Returns the distinct taxon IDs that have empty or placeholder names.
    ///
    /// - Returns: Array of taxon ID integers needing name resolution.
    public func taxonIdsNeedingNames() throws -> [Int] {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT DISTINCT tax_id FROM taxon_summaries WHERE name = '' OR name LIKE 'Taxon %'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var ids: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int64(stmt, 0)))
        }
        return ids
    }

    /// Updates taxon names in the summary table. Database must be open read-write.
    ///
    /// - Parameter names: Dictionary mapping taxon ID to resolved scientific name.
    public func updateTaxonNames(_ names: [Int: String]) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard !names.isEmpty else { return }

        let sql = "UPDATE taxon_summaries SET name = ? WHERE tax_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Prepare taxon name update failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (taxId, name) in names {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, name)
            sqlite3_bind_int64(stmt, 2, Int64(taxId))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                logger.warning("Failed to update name for taxId \(taxId): \(msg, privacy: .public)")
                continue
            }
        }
    }

    // MARK: - Reference Length Updates

    /// Stores reference sequence lengths. Database must be open read-write.
    ///
    /// - Parameter lengths: Dictionary mapping accession string to sequence length in bases.
    public func updateReferenceLengths(_ lengths: [String: Int]) throws {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        let sql = "INSERT OR REPLACE INTO reference_lengths (accession, length) VALUES (?, ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for (accession, length) in lengths {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, accession)
            sqlite3_bind_int64(stmt, 2, Int64(length))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Returns the reference length for an accession, or nil if unknown.
    public func referenceLength(forAccession accession: String) throws -> Int? {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT length FROM reference_lengths WHERE accession = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        naoBindText(stmt, 1, accession)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return nil
    }

    // MARK: - Read-Write Access

    /// Opens an existing NAO-MGS database for reading and writing.
    ///
    /// Used during import to update taxon names after creation.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``NaoMgsDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public static func openReadWrite(at url: URL) throws -> NaoMgsDatabase {
        let instance = NaoMgsDatabase(url: url)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &instance.db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = instance.db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(instance.db)
            instance.db = nil
            throw NaoMgsDatabaseError.openFailed(msg)
        }
        // Schema migration: ensure reference_lengths table exists (added post-initial release)
        sqlite3_exec(instance.db, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
        return instance
    }

    /// Private initializer used by `openReadWrite(at:)`.
    private init(url: URL) {
        self.url = url
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

        // Step 1: Get read_count, unique_read_count, and ref_length per accession
        let summarySQL = """
        SELECT
            vh.subject_seq_id,
            COUNT(*) as read_count,
            (SELECT COUNT(*) FROM (
                SELECT DISTINCT ref_start, is_reverse_complement, query_length
                FROM virus_hits v2
                WHERE v2.sample = ? AND v2.tax_id = ? AND v2.subject_seq_id = vh.subject_seq_id
            )) as unique_read_count,
            COALESCE(
                (SELECT length FROM reference_lengths WHERE accession = vh.subject_seq_id),
                MAX(vh.ref_start + vh.query_length)
            ) as ref_length
        FROM virus_hits vh
        WHERE vh.sample = ? AND vh.tax_id = ?
        GROUP BY vh.subject_seq_id
        ORDER BY read_count DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        naoBindText(stmt, 1, sample)
        sqlite3_bind_int64(stmt, 2, Int64(taxId))
        naoBindText(stmt, 3, sample)
        sqlite3_bind_int64(stmt, 4, Int64(taxId))

        // Collect intermediate results (accession, readCount, uniqueReadCount, refLength)
        var intermediates: [(accession: String, readCount: Int, uniqueReadCount: Int, refLength: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let accession = String(cString: sqlite3_column_text(stmt, 0))
            let readCount = Int(sqlite3_column_int64(stmt, 1))
            let uniqueReadCount = Int(sqlite3_column_int64(stmt, 2))
            let refLength = Int(sqlite3_column_int64(stmt, 3))
            intermediates.append((accession, readCount, uniqueReadCount, refLength))
        }

        // Step 2: For each accession, compute true pileup coverage via interval merging
        let pileupSQL = "SELECT ref_start, query_length FROM virus_hits WHERE sample = ? AND tax_id = ? AND subject_seq_id = ?"

        var results: [NaoMgsAccessionSummary] = []
        for entry in intermediates {
            var pileupStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, pileupSQL, -1, &pileupStmt, nil) == SQLITE_OK else {
                // Fall back to 0 coverage on query failure
                results.append(NaoMgsAccessionSummary(
                    accession: entry.accession, readCount: entry.readCount,
                    uniqueReadCount: entry.uniqueReadCount, referenceLength: entry.refLength,
                    coveredBasePairs: 0, coverageFraction: 0.0
                ))
                continue
            }
            defer { sqlite3_finalize(pileupStmt) }

            naoBindText(pileupStmt, 1, sample)
            sqlite3_bind_int64(pileupStmt, 2, Int64(taxId))
            naoBindText(pileupStmt, 3, entry.accession)

            var intervals: [(start: Int, end: Int)] = []
            while sqlite3_step(pileupStmt) == SQLITE_ROW {
                let refStart = Int(sqlite3_column_int64(pileupStmt, 0))
                let queryLen = Int(sqlite3_column_int64(pileupStmt, 1))
                intervals.append((start: refStart, end: refStart + queryLen))
            }

            let coveredBP = Self.computeCoveredBasePairs(intervals)
            let coverageFraction = entry.refLength > 0
                ? min(1.0, Double(coveredBP) / Double(entry.refLength))
                : 0.0

            results.append(NaoMgsAccessionSummary(
                accession: entry.accession,
                readCount: entry.readCount,
                uniqueReadCount: entry.uniqueReadCount,
                referenceLength: entry.refLength,
                coveredBasePairs: coveredBP,
                coverageFraction: coverageFraction
            ))
        }
        return results
    }

    /// Merges overlapping intervals and returns total covered base pairs.
    private static func computeCoveredBasePairs(_ intervals: [(start: Int, end: Int)]) -> Int {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.start < $1.start }
        var mergedStart = sorted[0].start
        var mergedEnd = sorted[0].end
        var total = 0
        for interval in sorted.dropFirst() {
            if interval.start <= mergedEnd {
                mergedEnd = max(mergedEnd, interval.end)
            } else {
                total += mergedEnd - mergedStart
                mergedStart = interval.start
                mergedEnd = interval.end
            }
        }
        total += mergedEnd - mergedStart
        return total
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

    // MARK: - BLAST Read Selection

    /// Fetches full virus hit records for BLAST verification, selecting representative
    /// reads from different genome positions. Returns reads deduplicated by alignment
    /// signature (accession + position + strand + length).
    ///
    /// - Parameters:
    ///   - sample: The sample name.
    ///   - taxId: The taxonomy ID.
    ///   - maxReads: Maximum number of reads to return (default 50).
    /// - Returns: Array of ``NaoMgsVirusHit`` suitable for BLAST verification.
    public func fetchVirusHitsForBLAST(
        sample: String,
        taxId: Int,
        maxReads: Int = 50
    ) throws -> [NaoMgsVirusHit] {
        guard let db else { throw NaoMgsDatabaseError.queryFailed("Database not open") }

        let sql = """
            SELECT sample, seq_id, tax_id, subject_seq_id, subject_title,
                   ref_start, cigar, read_sequence, read_quality,
                   percent_identity, bit_score, e_value, edit_distance,
                   query_length, is_reverse_complement, pair_status,
                   fragment_length, best_alignment_score
            FROM virus_hits
            WHERE sample = ? AND tax_id = ?
            GROUP BY subject_seq_id, ref_start, is_reverse_complement, query_length
            ORDER BY edit_distance ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        naoBindText(stmt, 1, sample)
        sqlite3_bind_int(stmt, 2, Int32(taxId))
        sqlite3_bind_int(stmt, 3, Int32(maxReads))

        var results: [NaoMgsVirusHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hit = NaoMgsVirusHit(
                sample: String(cString: sqlite3_column_text(stmt, 0)),
                seqId: String(cString: sqlite3_column_text(stmt, 1)),
                taxId: Int(sqlite3_column_int(stmt, 2)),
                bestAlignmentScore: sqlite3_column_double(stmt, 17),
                cigar: String(cString: sqlite3_column_text(stmt, 6)),
                queryStart: 0,
                queryEnd: Int(sqlite3_column_int(stmt, 13)),
                refStart: Int(sqlite3_column_int(stmt, 5)),
                refEnd: Int(sqlite3_column_int(stmt, 5)) + Int(sqlite3_column_int(stmt, 13)),
                readSequence: String(cString: sqlite3_column_text(stmt, 7)),
                readQuality: String(cString: sqlite3_column_text(stmt, 8)),
                subjectSeqId: String(cString: sqlite3_column_text(stmt, 3)),
                subjectTitle: String(cString: sqlite3_column_text(stmt, 4)),
                bitScore: sqlite3_column_double(stmt, 10),
                eValue: sqlite3_column_double(stmt, 11),
                percentIdentity: sqlite3_column_double(stmt, 9),
                editDistance: Int(sqlite3_column_int(stmt, 12)),
                fragmentLength: Int(sqlite3_column_int(stmt, 16)),
                isReverseComplement: sqlite3_column_int(stmt, 14) != 0,
                pairStatus: String(cString: sqlite3_column_text(stmt, 15)),
                queryLength: Int(sqlite3_column_int(stmt, 13))
            )
            results.append(hit)
        }
        return results
    }
}
