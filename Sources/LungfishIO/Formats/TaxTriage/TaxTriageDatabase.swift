// TaxTriageDatabase.swift - SQLite-backed database for TaxTriage taxonomy results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "TaxTriageDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func ttBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - TaxTriageDatabaseError

/// Errors from TaxTriage database operations.
public enum TaxTriageDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open TaxTriage database: \(msg)"
        case .createFailed(let msg): return "Failed to create TaxTriage database: \(msg)"
        case .queryFailed(let msg): return "TaxTriage database query failed: \(msg)"
        case .insertFailed(let msg): return "TaxTriage database insert failed: \(msg)"
        }
    }
}

// MARK: - Row Type

/// A single taxonomy row from TaxTriage output.
public struct TaxTriageTaxonomyRow: Sendable {
    public let sample: String
    public let organism: String
    public let taxId: Int?
    public let status: String?
    public let tassScore: Double
    public let readsAligned: Int
    public let uniqueReads: Int?
    public let pctReads: Double?
    public let pctAlignedReads: Double?
    public let coverageBreadth: Double?
    public let meanCoverage: Double?
    public let meanDepth: Double?
    public let confidence: String?
    public let k2Reads: Int?
    public let parentK2Reads: Int?
    public let giniCoefficient: Double?
    public let meanBaseQ: Double?
    public let meanMapQ: Double?
    public let mapqScore: Double?
    public let disparityScore: Double?
    public let minhashScore: Double?
    public let diamondIdentity: Double?
    public let k2DisparityScore: Double?
    public let siblingsScore: Double?
    public let breadthWeightScore: Double?
    public let hhsPercentile: Double?
    public let isAnnotated: Bool?
    public let annClass: String?
    public let microbialCategory: String?
    public let highConsequence: Bool?
    public let isSpecies: Bool?
    public let pathogenicSubstrains: String?
    public let sampleType: String?
    public let bamPath: String?
    public let bamIndexPath: String?
    public let primaryAccession: String?
    public let accessionLength: Int?

    public init(
        sample: String,
        organism: String,
        taxId: Int?,
        status: String?,
        tassScore: Double,
        readsAligned: Int,
        uniqueReads: Int?,
        pctReads: Double?,
        pctAlignedReads: Double?,
        coverageBreadth: Double?,
        meanCoverage: Double?,
        meanDepth: Double?,
        confidence: String?,
        k2Reads: Int?,
        parentK2Reads: Int?,
        giniCoefficient: Double?,
        meanBaseQ: Double?,
        meanMapQ: Double?,
        mapqScore: Double?,
        disparityScore: Double?,
        minhashScore: Double?,
        diamondIdentity: Double?,
        k2DisparityScore: Double?,
        siblingsScore: Double?,
        breadthWeightScore: Double?,
        hhsPercentile: Double?,
        isAnnotated: Bool?,
        annClass: String?,
        microbialCategory: String?,
        highConsequence: Bool?,
        isSpecies: Bool?,
        pathogenicSubstrains: String?,
        sampleType: String?,
        bamPath: String?,
        bamIndexPath: String?,
        primaryAccession: String?,
        accessionLength: Int?
    ) {
        self.sample = sample
        self.organism = organism
        self.taxId = taxId
        self.status = status
        self.tassScore = tassScore
        self.readsAligned = readsAligned
        self.uniqueReads = uniqueReads
        self.pctReads = pctReads
        self.pctAlignedReads = pctAlignedReads
        self.coverageBreadth = coverageBreadth
        self.meanCoverage = meanCoverage
        self.meanDepth = meanDepth
        self.confidence = confidence
        self.k2Reads = k2Reads
        self.parentK2Reads = parentK2Reads
        self.giniCoefficient = giniCoefficient
        self.meanBaseQ = meanBaseQ
        self.meanMapQ = meanMapQ
        self.mapqScore = mapqScore
        self.disparityScore = disparityScore
        self.minhashScore = minhashScore
        self.diamondIdentity = diamondIdentity
        self.k2DisparityScore = k2DisparityScore
        self.siblingsScore = siblingsScore
        self.breadthWeightScore = breadthWeightScore
        self.hhsPercentile = hhsPercentile
        self.isAnnotated = isAnnotated
        self.annClass = annClass
        self.microbialCategory = microbialCategory
        self.highConsequence = highConsequence
        self.isSpecies = isSpecies
        self.pathogenicSubstrains = pathogenicSubstrains
        self.sampleType = sampleType
        self.bamPath = bamPath
        self.bamIndexPath = bamIndexPath
        self.primaryAccession = primaryAccession
        self.accessionLength = accessionLength
    }
}

