// VariantDatabase.swift - SQLite-backed variant database for reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log


// MARK: - VariantDatabase (Reader)

/// Reads variant data from a SQLite database embedded in a .lungfishref bundle.
///
/// The database is created during bundle building from VCF files, providing instant
/// random-access queries by genomic region without requiring a tabix/CSI index reader.
///
/// Schema (v3):
/// ```sql
/// CREATE TABLE variants (
///     id INTEGER PRIMARY KEY AUTOINCREMENT,
///     chromosome TEXT NOT NULL,
///     position INTEGER NOT NULL,
///     end_pos INTEGER NOT NULL,
///     variant_id TEXT NOT NULL,
///     ref TEXT NOT NULL,
///     alt TEXT NOT NULL,
///     variant_type TEXT NOT NULL,
///     quality REAL,
///     filter TEXT,
///     info TEXT,
///     sample_count INTEGER DEFAULT 0
/// );
/// CREATE TABLE genotypes (...);
/// CREATE TABLE samples (...);
/// CREATE TABLE variant_info (...);
/// CREATE TABLE variant_info_defs (...);
/// CREATE TABLE db_metadata (...);
/// ```
public final class VariantDatabase: @unchecked Sendable {

    struct ImportTuning {
        let workerThreads: Int
        let cacheKB: Int
        let pageSizeKB: Int
        let writeBudget: Int
        let minWriteBudget: Int
        let shrinkEveryCommits: Int
        let shrinkEveryCommit: Bool
        /// Number of inserted variants between memory-pressure probes.
        let memoryProbeVariantInterval: Int
        /// Trigger forced COMMIT+shrink when resident set exceeds this fraction of RAM.
        let memoryPressureThresholdFraction: Double
        /// Return threshold for expanding the adaptive write budget again.
        let memoryPressureRelaxFraction: Double
        /// When true, create indexes on empty tables before inserts begin so they are
        /// maintained incrementally.  This avoids the multi-GB sort required by bulk
        /// CREATE INDEX on tables with billions of rows.
        let createIndexesUpFront: Bool
        /// Maximum number of INFO key-value pairs to store per variant in the
        /// `variant_info` EAV table.  0 = unlimited.  Limiting this dramatically
        /// reduces the size of `variant_info` for VCFs with VEP/CSQ annotations.
        let maxVariantInfoKeysPerVariant: Int
        /// When true, skip the variant_info EAV table entirely and store the raw
        /// INFO string in variants.info instead.  This eliminates billions of rows
        /// and 2 indexes for large VCFs, reducing DB size by ~50-70%.
        let skipVariantInfo: Bool
        /// If > 0, close and reopen the SQLite connection after this many variant
        /// inserts to fight malloc fragmentation.  0 = never reset.
        let connectionResetInterval: Int
    }

    static let expectedSchemaVersion = 3
    static let requiredTables: Set<String> = [
        "variants", "genotypes", "samples", "variant_info", "variant_info_defs", "db_metadata"
    ]
    static let requiredVariantColumns: Set<String> = [
        "id", "chromosome", "position", "end_pos", "variant_id",
        "ref", "alt", "variant_type", "quality", "filter", "info", "sample_count"
    ]
    static let requiredGenotypeColumns: Set<String> = [
        "variant_id", "sample_name", "genotype", "allele1", "allele2",
        "is_phased", "depth", "genotype_quality", "allele_depths", "raw_fields"
    ]

