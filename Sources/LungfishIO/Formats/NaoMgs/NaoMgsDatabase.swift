// NaoMgsDatabase.swift - SQLite-backed database for NAO-MGS virus hits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

let naoMgsDatabaseLogger = Logger(subsystem: LogSubsystem.io, category: "NaoMgsDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
func naoBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    _ = text.withCString { cStr in
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
    public let bamPath: String?
    public let bamIndexPath: String?

    public init(
        sample: String,
        taxId: Int,
        name: String,
        hitCount: Int,
        uniqueReadCount: Int,
        avgIdentity: Double,
        avgBitScore: Double,
        avgEditDistance: Double,
        pcrDuplicateCount: Int,
        accessionCount: Int,
        topAccessions: [String],
        bamPath: String?,
        bamIndexPath: String?
    ) {
        self.sample = sample
        self.taxId = taxId
        self.name = name
        self.hitCount = hitCount
        self.uniqueReadCount = uniqueReadCount
        self.avgIdentity = avgIdentity
        self.avgBitScore = avgBitScore
        self.avgEditDistance = avgEditDistance
        self.pcrDuplicateCount = pcrDuplicateCount
        self.accessionCount = accessionCount
        self.topAccessions = topAccessions
        self.bamPath = bamPath
        self.bamIndexPath = bamIndexPath
    }
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

/// A staged per-sample NAO-MGS database to merge into a final summary database.
public struct NaoMgsStageDatabaseInput: Sendable {
    public let sample: String
    public let databaseURL: URL
    public let bamRelativePath: String
    public let bamIndexRelativePath: String?

    public init(
        sample: String,
        databaseURL: URL,
        bamRelativePath: String,
        bamIndexRelativePath: String?
    ) {
        self.sample = sample
        self.databaseURL = databaseURL
        self.bamRelativePath = bamRelativePath
        self.bamIndexRelativePath = bamIndexRelativePath
    }
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

    var db: OpaquePointer?
    let url: URL

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
        // Schema migration: check which tables/columns need to be added.
        var hasRefLengths = false
        var hasAccessionSummaries = false
        var hasTaxonReadNames = false
        var hasSampleHitCounts = false
        let tableListSQL = "SELECT name FROM sqlite_master WHERE type='table'"
        var tblStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, tableListSQL, -1, &tblStmt, nil) == SQLITE_OK {
            while sqlite3_step(tblStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(tblStmt, 0) {
                    let name = String(cString: namePtr)
                    if name == "reference_lengths" { hasRefLengths = true }
                    if name == "accession_summaries" { hasAccessionSummaries = true }
                    if name == "taxon_read_names" { hasTaxonReadNames = true }
                    if name == "sample_hit_counts" { hasSampleHitCounts = true }
                }
            }
            sqlite3_finalize(tblStmt)
        }

        var hasBamPath = false
        var hasBamIndexPath = false
        let colCheck = "PRAGMA table_info(taxon_summaries)"
        var colStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, colCheck, -1, &colStmt, nil) == SQLITE_OK {
            while sqlite3_step(colStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(colStmt, 1) {
                    let colName = String(cString: namePtr)
                    if colName == "bam_path" { hasBamPath = true }
                    if colName == "bam_index_path" { hasBamIndexPath = true }
                }
            }
            sqlite3_finalize(colStmt)
        }

        let needsMigration = !hasRefLengths || !hasAccessionSummaries || !hasTaxonReadNames || !hasSampleHitCounts || !hasBamPath || !hasBamIndexPath
        if needsMigration {
            sqlite3_close(db)
            self.db = nil

            var rwDB: OpaquePointer?
            if sqlite3_open_v2(url.path, &rwDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                if !hasRefLengths {
                    sqlite3_exec(rwDB, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
                }
                if !hasBamPath {
                    sqlite3_exec(rwDB, "ALTER TABLE taxon_summaries ADD COLUMN bam_path TEXT", nil, nil, nil)
                }
                if !hasBamIndexPath {
                    sqlite3_exec(rwDB, "ALTER TABLE taxon_summaries ADD COLUMN bam_index_path TEXT", nil, nil, nil)
                }
                if !hasAccessionSummaries {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS accession_summaries (
                        sample TEXT NOT NULL,
                        tax_id INTEGER NOT NULL,
                        accession TEXT NOT NULL,
                        read_count INTEGER NOT NULL,
                        unique_read_count INTEGER NOT NULL,
                        reference_length INTEGER NOT NULL,
                        covered_base_pairs INTEGER NOT NULL,
                        coverage_fraction REAL NOT NULL,
                        PRIMARY KEY (sample, tax_id, accession)
                    )
                    """, nil, nil, nil)
                    // Populate from virus_hits if rows exist (pre-migration database)
                    if let rwDB {
                        var countStmt: OpaquePointer?
                        if sqlite3_prepare_v2(rwDB, "SELECT COUNT(*) FROM virus_hits", -1, &countStmt, nil) == SQLITE_OK {
                            if sqlite3_step(countStmt) == SQLITE_ROW, sqlite3_column_int64(countStmt, 0) > 0 {
                                naoMgsDatabaseLogger.info("Migrating: computing accession_summaries from virus_hits")
                                try? Self.computeAccessionSummaries(db: rwDB)
                            }
                            sqlite3_finalize(countStmt)
                        }
                    }
                }
                if !hasTaxonReadNames {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS taxon_read_names (
                        sample TEXT NOT NULL,
                        tax_id INTEGER NOT NULL,
                        seq_id TEXT NOT NULL,
                        PRIMARY KEY (sample, tax_id, seq_id)
                    )
                    """, nil, nil, nil)
                    try? Self.populateTaxonReadNames(db: rwDB)
                    sqlite3_exec(rwDB, "CREATE INDEX IF NOT EXISTS idx_taxon_read_names_sample_taxid ON taxon_read_names(sample, tax_id)", nil, nil, nil)
                }
                if !hasSampleHitCounts {
                    sqlite3_exec(rwDB, """
                    CREATE TABLE IF NOT EXISTS sample_hit_counts (
                        sample TEXT PRIMARY KEY,
                        hit_count INTEGER NOT NULL
                    )
                    """, nil, nil, nil)
                    try? Self.populateSampleHitCounts(db: rwDB)
                }
                sqlite3_close(rwDB)
            }

            let rc2 = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard rc2 == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                sqlite3_close(db)
                self.db = nil
                throw NaoMgsDatabaseError.openFailed(msg)
            }
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil) // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        naoMgsDatabaseLogger.info("Opened NAO-MGS database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Streaming Import Result

    /// Metadata returned by `createStreaming` after a streaming import.
    public struct StreamingImportResult: Sendable {
        /// Total number of hits inserted (after identity filtering).
        public let hitCount: Int
        /// Sample name (from the first row, or user override).
        public let sampleName: String
        /// Number of distinct (sample, taxId) pairs.
        public let taxonCount: Int
        /// Path to the virus_hits TSV file that was parsed.
        public let virusHitsFile: URL
    }

    // MARK: - Sample Name Normalization

    /// Strips Illumina sequencing metadata (`_S{index}_L{lane}`) from sample names.
    ///
    /// NAO-MGS sample names include Illumina lane/index suffixes like `_S2_L001`.
    /// Stripping these produces the biological sample identity, allowing reads from
    /// multiple lanes/indices to aggregate under one logical sample.
    public static func normalizeImportedSampleName(_ raw: String) -> String {
        if let range = raw.range(of: #"_S\d+_L\d+.*$"#, options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        return raw
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
                naoMgsDatabaseLogger.warning("Failed to update name for taxId \(taxId): \(msg, privacy: .public)")
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
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
        let sql = "SELECT length FROM reference_lengths WHERE accession = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NaoMgsDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
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
        // Schema migrations
        sqlite3_exec(instance.db, "CREATE TABLE IF NOT EXISTS reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL)", nil, nil, nil)
        sqlite3_exec(instance.db, "ALTER TABLE taxon_summaries ADD COLUMN bam_path TEXT", nil, nil, nil)
        sqlite3_exec(instance.db, "ALTER TABLE taxon_summaries ADD COLUMN bam_index_path TEXT", nil, nil, nil)
        sqlite3_exec(instance.db, """
        CREATE TABLE IF NOT EXISTS accession_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            accession TEXT NOT NULL,
            read_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            reference_length INTEGER NOT NULL,
            covered_base_pairs INTEGER NOT NULL,
            coverage_fraction REAL NOT NULL,
            PRIMARY KEY (sample, tax_id, accession)
        )
        """, nil, nil, nil)
        sqlite3_exec(instance.db, """
        CREATE TABLE IF NOT EXISTS taxon_read_names (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            seq_id TEXT NOT NULL,
            PRIMARY KEY (sample, tax_id, seq_id)
        )
        """, nil, nil, nil)
        return instance
    }

    /// Private initializer used by `openReadWrite(at:)`.
    private init(url: URL) {
        self.url = url
    }

    /// Deletes all rows from the `virus_hits` table and vacuums the database.
    ///
    /// Called after BAMs have been materialized and accession summaries pre-computed.
    /// The table structure is preserved (so schema checks don't break) but all row
    /// data — including read sequences and quality strings — is reclaimed.
    ///
    /// Requires a read-write database connection (use `openReadWrite(at:)`).
    public func deleteVirusHitsAndVacuum() throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard sqlite3_exec(db, "DELETE FROM virus_hits", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Failed to delete virus_hits: \(msg)")
        }
        // Drop indices on the now-empty table to save space
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_sample_taxon_accession", nil, nil, nil)
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_taxon_accession", nil, nil, nil)
        sqlite3_exec(db, "DROP INDEX IF EXISTS idx_hits_sample", nil, nil, nil)
        // Reclaim disk space
        guard sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("VACUUM failed: \(msg)")
        }
        naoMgsDatabaseLogger.info("Deleted virus_hits rows and vacuumed database")
    }

    /// Updates BAM and index paths for all taxon rows in each sample.
    ///
    /// - Parameter bamPathsBySample: Maps sample ID -> (bam path, optional index path),
    ///   both paths relative to the NAO-MGS result directory.
    public func updateBamPaths(_ bamPathsBySample: [String: (bamPath: String, bamIndexPath: String?)]) throws {
        guard let db else {
            throw NaoMgsDatabaseError.queryFailed("Database not open")
        }
        guard !bamPathsBySample.isEmpty else { return }

        let sql = "UPDATE taxon_summaries SET bam_path = ?, bam_index_path = ? WHERE sample = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NaoMgsDatabaseError.queryFailed("Prepare BAM path update failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for (sample, paths) in bamPathsBySample {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            naoBindText(stmt, 1, paths.bamPath)
            if let bamIndexPath = paths.bamIndexPath {
                naoBindText(stmt, 2, bamIndexPath)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            naoBindText(stmt, 3, sample)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                let msg = String(cString: sqlite3_errmsg(db))
                throw NaoMgsDatabaseError.queryFailed("BAM path update failed for sample \(sample): \(msg)")
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Merges overlapping intervals and returns total covered base pairs.
    static func computeCoveredBasePairs(_ intervals: [(start: Int, end: Int)]) -> Int {
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
}
