// EsVirituDatabase.swift - SQLite-backed database for EsViritu viral detection results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "EsVirituDatabase")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func evBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - EsVirituDatabaseError

/// Errors from EsViritu database operations.
public enum EsVirituDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open EsViritu database: \(msg)"
        case .createFailed(let msg): return "Failed to create EsViritu database: \(msg)"
        case .queryFailed(let msg): return "EsViritu database query failed: \(msg)"
        case .insertFailed(let msg): return "EsViritu database insert failed: \(msg)"
        }
    }
}

// MARK: - Row Type

/// A single viral detection row from EsViritu output.
public struct EsVirituDetectionRow: Sendable {
    public let sample: String
    public let virusName: String
    public let description: String?
    public let contigLength: Int?
    public let segment: String?
    public let accession: String
    public let assembly: String
    public let assemblyLength: Int?
    public let kingdom: String?
    public let phylum: String?
    public let tclass: String?
    public let torder: String?
    public let family: String?
    public let genus: String?
    public let species: String?
    public let subspecies: String?
    public let rpkmf: Double?
    public let readCount: Int
    public let uniqueReads: Int?
    public let coveredBases: Int?
    public let meanCoverage: Double?
    public let avgReadIdentity: Double?
    public let pi: Double?
    public let filteredReadsInSample: Int?
    public let bamPath: String?
    public let bamIndexPath: String?

    public init(
        sample: String,
        virusName: String,
        description: String?,
        contigLength: Int?,
        segment: String?,
        accession: String,
        assembly: String,
        assemblyLength: Int?,
        kingdom: String?,
        phylum: String?,
        tclass: String?,
        torder: String?,
        family: String?,
        genus: String?,
        species: String?,
        subspecies: String?,
        rpkmf: Double?,
        readCount: Int,
        uniqueReads: Int?,
        coveredBases: Int?,
        meanCoverage: Double?,
        avgReadIdentity: Double?,
        pi: Double?,
        filteredReadsInSample: Int?,
        bamPath: String?,
        bamIndexPath: String?
    ) {
        self.sample = sample
        self.virusName = virusName
        self.description = description
        self.contigLength = contigLength
        self.segment = segment
        self.accession = accession
        self.assembly = assembly
        self.assemblyLength = assemblyLength
        self.kingdom = kingdom
        self.phylum = phylum
        self.tclass = tclass
        self.torder = torder
        self.family = family
        self.genus = genus
        self.species = species
        self.subspecies = subspecies
        self.rpkmf = rpkmf
        self.readCount = readCount
        self.uniqueReads = uniqueReads
        self.coveredBases = coveredBases
        self.meanCoverage = meanCoverage
        self.avgReadIdentity = avgReadIdentity
        self.pi = pi
        self.filteredReadsInSample = filteredReadsInSample
        self.bamPath = bamPath
        self.bamIndexPath = bamIndexPath
    }
}

// MARK: - EsVirituDatabase

