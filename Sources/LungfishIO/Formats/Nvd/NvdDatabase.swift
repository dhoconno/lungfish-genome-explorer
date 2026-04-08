// NvdDatabase.swift - SQLite-backed database for NVD BLAST results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "NvdDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func nvdBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - NvdDatabaseError

/// Errors from NVD database operations.
public enum NvdDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open NVD database: \(msg)"
        case .createFailed(let msg): return "Failed to create NVD database: \(msg)"
        case .queryFailed(let msg): return "NVD database query failed: \(msg)"
        case .insertFailed(let msg): return "NVD database insert failed: \(msg)"
        }
    }
}

// MARK: - Result Types

/// Per-sample metadata stored in the NVD database.
public struct NvdSampleMetadata: Sendable, Codable {
    public let sampleId: String
    public let bamPath: String
    public let fastaPath: String
    public let totalReads: Int
    public let contigCount: Int
    public let hitCount: Int

    public init(
        sampleId: String,
        bamPath: String,
        fastaPath: String,
        totalReads: Int,
        contigCount: Int,
        hitCount: Int
    ) {
        self.sampleId = sampleId
        self.bamPath = bamPath
        self.fastaPath = fastaPath
        self.totalReads = totalReads
        self.contigCount = contigCount
        self.hitCount = hitCount
    }
}

/// Aggregated taxon-level summary for one or more samples.
public struct NvdTaxonGroup: Sendable {
    public let adjustedTaxidName: String
    public let adjustedTaxidRank: String
    public let contigCount: Int
    public let totalMappedReads: Int

    public init(
        adjustedTaxidName: String,
        adjustedTaxidRank: String,
        contigCount: Int,
        totalMappedReads: Int
    ) {
        self.adjustedTaxidName = adjustedTaxidName
        self.adjustedTaxidRank = adjustedTaxidRank
        self.contigCount = contigCount
        self.totalMappedReads = totalMappedReads
    }
}

// MARK: - NvdDatabase