// MARK: - Accession Map Entry

/// An entry in the accession_map table linking organisms to their reference accessions.
public struct TaxTriageAccessionEntry: Sendable {
    public let sample: String
    public let organism: String
    public let accession: String
    public let description: String?

    public init(sample: String, organism: String, accession: String, description: String? = nil) {
        self.sample = sample
        self.organism = organism
        self.accession = accession
        self.description = description
    }
}

// MARK: - TaxTriageDatabase

/// SQLite-backed storage for TaxTriage taxonomy results and run metadata.
///
/// Provides fast random-access queries for taxonomy browsing and cross-sample
/// comparisons.  Created once during import, then opened read-only for all
/// subsequent access.
///
/// Thread-safe via `@unchecked Sendable` -- the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class TaxTriageDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing TaxTriage database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``TaxTriageDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw TaxTriageDatabaseError.openFailed(msg)
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)  // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened TaxTriage database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Create New Database

    /// Creates a new TaxTriage database from parsed taxonomy rows.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all rows
    /// and metadata, then builds indices.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - rows: Parsed taxonomy rows to insert.
    ///   - metadata: Key-value metadata pairs (tool version, timestamps, etc.).
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: A `TaxTriageDatabase` opened read-only on the new file.
    /// - Throws: ``TaxTriageDatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        rows: [TaxTriageTaxonomyRow],
        accessionMap: [TaxTriageAccessionEntry] = [],
        metadata: [String: String],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> TaxTriageDatabase {
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
            throw TaxTriageDatabaseError.createFailed(msg)
        }

        // Performance pragmas for bulk import
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)

        do {
            try createSchema(db: db)
            progress?(0.05, "Schema created")

            try bulkInsertRows(db: db, rows: rows, progress: progress)
            progress?(0.75, "Inserting accession map...")

            try bulkInsertAccessionMap(db: db, entries: accessionMap)
            progress?(0.80, "Inserting metadata...")

            try insertMetadata(db: db, metadata: metadata)
            progress?(0.85, "Building indices...")

            try createIndices(db: db)
            progress?(0.95, "Finalizing...")

            sqlite3_close(db)
            logger.info("Created TaxTriage database with \(rows.count) rows at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try TaxTriageDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE taxonomy_rows (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            organism TEXT NOT NULL,
            tax_id INTEGER,
            status TEXT,
            tass_score REAL NOT NULL,
            reads_aligned INTEGER NOT NULL,
            unique_reads INTEGER,
            pct_reads REAL,
            pct_aligned_reads REAL,
            coverage_breadth REAL,
            mean_coverage REAL,
            mean_depth REAL,
            confidence TEXT,
            k2_reads INTEGER,
            parent_k2_reads INTEGER,
            gini_coefficient REAL,
            mean_baseq REAL,
            mean_mapq REAL,
            mapq_score REAL,
            disparity_score REAL,
            minhash_score REAL,
            diamond_identity REAL,
            k2_disparity_score REAL,
            siblings_score REAL,
            breadth_weight_score REAL,
            hhs_percentile REAL,
            is_annotated INTEGER,
            ann_class TEXT,
            microbial_category TEXT,
            high_consequence INTEGER,
            is_species INTEGER,
            pathogenic_substrains TEXT,
            sample_type TEXT,
            bam_path TEXT,
            bam_index_path TEXT,
            primary_accession TEXT,
            accession_length INTEGER,
            UNIQUE(sample, organism)
        );

        CREATE TABLE accession_map (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            organism TEXT NOT NULL,
            accession TEXT NOT NULL,
            description TEXT
        );

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Rows

    private static func bulkInsertRows(
        db: OpaquePointer,
        rows: [TaxTriageTaxonomyRow],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !rows.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO taxonomy_rows (
            sample, organism, tax_id, status, tass_score, reads_aligned,
            unique_reads, pct_reads, pct_aligned_reads, coverage_breadth,
            mean_coverage, mean_depth, confidence, k2_reads, parent_k2_reads,
            gini_coefficient, mean_baseq, mean_mapq, mapq_score,
            disparity_score, minhash_score, diamond_identity,
            k2_disparity_score, siblings_score, breadth_weight_score,
            hhs_percentile, is_annotated, ann_class, microbial_category,
            high_consequence, is_species, pathogenic_substrains, sample_type,
            bam_path, bam_index_path, primary_accession, accession_length
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw TaxTriageDatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = rows.count
        let reportInterval = max(1, rows.count / 20)

        for (i, row) in rows.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            // 1: sample (TEXT NOT NULL)
            ttBindText(stmt, 1, row.sample)
            // 2: organism (TEXT NOT NULL)
            ttBindText(stmt, 2, row.organism)
            // 3: tax_id (INTEGER)
            if let taxId = row.taxId {
                sqlite3_bind_int64(stmt, 3, Int64(taxId))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            // 4: status (TEXT)
            if let status = row.status {
                ttBindText(stmt, 4, status)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            // 5: tass_score (REAL NOT NULL)
            sqlite3_bind_double(stmt, 5, row.tassScore)
            // 6: reads_aligned (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 6, Int64(row.readsAligned))
            // 7: unique_reads (INTEGER)
            if let uniqueReads = row.uniqueReads {
                sqlite3_bind_int64(stmt, 7, Int64(uniqueReads))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            // 8: pct_reads (REAL)
            if let v = row.pctReads { sqlite3_bind_double(stmt, 8, v) } else { sqlite3_bind_null(stmt, 8) }
            // 9: pct_aligned_reads (REAL)
            if let v = row.pctAlignedReads { sqlite3_bind_double(stmt, 9, v) } else { sqlite3_bind_null(stmt, 9) }
            // 10: coverage_breadth (REAL)
            if let v = row.coverageBreadth { sqlite3_bind_double(stmt, 10, v) } else { sqlite3_bind_null(stmt, 10) }
            // 11: mean_coverage (REAL)
            if let v = row.meanCoverage { sqlite3_bind_double(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
            // 12: mean_depth (REAL)
            if let v = row.meanDepth { sqlite3_bind_double(stmt, 12, v) } else { sqlite3_bind_null(stmt, 12) }
            // 13: confidence (TEXT)
            if let v = row.confidence { ttBindText(stmt, 13, v) } else { sqlite3_bind_null(stmt, 13) }
            // 14: k2_reads (INTEGER)
            if let v = row.k2Reads { sqlite3_bind_int64(stmt, 14, Int64(v)) } else { sqlite3_bind_null(stmt, 14) }
            // 15: parent_k2_reads (INTEGER)
            if let v = row.parentK2Reads { sqlite3_bind_int64(stmt, 15, Int64(v)) } else { sqlite3_bind_null(stmt, 15) }
            // 16: gini_coefficient (REAL)
            if let v = row.giniCoefficient { sqlite3_bind_double(stmt, 16, v) } else { sqlite3_bind_null(stmt, 16) }
            // 17: mean_base_q (REAL)
            if let v = row.meanBaseQ { sqlite3_bind_double(stmt, 17, v) } else { sqlite3_bind_null(stmt, 17) }
            // 18: mean_map_q (REAL)
            if let v = row.meanMapQ { sqlite3_bind_double(stmt, 18, v) } else { sqlite3_bind_null(stmt, 18) }
            // 19: mapq_score (REAL)
            if let v = row.mapqScore { sqlite3_bind_double(stmt, 19, v) } else { sqlite3_bind_null(stmt, 19) }
            // 20: disparity_score (REAL)
            if let v = row.disparityScore { sqlite3_bind_double(stmt, 20, v) } else { sqlite3_bind_null(stmt, 20) }
            // 21: minhash_score (REAL)
            if let v = row.minhashScore { sqlite3_bind_double(stmt, 21, v) } else { sqlite3_bind_null(stmt, 21) }
            // 22: diamond_identity (REAL)
            if let v = row.diamondIdentity { sqlite3_bind_double(stmt, 22, v) } else { sqlite3_bind_null(stmt, 22) }
            // 23: k2_disparity_score (REAL)
            if let v = row.k2DisparityScore { sqlite3_bind_double(stmt, 23, v) } else { sqlite3_bind_null(stmt, 23) }
            // 24: siblings_score (REAL)
            if let v = row.siblingsScore { sqlite3_bind_double(stmt, 24, v) } else { sqlite3_bind_null(stmt, 24) }
            // 25: breadth_weight_score (REAL)
            if let v = row.breadthWeightScore { sqlite3_bind_double(stmt, 25, v) } else { sqlite3_bind_null(stmt, 25) }
            // 26: hhs_percentile (REAL)
            if let v = row.hhsPercentile { sqlite3_bind_double(stmt, 26, v) } else { sqlite3_bind_null(stmt, 26) }
            // 27: is_annotated (INTEGER as bool)
            if let v = row.isAnnotated { sqlite3_bind_int64(stmt, 27, v ? 1 : 0) } else { sqlite3_bind_null(stmt, 27) }
            // 28: ann_class (TEXT)
            if let v = row.annClass { ttBindText(stmt, 28, v) } else { sqlite3_bind_null(stmt, 28) }
            // 29: microbial_category (TEXT)
            if let v = row.microbialCategory { ttBindText(stmt, 29, v) } else { sqlite3_bind_null(stmt, 29) }
            // 30: high_consequence (INTEGER as bool)
            if let v = row.highConsequence { sqlite3_bind_int64(stmt, 30, v ? 1 : 0) } else { sqlite3_bind_null(stmt, 30) }
            // 31: is_species (INTEGER as bool)
            if let v = row.isSpecies { sqlite3_bind_int64(stmt, 31, v ? 1 : 0) } else { sqlite3_bind_null(stmt, 31) }
            // 32: pathogenic_substrains (TEXT)
            if let v = row.pathogenicSubstrains { ttBindText(stmt, 32, v) } else { sqlite3_bind_null(stmt, 32) }
            // 33: sample_type (TEXT)
            if let v = row.sampleType { ttBindText(stmt, 33, v) } else { sqlite3_bind_null(stmt, 33) }
            // 34: bam_path (TEXT)
            if let v = row.bamPath { ttBindText(stmt, 34, v) } else { sqlite3_bind_null(stmt, 34) }
            // 35: bam_index_path (TEXT)
            if let v = row.bamIndexPath { ttBindText(stmt, 35, v) } else { sqlite3_bind_null(stmt, 35) }
            // 36: primary_accession (TEXT)
            if let v = row.primaryAccession { ttBindText(stmt, 36, v) } else { sqlite3_bind_null(stmt, 36) }
            // 37: accession_length (INTEGER)
            if let v = row.accessionLength { sqlite3_bind_int64(stmt, 37, Int64(v)) } else { sqlite3_bind_null(stmt, 37) }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw TaxTriageDatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.75 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting rows \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.insertFailed("Commit failed: \(msg)")
        }
    }

    // MARK: - Insert Metadata

    private static func insertMetadata(
        db: OpaquePointer,
        metadata: [String: String]
    ) throws {
        guard !metadata.isEmpty else { return }

        let insertSQL = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.insertFailed("Metadata prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for (key, value) in metadata {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            ttBindText(stmt, 1, key)
            ttBindText(stmt, 2, value)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw TaxTriageDatabaseError.insertFailed("Metadata row failed: \(msg)")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.insertFailed("Metadata commit failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Accession Map

    private static func bulkInsertAccessionMap(
        db: OpaquePointer,
        entries: [TaxTriageAccessionEntry]
    ) throws {
        guard !entries.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO accession_map (sample, organism, accession, description)
        VALUES (?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw TaxTriageDatabaseError.insertFailed("Accession map prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, entry) in entries.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            ttBindText(stmt, 1, entry.sample)
            ttBindText(stmt, 2, entry.organism)
            ttBindText(stmt, 3, entry.accession)
            if let desc = entry.description {
                ttBindText(stmt, 4, desc)
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw TaxTriageDatabaseError.insertFailed("Accession map row \(i) failed: \(msg)")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.insertFailed("Accession map commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            "CREATE INDEX idx_taxonomy_sample ON taxonomy_rows(sample)",
            "CREATE INDEX idx_taxonomy_organism ON taxonomy_rows(organism)",
            "CREATE INDEX idx_tt_tass ON taxonomy_rows(tass_score)",
            "CREATE INDEX idx_accmap_sample_organism ON accession_map(sample, organism)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw TaxTriageDatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    // MARK: - Queries

    /// Returns taxonomy rows for the given sample names.
    ///
    /// - Parameter samples: Sample identifiers to fetch. If empty, returns [].
    /// - Returns: Array of ``TaxTriageTaxonomyRow`` matching the requested samples.
    public func fetchRows(samples: [String]) throws -> [TaxTriageTaxonomyRow] {
        guard let db else {
            throw TaxTriageDatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT * FROM taxonomy_rows WHERE sample IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            ttBindText(stmt, Int32(i + 1), sample)
        }

        return collectRows(stmt: stmt)
    }

    /// Returns all distinct samples and their organism counts.
    ///
    /// - Returns: Array of (sample, organismCount) tuples ordered by sample name.
    public func fetchSamples() throws -> [(sample: String, organismCount: Int)] {
        guard let db else {
            throw TaxTriageDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, COUNT(*) as cnt FROM taxonomy_rows GROUP BY sample ORDER BY sample"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(sample: String, organismCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            results.append((sample: sample, organismCount: count))
        }
        return results
    }

    /// Returns all metadata key-value pairs.
    ///
    /// - Returns: Dictionary of metadata entries.
    public func fetchMetadata() throws -> [String: String] {
        guard let db else {
            throw TaxTriageDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT key, value FROM metadata"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            results[key] = value
        }
        return results
    }

    /// Returns accession entries for a given sample and organism.
    ///
    /// - Parameters:
    ///   - sample: Sample identifier.
    ///   - organism: Organism name (raw gcfmap name; may need fuzzy matching on caller side).
    /// - Returns: Array of ``TaxTriageAccessionEntry`` ordered by accession.
    public func fetchAccessions(sample: String, organism: String) throws -> [TaxTriageAccessionEntry] {
        guard let db else { throw TaxTriageDatabaseError.queryFailed("Database not open") }

        let sql = """
        SELECT sample, organism, accession, description
        FROM accession_map
        WHERE sample = ? AND organism = ?
        ORDER BY accession
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaxTriageDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        ttBindText(stmt, 1, sample)
        ttBindText(stmt, 2, organism)

        var results: [TaxTriageAccessionEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let desc: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 3))
            results.append(TaxTriageAccessionEntry(
                sample: String(cString: sqlite3_column_text(stmt, 0)),
                organism: String(cString: sqlite3_column_text(stmt, 1)),
                accession: String(cString: sqlite3_column_text(stmt, 2)),
                description: desc
            ))
        }
        return results
    }

    // MARK: - Private Helpers

    /// Reads an optional TEXT column, returning nil if the column is NULL.
    private func optionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    /// Reads an optional INTEGER column, returning nil if the column is NULL.
    private func optionalInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }

    /// Reads an optional REAL column, returning nil if the column is NULL.
    private func optionalDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, col)
    }

    /// Reads an optional bool stored as INTEGER (0/1), returning nil if the column is NULL.
    private func optionalBool(_ stmt: OpaquePointer?, _ col: Int32) -> Bool? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, col) != 0
    }

    /// Collects all rows from a prepared SELECT * FROM taxonomy_rows statement.
    ///
    /// Column order must match the schema: rowid(0), sample(1), organism(2), tax_id(3),
    /// status(4), tass_score(5), reads_aligned(6), unique_reads(7), ... accession_length(37).
    private func collectRows(stmt: OpaquePointer?) -> [TaxTriageTaxonomyRow] {
        var rows: [TaxTriageTaxonomyRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Column 0 is rowid (skip), actual data starts at column 1
            let sample          = String(cString: sqlite3_column_text(stmt, 1))
            let organism        = String(cString: sqlite3_column_text(stmt, 2))
            let taxId           = optionalInt(stmt, 3)
            let status          = optionalText(stmt, 4)
            let tassScore       = sqlite3_column_double(stmt, 5)
            let readsAligned    = Int(sqlite3_column_int64(stmt, 6))
            let uniqueReads     = optionalInt(stmt, 7)
            let pctReads        = optionalDouble(stmt, 8)
            let pctAlignedReads = optionalDouble(stmt, 9)
            let coverageBreadth = optionalDouble(stmt, 10)
            let meanCoverage    = optionalDouble(stmt, 11)
            let meanDepth       = optionalDouble(stmt, 12)
            let confidence      = optionalText(stmt, 13)
            let k2Reads         = optionalInt(stmt, 14)
            let parentK2Reads   = optionalInt(stmt, 15)
            let giniCoefficient = optionalDouble(stmt, 16)
            let meanBaseQ       = optionalDouble(stmt, 17)
            let meanMapQ        = optionalDouble(stmt, 18)
            let mapqScore       = optionalDouble(stmt, 19)
            let disparityScore  = optionalDouble(stmt, 20)
            let minhashScore    = optionalDouble(stmt, 21)
            let diamondIdentity = optionalDouble(stmt, 22)
            let k2DisparityScore = optionalDouble(stmt, 23)
            let siblingsScore   = optionalDouble(stmt, 24)
            let breadthWeightScore = optionalDouble(stmt, 25)
            let hhsPercentile   = optionalDouble(stmt, 26)
            let isAnnotated     = optionalBool(stmt, 27)
            let annClass        = optionalText(stmt, 28)
            let microbialCategory = optionalText(stmt, 29)
            let highConsequence = optionalBool(stmt, 30)
            let isSpecies       = optionalBool(stmt, 31)
            let pathogenicSubstrains = optionalText(stmt, 32)
            let sampleType      = optionalText(stmt, 33)
            let bamPath         = optionalText(stmt, 34)
            let bamIndexPath    = optionalText(stmt, 35)
            let primaryAccession = optionalText(stmt, 36)
            let accessionLength = optionalInt(stmt, 37)

            rows.append(TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: taxId,
                status: status,
                tassScore: tassScore,
                readsAligned: readsAligned,
                uniqueReads: uniqueReads,
                pctReads: pctReads,
                pctAlignedReads: pctAlignedReads,
                coverageBreadth: coverageBreadth,
                meanCoverage: meanCoverage,
                meanDepth: meanDepth,
                confidence: confidence,
                k2Reads: k2Reads,
                parentK2Reads: parentK2Reads,
                giniCoefficient: giniCoefficient,
                meanBaseQ: meanBaseQ,
                meanMapQ: meanMapQ,
                mapqScore: mapqScore,
                disparityScore: disparityScore,
                minhashScore: minhashScore,
                diamondIdentity: diamondIdentity,
                k2DisparityScore: k2DisparityScore,
                siblingsScore: siblingsScore,
                breadthWeightScore: breadthWeightScore,
                hhsPercentile: hhsPercentile,
                isAnnotated: isAnnotated,
                annClass: annClass,
                microbialCategory: microbialCategory,
                highConsequence: highConsequence,
                isSpecies: isSpecies,
                pathogenicSubstrains: pathogenicSubstrains,
                sampleType: sampleType,
                bamPath: bamPath,
                bamIndexPath: bamIndexPath,
                primaryAccession: primaryAccession,
                accessionLength: accessionLength
            ))
        }
        return rows
    }
}
