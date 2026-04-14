// Kraken2Database.swift - SQLite-backed database for Kraken2 taxonomy results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "Kraken2Database")

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
private func krBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - Kraken2DatabaseError

/// Errors from Kraken2 database operations.
public enum Kraken2DatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open Kraken2 database: \(msg)"
        case .createFailed(let msg): return "Failed to create Kraken2 database: \(msg)"
        case .queryFailed(let msg): return "Kraken2 database query failed: \(msg)"
        case .insertFailed(let msg): return "Kraken2 database insert failed: \(msg)"
        }
    }
}

// MARK: - Row Type

/// A single classification row from Kraken2 output.
public struct Kraken2ClassificationRow: Sendable {
    public let sample: String
    public let taxonName: String
    public let taxId: Int
    public let rank: String?
    public let rankDisplayName: String?
    public let readsDirect: Int
    public let readsClade: Int
    public let percentage: Double
    public let parentTaxId: Int?
    public let depth: Int
    public let fractionDirect: Double

    public init(
        sample: String,
        taxonName: String,
        taxId: Int,
        rank: String?,
        rankDisplayName: String?,
        readsDirect: Int,
        readsClade: Int,
        percentage: Double,
        parentTaxId: Int? = nil,
        depth: Int = 0,
        fractionDirect: Double = 0.0
    ) {
        self.sample = sample
        self.taxonName = taxonName
        self.taxId = taxId
        self.rank = rank
        self.rankDisplayName = rankDisplayName
        self.readsDirect = readsDirect
        self.readsClade = readsClade
        self.percentage = percentage
        self.parentTaxId = parentTaxId
        self.depth = depth
        self.fractionDirect = fractionDirect
    }
}

public struct KrakenMetadataFilter: Sendable {
    public enum Operation: Sendable {
        case equal
        case contains
    }

    public let field: String
    public let op: Operation
    public let value: String

    public init(field: String, op: Operation, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct KrakenPrunedSearchResult: Sendable {
    public let rows: [Kraken2ClassificationRow]
    public let matchingSamples: [String]

    public init(rows: [Kraken2ClassificationRow], matchingSamples: [String]) {
        self.rows = rows
        self.matchingSamples = matchingSamples
    }
}

// MARK: - Kraken2Database

/// SQLite-backed storage for Kraken2 taxonomy results and run metadata.
///
/// Provides fast random-access queries for taxonomy browsing and cross-sample
/// comparisons.  Created once during import, then opened read-only for all
/// subsequent access.
///
/// Thread-safe via `@unchecked Sendable` -- the underlying SQLite handle uses
/// `SQLITE_OPEN_FULLMUTEX` (serialized mode).
public final class Kraken2Database: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }

    // MARK: - Open Existing (Read-Only)

    /// Opens an existing Kraken2 database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file.
    /// - Throws: ``Kraken2DatabaseError/openFailed(_:)`` if the file cannot be opened.
    public init(at url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw Kraken2DatabaseError.openFailed(msg)
        }