    var db: OpaquePointer?
    let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }
    /// Whether the database is opened read-only.
    let isReadOnly: Bool

    // MARK: - Query Timeout (sqlite3_progress_handler)

    /// Context object for the sqlite3_progress_handler callback.
    /// Stored as a strong reference to keep it alive for the Unmanaged pointer.
    var progressContext: QueryProgressContext?

    final class QueryProgressContext {
        let startTime: CFAbsoluteTime
        let timeoutSeconds: TimeInterval
        let cancelCheck: (() -> Bool)?

        init(timeoutSeconds: TimeInterval, cancelCheck: (() -> Bool)? = nil) {
            self.startTime = CFAbsoluteTimeGetCurrent()
            self.timeoutSeconds = timeoutSeconds
            self.cancelCheck = cancelCheck
        }

        var isExpired: Bool {
            CFAbsoluteTimeGetCurrent() - startTime > timeoutSeconds
        }
    }

    /// Installs a progress handler that aborts queries exceeding the timeout.
    /// The callback is invoked every ~1000 virtual machine opcodes (~0.5-2ms).
    /// If the callback returns non-zero, the current query aborts with SQLITE_INTERRUPT.
    public func installQueryTimeout(seconds: TimeInterval, cancelCheck: (() -> Bool)? = nil) {
        guard let db else { return }
        let ctx = QueryProgressContext(timeoutSeconds: seconds, cancelCheck: cancelCheck)
        self.progressContext = ctx
        let rawPtr = Unmanaged.passUnretained(ctx).toOpaque()
        sqlite3_progress_handler(db, 1000, { rawPtr in
            guard let rawPtr else { return 0 }
            let ctx = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
            if ctx.isExpired { return 1 }
            if ctx.cancelCheck?() == true { return 1 }
            return 0
        }, rawPtr)
    }

    /// Removes the progress handler.  Call after query completes.
    public func removeQueryTimeout() {
        guard let db else { return }
        sqlite3_progress_handler(db, 0, nil, nil)
        self.progressContext = nil
    }

    // MARK: - Metadata Cache

    /// Lock protecting all mutable cache fields below.  Required because
    /// VariantDatabase is `@unchecked Sendable` and may be accessed from
    /// both the main thread and background query queues.
    let cacheLock = NSLock()

    var _cachedTotalCount: Int?
    var _cachedAllTypes: [String]?
    var _cachedAllChromosomes: [String]?
    var _cachedChromosomeMaxPositions: [String: Int]?
    var _cachedChromosomeCounts: [String: Int]?
    /// Whether the high-impact temp table has been created.
    var _highImpactCacheReady = false
    /// Cached INFO keys discovered from raw INFO strings (for skipVariantInfo databases).
    var _cachedDiscoveredInfoKeys: [(key: String, type: String, number: String, description: String)]?
    /// Per-SmartToken cache state: token name → (ready, count).
    var _tokenCacheState: [String: (ready: Bool, count: Int)] = [:]

    /// Opens an existing variant database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file
    /// - Parameter readWrite: If true, opens for read-write access (needed for metadata import)
    /// - Throws: If the database cannot be opened
    public init(url: URL, readWrite: Bool = false) throws {
        self.url = url
        self.isReadOnly = !readWrite
        let flags = readWrite
            ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw VariantDatabaseError.openFailed(msg)
        }
        guard let db else {
            throw VariantDatabaseError.openFailed("Database handle is nil")
        }
        // Enforce FK constraints so genotype rows cannot be orphaned.
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        // Read-side performance tuning: larger page cache and memory-mapped I/O
        // for interactive queries on multi-GB databases.
        if !readWrite {
            sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)   // 64 MB page cache
            sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil) // 256 MB mmap
            sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
        }
        try Self.validateSchema(db: db)
        // Eagerly compute variantInfoSkipped (must happen before loadTokenCacheState).
        self.variantInfoSkipped = Self.readMetadataValue(db, key: "skip_variant_info") == "true"
        // Load pre-built token filter tables (created during import) — instant.
        loadTokenCacheState()
        variantDBLogger.info("Opened variant database: \(url.lastPathComponent)")
    }

    /// Convenience init that opens read-only (backward compatible).
    public convenience init(url: URL) throws {
        try self.init(url: url, readWrite: false)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Checks whether a table exists in the database.
    static func tableExists(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        variantDBBindText(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    static func columnsForTable(db: OpaquePointer, table: String) -> Set<String> {
        // Guard against injection — PRAGMA doesn't support parameterized bindings.
        guard table.allSatisfy({ $0.isLetter || $0 == "_" || $0.isNumber }) else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cStr))
            }
        }
        return columns
    }

    static func schemaVersion(db: OpaquePointer) -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM db_metadata WHERE key='schema_version' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return Int(String(cString: cStr))
    }

    static func validateSchema(db: OpaquePointer) throws {
        let existingTables = requiredTables.filter { tableExists(db: db, name: $0) }
        guard existingTables.count == requiredTables.count else {
            let missing = requiredTables.subtracting(existingTables).sorted().joined(separator: ", ")
            throw VariantDatabaseError.invalidSchema("Missing required tables: \(missing)")
        }
        let variantColumns = columnsForTable(db: db, table: "variants")
        guard requiredVariantColumns.isSubset(of: variantColumns) else {
            let missing = requiredVariantColumns.subtracting(variantColumns).sorted().joined(separator: ", ")
            throw VariantDatabaseError.invalidSchema("variants table missing required columns: \(missing)")
        }
        let genotypeColumns = columnsForTable(db: db, table: "genotypes")
        guard requiredGenotypeColumns.isSubset(of: genotypeColumns) else {
            let missing = requiredGenotypeColumns.subtracting(genotypeColumns).sorted().joined(separator: ", ")
            throw VariantDatabaseError.invalidSchema("genotypes table missing required columns: \(missing)")
        }
        guard let version = schemaVersion(db: db) else {
            throw VariantDatabaseError.invalidSchema("Missing db_metadata schema_version")
        }
        guard version == expectedSchemaVersion else {
            throw VariantDatabaseError.invalidSchema("Unsupported schema_version \(version); expected \(expectedSchemaVersion)")
        }
        try validateCompletedImport(db: db)
    }

    private static func validateCompletedImport(db: OpaquePointer) throws {
        guard let importState = readMetadataValue(db, key: "import_state") else {
            throw VariantDatabaseError.invalidSchema("Missing db_metadata import_state; expected complete")
        }
        guard importState == "complete" else {
            throw VariantDatabaseError.invalidSchema(
                "Variant database import_state is '\(importState)'; expected complete before opening for queries"
            )
        }

        let skipVariantInfo = readMetadataValue(db, key: "skip_variant_info") == "true"
        let requiredIndexNames = allIndexStatements
            .filter { !(skipVariantInfo && $0.name.contains("variant_info")) }
            .map(\.name)
        let existingIndexNames = listExistingIndexes(db)
        let missingIndexes = requiredIndexNames
            .filter { !existingIndexNames.contains($0) }
            .sorted()
        guard missingIndexes.isEmpty else {
            throw VariantDatabaseError.invalidSchema(
                "Missing required indexes: \(missingIndexes.joined(separator: ", "))"
            )
        }
    }

    /// Whether this database was imported with `skipVariantInfo = true`, meaning the
    /// `variant_info` EAV table is empty and the raw INFO string is stored in
    /// `variants.info` instead.  Computed eagerly in `init` for thread safety.
    public let variantInfoSkipped: Bool

    /// Whether the variant_bookmarks table exists.
    var hasBookmarkTable: Bool = false
}