/// SQLite-backed storage for EsViritu viral detection results and run metadata.
///
/// Provides fast random-access queries for taxonomy browsing and cross-sample
/// comparisons.  Created once during import, then opened read-only for all
/// subsequent access.
///
/// Thread-safe via `@unchecked Sendable` -- the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class EsVirituDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing EsViritu database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``EsVirituDatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw EsVirituDatabaseError.openFailed(msg)
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)  // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened EsViritu database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Create New Database

    /// Creates a new EsViritu database from parsed detection rows.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all rows
    /// and metadata, then builds indices.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - rows: Parsed detection rows to insert.
    ///   - metadata: Key-value metadata pairs (tool version, timestamps, etc.).
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: An `EsVirituDatabase` opened read-only on the new file.
    /// - Throws: ``EsVirituDatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        rows: [EsVirituDetectionRow],
        metadata: [String: String],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> EsVirituDatabase {
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
            throw EsVirituDatabaseError.createFailed(msg)
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
            progress?(0.80, "Inserting metadata...")

            try insertMetadata(db: db, metadata: metadata)
            progress?(0.85, "Building indices...")

            try createIndices(db: db)
            progress?(0.95, "Finalizing...")

            sqlite3_close(db)
            logger.info("Created EsViritu database with \(rows.count) rows at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try EsVirituDatabase(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE detection_rows (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            virus_name TEXT NOT NULL,
            description TEXT,
            contig_length INTEGER,
            segment TEXT,
            accession TEXT NOT NULL,
            assembly TEXT NOT NULL,
            assembly_length INTEGER,
            kingdom TEXT,
            phylum TEXT,
            tclass TEXT,
            torder TEXT,
            family TEXT,
            genus TEXT,
            species TEXT,
            subspecies TEXT,
            rpkmf REAL,
            read_count INTEGER NOT NULL,
            unique_reads INTEGER,
            covered_bases INTEGER,
            mean_coverage REAL,
            avg_read_identity REAL,
            pi REAL,
            filtered_reads_in_sample INTEGER,
            bam_path TEXT,
            bam_index_path TEXT,
            UNIQUE(sample, accession)
        );

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Rows

    private static func bulkInsertRows(
        db: OpaquePointer,
        rows: [EsVirituDetectionRow],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !rows.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO detection_rows (
            sample, virus_name, description, contig_length, segment,
            accession, assembly, assembly_length,
            kingdom, phylum, tclass, torder, family, genus, species, subspecies,
            rpkmf, read_count, unique_reads, covered_bases, mean_coverage,
            avg_read_identity, pi, filtered_reads_in_sample,
            bam_path, bam_index_path
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw EsVirituDatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = rows.count
        let reportInterval = max(1, rows.count / 20)

        for (i, row) in rows.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            // 1: sample (TEXT NOT NULL)
            evBindText(stmt, 1, row.sample)
            // 2: virus_name (TEXT NOT NULL)
            evBindText(stmt, 2, row.virusName)
            // 3: description (TEXT)
            if let v = row.description { evBindText(stmt, 3, v) } else { sqlite3_bind_null(stmt, 3) }
            // 4: contig_length (INTEGER)
            if let v = row.contigLength { sqlite3_bind_int64(stmt, 4, Int64(v)) } else { sqlite3_bind_null(stmt, 4) }
            // 5: segment (TEXT)
            if let v = row.segment { evBindText(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
            // 6: accession (TEXT NOT NULL)
            evBindText(stmt, 6, row.accession)
            // 7: assembly (TEXT NOT NULL)
            evBindText(stmt, 7, row.assembly)
            // 8: assembly_length (INTEGER)
            if let v = row.assemblyLength { sqlite3_bind_int64(stmt, 8, Int64(v)) } else { sqlite3_bind_null(stmt, 8) }
            // 9: kingdom (TEXT)
            if let v = row.kingdom { evBindText(stmt, 9, v) } else { sqlite3_bind_null(stmt, 9) }
            // 10: phylum (TEXT)
            if let v = row.phylum { evBindText(stmt, 10, v) } else { sqlite3_bind_null(stmt, 10) }
            // 11: tclass (TEXT)
            if let v = row.tclass { evBindText(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
            // 12: torder (TEXT)
            if let v = row.torder { evBindText(stmt, 12, v) } else { sqlite3_bind_null(stmt, 12) }
            // 13: family (TEXT)
            if let v = row.family { evBindText(stmt, 13, v) } else { sqlite3_bind_null(stmt, 13) }
            // 14: genus (TEXT)
            if let v = row.genus { evBindText(stmt, 14, v) } else { sqlite3_bind_null(stmt, 14) }
            // 15: species (TEXT)
            if let v = row.species { evBindText(stmt, 15, v) } else { sqlite3_bind_null(stmt, 15) }
            // 16: subspecies (TEXT)
            if let v = row.subspecies { evBindText(stmt, 16, v) } else { sqlite3_bind_null(stmt, 16) }
            // 17: rpkmf (REAL)
            if let v = row.rpkmf { sqlite3_bind_double(stmt, 17, v) } else { sqlite3_bind_null(stmt, 17) }
            // 18: read_count (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 18, Int64(row.readCount))
            // 19: unique_reads (INTEGER)
            if let v = row.uniqueReads { sqlite3_bind_int64(stmt, 19, Int64(v)) } else { sqlite3_bind_null(stmt, 19) }
            // 20: covered_bases (INTEGER)
            if let v = row.coveredBases { sqlite3_bind_int64(stmt, 20, Int64(v)) } else { sqlite3_bind_null(stmt, 20) }
            // 21: mean_coverage (REAL)
            if let v = row.meanCoverage { sqlite3_bind_double(stmt, 21, v) } else { sqlite3_bind_null(stmt, 21) }
            // 22: avg_read_identity (REAL)
            if let v = row.avgReadIdentity { sqlite3_bind_double(stmt, 22, v) } else { sqlite3_bind_null(stmt, 22) }
            // 23: pi (REAL)
            if let v = row.pi { sqlite3_bind_double(stmt, 23, v) } else { sqlite3_bind_null(stmt, 23) }
            // 24: filtered_reads_in_sample (INTEGER)
            if let v = row.filteredReadsInSample { sqlite3_bind_int64(stmt, 24, Int64(v)) } else { sqlite3_bind_null(stmt, 24) }
            // 25: bam_path (TEXT)
            if let v = row.bamPath { evBindText(stmt, 25, v) } else { sqlite3_bind_null(stmt, 25) }
            // 26: bam_index_path (TEXT)
            if let v = row.bamIndexPath { evBindText(stmt, 26, v) } else { sqlite3_bind_null(stmt, 26) }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw EsVirituDatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.75 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting rows \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.insertFailed("Commit failed: \(msg)")
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
            throw EsVirituDatabaseError.insertFailed("Metadata prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for (key, value) in metadata {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            evBindText(stmt, 1, key)
            evBindText(stmt, 2, value)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw EsVirituDatabaseError.insertFailed("Metadata row failed: \(msg)")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.insertFailed("Metadata commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            "CREATE INDEX idx_ev_sample ON detection_rows(sample)",
            "CREATE INDEX idx_ev_virus ON detection_rows(virus_name)",
            "CREATE INDEX idx_ev_assembly ON detection_rows(assembly)",
            "CREATE INDEX idx_ev_reads ON detection_rows(read_count)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw EsVirituDatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    // MARK: - Queries

    /// Returns detection rows for the given sample names.
    ///
    /// - Parameter samples: Sample identifiers to fetch. If empty, returns [].
    /// - Returns: Array of ``EsVirituDetectionRow`` matching the requested samples.
    public func fetchRows(samples: [String]) throws -> [EsVirituDetectionRow] {
        guard let db else {
            throw EsVirituDatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT * FROM detection_rows WHERE sample IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            evBindText(stmt, Int32(i + 1), sample)
        }

        return collectRows(stmt: stmt)
    }

    /// Returns all distinct samples and their detection counts.
    ///
    /// - Returns: Array of (sample, detectionCount) tuples ordered by sample name.
    public func fetchSamples() throws -> [(sample: String, detectionCount: Int)] {
        guard let db else {
            throw EsVirituDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, COUNT(*) as cnt FROM detection_rows GROUP BY sample ORDER BY sample"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(sample: String, detectionCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            results.append((sample: sample, detectionCount: count))
        }
        return results
    }

    /// Returns all metadata key-value pairs.
    ///
    /// - Returns: Dictionary of metadata entries.
    public func fetchMetadata() throws -> [String: String] {
        guard let db else {
            throw EsVirituDatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT key, value FROM metadata"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EsVirituDatabaseError.queryFailed(msg)
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

    /// Collects all rows from a prepared SELECT * FROM detection_rows statement.
    ///
    /// Column order must match the schema: rowid(0), sample(1), virus_name(2), description(3),
    /// contig_length(4), segment(5), accession(6), assembly(7), assembly_length(8),
    /// kingdom(9), phylum(10), tclass(11), torder(12), family(13), genus(14),
    /// species(15), subspecies(16), rpkmf(17), read_count(18), unique_reads(19),
    /// covered_bases(20), mean_coverage(21), avg_read_identity(22), pi(23),
    /// filtered_reads_in_sample(24), bam_path(25), bam_index_path(26).
    private func collectRows(stmt: OpaquePointer?) -> [EsVirituDetectionRow] {
        var rows: [EsVirituDetectionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Column 0 is rowid (skip), actual data starts at column 1
            let sample              = String(cString: sqlite3_column_text(stmt, 1))
            let virusName           = String(cString: sqlite3_column_text(stmt, 2))
            let description         = optionalText(stmt, 3)
            let contigLength        = optionalInt(stmt, 4)
            let segment             = optionalText(stmt, 5)
            let accession           = String(cString: sqlite3_column_text(stmt, 6))
            let assembly            = String(cString: sqlite3_column_text(stmt, 7))
            let assemblyLength      = optionalInt(stmt, 8)
            let kingdom             = optionalText(stmt, 9)
            let phylum              = optionalText(stmt, 10)
            let tclass              = optionalText(stmt, 11)
            let torder              = optionalText(stmt, 12)
            let family              = optionalText(stmt, 13)
            let genus               = optionalText(stmt, 14)
            let species             = optionalText(stmt, 15)
            let subspecies          = optionalText(stmt, 16)
            let rpkmf               = optionalDouble(stmt, 17)
            let readCount           = Int(sqlite3_column_int64(stmt, 18))
            let uniqueReads         = optionalInt(stmt, 19)
            let coveredBases        = optionalInt(stmt, 20)
            let meanCoverage        = optionalDouble(stmt, 21)
            let avgReadIdentity     = optionalDouble(stmt, 22)
            let pi                  = optionalDouble(stmt, 23)
            let filteredReadsInSample = optionalInt(stmt, 24)
            let bamPath             = optionalText(stmt, 25)
            let bamIndexPath        = optionalText(stmt, 26)

            rows.append(EsVirituDetectionRow(
                sample: sample,
                virusName: virusName,
                description: description,
                contigLength: contigLength,
                segment: segment,
                accession: accession,
                assembly: assembly,
                assemblyLength: assemblyLength,
                kingdom: kingdom,
                phylum: phylum,
                tclass: tclass,
                torder: torder,
                family: family,
                genus: genus,
                species: species,
                subspecies: subspecies,
                rpkmf: rpkmf,
                readCount: readCount,
                uniqueReads: uniqueReads,
                coveredBases: coveredBases,
                meanCoverage: meanCoverage,
                avgReadIdentity: avgReadIdentity,
                pi: pi,
                filteredReadsInSample: filteredReadsInSample,
                bamPath: bamPath,
                bamIndexPath: bamIndexPath
            ))
        }
        return rows
    }
}