/// SQLite-backed storage for NVD BLAST results and sample metadata.
///
/// Provides fast random-access queries for taxonomy browsing, contig detail views,
/// and cross-sample comparisons.  Created once during import, then opened read-only
/// for all subsequent access.
///
/// Thread-safe via `@unchecked Sendable` — the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class NvdDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing NVD database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``NvdDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw NvdDatabaseError.openFailed(msg)
        }

        // Schema migration: ensure unique_reads column exists (added post-initial release)
        let colCheck = "PRAGMA table_info(blast_hits)"
        var checkStmt: OpaquePointer?
        var hasUniqueReads = false
        if sqlite3_prepare_v2(db, colCheck, -1, &checkStmt, nil) == SQLITE_OK {
            while sqlite3_step(checkStmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(checkStmt, 1) {
                    let colName = String(cString: namePtr)
                    if colName == "unique_reads" {
                        hasUniqueReads = true
                        break
                    }
                }
            }
            sqlite3_finalize(checkStmt)
        }
        if !hasUniqueReads {
            // Close read-only handle, reopen read-write to add the column
            sqlite3_close(db)
            db = nil
            var rwDB: OpaquePointer?
            if sqlite3_open_v2(url.path, &rwDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                sqlite3_exec(rwDB, "ALTER TABLE blast_hits ADD COLUMN unique_reads INTEGER", nil, nil, nil)
                sqlite3_close(rwDB)
            }
            // Reopen read-only
            let rc2 = sqlite3_open_v2(url.path, &db, flags, nil)
            guard rc2 == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                sqlite3_close(db)
                db = nil
                throw NvdDatabaseError.openFailed(msg)
            }
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)  // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened NVD database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Private init (used by create)

    private init(url: URL) {
        self.url = url
    }

    // MARK: - Create New Database

    /// Creates a new NVD database from parsed BLAST hits and sample metadata.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all hits
    /// and sample rows, then builds indices.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - hits: Parsed BLAST hits to insert.
    ///   - samples: Per-sample metadata (bam/fasta paths, read counts, etc.).
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: An `NvdDatabase` opened read-only on the new file.
    /// - Throws: ``NvdDatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        hits: [NvdBlastHit],
        samples: [NvdSampleMetadata],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> NvdDatabase {
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
            throw NvdDatabaseError.createFailed(msg)
        }

        // Performance pragmas for bulk import
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: db)
            progress?(0.05, "Schema created")

            try bulkInsertHits(db: db, hits: hits, progress: progress)
            progress?(0.70, "Inserting sample metadata...")

            try bulkInsertSamples(db: db, samples: samples)
            progress?(0.80, "Building indices...")

            try createIndices(db: db)
            progress?(0.95, "Finalizing...")

            sqlite3_close(db)
            logger.info("Created NVD database with \(hits.count) hits at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try NvdDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE blast_hits (
            rowid INTEGER PRIMARY KEY,
            experiment TEXT NOT NULL,
            blast_task TEXT NOT NULL,
            sample_id TEXT NOT NULL,
            qseqid TEXT NOT NULL,
            qlen INTEGER NOT NULL,
            sseqid TEXT NOT NULL,
            stitle TEXT NOT NULL,
            tax_rank TEXT NOT NULL,
            length INTEGER NOT NULL,
            pident REAL NOT NULL,
            evalue REAL NOT NULL,
            bitscore REAL NOT NULL,
            sscinames TEXT NOT NULL,
            staxids TEXT NOT NULL,
            blast_db_version TEXT NOT NULL,
            snakemake_run_id TEXT NOT NULL,
            mapped_reads INTEGER NOT NULL,
            unique_reads INTEGER,
            total_reads INTEGER NOT NULL,
            stat_db_version TEXT NOT NULL,
            adjusted_taxid INTEGER NOT NULL,
            adjustment_method TEXT NOT NULL,
            adjusted_taxid_name TEXT NOT NULL,
            adjusted_taxid_rank TEXT NOT NULL,
            hit_rank INTEGER NOT NULL,
            reads_per_billion REAL NOT NULL
        );

        CREATE TABLE samples (
            sample_id TEXT PRIMARY KEY,
            bam_path TEXT NOT NULL,
            fasta_path TEXT NOT NULL,
            total_reads INTEGER NOT NULL,
            contig_count INTEGER NOT NULL,
            hit_count INTEGER NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Hits

    private static func bulkInsertHits(
        db: OpaquePointer,
        hits: [NvdBlastHit],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !hits.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO blast_hits (
            experiment, blast_task, sample_id, qseqid, qlen,
            sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
            sscinames, staxids, blast_db_version, snakemake_run_id,
            mapped_reads, unique_reads, total_reads, stat_db_version,
            adjusted_taxid, adjustment_method, adjusted_taxid_name,
            adjusted_taxid_rank, hit_rank, reads_per_billion
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw NvdDatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = hits.count
        let reportInterval = max(1, total / 20) // ~5% increments

        for (i, hit) in hits.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            nvdBindText(stmt, 1, hit.experiment)
            nvdBindText(stmt, 2, hit.blastTask)
            nvdBindText(stmt, 3, hit.sampleId)
            nvdBindText(stmt, 4, hit.qseqid)
            sqlite3_bind_int64(stmt, 5, Int64(hit.qlen))
            nvdBindText(stmt, 6, hit.sseqid)
            nvdBindText(stmt, 7, hit.stitle)
            nvdBindText(stmt, 8, hit.taxRank)
            sqlite3_bind_int64(stmt, 9, Int64(hit.length))
            sqlite3_bind_double(stmt, 10, hit.pident)
            sqlite3_bind_double(stmt, 11, hit.evalue)
            sqlite3_bind_double(stmt, 12, hit.bitscore)
            nvdBindText(stmt, 13, hit.sscinames)
            nvdBindText(stmt, 14, hit.staxids)
            nvdBindText(stmt, 15, hit.blastDbVersion)
            nvdBindText(stmt, 16, hit.snakemakeRunId)
            sqlite3_bind_int64(stmt, 17, Int64(hit.mappedReads))
            // 18: unique_reads (nullable)
            if let unique = hit.uniqueReads {
                sqlite3_bind_int64(stmt, 18, Int64(unique))
            } else {
                sqlite3_bind_null(stmt, 18)
            }
            sqlite3_bind_int64(stmt, 19, Int64(hit.totalReads))
            nvdBindText(stmt, 20, hit.statDbVersion)
            // adjusted_taxid is stored as INTEGER — parse from string
            sqlite3_bind_int64(stmt, 21, Int64(hit.adjustedTaxid) ?? 0)
            nvdBindText(stmt, 22, hit.adjustmentMethod)
            nvdBindText(stmt, 23, hit.adjustedTaxidName)
            nvdBindText(stmt, 24, hit.adjustedTaxidRank)
            sqlite3_bind_int64(stmt, 25, Int64(hit.hitRank))
            sqlite3_bind_double(stmt, 26, hit.readsPerBillion)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw NvdDatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.65 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting hits \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.insertFailed("Commit failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Samples

    private static func bulkInsertSamples(
        db: OpaquePointer,
        samples: [NvdSampleMetadata]
    ) throws {
        guard !samples.isEmpty else { return }

        let insertSQL = """
        INSERT OR REPLACE INTO samples (
            sample_id, bam_path, fasta_path, total_reads, contig_count, hit_count
        ) VALUES (?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.insertFailed("Sample insert prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for sample in samples {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            nvdBindText(stmt, 1, sample.sampleId)
            nvdBindText(stmt, 2, sample.bamPath)
            nvdBindText(stmt, 3, sample.fastaPath)
            sqlite3_bind_int64(stmt, 4, Int64(sample.totalReads))
            sqlite3_bind_int64(stmt, 5, Int64(sample.contigCount))
            sqlite3_bind_int64(stmt, 6, Int64(sample.hitCount))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw NvdDatabaseError.insertFailed("Sample row failed: \(msg)")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.insertFailed("Sample commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            "CREATE INDEX idx_hits_sample ON blast_hits(sample_id)",
            "CREATE INDEX idx_hits_contig ON blast_hits(sample_id, qseqid)",
            "CREATE INDEX idx_hits_taxon ON blast_hits(adjusted_taxid_name)",
            "CREATE INDEX idx_hits_experiment ON blast_hits(experiment)",
            "CREATE INDEX idx_hits_rank ON blast_hits(adjusted_taxid_rank)",
            "CREATE INDEX idx_hits_evalue ON blast_hits(sample_id, qseqid, evalue)",
            "CREATE INDEX idx_hits_stitle ON blast_hits(stitle)",
            "CREATE INDEX idx_hits_best ON blast_hits(hit_rank, sample_id)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NvdDatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    // MARK: - Queries

    /// Returns the total number of BLAST hits, optionally filtered by sample IDs.
    ///
    /// - Parameter samples: If non-nil, only count hits from these samples.
    /// - Returns: Total hit count.
    public func totalHitCount(samples: [String]? = nil) throws -> Int {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }

        let sql: String
        if let samples, !samples.isEmpty {
            let placeholders = samples.map { _ in "?" }.joined(separator: ",")
            sql = "SELECT COUNT(*) FROM blast_hits WHERE sample_id IN (\(placeholders))"
        } else {
            sql = "SELECT COUNT(*) FROM blast_hits"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        if let samples, !samples.isEmpty {
            for (i, sample) in samples.enumerated() {
                nvdBindText(stmt, Int32(i + 1), sample)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NvdDatabaseError.queryFailed("COUNT query returned no rows")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns the best BLAST hit (hit_rank = 1) for each contig in the given samples.
    ///
    /// - Parameter samples: Sample IDs to filter by.
    /// - Returns: Array of ``NvdBlastHit`` with hit_rank == 1, ordered by sample_id then qseqid.
    public func bestHits(forSamples samples: [String]) throws -> [NvdBlastHit] {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT experiment, blast_task, sample_id, qseqid, qlen,
               sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
               sscinames, staxids, blast_db_version, snakemake_run_id,
               mapped_reads, unique_reads, total_reads, stat_db_version,
               adjusted_taxid, adjustment_method, adjusted_taxid_name,
               adjusted_taxid_rank, hit_rank, reads_per_billion
        FROM blast_hits
        WHERE hit_rank = 1 AND sample_id IN (\(placeholders))
        ORDER BY qlen DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            nvdBindText(stmt, Int32(i + 1), sample)
        }

        return try collectHits(stmt: stmt)
    }

    /// Returns all BLAST hits for a specific contig in a specific sample, ordered by evalue.
    ///
    /// - Parameters:
    ///   - sampleId: The sample identifier.
    ///   - qseqid: The contig/query sequence identifier.
    /// - Returns: All hits for this contig, ordered by evalue ascending.
    public func childHits(sampleId: String, qseqid: String) throws -> [NvdBlastHit] {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        SELECT experiment, blast_task, sample_id, qseqid, qlen,
               sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
               sscinames, staxids, blast_db_version, snakemake_run_id,
               mapped_reads, unique_reads, total_reads, stat_db_version,
               adjusted_taxid, adjustment_method, adjusted_taxid_name,
               adjusted_taxid_rank, hit_rank, reads_per_billion
        FROM blast_hits
        WHERE sample_id = ? AND qseqid = ?
        ORDER BY evalue ASC, bitscore DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        nvdBindText(stmt, 1, sampleId)
        nvdBindText(stmt, 2, qseqid)

        return try collectHits(stmt: stmt)
    }

    /// Returns taxon groups (aggregated by adjusted_taxid_name) for the given samples.
    ///
    /// Groups best hits by taxon name, counting distinct contigs and summing mapped reads.
    ///
    /// - Parameter samples: Sample IDs to include.
    /// - Returns: Array of ``NvdTaxonGroup`` ordered by total mapped reads descending.
    public func taxonGroups(forSamples samples: [String]) throws -> [NvdTaxonGroup] {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT adjusted_taxid_name, adjusted_taxid_rank,
               COUNT(DISTINCT qseqid) AS contig_count,
               SUM(mapped_reads) AS total_mapped_reads
        FROM blast_hits
        WHERE hit_rank = 1 AND sample_id IN (\(placeholders))
        GROUP BY adjusted_taxid_name, adjusted_taxid_rank
        ORDER BY total_mapped_reads DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            nvdBindText(stmt, Int32(i + 1), sample)
        }

        var groups: [NvdTaxonGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let rank = String(cString: sqlite3_column_text(stmt, 1))
            let contigCount = Int(sqlite3_column_int64(stmt, 2))
            let totalMappedReads = Int(sqlite3_column_int64(stmt, 3))
            groups.append(NvdTaxonGroup(
                adjustedTaxidName: name,
                adjustedTaxidRank: rank,
                contigCount: contigCount,
                totalMappedReads: totalMappedReads
            ))
        }
        return groups
    }

    /// Searches best hits using a text query against taxon name, accession, and contig name.
    ///
    /// - Parameters:
    ///   - query: Text to search for (LIKE matching with wildcards).
    ///   - samples: Sample IDs to search within.
    /// - Returns: Matching hits with hit_rank = 1, ordered by sample_id then qseqid.
    public func searchBestHits(query: String, samples: [String]) throws -> [NvdBlastHit] {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT experiment, blast_task, sample_id, qseqid, qlen,
               sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
               sscinames, staxids, blast_db_version, snakemake_run_id,
               mapped_reads, unique_reads, total_reads, stat_db_version,
               adjusted_taxid, adjustment_method, adjusted_taxid_name,
               adjusted_taxid_rank, hit_rank, reads_per_billion
        FROM blast_hits
        WHERE hit_rank = 1
          AND sample_id IN (\(placeholders))
          AND (adjusted_taxid_name LIKE ? OR stitle LIKE ? OR sseqid LIKE ? OR qseqid LIKE ?)
        ORDER BY qlen DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            nvdBindText(stmt, Int32(i + 1), sample)
        }
        let likePattern = "%\(query)%"
        let baseIndex = Int32(samples.count + 1)
        nvdBindText(stmt, baseIndex,     likePattern)
        nvdBindText(stmt, baseIndex + 1, likePattern)
        nvdBindText(stmt, baseIndex + 2, likePattern)
        nvdBindText(stmt, baseIndex + 3, likePattern)

        return try collectHits(stmt: stmt)
    }

    /// Returns all sample metadata rows stored in the database.
    ///
    /// - Returns: Array of ``NvdSampleMetadata`` ordered by sample_id.
    public func allSamples() throws -> [NvdSampleMetadata] {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }

        let sql = """
        SELECT sample_id, bam_path, fasta_path, total_reads, contig_count, hit_count
        FROM samples
        ORDER BY sample_id
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [NvdSampleMetadata] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sampleId    = String(cString: sqlite3_column_text(stmt, 0))
            let bamPath     = String(cString: sqlite3_column_text(stmt, 1))
            let fastaPath   = String(cString: sqlite3_column_text(stmt, 2))
            let totalReads  = Int(sqlite3_column_int64(stmt, 3))
            let contigCount = Int(sqlite3_column_int64(stmt, 4))
            let hitCount    = Int(sqlite3_column_int64(stmt, 5))
            results.append(NvdSampleMetadata(
                sampleId: sampleId,
                bamPath: bamPath,
                fastaPath: fastaPath,
                totalReads: totalReads,
                contigCount: contigCount,
                hitCount: hitCount
            ))
        }
        return results
    }

    /// Returns the BAM file path for a given sample, or nil if the sample is not found.
    ///
    /// - Parameter sampleId: The sample identifier.
    /// - Returns: The stored BAM path string, or nil.
    public func bamPath(forSample sampleId: String) throws -> String? {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT bam_path FROM samples WHERE sample_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        nvdBindText(stmt, 1, sampleId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }

    /// Returns the FASTA file path for a given sample, or nil if the sample is not found.
    ///
    /// - Parameter sampleId: The sample identifier.
    /// - Returns: The stored FASTA path string, or nil.
    public func fastaPath(forSample sampleId: String) throws -> String? {
        guard let db else {
            throw NvdDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT fasta_path FROM samples WHERE sample_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NvdDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        nvdBindText(stmt, 1, sampleId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }

    // MARK: - Private Helpers

    /// Collects all rows from a prepared SELECT statement into NvdBlastHit values.
    ///
    /// The SELECT must project the 26 blast_hits columns in the standard order:
    /// experiment, blast_task, sample_id, qseqid, qlen,
    /// sseqid, stitle, tax_rank, length, pident, evalue, bitscore,
    /// sscinames, staxids, blast_db_version, snakemake_run_id,
    /// mapped_reads, unique_reads, total_reads, stat_db_version,
    /// adjusted_taxid, adjustment_method, adjusted_taxid_name,
    /// adjusted_taxid_rank, hit_rank, reads_per_billion
    private func collectHits(stmt: OpaquePointer?) throws -> [NvdBlastHit] {
        var hits: [NvdBlastHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let experiment        = String(cString: sqlite3_column_text(stmt, 0))
            let blastTask         = String(cString: sqlite3_column_text(stmt, 1))
            let sampleId          = String(cString: sqlite3_column_text(stmt, 2))
            let qseqid            = String(cString: sqlite3_column_text(stmt, 3))
            let qlen              = Int(sqlite3_column_int64(stmt, 4))
            let sseqid            = String(cString: sqlite3_column_text(stmt, 5))
            let stitle            = String(cString: sqlite3_column_text(stmt, 6))
            let taxRank           = String(cString: sqlite3_column_text(stmt, 7))
            let length            = Int(sqlite3_column_int64(stmt, 8))
            let pident            = sqlite3_column_double(stmt, 9)
            let evalue            = sqlite3_column_double(stmt, 10)
            let bitscore          = sqlite3_column_double(stmt, 11)
            let sscinames         = String(cString: sqlite3_column_text(stmt, 12))
            let staxids           = String(cString: sqlite3_column_text(stmt, 13))
            let blastDbVersion    = String(cString: sqlite3_column_text(stmt, 14))
            let snakemakeRunId    = String(cString: sqlite3_column_text(stmt, 15))
            let mappedReads       = Int(sqlite3_column_int64(stmt, 16))
            // unique_reads is nullable (populated post-markdup)
            let uniqueReads: Int? = sqlite3_column_type(stmt, 17) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, 17))
            let totalReads        = Int(sqlite3_column_int64(stmt, 18))
            let statDbVersion     = String(cString: sqlite3_column_text(stmt, 19))
            // adjusted_taxid stored as INTEGER, returned as string for NvdBlastHit
            let adjustedTaxidInt  = sqlite3_column_int64(stmt, 20)
            let adjustedTaxid     = String(adjustedTaxidInt)
            let adjustmentMethod  = String(cString: sqlite3_column_text(stmt, 21))
            let adjustedTaxidName = String(cString: sqlite3_column_text(stmt, 22))
            let adjustedTaxidRank = String(cString: sqlite3_column_text(stmt, 23))
            let hitRank           = Int(sqlite3_column_int64(stmt, 24))
            let readsPerBillion   = sqlite3_column_double(stmt, 25)

            hits.append(NvdBlastHit(
                experiment: experiment,
                blastTask: blastTask,
                sampleId: sampleId,
                qseqid: qseqid,
                qlen: qlen,
                sseqid: sseqid,
                stitle: stitle,
                taxRank: taxRank,
                length: length,
                pident: pident,
                evalue: evalue,
                bitscore: bitscore,
                sscinames: sscinames,
                staxids: staxids,
                blastDbVersion: blastDbVersion,
                snakemakeRunId: snakemakeRunId,
                mappedReads: mappedReads,
                uniqueReads: uniqueReads,
                totalReads: totalReads,
                statDbVersion: statDbVersion,
                adjustedTaxid: adjustedTaxid,
                adjustmentMethod: adjustmentMethod,
                adjustedTaxidName: adjustedTaxidName,
                adjustedTaxidRank: adjustedTaxidRank,
                hitRank: hitRank,
                readsPerBillion: readsPerBillion
            ))
        }
        return hits
    }
}