        // Read-side performance tuning
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)    // 64 MB
        sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)  // 256 MB
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        logger.info("Opened Kraken2 database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Create New Database

    /// Creates a new Kraken2 database from parsed classification rows.
    ///
    /// Deletes any existing file at `url`, creates the schema, bulk-inserts all rows
    /// and metadata, then builds indices.
    ///
    /// - Parameters:
    ///   - url: Path for the new SQLite database file.
    ///   - rows: Parsed classification rows to insert.
    ///   - metadata: Key-value metadata pairs (tool version, timestamps, etc.).
    ///   - progress: Optional callback receiving (fraction 0..1, description).
    /// - Returns: A `Kraken2Database` opened read-only on the new file.
    /// - Throws: ``Kraken2DatabaseError`` on failure.
    @discardableResult
    public static func create(
        at url: URL,
        rows: [Kraken2ClassificationRow],
        metadata: [String: String],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> Kraken2Database {
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
            throw Kraken2DatabaseError.createFailed(msg)
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
            logger.info("Created Kraken2 database with \(rows.count) rows at \(url.lastPathComponent)")

            progress?(1.0, "Complete")
            return try Kraken2Database(at: url)
        } catch {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Schema

    private static func createSchema(db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE classification_rows (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            taxon_name TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            rank TEXT,
            rank_display_name TEXT,
            reads_direct INTEGER NOT NULL,
            reads_clade INTEGER NOT NULL,
            percentage REAL NOT NULL,
            parent_tax_id INTEGER,
            depth INTEGER NOT NULL DEFAULT 0,
            fraction_direct REAL NOT NULL DEFAULT 0.0,
            UNIQUE(sample, tax_id)
        );

        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE sample_metadata_cache (
            sample TEXT NOT NULL,
            field TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(sample, field)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.createFailed("Schema creation failed: \(msg)")
        }
    }

    // MARK: - Bulk Insert Rows

    private static func bulkInsertRows(
        db: OpaquePointer,
        rows: [Kraken2ClassificationRow],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        guard !rows.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = """
        INSERT INTO classification_rows (
            sample, taxon_name, tax_id, rank, rank_display_name,
            reads_direct, reads_clade, percentage,
            parent_tax_id, depth, fraction_direct
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw Kraken2DatabaseError.insertFailed("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let total = rows.count
        let reportInterval = max(1, rows.count / 20)

        for (i, row) in rows.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            // 1: sample (TEXT NOT NULL)
            krBindText(stmt, 1, row.sample)
            // 2: taxon_name (TEXT NOT NULL)
            krBindText(stmt, 2, row.taxonName)
            // 3: tax_id (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 3, Int64(row.taxId))
            // 4: rank (TEXT)
            if let rank = row.rank {
                krBindText(stmt, 4, rank)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            // 5: rank_display_name (TEXT)
            if let rankDisplayName = row.rankDisplayName {
                krBindText(stmt, 5, rankDisplayName)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            // 6: reads_direct (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 6, Int64(row.readsDirect))
            // 7: reads_clade (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 7, Int64(row.readsClade))
            // 8: percentage (REAL NOT NULL)
            sqlite3_bind_double(stmt, 8, row.percentage)
            // 9: parent_tax_id (INTEGER, nullable)
            if let parentTaxId = row.parentTaxId {
                sqlite3_bind_int64(stmt, 9, Int64(parentTaxId))
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            // 10: depth (INTEGER NOT NULL)
            sqlite3_bind_int64(stmt, 10, Int64(row.depth))
            // 11: fraction_direct (REAL NOT NULL)
            sqlite3_bind_double(stmt, 11, row.fractionDirect)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw Kraken2DatabaseError.insertFailed("Row \(i) failed: \(msg)")
            }

            if (i + 1) % reportInterval == 0 {
                let fraction = 0.05 + 0.75 * Double(i + 1) / Double(total)
                progress?(fraction, "Inserting rows \(i + 1)/\(total)...")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.insertFailed("Commit failed: \(msg)")
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
            throw Kraken2DatabaseError.insertFailed("Metadata prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        for (key, value) in metadata {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            krBindText(stmt, 1, key)
            krBindText(stmt, 2, value)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw Kraken2DatabaseError.insertFailed("Metadata row failed: \(msg)")
            }
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.insertFailed("Metadata commit failed: \(msg)")
        }
    }

    // MARK: - Indices

    private static func createIndices(db: OpaquePointer) throws {
        let indices = [
            "CREATE INDEX idx_kr_sample ON classification_rows(sample)",
            "CREATE INDEX idx_kr_taxon ON classification_rows(taxon_name)",
            "CREATE INDEX idx_kr_reads ON classification_rows(reads_clade)",
            "CREATE INDEX idx_kr_metadata_field_value ON sample_metadata_cache(field, value)",
            "CREATE INDEX idx_kr_metadata_sample ON sample_metadata_cache(sample)",
        ]
        for sql in indices {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw Kraken2DatabaseError.createFailed("Index creation failed: \(msg)")
            }
        }
    }

    // MARK: - Queries

    /// Returns classification rows for the given sample names.
    ///
    /// - Parameter samples: Sample identifiers to fetch. If empty, returns [].
    /// - Returns: Array of ``Kraken2ClassificationRow`` matching the requested samples.
    public func fetchRows(samples: [String]) throws -> [Kraken2ClassificationRow] {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }
        guard !samples.isEmpty else { return [] }

        let placeholders = samples.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT * FROM classification_rows WHERE sample IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, sample) in samples.enumerated() {
            krBindText(stmt, Int32(i + 1), sample)
        }

        return collectRows(stmt: stmt)
    }

    /// Returns all distinct samples and their taxon counts.
    ///
    /// - Returns: Array of (sample, taxonCount) tuples ordered by sample name.
    public func fetchSamples() throws -> [(sample: String, taxonCount: Int)] {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, COUNT(*) as cnt FROM classification_rows GROUP BY sample ORDER BY sample"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(sample: String, taxonCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            results.append((sample: sample, taxonCount: count))
        }
        return results
    }

    /// Returns all metadata key-value pairs.
    ///
    /// - Returns: Dictionary of metadata entries.
    public func fetchMetadata() throws -> [String: String] {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT key, value FROM metadata"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.queryFailed(msg)
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

    public func refreshSampleMetadataCache(store: SampleMetadataStore) throws {
        var writeDB: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &writeDB, flags, nil)
        guard rc == SQLITE_OK, let writeDB else {
            let msg = writeDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(writeDB)
            throw Kraken2DatabaseError.queryFailed("Failed to open metadata cache for writing: \(msg)")
        }
        defer { sqlite3_close(writeDB) }

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS sample_metadata_cache (
            sample TEXT NOT NULL,
            field TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(sample, field)
        );
        CREATE INDEX IF NOT EXISTS idx_kr_metadata_field_value ON sample_metadata_cache(field, value);
        CREATE INDEX IF NOT EXISTS idx_kr_metadata_sample ON sample_metadata_cache(sample);
        """
        guard sqlite3_exec(writeDB, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(writeDB))
            throw Kraken2DatabaseError.queryFailed("Failed to ensure metadata cache schema: \(msg)")
        }

        guard sqlite3_exec(writeDB, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(writeDB))
            throw Kraken2DatabaseError.queryFailed("Failed to begin metadata cache transaction: \(msg)")
        }

        guard sqlite3_exec(writeDB, "DELETE FROM sample_metadata_cache", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(writeDB))
            sqlite3_exec(writeDB, "ROLLBACK", nil, nil, nil)
            throw Kraken2DatabaseError.queryFailed("Failed to clear metadata cache: \(msg)")
        }

        let insertSQL = "INSERT INTO sample_metadata_cache (sample, field, value) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(writeDB, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(writeDB))
            sqlite3_exec(writeDB, "ROLLBACK", nil, nil, nil)
            throw Kraken2DatabaseError.queryFailed("Failed to prepare metadata cache insert: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (sample, record) in store.records {
            for (field, value) in record {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                krBindText(stmt, 1, sample)
                krBindText(stmt, 2, field)
                krBindText(stmt, 3, value)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    let msg = String(cString: sqlite3_errmsg(writeDB))
                    sqlite3_exec(writeDB, "ROLLBACK", nil, nil, nil)
                    throw Kraken2DatabaseError.queryFailed("Failed to insert metadata cache row: \(msg)")
                }
            }
        }

        guard sqlite3_exec(writeDB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(writeDB))
            throw Kraken2DatabaseError.queryFailed("Failed to commit metadata cache transaction: \(msg)")
        }
    }

    public func fetchMetadataValues(field: String) throws -> [String: String] {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }

        let sql = "SELECT sample, value FROM sample_metadata_cache WHERE field = ? ORDER BY sample"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        krBindText(stmt, 1, field)

        var results: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sample = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            results[sample] = value
        }
        return results
    }

    public func filterSamplesByMetadata(_ filters: [KrakenMetadataFilter]) throws -> [String] {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }
        let allSamples = try fetchSamples().map(\.sample)
        guard !filters.isEmpty else { return allSamples }

        var matchingSamples = Set(allSamples)

        for filter in filters {
            let sql: String
            let boundValue: String
            switch filter.op {
            case .equal:
                sql = "SELECT sample FROM sample_metadata_cache WHERE field = ? AND lower(value) = lower(?)"
                boundValue = filter.value
            case .contains:
                sql = "SELECT sample FROM sample_metadata_cache WHERE field = ? AND lower(value) LIKE lower(?)"
                boundValue = "%\(filter.value)%"
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw Kraken2DatabaseError.queryFailed(msg)
            }

            krBindText(stmt, 1, filter.field)
            krBindText(stmt, 2, boundValue)

            var currentMatches: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                currentMatches.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
            sqlite3_finalize(stmt)

            matchingSamples.formIntersection(currentMatches)
            if matchingSamples.isEmpty {
                return []
            }
        }

        return matchingSamples.sorted()
    }

    public func searchPrunedHierarchy(
        taxonQuery: String,
        sampleIds: [String]
    ) throws -> KrakenPrunedSearchResult {
        guard let db else {
            throw Kraken2DatabaseError.queryFailed("Database not open")
        }
        let trimmed = taxonQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sampleIds.isEmpty else {
            return KrakenPrunedSearchResult(rows: [], matchingSamples: [])
        }

        let samplePlaceholders = sampleIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
        WITH RECURSIVE
        matches AS (
            SELECT sample, tax_id
            FROM classification_rows
            WHERE sample IN (\(samplePlaceholders))
              AND lower(taxon_name) LIKE lower(?)
        ),
        ancestor_ids(sample, tax_id) AS (
            SELECT sample, tax_id FROM matches
            UNION
            SELECT cr.sample, cr.parent_tax_id
            FROM classification_rows cr
            JOIN ancestor_ids a
              ON cr.sample = a.sample AND cr.tax_id = a.tax_id
            WHERE cr.parent_tax_id IS NOT NULL
        )
        SELECT DISTINCT
            cr.rowid, cr.sample, cr.taxon_name, cr.tax_id, cr.rank, cr.rank_display_name,
            cr.reads_direct, cr.reads_clade, cr.percentage, cr.parent_tax_id, cr.depth, cr.fraction_direct
        FROM classification_rows cr
        JOIN ancestor_ids a
          ON cr.sample = a.sample AND cr.tax_id = a.tax_id
        ORDER BY cr.sample, cr.depth, cr.reads_clade DESC, cr.taxon_name
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Kraken2DatabaseError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (index, sampleId) in sampleIds.enumerated() {
            krBindText(stmt, Int32(index + 1), sampleId)
        }
        krBindText(stmt, Int32(sampleIds.count + 1), "%\(trimmed)%")

        let rows = collectRows(stmt: stmt)
        let matchingSamples = Set(rows.map(\.sample)).sorted()
        return KrakenPrunedSearchResult(rows: rows, matchingSamples: matchingSamples)
    }

    // MARK: - Tree Reconstruction

    /// Reconstructs a ``TaxonTree`` for a single sample from DB rows.
    ///
    /// Builds ``TaxonNode`` instances from the stored classification rows, links
    /// parent-child relationships via ``TaxonNode/addChild(_:)``, and returns a
    /// complete ``TaxonTree`` suitable for sunburst rendering and hierarchical tables.
    ///
    /// - Parameter sample: The sample identifier to reconstruct the tree for.
    /// - Returns: A fully linked ``TaxonTree``.
    /// - Throws: ``Kraken2DatabaseError/queryFailed(_:)`` if no root node is found.
    public func fetchTree(sample: String) throws -> TaxonTree {
        let rows = try fetchRows(samples: [sample])
        let meta = try fetchMetadata()

        // Per-sample metadata takes priority, fall back to aggregated
        let totalReads = Int(meta["total_reads_\(sample)"] ?? meta["total_reads"] ?? "0") ?? 0

        // Build nodes indexed by taxId
        var nodesByTaxId: [Int: TaxonNode] = [:]
        for row in rows {
            let node = TaxonNode(
                taxId: row.taxId,
                name: row.taxonName,
                rank: TaxonomicRank(code: row.rank ?? "no rank"),
                depth: row.depth,
                readsDirect: row.readsDirect,
                readsClade: row.readsClade,
                fractionClade: row.percentage / 100.0,
                fractionDirect: row.fractionDirect,
                parentTaxId: row.parentTaxId
            )
            nodesByTaxId[row.taxId] = node
        }

        // Link parent-child via addChild (sets both parent ref and children array)
        for (_, node) in nodesByTaxId {
            if let parentId = node.parentTaxId, let parent = nodesByTaxId[parentId] {
                parent.addChild(node)
            }
        }

        // Sort children by readsClade descending
        for (_, node) in nodesByTaxId {
            node.children.sort { $0.readsClade > $1.readsClade }
        }

        // Find root (depth 0)
        guard let root = nodesByTaxId.values.first(where: { $0.depth == 0 }) else {
            throw Kraken2DatabaseError.queryFailed("No root node found for sample \(sample)")
        }

        // Build unclassified node from metadata
        let unclassifiedReads = Int(
            meta["unclassified_reads_\(sample)"] ?? meta["unclassified_reads"] ?? "0"
        ) ?? 0
        let unclassifiedNode: TaxonNode? = unclassifiedReads > 0 ? TaxonNode(
            taxId: 0,
            name: "unclassified",
            rank: .unclassified,
            depth: 0,
            readsDirect: unclassifiedReads,
            readsClade: unclassifiedReads,
            fractionClade: totalReads > 0 ? Double(unclassifiedReads) / Double(totalReads) : 0,
            fractionDirect: totalReads > 0 ? Double(unclassifiedReads) / Double(totalReads) : 0,
            parentTaxId: nil
        ) : nil

        return TaxonTree(root: root, unclassifiedNode: unclassifiedNode, totalReads: totalReads)
    }

    // MARK: - Private Helpers

    /// Reads an optional TEXT column, returning nil if the column is NULL.
    private func optionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return String(cString: sqlite3_column_text(stmt, col))
    }

    /// Collects all rows from a prepared SELECT * FROM classification_rows statement.
    ///
    /// Column order must match the schema: rowid(0), sample(1), taxon_name(2), tax_id(3),
    /// rank(4), rank_display_name(5), reads_direct(6), reads_clade(7), percentage(8),
    /// parent_tax_id(9), depth(10), fraction_direct(11).
    private func collectRows(stmt: OpaquePointer?) -> [Kraken2ClassificationRow] {
        var rows: [Kraken2ClassificationRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Column 0 is rowid (skip), actual data starts at column 1
            let sample          = String(cString: sqlite3_column_text(stmt, 1))
            let taxonName       = String(cString: sqlite3_column_text(stmt, 2))
            let taxId           = Int(sqlite3_column_int64(stmt, 3))
            let rank            = optionalText(stmt, 4)
            let rankDisplayName = optionalText(stmt, 5)
            let readsDirect     = Int(sqlite3_column_int64(stmt, 6))
            let readsClade      = Int(sqlite3_column_int64(stmt, 7))
            let percentage      = sqlite3_column_double(stmt, 8)
            let parentTaxId: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, 9))
            let depth           = Int(sqlite3_column_int64(stmt, 10))
            let fractionDirect  = sqlite3_column_double(stmt, 11)

            rows.append(Kraken2ClassificationRow(
                sample: sample,
                taxonName: taxonName,
                taxId: taxId,
                rank: rank,
                rankDisplayName: rankDisplayName,
                readsDirect: readsDirect,
                readsClade: readsClade,
                percentage: percentage,
                parentTaxId: parentTaxId,
                depth: depth,
                fractionDirect: fractionDirect
            ))
        }
        return rows
    }
}
