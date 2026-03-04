// VariantDatabase.swift - SQLite-backed variant database for reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// Logger for variant database operations
private let variantDBLogger = Logger(subsystem: "com.lungfish.browser", category: "VariantDatabase")

// MARK: - VariantDatabaseRecord

/// A single variant record from the SQLite database.
public struct VariantDatabaseRecord: Sendable, Equatable {
    /// Auto-increment row ID.
    public let id: Int64?

    /// Chromosome name
    public let chromosome: String

    /// 0-based start position
    public let position: Int

    /// 0-based end position (exclusive)
    public let end: Int

    /// Variant ID (rsID or generated)
    public let variantID: String

    /// Reference allele
    public let ref: String

    /// Alternate allele(s), comma-separated
    public let alt: String

    /// Variant type (SNP, INS, DEL, MNP, COMPLEX)
    public let variantType: String

    /// Quality score (PHRED-scaled), nil if unknown
    public let quality: Double?

    /// Filter status (PASS, filter name, or nil)
    public let filter: String?

    /// INFO field as raw string for optional parsing
    public let info: String?

    /// Number of samples with genotype data at this site
    public let sampleCount: Int

    public init(
        id: Int64? = nil,
        chromosome: String, position: Int, end: Int, variantID: String,
        ref: String, alt: String, variantType: String,
        quality: Double?, filter: String?, info: String?,
        sampleCount: Int = 0
    ) {
        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.end = end
        self.variantID = variantID
        self.ref = ref
        self.alt = alt
        self.variantType = variantType
        self.quality = quality
        self.filter = filter
        self.info = info
        self.sampleCount = sampleCount
    }

    /// Converts this record to a `BundleVariant` for use by the rendering pipeline.
    public func toBundleVariant() -> BundleVariant {
        BundleVariant(
            id: variantID,
            chromosome: chromosome,
            position: Int64(position),
            ref: ref,
            alt: alt.split(separator: ",").map(String.init),
            quality: quality.map { Float($0) },
            variantId: variantID,
            filter: filter
        )
    }

    /// Converts this record to a `SequenceAnnotation` for rendering in the annotation pipeline.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType: AnnotationType
        switch variantType {
        case "SNP": annotationType = .snp
        case "INS": annotationType = .insertion
        case "DEL": annotationType = .deletion
        default: annotationType = .variation
        }

        let vtype = VariantType(rawValue: variantType) ?? .complex
        let color = vtype.defaultColor

        var qualifiers: [String: AnnotationQualifier] = [:]
        qualifiers["variant_type"] = AnnotationQualifier(variantType)
        qualifiers["ref"] = AnnotationQualifier(ref)
        qualifiers["alt"] = AnnotationQualifier(alt)
        if let q = quality {
            qualifiers["quality"] = AnnotationQualifier(String(format: "%.2f", q))
        }
        if let f = filter {
            qualifiers["filter"] = AnnotationQualifier(f)
        }
        qualifiers["sample_count"] = AnnotationQualifier(String(sampleCount))
        if let rowId = id {
            qualifiers["variant_row_id"] = AnnotationQualifier(String(rowId))
        }

        let alts = alt.split(separator: ",").map(String.init)
        var noteComponents: [String] = []
        noteComponents.append("\(vtype.displayName): \(ref) > \(alts.joined(separator: ", "))")
        if let q = quality {
            noteComponents.append("Quality: \(String(format: "%.1f", q))")
        }
        if let f = filter, f != "." {
            noteComponents.append("Filter: \(f)")
        }

        return SequenceAnnotation(
            type: annotationType,
            name: variantID,
            chromosome: chromosome,
            start: position,
            end: end,
            strand: .unknown,
            qualifiers: qualifiers,
            color: color,
            note: noteComponents.joined(separator: "\n")
        )
    }
}

// MARK: - GenotypeRecord

/// A single sample genotype record from the SQLite database.
public struct GenotypeRecord: Sendable, Equatable {
    /// The variant row ID this genotype belongs to.
    public let variantRowId: Int64

    /// Sample name (matches VCF header sample column).
    public let sampleName: String

    /// Raw genotype string from GT field (e.g. "0/1", "1|1", "./.").
    public let genotype: String?

    /// First allele index (0 = ref, 1+ = alt, -1 = missing).
    public let allele1: Int

    /// Second allele index (0 = ref, 1+ = alt, -1 = missing).
    public let allele2: Int

    /// Whether the genotype is phased (| separator vs /).
    public let isPhased: Bool

    /// Read depth at this site (DP field).
    public let depth: Int?

    /// Genotype quality (GQ field).
    public let genotypeQuality: Int?

    /// Allele depths as comma-separated string (AD field).
    public let alleleDepths: String?

    /// All FORMAT fields as semicolon-delimited key=value pairs.
    public let rawFields: String?

    public init(
        variantRowId: Int64, sampleName: String, genotype: String?,
        allele1: Int, allele2: Int, isPhased: Bool,
        depth: Int?, genotypeQuality: Int?,
        alleleDepths: String?, rawFields: String?
    ) {
        self.variantRowId = variantRowId
        self.sampleName = sampleName
        self.genotype = genotype
        self.allele1 = allele1
        self.allele2 = allele2
        self.isPhased = isPhased
        self.depth = depth
        self.genotypeQuality = genotypeQuality
        self.alleleDepths = alleleDepths
        self.rawFields = rawFields
    }

    /// Genotype classification for rendering.
    public var genotypeCall: GenotypeCall {
        if allele1 < 0 || allele2 < 0 { return .noCall }
        if allele1 == 0 && allele2 == 0 { return .homRef }
        if allele1 == allele2 { return .homAlt }
        return .het
    }
}

/// Classification of a genotype call for rendering purposes.
public enum GenotypeCall: String, Sendable, CaseIterable {
    case homRef = "HOM_REF"
    case het = "HET"
    case homAlt = "HOM_ALT"
    case noCall = "NO_CALL"

    /// IGV-compatible display colors.
    public var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .homRef:  return (0.784, 0.784, 0.784)   // rgb(200, 200, 200) light gray
        case .het:     return (0.133, 0.047, 0.992)    // rgb(34, 12, 253)   dark blue
        case .homAlt:  return (0.067, 0.973, 0.996)    // rgb(17, 248, 254)  cyan
        case .noCall:  return (0.980, 0.980, 0.980)    // rgb(250, 250, 250) near-white
        }
    }

    public var displayName: String {
        switch self {
        case .homRef: return "Hom Ref"
        case .het: return "Het"
        case .homAlt: return "Hom Alt"
        case .noCall: return "No Call"
        }
    }
}

// MARK: - MetadataFormat

/// Supported formats for sample metadata import.
public enum MetadataFormat: String, Sendable {
    case tsv
    case csv
    case excel
}

// MARK: - Safe SQLite Text Binding

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
///
/// Uses `withCString` to keep the C string alive for the duration of the bind call,
/// combined with `SQLITE_TRANSIENT` so SQLite copies the bytes immediately.
/// This prevents dangling pointer bugs from temporary NSString conversions.
private func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

/// Binds a Swift String to a SQLite prepared statement, or NULL if the string is nil.
private func sqliteBindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
    if let text {
        sqliteBindText(stmt, index, text)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

// MARK: - VariantDatabase (Reader)

/// Runtime profile for VCF import resource tuning.
public enum VCFImportProfile: String, Sendable, Codable, CaseIterable {
    case auto
    case lowMemory = "low-memory"
    case fast
    case ultraLowMemory = "ultra-low-memory"
}

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

    private struct ImportTuning {
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

    private static let expectedSchemaVersion = 3
    private static let requiredTables: Set<String> = [
        "variants", "genotypes", "samples", "variant_info", "variant_info_defs", "db_metadata"
    ]
    private static let requiredVariantColumns: Set<String> = [
        "id", "chromosome", "position", "end_pos", "variant_id",
        "ref", "alt", "variant_type", "quality", "filter", "info", "sample_count"
    ]
    private static let requiredGenotypeColumns: Set<String> = [
        "variant_id", "sample_name", "genotype", "allele1", "allele2",
        "is_phased", "depth", "genotype_quality", "allele_depths", "raw_fields"
    ]

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }
    /// Whether the database is opened read-only.
    private let isReadOnly: Bool

    // MARK: - Query Timeout (sqlite3_progress_handler)

    /// Context object for the sqlite3_progress_handler callback.
    /// Stored as a strong reference to keep it alive for the Unmanaged pointer.
    private var progressContext: QueryProgressContext?

    private final class QueryProgressContext {
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
    private let cacheLock = NSLock()

    private var _cachedTotalCount: Int?
    private var _cachedAllTypes: [String]?
    private var _cachedAllChromosomes: [String]?
    private var _cachedChromosomeMaxPositions: [String: Int]?
    private var _cachedChromosomeCounts: [String: Int]?
    /// Whether the high-impact temp table has been created.
    private var _highImpactCacheReady = false
    /// Cached INFO keys discovered from raw INFO strings (for skipVariantInfo databases).
    private var _cachedDiscoveredInfoKeys: [(key: String, type: String, number: String, description: String)]?
    /// Per-SmartToken cache state: token name → (ready, count).
    private var _tokenCacheState: [String: (ready: Bool, count: Int)] = [:]

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
    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqliteBindText(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnsForTable(db: OpaquePointer, table: String) -> Set<String> {
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

    private static func schemaVersion(db: OpaquePointer) -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM db_metadata WHERE key='schema_version' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return Int(String(cString: cStr))
    }

    private static func validateSchema(db: OpaquePointer) throws {
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
    }

    // MARK: - Metadata Queries

    /// Whether this database was imported with `skipVariantInfo = true`, meaning the
    /// `variant_info` EAV table is empty and the raw INFO string is stored in
    /// `variants.info` instead.  Computed eagerly in `init` for thread safety.
    public let variantInfoSkipped: Bool

    /// Returns the total number of variants in the database.
    /// Result is cached on first call for read-only databases.
    public func totalCount() -> Int {
        if let cached = cacheLock.withLock({ _cachedTotalCount }) { return cached }
        let result = computeTotalCount()
        if isReadOnly { cacheLock.withLock { _cachedTotalCount = result } }
        return result
    }

    private func computeTotalCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns all distinct variant type strings (SNP, INS, DEL, MNP, COMPLEX, REF).
    /// Result is cached on first call for read-only databases.
    public func allTypes() -> [String] {
        if let cached = cacheLock.withLock({ _cachedAllTypes }) { return cached }
        let result = computeAllTypes()
        if isReadOnly { cacheLock.withLock { _cachedAllTypes = result } }
        return result
    }

    private func computeAllTypes() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT variant_type FROM variants ORDER BY variant_type", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var types: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                types.append(String(cString: cStr))
            }
        }
        return types
    }

    /// Returns all distinct chromosome names in the database.
    /// Result is cached on first call for read-only databases.
    public func allChromosomes() -> [String] {
        if let cached = cacheLock.withLock({ _cachedAllChromosomes }) { return cached }
        let result = computeAllChromosomes()
        if isReadOnly { cacheLock.withLock { _cachedAllChromosomes = result } }
        return result
    }

    private func computeAllChromosomes() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT chromosome FROM variants ORDER BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var chroms: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                chroms.append(String(cString: cStr))
            }
        }
        return chroms
    }

    /// Returns the maximum end position per chromosome.
    /// Result is cached on first call for read-only databases.
    public func chromosomeMaxPositions() -> [String: Int] {
        if let cached = cacheLock.withLock({ _cachedChromosomeMaxPositions }) { return cached }
        let result = computeChromosomeMaxPositions()
        if isReadOnly { cacheLock.withLock { _cachedChromosomeMaxPositions = result } }
        return result
    }

    private func computeChromosomeMaxPositions() -> [String: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT chromosome, MAX(end_pos) FROM variants GROUP BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [:] }

        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                let chrom = String(cString: cStr)
                let maxPos = Int(sqlite3_column_int64(stmt, 1))
                result[chrom] = maxPos
            }
        }
        return result
    }

    /// Returns per-chromosome variant counts.
    /// Result is cached on first call for read-only databases.
    public func chromosomeVariantCounts() -> [String: Int] {
        if let cached = cacheLock.withLock({ _cachedChromosomeCounts }) { return cached }
        let result = computeChromosomeVariantCounts()
        if isReadOnly { cacheLock.withLock { _cachedChromosomeCounts = result } }
        return result
    }

    private func computeChromosomeVariantCounts() -> [String: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT chromosome, COUNT(*) FROM variants GROUP BY chromosome", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                result[String(cString: cStr)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return result
    }

    /// Returns contig lengths from VCF `##contig` header lines stored during import.
    ///
    /// These provide exact chromosome lengths for reliable alias matching when
    /// VCF chromosome names differ from the reference (e.g., "1" vs "NC_048383.1").
    /// Returns an empty dictionary if contig lengths were not stored (older databases).
    public func contigLengths() -> [String: Int64] {
        guard let db else { return [:] }
        guard let jsonString = Self.readMetadataValue(db, key: "contig_lengths") else { return [:] }
        guard let data = jsonString.data(using: String.Encoding.utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: Int64] = [:]
        for (key, value) in dict {
            if let num = value as? NSNumber {
                result[key] = num.int64Value
            }
        }
        return result
    }

    // MARK: - Region Query

    /// Queries variants overlapping a genomic region.
    ///
    /// This is the primary query for rendering — returns all variants whose
    /// `[position, end_pos)` interval overlaps the given `[start, end)` region.
    public func query(
        chromosome: String,
        start: Int,
        end: Int,
        types: Set<String> = [],
        minQuality: Double? = nil,
        onlyPassing: Bool = false,
        limit: Int = 50_000
    ) -> [VariantDatabaseRecord] {
        guard let db else { return [] }

        var sql = "SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants"
        var conditions: [String] = []
        var bindingsText: [(Int32, String)] = []
        var bindingsInt64: [(Int32, Int64)] = []
        var bindingsDouble: [(Int32, Double)] = []
        var paramIndex: Int32 = 1

        conditions.append("chromosome = ?")
        bindingsText.append((paramIndex, chromosome))
        paramIndex += 1

        conditions.append("position < ?")
        bindingsInt64.append((paramIndex, Int64(end)))
        paramIndex += 1

        conditions.append("end_pos > ?")
        bindingsInt64.append((paramIndex, Int64(start)))
        paramIndex += 1

        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindingsText.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if let minQ = minQuality {
            conditions.append("quality >= ?")
            bindingsDouble.append((paramIndex, minQ))
            paramIndex += 1
        }

        if onlyPassing {
            conditions.append("(filter = 'PASS' OR filter = '.' OR filter IS NULL)")
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY position"
        sql += " LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            variantDBLogger.error("Failed to prepare variant query: \(sql)")
            return []
        }

        for (idx, value) in bindingsText {
            sqliteBindText(stmt, idx, value)
        }
        for (idx, value) in bindingsInt64 {
            sqlite3_bind_int64(stmt, idx, value)
        }
        for (idx, value) in bindingsDouble {
            sqlite3_bind_double(stmt, idx, value)
        }

        return readVariantRows(stmt: stmt!)
    }

    /// Queries variant count in a region (without fetching full records).
    public func queryCount(chromosome: String, start: Int, end: Int) -> Int {
        guard let db else { return 0 }

        let sql = "SELECT COUNT(*) FROM variants WHERE chromosome = ? AND position < ? AND end_pos > ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        sqliteBindText(stmt, 1, chromosome)
        sqlite3_bind_int64(stmt, 2, Int64(end))
        sqlite3_bind_int64(stmt, 3, Int64(start))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// A filter expression on a VCF INFO field (e.g., `DP>20`, `AF>=0.05`).
    public struct InfoFilter: Sendable {
        public let key: String
        public let op: ComparisonOp
        public let value: String

        public enum ComparisonOp: String, Sendable {
            case gt = ">"
            case gte = ">="
            case lt = "<"
            case lte = "<="
            case eq = "="
            case neq = "!="
            case like = "~"
        }

        public init(key: String, op: ComparisonOp, value: String) {
            self.key = key
            self.op = op
            self.value = value
        }

        /// Parses a filter string like "DP>20" or "AF>=0.05" or "GENE~BRCA".
        /// Returns nil if the string doesn't match any recognized pattern.
        public static func parse(_ text: String) -> InfoFilter? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // Try operators longest first to avoid ">" matching before ">="
            for op in [ComparisonOp.gte, .lte, .neq, .gt, .lt, .eq, .like] {
                if let range = trimmed.range(of: op.rawValue) {
                    let key = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !value.isEmpty else { return nil }
                    // Numeric operators require a numeric RHS; invalid numeric tokens are not filters.
                    if op == .gt || op == .gte || op == .lt || op == .lte {
                        guard Double(value) != nil else { return nil }
                    }
                    return InfoFilter(key: key, op: op, value: value)
                }
            }
            return nil
        }

        /// SQL condition fragment for an EXISTS subquery on variant_info.
        func sqlCondition(paramIndex: inout Int32) -> (sql: String, bindings: [(Int32, String)]) {
            var bindings: [(Int32, String)] = []
            let keyParam = paramIndex; paramIndex += 1
            let valueParam = paramIndex; paramIndex += 1
            bindings.append((keyParam, key))
            bindings.append((valueParam, value))

            let cast = "CAST(vi.value AS REAL)"
            let cmp: String
            switch op {
            case .gt:   cmp = "\(cast) > CAST(? AS REAL)"
            case .gte:  cmp = "\(cast) >= CAST(? AS REAL)"
            case .lt:   cmp = "\(cast) < CAST(? AS REAL)"
            case .lte:  cmp = "\(cast) <= CAST(? AS REAL)"
            case .eq:   cmp = "vi.value = ?"
            case .neq:  cmp = "vi.value != ?"
            case .like: cmp = "vi.value LIKE '%' || ? || '%'"
            }

            let sql = "EXISTS (SELECT 1 FROM variant_info vi WHERE vi.variant_id = variants.id AND vi.key COLLATE NOCASE = ? AND \(cmp))"
            return (sql: sql, bindings: bindings)
        }
    }

    /// Queries variants with optional type filter, name filter, INFO filters, and pre-materialized token caches.
    ///
    /// When `activeTokens` is non-empty, matching pre-materialized temp tables are used
    /// via INNER JOIN for instant filtering, and redundant WHERE clauses are skipped.
    public func queryForTable(
        chromosome: String? = nil,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = [],
        limit: Int = 5000
    ) -> [VariantDatabaseRecord] {
        guard let db else { return [] }

        // Collect token JOINs and determine which WHERE clauses they supersede.
        var tokenJoins: [String] = []
        var supersededFilters = SupersededFilters()
        for token in activeTokens {
            if let join = tokenJoinSQL(for: token) {
                tokenJoins.append(join)
                supersededFilters.add(token)
            }
        }

        // Fall back to legacy high-impact JOIN for sole IMPACT=HIGH filter when no token cache.
        let useHighImpactJoin = tokenJoins.isEmpty && isHighImpactOnlyFilter(infoFilters)
        let effectiveInfoFilters = useHighImpactJoin ? [] : supersededFilters.filterInfoFilters(infoFilters)

        let useQualifiedCols = !tokenJoins.isEmpty || useHighImpactJoin
        let selectCols = useQualifiedCols
            ? "variants.id, variants.chromosome, variants.position, variants.end_pos, variants.variant_id, variants.ref, variants.alt, variants.variant_type, variants.quality, variants.filter, variants.info, variants.sample_count"
            : "id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count"
        var sql = "SELECT \(selectCols) FROM variants"
        for join in tokenJoins { sql += " \(join)" }
        if useHighImpactJoin { sql += " \(highImpactJoinSQL())" }

        var conditions: [String] = []
        var bindings: [(Int32, String)] = []
        var paramIndex: Int32 = 1

        if let chromosome {
            conditions.append("variants.chromosome = ?")
            bindings.append((paramIndex, chromosome))
            paramIndex += 1
        }

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ?")
            bindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.map { _ in "?" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, sampleName))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings)
        }

        if !supersededFilters.qualitySuperseded {
            // Quality filter not handled by token JOIN
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY variants.chromosome, variants.position LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        for (idx, value) in bindings {
            sqliteBindText(stmt, idx, value)
        }

        return readVariantRows(stmt: stmt!)
    }

    /// Tracks which WHERE clauses are superseded by pre-materialized token JOINs.
    private struct SupersededFilters {
        var typesSuperseded = false
        var qualitySuperseded = false
        var filterColumnSuperseded = false
        var supersededInfoKeys: Set<String> = []

        mutating func add(_ tokenName: String) {
            switch tokenName {
            case "passOnly": filterColumnSuperseded = true
            case "snv", "indel": typesSuperseded = true
            case "qualityGE30": qualitySuperseded = true
            case "depthGE10": supersededInfoKeys.insert("DP")
            case "rareVariant":
                for key in ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF", "gnomADe_AF", "gnomADg_AF"] {
                    supersededInfoKeys.insert(key)
                }
            case "highImpact":
                for key in ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"] {
                    supersededInfoKeys.insert(key)
                }
            case "highImpactBiological":
                for key in ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"] {
                    supersededInfoKeys.insert(key)
                }
                for key in VariantDatabase.impactConsequenceInfoKeys {
                    supersededInfoKeys.insert(key)
                }
            case "clinvarPathogenic":
                for key in ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"] {
                    supersededInfoKeys.insert(key)
                }
            default: break
            }
        }

        /// Removes InfoFilters that are already handled by token JOINs.
        func filterInfoFilters(_ filters: [InfoFilter]) -> [InfoFilter] {
            filters.filter { !supersededInfoKeys.contains($0.key) }
        }
    }

    /// Returns variant count matching optional filters.
    public func queryCountForTable(
        chromosome: String? = nil,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = []
    ) -> Int {
        guard let db else { return 0 }

        // Collect token JOINs and determine which WHERE clauses they supersede.
        var tokenJoins: [String] = []
        var supersededFilters = SupersededFilters()
        for token in activeTokens {
            if let join = tokenJoinSQL(for: token) {
                tokenJoins.append(join)
                supersededFilters.add(token)
            }
        }

        let useHighImpactJoin = tokenJoins.isEmpty && isHighImpactOnlyFilter(infoFilters)
        let effectiveInfoFilters = useHighImpactJoin ? [] : supersededFilters.filterInfoFilters(infoFilters)

        var sql = "SELECT COUNT(*) FROM variants"
        for join in tokenJoins { sql += " \(join)" }
        if useHighImpactJoin { sql += " \(highImpactJoinSQL())" }

        var conditions: [String] = []
        var bindings: [(Int32, String)] = []
        var paramIndex: Int32 = 1

        if let chromosome {
            conditions.append("variants.chromosome = ?")
            bindings.append((paramIndex, chromosome))
            paramIndex += 1
        }

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ?")
            bindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.map { _ in "?" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, sampleName))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings)
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (idx, value) in bindings {
            sqliteBindText(stmt, idx, value)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Region-filtered variant query for table display.
    /// Combines the region constraint of `query()` with the name/type/info filters of `queryForTable()`.
    public func queryForTableInRegion(
        chromosome: String,
        start: Int,
        end: Int,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = [],
        limit: Int = 5000
    ) -> [VariantDatabaseRecord] {
        guard let db else { return [] }

        // Collect token JOINs and determine which WHERE clauses they supersede.
        var tokenJoins: [String] = []
        var supersededFilters = SupersededFilters()
        for token in activeTokens {
            if let join = tokenJoinSQL(for: token) {
                tokenJoins.append(join)
                supersededFilters.add(token)
            }
        }

        let useHighImpactJoin = tokenJoins.isEmpty && isHighImpactOnlyFilter(infoFilters)
        let effectiveInfoFilters = useHighImpactJoin ? [] : supersededFilters.filterInfoFilters(infoFilters)

        let useQualifiedCols = !tokenJoins.isEmpty || useHighImpactJoin
        let selectCols = useQualifiedCols
            ? "variants.id, variants.chromosome, variants.position, variants.end_pos, variants.variant_id, variants.ref, variants.alt, variants.variant_type, variants.quality, variants.filter, variants.info, variants.sample_count"
            : "id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count"
        var sql = "SELECT \(selectCols) FROM variants"
        for join in tokenJoins { sql += " \(join)" }
        if useHighImpactJoin { sql += " \(highImpactJoinSQL())" }

        let colPrefix = useQualifiedCols ? "variants." : ""
        var conditions: [String] = ["\(colPrefix)chromosome = ?1", "\(colPrefix)position < ?2", "\(colPrefix)end_pos > ?3"]
        var textBindings: [(Int32, String)] = [(1, chromosome)]
        let intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("\(colPrefix)variant_id LIKE ?\(paramIndex)")
            textBindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("\(colPrefix)variant_type IN (\(placeholders))")
            for t in types.sorted() {
                textBindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                textBindings.append((paramIndex, sampleName))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            textBindings.append(contentsOf: filterBindings)
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY \(colPrefix)chromosome, \(colPrefix)position LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        for (idx, value) in textBindings {
            sqliteBindText(stmt, idx, value)
        }
        for (idx, value) in intBindings {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        }

        return readVariantRows(stmt: stmt!)
    }

    /// Region-filtered variant count for table display.
    public func queryCountInRegion(
        chromosome: String,
        start: Int,
        end: Int,
        nameFilter: String = "",
        types: Set<String> = [],
        infoFilters: [InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = []
    ) -> Int {
        guard let db else { return 0 }

        var tokenJoins: [String] = []
        var supersededFilters = SupersededFilters()
        for token in activeTokens {
            if let join = tokenJoinSQL(for: token) {
                tokenJoins.append(join)
                supersededFilters.add(token)
            }
        }

        let useHighImpactJoin = tokenJoins.isEmpty && isHighImpactOnlyFilter(infoFilters)
        let effectiveInfoFilters = useHighImpactJoin ? [] : supersededFilters.filterInfoFilters(infoFilters)

        var sql = "SELECT COUNT(*) FROM variants"
        for join in tokenJoins { sql += " \(join)" }
        if useHighImpactJoin { sql += " \(highImpactJoinSQL())" }

        var conditions: [String] = ["variants.chromosome = ?1", "variants.position < ?2", "variants.end_pos > ?3"]
        var textBindings: [(Int32, String)] = [(1, chromosome)]
        let intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ?\(paramIndex)")
            textBindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                textBindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                textBindings.append((paramIndex, sampleName))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            textBindings.append(contentsOf: filterBindings)
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (idx, value) in textBindings {
            sqliteBindText(stmt, idx, value)
        }
        for (idx, value) in intBindings {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Searches variants by ID (e.g., rsID) with case-insensitive prefix/substring matching.
    public func searchByID(idFilter: String, limit: Int = 1000) -> [VariantDatabaseRecord] {
        guard let db, !idFilter.isEmpty else { return [] }

        let sql = "SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants WHERE variant_id LIKE ? ORDER BY variant_id COLLATE NOCASE LIMIT ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqliteBindText(stmt, 1, "%\(idFilter)%")
        sqlite3_bind_int(stmt, 2, Int32(limit))

        return readVariantRows(stmt: stmt!)
    }

    // MARK: - High-Impact Variant Cache

    /// Known INFO keys for the IMPACT field.
    private static let impactInfoKeys = ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"]

    /// INFO keys that commonly encode VEP/SnpEff consequence terms.
    private static let impactConsequenceInfoKeys = [
        "CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence",
    ]

    /// Consequence terms treated as biologically high impact.
    private static let biologicalHighImpactConsequenceTerms = [
        "transcript_ablation",
        "splice_acceptor_variant",
        "splice_donor_variant",
        "stop_gained",
        "stop_lost",
        "start_lost",
        "frameshift_variant",
        "exon_loss_variant",
        "rare_amino_acid_variant",
    ]

    private static func biologicalHighImpactTokenSQL(
        impactKeys: [String],
        consequenceKeys: [String]
    ) -> String {
        let impactKeyList = impactKeys.map { "'\($0)'" }.joined(separator: ",")
        let consequenceKeyList = consequenceKeys.map { "'\($0)'" }.joined(separator: ",")
        let consequenceMatch = biologicalHighImpactConsequenceTerms
            .map { "INSTR(LOWER(value), '\($0)') > 0" }
            .joined(separator: " OR ")
        return """
        SELECT DISTINCT variant_id FROM (
            SELECT variant_id FROM variant_info
            WHERE key IN (\(impactKeyList)) AND value = 'HIGH'
            UNION
            SELECT variant_id FROM variant_info
            WHERE key IN (\(consequenceKeyList))
              AND (\(consequenceMatch))
        )
        """
    }

    private static func biologicalHighImpactRawInfoSQL() -> String {
        let highImpactMatches = [
            "UPPER(info) LIKE '%IMPACT=HIGH%'",
            "UPPER(info) LIKE '%ANN_IMPACT=HIGH%'",
            "UPPER(info) LIKE '%CSQ_IMPACT=HIGH%'",
        ].joined(separator: " OR ")
        let severeConsequenceMatches = biologicalHighImpactConsequenceTerms
            .map { "LOWER(info) LIKE '%\($0)%'" }
            .joined(separator: " OR ")
        return """
        SELECT id AS variant_id FROM variants
        WHERE info IS NOT NULL AND info != ''
          AND (
            \(highImpactMatches)
            OR
            \(severeConsequenceMatches)
          )
        """
    }

    /// Creates a temp table of variant IDs with IMPACT=HIGH for instant filtering.
    /// Runs once per connection; protected by the progress handler timeout.
    /// Returns true if the cache was created successfully.
    @discardableResult
    public func warmHighImpactCache(timeoutSeconds: TimeInterval = 30) -> Bool {
        guard let db, !_highImpactCacheReady else { return _highImpactCacheReady }

        // Install a timeout so the initial scan doesn't block forever.
        let ctx = QueryProgressContext(timeoutSeconds: timeoutSeconds)
        let savedCtx = progressContext
        progressContext = ctx
        let rawPtr = Unmanaged.passUnretained(ctx).toOpaque()
        sqlite3_progress_handler(db, 1000, { rawPtr in
            guard let rawPtr else { return 0 }
            let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
            return c.isExpired ? 1 : 0
        }, rawPtr)

        defer {
            // Restore previous progress handler state.
            if let savedCtx {
                progressContext = savedCtx
                let rawPtr = Unmanaged.passUnretained(savedCtx).toOpaque()
                sqlite3_progress_handler(db, 1000, { rawPtr in
                    guard let rawPtr else { return 0 }
                    let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                    if c.isExpired { return 1 }
                    if c.cancelCheck?() == true { return 1 }
                    return 0
                }, rawPtr)
            } else {
                sqlite3_progress_handler(db, 0, nil, nil)
                progressContext = nil
            }
        }

        let keyList = Self.impactInfoKeys.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        CREATE TABLE IF NOT EXISTS _high_impact AS
        SELECT DISTINCT variant_id FROM variant_info
        WHERE key IN (\(keyList))
        AND value = 'HIGH'
        """
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err {
            let msg = String(cString: err)
            sqlite3_free(err)
            if rc == SQLITE_INTERRUPT {
                variantDBLogger.info("warmHighImpactCache: timed out after \(timeoutSeconds)s")
            } else {
                variantDBLogger.warning("warmHighImpactCache: failed: \(msg)")
            }
            return false
        }
        // Create index on the temp table for fast JOINs.
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS _idx_hi ON _high_impact(variant_id)", nil, nil, nil)
        _highImpactCacheReady = true

        var countStmt: OpaquePointer?
        defer { sqlite3_finalize(countStmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM _high_impact", -1, &countStmt, nil) == SQLITE_OK,
           sqlite3_step(countStmt) == SQLITE_ROW {
            let count = sqlite3_column_int64(countStmt, 0)
            variantDBLogger.info("warmHighImpactCache: cached \(count) high-impact variants")
        }
        return true
    }

    /// Whether the high-impact temp table is ready for fast queries.
    public var highImpactCacheReady: Bool { _highImpactCacheReady }

    /// Returns the current SmartToken cache state (token rawValue → ready status and count).
    public var tokenCacheState: [String: (ready: Bool, count: Int)] { _tokenCacheState }

    // MARK: - SmartToken Pre-Materialization

    /// Token names used as keys for the cache state dictionary and temp table naming.
    private struct TokenDef {
        let name: String
        let tableName: String
        let sql: String
        let idColumn: String  // "id" for variants-table queries, "variant_id" for EAV queries
        let requiresEAV: Bool
    }

    /// Builds the list of token definitions that can be pre-materialized.
    private func tokenDefinitions(availableInfoKeys: Set<String>) -> [TokenDef] {
        var defs: [TokenDef] = []

        // Column-based tokens (always available)
        defs.append(TokenDef(
            name: "passOnly",
            tableName: "_tok_pass",
            sql: "SELECT id FROM variants WHERE filter = 'PASS'",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "snv",
            tableName: "_tok_snv",
            sql: "SELECT id FROM variants WHERE variant_type IN ('SNV','snv','SNP','snp')",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "indel",
            tableName: "_tok_indel",
            sql: "SELECT id FROM variants WHERE variant_type IN ('Indel','indel','INS','DEL','Insertion','Deletion')",
            idColumn: "id",
            requiresEAV: false
        ))
        defs.append(TokenDef(
            name: "qualityGE30",
            tableName: "_tok_qual30",
            sql: "SELECT id FROM variants WHERE quality >= 30",
            idColumn: "id",
            requiresEAV: false
        ))

        if variantInfoSkipped {
            defs.append(TokenDef(
                name: "highImpactBiological",
                tableName: "_tok_bio_hi",
                sql: Self.biologicalHighImpactRawInfoSQL(),
                idColumn: "variant_id",
                requiresEAV: false
            ))
        }

        // EAV-based tokens (only for databases with variant_info populated)
        if !variantInfoSkipped {
            if availableInfoKeys.contains("DP") {
                defs.append(TokenDef(
                    name: "depthGE10",
                    tableName: "_tok_dp10",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = 'DP' AND CAST(value AS REAL) >= 10",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            let afKey = ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF", "gnomADe_AF", "gnomADg_AF"]
                .first { availableInfoKeys.contains($0) }
            if let afKey {
                defs.append(TokenDef(
                    name: "rareVariant",
                    tableName: "_tok_rare",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(afKey)' AND CAST(value AS REAL) < 0.01",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            // High impact is handled separately by warmHighImpactCache()
            // but we track its state here too.
            let availableConsequenceKeys = Self.impactConsequenceInfoKeys
                .filter { availableInfoKeys.contains($0) }
            let hasImpactKey = !availableInfoKeys.isDisjoint(with: Set(Self.impactInfoKeys))
            if hasImpactKey || !availableConsequenceKeys.isEmpty {
                let tokenSQL = Self.biologicalHighImpactTokenSQL(
                    impactKeys: Self.impactInfoKeys,
                    consequenceKeys: availableConsequenceKeys.isEmpty
                        ? Self.impactConsequenceInfoKeys
                        : availableConsequenceKeys
                )
                defs.append(TokenDef(
                    name: "highImpactBiological",
                    tableName: "_tok_bio_hi",
                    sql: tokenSQL,
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }

            let clinvarKey = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
                .first { availableInfoKeys.contains($0) }
            if let clinvarKey {
                defs.append(TokenDef(
                    name: "clinvarPathogenic",
                    tableName: "_tok_clinvar",
                    sql: "SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(clinvarKey)' AND value LIKE '%athogenic%'",
                    idColumn: "variant_id",
                    requiresEAV: true
                ))
            }
        }

        return defs
    }

    /// Pre-materializes all applicable SmartToken filters as persistent indexed tables.
    ///
    /// Creates permanent `_tok_*` tables during import so that opening the database
    /// later only needs a fast `loadTokenCacheState()` call (row counts, no scans).
    ///
    /// - Parameters:
    ///   - availableInfoKeys: Set of INFO keys present in this database
    ///   - timeoutPerToken: Maximum seconds allowed per table creation
    /// - Returns: Token cache state dictionary
    @discardableResult
    public func warmSmartTokenCaches(
        availableInfoKeys: Set<String>,
        timeoutPerToken: TimeInterval = 30
    ) -> [String: (ready: Bool, count: Int)] {
        guard let db else { return _tokenCacheState }

        let defs = tokenDefinitions(availableInfoKeys: availableInfoKeys)

        for def in defs {
            // Skip if already cached (e.g. loaded from persistent table)
            if _tokenCacheState[def.name]?.ready == true { continue }

            // Install per-token timeout
            let ctx = QueryProgressContext(timeoutSeconds: timeoutPerToken)
            let savedCtx = progressContext
            progressContext = ctx
            let rawPtr = Unmanaged.passUnretained(ctx).toOpaque()
            sqlite3_progress_handler(db, 1000, { rawPtr in
                guard let rawPtr else { return 0 }
                let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                return c.isExpired ? 1 : 0
            }, rawPtr)

            // Persistent table (not TEMP) — survives database close/reopen.
            let createSQL = "CREATE TABLE IF NOT EXISTS \(def.tableName) AS \(def.sql)"
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, createSQL, nil, nil, &err)

            // Restore progress handler
            if let savedCtx {
                progressContext = savedCtx
                let rawPtr = Unmanaged.passUnretained(savedCtx).toOpaque()
                sqlite3_progress_handler(db, 1000, { rawPtr in
                    guard let rawPtr else { return 0 }
                    let c = Unmanaged<QueryProgressContext>.fromOpaque(rawPtr).takeUnretainedValue()
                    if c.isExpired { return 1 }
                    if c.cancelCheck?() == true { return 1 }
                    return 0
                }, rawPtr)
            } else {
                sqlite3_progress_handler(db, 0, nil, nil)
                progressContext = nil
            }

            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                if rc == SQLITE_INTERRUPT {
                    variantDBLogger.info("warmSmartTokenCaches: \(def.name) timed out after \(timeoutPerToken)s")
                } else {
                    variantDBLogger.warning("warmSmartTokenCaches: \(def.name) failed: \(msg)")
                }
                _tokenCacheState[def.name] = (ready: false, count: 0)
                continue
            }

            // Create index on the persistent table
            let indexSQL = "CREATE INDEX IF NOT EXISTS _idx_\(def.tableName) ON \(def.tableName)(\(def.idColumn))"
            sqlite3_exec(db, indexSQL, nil, nil, nil)

            // Count rows
            var count = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(def.tableName)", -1, &countStmt, nil) == SQLITE_OK,
               sqlite3_step(countStmt!) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt!, 0))
            }
            sqlite3_finalize(countStmt)

            _tokenCacheState[def.name] = (ready: true, count: count)
            variantDBLogger.info("warmSmartTokenCaches: \(def.name) cached \(count) variants in \(def.tableName)")
        }

        // Also create persistent high-impact table if not already done
        if !_highImpactCacheReady && !variantInfoSkipped {
            let hasImpactKey = !availableInfoKeys.isDisjoint(with: Set(Self.impactInfoKeys))
            if hasImpactKey {
                warmHighImpactCache(timeoutSeconds: timeoutPerToken)
                if _highImpactCacheReady {
                    var countStmt: OpaquePointer?
                    var hiCount = 0
                    if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM _high_impact", -1, &countStmt, nil) == SQLITE_OK,
                       sqlite3_step(countStmt!) == SQLITE_ROW {
                        hiCount = Int(sqlite3_column_int64(countStmt!, 0))
                    }
                    sqlite3_finalize(countStmt)
                    _tokenCacheState["highImpact"] = (ready: true, count: hiCount)
                }
            }
        }

        return _tokenCacheState
    }

    /// Loads token cache state from pre-existing persistent `_tok_*` tables.
    ///
    /// This is fast (no full table scans — just checks table existence and reads row counts).
    /// Called during database open so SmartToken chips are available instantly.
    public func loadTokenCacheState() {
        guard let db else { return }

        // All known persistent token tables and their token names.
        let knownTables: [(name: String, tableName: String)] = [
            ("passOnly", "_tok_pass"),
            ("snv", "_tok_snv"),
            ("indel", "_tok_indel"),
            ("qualityGE30", "_tok_qual30"),
            ("depthGE10", "_tok_dp10"),
            ("rareVariant", "_tok_rare"),
            ("clinvarPathogenic", "_tok_clinvar"),
            ("highImpactBiological", "_tok_bio_hi"),
            ("highImpact", "_high_impact"),
        ]

        for (name, tableName) in knownTables {
            // Check if the table exists.
            var checkStmt: OpaquePointer?
            let checkSQL = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(checkStmt, 1, tableName, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let exists: Bool
            if sqlite3_step(checkStmt!) == SQLITE_ROW {
                exists = sqlite3_column_int64(checkStmt!, 0) > 0
            } else {
                exists = false
            }
            sqlite3_finalize(checkStmt)
            guard exists else { continue }

            // Read row count (instant — SQLite caches this).
            var countStmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(tableName)", -1, &countStmt, nil) == SQLITE_OK,
               sqlite3_step(countStmt!) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt!, 0))
            }
            sqlite3_finalize(countStmt)

            _tokenCacheState[name] = (ready: true, count: count)
            if name == "highImpact" {
                _highImpactCacheReady = true
            }
        }

        if !_tokenCacheState.isEmpty {
            let loadedCount = _tokenCacheState.count
            variantDBLogger.info("loadTokenCacheState: loaded \(loadedCount) pre-built token tables")
        }
    }

    /// Returns the temp table JOIN fragment for a SmartToken, or nil if not cached.
    ///
    /// The JOIN links `variants.id` to the temp table's id/variant_id column.
    /// Used by query methods to replace WHERE/EXISTS clauses with fast JOINs.
    func tokenJoinSQL(for tokenName: String) -> String? {
        guard _tokenCacheState[tokenName]?.ready == true else { return nil }
        // Map token names to their table definitions
        let tableName: String
        let idColumn: String
        switch tokenName {
        case "passOnly": tableName = "_tok_pass"; idColumn = "id"
        case "snv": tableName = "_tok_snv"; idColumn = "id"
        case "indel": tableName = "_tok_indel"; idColumn = "id"
        case "qualityGE30": tableName = "_tok_qual30"; idColumn = "id"
        case "depthGE10": tableName = "_tok_dp10"; idColumn = "variant_id"
        case "rareVariant": tableName = "_tok_rare"; idColumn = "variant_id"
        case "clinvarPathogenic": tableName = "_tok_clinvar"; idColumn = "variant_id"
        case "highImpactBiological": tableName = "_tok_bio_hi"; idColumn = "variant_id"
        case "highImpact": tableName = "_high_impact"; idColumn = "variant_id"
        default: return nil
        }
        let joinColumn = idColumn == "id" ? "variants.id" : "variants.id"
        let targetColumn = "\(tableName).\(idColumn)"
        return "INNER JOIN \(tableName) ON \(joinColumn) = \(targetColumn)"
    }

    /// Detects whether a set of InfoFilters is a sole IMPACT=HIGH filter
    /// that can be served from the pre-cached temp table.
    private func isHighImpactOnlyFilter(_ infoFilters: [InfoFilter]) -> Bool {
        guard _highImpactCacheReady else { return false }
        guard infoFilters.count == 1 else { return false }
        let f = infoFilters[0]
        return f.op == .eq
            && f.value == "HIGH"
            && Self.impactInfoKeys.contains(where: { $0.caseInsensitiveCompare(f.key) == .orderedSame })
    }

    /// Replaces the EXISTS subquery for IMPACT=HIGH with a JOIN on the temp table.
    /// Returns the SQL fragment and whether it was substituted.
    private func highImpactJoinSQL() -> String {
        "INNER JOIN _high_impact _hi ON variants.id = _hi.variant_id"
    }

    // MARK: - Variant Row Reader

    /// Reads variant rows from a prepared statement.
    ///
    /// Expected column order: id, chromosome, position, end_pos, variant_id, ref, alt,
    /// variant_type, quality, filter, info, sample_count
    private func readVariantRows(stmt: OpaquePointer) -> [VariantDatabaseRecord] {
        var results: [VariantDatabaseRecord] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let chrom = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let pos = Int(sqlite3_column_int64(stmt, 2))
            let endPos = Int(sqlite3_column_int64(stmt, 3))
            let vid = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let ref = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let alt = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let vtype = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "SNP"
            let quality: Double? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
            let filter = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let info = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let sampleCount = Int(sqlite3_column_int64(stmt, 11))

            results.append(VariantDatabaseRecord(
                id: rowId,
                chromosome: chrom, position: pos, end: endPos, variantID: vid,
                ref: ref, alt: alt, variantType: vtype,
                quality: quality, filter: filter, info: info,
                sampleCount: sampleCount
            ))
        }
        return results
    }

    // MARK: - Genotype Queries

    /// Returns all sample names in the database.
    public func sampleNames() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM samples ORDER BY name", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cStr))
            }
        }
        return names
    }

    /// Returns the number of samples in the database.
    public func sampleCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns genotype records for a specific variant (by row ID).
    public func genotypes(forVariantId variantRowId: Int64) -> [GenotypeRecord] {
        guard let db else { return [] }
        let sql = "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes WHERE variant_id = ? ORDER BY sample_name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, variantRowId)
        return readGenotypeRows(stmt: stmt!)
    }

    /// Returns genotype records for many variants in one query batch.
    ///
    /// This avoids N+1 round trips when rendering genotype-heavy table views.
    public func genotypes(forVariantIds variantRowIds: [Int64]) -> [Int64: [GenotypeRecord]] {
        guard let db else { return [:] }
        let uniqueIds = Array(Set(variantRowIds))
        guard !uniqueIds.isEmpty else { return [:] }

        var grouped: [Int64: [GenotypeRecord]] = [:]
        let chunkSize = 500
        for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
            let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
                FROM genotypes
                WHERE variant_id IN (\(placeholders))
                ORDER BY variant_id, sample_name
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (idx, id) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(idx + 1), id)
            }
            let rows = readGenotypeRows(stmt: stmt!)
            for row in rows {
                grouped[row.variantRowId, default: []].append(row)
            }
        }
        return grouped
    }

    /// Returns genotype records for a specific sample in a genomic region.
    ///
    /// Joins genotypes with variants to filter by region.
    public func genotypes(forSample sampleName: String, chromosome: String, start: Int, end: Int) -> [GenotypeRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT g.variant_id, g.sample_name, g.genotype, g.allele1, g.allele2,
                   g.is_phased, g.depth, g.genotype_quality, g.allele_depths, g.raw_fields
            FROM genotypes g
            JOIN variants v ON g.variant_id = v.id
            WHERE g.sample_name = ? AND v.chromosome = ? AND v.position < ? AND v.end_pos > ?
            ORDER BY v.position
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqliteBindText(stmt, 1, sampleName)
        sqliteBindText(stmt, 2, chromosome)
        sqlite3_bind_int64(stmt, 3, Int64(end))
        sqlite3_bind_int64(stmt, 4, Int64(start))
        return readGenotypeRows(stmt: stmt!)
    }

    /// Returns all genotypes for all samples in a genomic region, grouped by variant position.
    ///
    /// This is the primary query for genotype rendering — returns variant positions with
    /// all sample genotypes for that region. Uses a single JOIN query to avoid N+1 round-trips.
    public func genotypesInRegion(chromosome: String, start: Int, end: Int, limit: Int = 10_000) -> [(variant: VariantDatabaseRecord, genotypes: [GenotypeRecord])] {
        guard let db else { return [] }

        // Step 1: fetch a bounded list of variant rows in-region.
        let variantSQL = """
            SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            FROM variants
            WHERE chromosome = ? AND position < ? AND end_pos > ?
            ORDER BY position, id
            LIMIT ?
            """
        var variantStmt: OpaquePointer?
        defer { sqlite3_finalize(variantStmt) }
        guard sqlite3_prepare_v2(db, variantSQL, -1, &variantStmt, nil) == SQLITE_OK else {
            variantDBLogger.error("genotypesInRegion: Failed to prepare variant query")
            return []
        }
        sqliteBindText(variantStmt, 1, chromosome)
        sqlite3_bind_int64(variantStmt, 2, Int64(end))
        sqlite3_bind_int64(variantStmt, 3, Int64(start))
        sqlite3_bind_int64(variantStmt, 4, Int64(limit))
        let variants = readVariantRows(stmt: variantStmt!)
        guard !variants.isEmpty else { return [] }

        // Step 2: fetch all genotypes for just those variant IDs.
        // Chunk to avoid exceeding SQLITE_MAX_VARIABLE_NUMBER (default 999).
        let variantIDs = variants.compactMap(\.id)
        guard !variantIDs.isEmpty else {
            return variants.map { ($0, []) }
        }
        let genotypeMap = genotypes(forVariantIds: variantIDs)
        return variants.map { variant in
            let rows = variant.id.flatMap { genotypeMap[$0] } ?? []
            return (variant: variant, genotypes: rows)
        }
    }

    /// Reads genotype rows from a prepared statement.
    private func readGenotypeRows(stmt: OpaquePointer) -> [GenotypeRecord] {
        var results: [GenotypeRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let variantId = sqlite3_column_int64(stmt, 0)
            let sampleName = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let genotype = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let allele1 = Int(sqlite3_column_int(stmt, 3))
            let allele2 = Int(sqlite3_column_int(stmt, 4))
            let isPhased = sqlite3_column_int(stmt, 5) != 0
            let depth: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
            let gq: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
            let ad = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let raw = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

            results.append(GenotypeRecord(
                variantRowId: variantId,
                sampleName: sampleName,
                genotype: genotype,
                allele1: allele1,
                allele2: allele2,
                isPhased: isPhased,
                depth: depth,
                genotypeQuality: gq,
                alleleDepths: ad,
                rawFields: raw
            ))
        }
        return results
    }

    // MARK: - Mutation Methods (Read-Write)

    /// Renames chromosome names in the variants table using the given mapping.
    ///
    /// Used during VCF import to normalize chromosome names (e.g., `MN908947.3` → `MN908947`).
    /// The database must be opened in read-write mode.
    ///
    /// - Parameter mapping: Dictionary mapping old chromosome names to new names
    /// - Throws: If the database is read-only or the update fails
    public func renameChromosomes(_ mapping: [String: String]) throws {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        guard !mapping.isEmpty else { return }

        let sql = "UPDATE variants SET chromosome = ? WHERE chromosome = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare chromosome rename statement")
        }

        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &errMsg)

        for (oldName, newName) in mapping {
            sqlite3_reset(stmt)
            sqliteBindText(stmt, 1, newName)
            sqliteBindText(stmt, 2, oldName)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw VariantDatabaseError.createFailed("Failed to rename chromosome '\(oldName)' → '\(newName)'")
            }
            let changes = sqlite3_changes(db)
            if changes > 0 {
                variantDBLogger.info("renameChromosomes: '\(oldName)' → '\(newName)' (\(changes) variants)")
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Deletes variants by their row IDs, including associated genotype records.
    ///
    /// - Parameter ids: Array of variant row IDs to delete
    /// - Throws: If the database is read-only or the delete fails
    public func deleteVariants(ids: [Int64]) throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        guard !ids.isEmpty else { return 0 }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        do {
            try executeSQL("BEGIN TRANSACTION")

            // Child rows must be deleted BEFORE variants because PRAGMA foreign_keys = ON
            // is active at runtime and the schema declares REFERENCES variants(id) without
            // ON DELETE CASCADE. Deleting a variant first would trigger SQLITE_CONSTRAINT.
            let deleteInfoSQL = "DELETE FROM variant_info WHERE variant_id IN (\(placeholders))"
            var infoStmt: OpaquePointer?
            defer { sqlite3_finalize(infoStmt) }
            guard sqlite3_prepare_v2(db, deleteInfoSQL, -1, &infoStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(infoStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(infoStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete info for selected variants")
            }

            let deleteGenotypesSQL = "DELETE FROM genotypes WHERE variant_id IN (\(placeholders))"
            var gtStmt: OpaquePointer?
            defer { sqlite3_finalize(gtStmt) }
            guard sqlite3_prepare_v2(db, deleteGenotypesSQL, -1, &gtStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare genotype delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(gtStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(gtStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete genotypes for selected variants")
            }

            let deleteVariantsSQL = "DELETE FROM variants WHERE id IN (\(placeholders))"
            var varStmt: OpaquePointer?
            defer { sqlite3_finalize(varStmt) }
            guard sqlite3_prepare_v2(db, deleteVariantsSQL, -1, &varStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare variant delete statement")
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(varStmt, Int32(i + 1), id)
            }
            guard sqlite3_step(varStmt) == SQLITE_DONE else {
                throw VariantDatabaseError.createFailed("Failed to delete variants")
            }

            let deleted = Int(sqlite3_changes(db))
            try executeSQL("COMMIT")
            variantDBLogger.info("deleteVariants: Deleted \(deleted) variants")
            return deleted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Deletes all variants and associated genotypes from the database.
    ///
    /// - Throws: If the database is read-only or the delete fails
    public func deleteAllVariants() throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }

        do {
            try executeSQL("BEGIN TRANSACTION")
            try executeSQL("DELETE FROM variant_info")
            try executeSQL("DELETE FROM genotypes")
            try executeSQL("DELETE FROM variants")
            let deleted = Int(sqlite3_changes(db))
            try executeSQL("COMMIT")
            variantDBLogger.info("deleteAllVariants: Deleted \(deleted) variants")
            return deleted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Returns the total number of variants in the database.
    /// Delegates to `totalCount()` which caches the result for read-only databases.
    public func totalVariantCount() -> Int {
        totalCount()
    }

    // MARK: - Structured INFO Queries

    /// Returns INFO field definitions from the variant_info_defs table.
    ///
    /// These are parsed from VCF `##INFO=<...>` header lines during import.
    /// For `skipVariantInfo` databases where the defs table is empty, falls back
    /// to discovering keys by sampling raw INFO strings from the variants table.
    public func infoKeys() -> [(key: String, type: String, number: String, description: String)] {
        guard let db else { return [] }
        let sql = "SELECT key, type, number, description FROM variant_info_defs ORDER BY key"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var results: [(key: String, type: String, number: String, description: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "String"
            let number = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "."
            let desc = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            results.append((key: key, type: type, number: number, description: desc))
        }
        if !results.isEmpty {
            var seen = Set(results.map(\.key))
            if seen.contains("CSQ") {
                for subField in Self.csqSubFieldTemplate {
                    let subKey = "CSQ_\(subField)"
                    if !seen.contains(subKey) {
                        results.append((key: subKey, type: "String", number: ".", description: "CSQ sub-field: \(subField)"))
                        seen.insert(subKey)
                    }
                }
                if !seen.contains("CSQ_entries") {
                    results.append((key: "CSQ_entries", type: "Integer", number: "1", description: "Number of CSQ transcript entries"))
                    seen.insert("CSQ_entries")
                }
            }
            if seen.contains("ANN") {
                for subField in Self.annSubFieldTemplate {
                    let subKey = "ANN_\(subField)"
                    if !seen.contains(subKey) {
                        results.append((key: subKey, type: "String", number: ".", description: "ANN sub-field: \(subField)"))
                        seen.insert(subKey)
                    }
                }
                for alias in ["ANN_Consequence", "ANN_IMPACT", "ANN_Gene", "ANN_entries"] where !seen.contains(alias) {
                    results.append((key: alias, type: "String", number: ".", description: "ANN compatibility alias"))
                    seen.insert(alias)
                }
            }
            results.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }
        // For skipVariantInfo databases, discover keys from raw INFO strings.
        if results.isEmpty && variantInfoSkipped {
            return discoverInfoKeysFromRawInfo()
        }
        return results
    }

    /// Discovers INFO keys by sampling raw INFO strings from the variants table.
    ///
    /// Used for databases imported with `skipVariantInfo = true` where the EAV
    /// `variant_info` and `variant_info_defs` tables are empty. Samples rows
    /// from start, middle, and end of the table to capture all keys.
    public func discoverInfoKeysFromRawInfo(sampleSize: Int = 500) -> [(key: String, type: String, number: String, description: String)] {
        if let cached = _cachedDiscoveredInfoKeys { return cached }
        guard let db else { return [] }

        // Sample from three regions of the table for diverse key coverage.
        var maxId: Int64 = 0
        var maxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(id) FROM variants", -1, &maxStmt, nil) == SQLITE_OK,
           sqlite3_step(maxStmt!) == SQLITE_ROW {
            maxId = sqlite3_column_int64(maxStmt!, 0)
        }
        sqlite3_finalize(maxStmt)
        guard maxId > 0 else { return [] }

        let perRegion = max(sampleSize / 3, 50)
        let boundaries: [(Int64, Int64)] = [
            (0, maxId / 3),
            (maxId / 3, 2 * maxId / 3),
            (2 * maxId / 3, maxId),
        ]

        var allKeys: [String: (values: [String], count: Int)] = [:]

        for (lo, hi) in boundaries {
            let sql = "SELECT info FROM variants WHERE id > ? AND id <= ? AND info IS NOT NULL AND info != '' AND info != '.' LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, lo)
            sqlite3_bind_int64(stmt, 2, hi)
            sqlite3_bind_int(stmt, 3, Int32(perRegion))

            while sqlite3_step(stmt!) == SQLITE_ROW {
                guard let cStr = sqlite3_column_text(stmt!, 0) else { continue }
                let infoStr = String(cString: cStr)
                for (key, value) in Self.parseRawINFOString(infoStr) {
                    var entry = allKeys[key] ?? (values: [], count: 0)
                    entry.count += 1
                    if entry.values.count < 5 { entry.values.append(value) }
                    allKeys[key] = entry
                }
            }
        }

        let results: [(key: String, type: String, number: String, description: String)] = allKeys.keys.sorted().map { key in
            let entry = allKeys[key]!
            let inferredType = Self.inferInfoType(from: entry.values)
            return (key: key, type: inferredType, number: ".", description: "")
        }
        _cachedDiscoveredInfoKeys = results
        return results
    }

    /// Infers the VCF INFO type from a sample of values.
    private static func inferInfoType(from values: [String]) -> String {
        let nonEmpty = values.filter { !$0.isEmpty }
        if nonEmpty.isEmpty { return "Flag" }
        let allInteger = nonEmpty.allSatisfy { Int($0) != nil }
        if allInteger { return "Integer" }
        let allNumeric = nonEmpty.allSatisfy { Double($0) != nil }
        if allNumeric { return "Float" }
        return "String"
    }

    /// Returns true if the given INFO key has at least one non-empty value in `variant_info`.
    public func hasNonEmptyInfoValue(forKey key: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM variant_info WHERE key = ? AND TRIM(value) != '' LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqliteBindText(stmt, 1, key)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return true
        }

        // Compatibility for structured raw keys present as CSQ/ANN without expanded sub-fields.
        if key.hasPrefix("CSQ_") {
            var csqStmt: OpaquePointer?
            defer { sqlite3_finalize(csqStmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &csqStmt, nil) == SQLITE_OK else { return false }
            sqliteBindText(csqStmt, 1, "CSQ")
            return sqlite3_step(csqStmt) == SQLITE_ROW
        }
        if key.hasPrefix("ANN_") {
            var annStmt: OpaquePointer?
            defer { sqlite3_finalize(annStmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &annStmt, nil) == SQLITE_OK else { return false }
            sqliteBindText(annStmt, 1, "ANN")
            return sqlite3_step(annStmt) == SQLITE_ROW
        }
        return false
    }

    /// Returns all INFO key-value pairs for a specific variant.
    ///
    /// For standard imports, reads from the `variant_info` EAV table.
    /// For `skipVariantInfo` imports, parses the raw INFO string from `variants.info`.
    public func infoValues(variantId: Int64) -> [String: String] {
        guard let db else { return [:] }

        if variantInfoSkipped {
            // Parse raw INFO string from the variants table.
            let sql = "SELECT info FROM variants WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            sqlite3_bind_int64(stmt, 1, variantId)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let cStr = sqlite3_column_text(stmt, 0) else { return [:] }
            return Self.parseRawINFOString(String(cString: cStr))
        }

        let sql = "SELECT key, value FROM variant_info WHERE variant_id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_int64(stmt, 1, variantId)
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let value = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            result[key] = value
            Self.expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &result)
        }
        return result
    }

    /// Parses a raw VCF INFO string (e.g. "AC=2;AF=0.5;DP=100") into key-value pairs.
    private static func parseRawINFOString(_ info: String) -> [String: String] {
        guard info != "." else { return [:] }
        var result: [String: String] = [:]
        for field in info.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1])
                result[key] = value
                expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &result)
            } else if parts.count == 1 {
                result[String(parts[0])] = "true"
            }
        }
        return result
    }

    /// Common VEP CSQ sub-field order.
    private static let csqSubFieldTemplate: [String] = [
        "Allele", "Consequence", "IMPACT", "SYMBOL", "Gene", "Feature_type", "Feature",
        "BIOTYPE", "EXON", "INTRON", "HGVSc", "HGVSp", "cDNA_position", "CDS_position",
        "Protein_position", "Amino_acids", "Codons", "Existing_variation", "DISTANCE",
        "STRAND", "FLAGS", "SYMBOL_SOURCE", "HGNC_ID",
    ]

    /// Common SnpEff ANN sub-field order.
    private static let annSubFieldTemplate: [String] = [
        "Allele", "Annotation", "Annotation_Impact", "Gene_Name", "Gene_ID", "Feature_Type",
        "Feature_ID", "Transcript_BioType", "Rank", "HGVS_c", "HGVS_p", "cDNA_pos_len",
        "CDS_pos_len", "AA_pos_len", "Distance", "ERRORS_WARNINGS_INFO",
    ]

    /// Expands raw CSQ/ANN entries into synthetic `CSQ_*` / `ANN_*` keys.
    ///
    /// This keeps high-value fields such as IMPACT/Consequence/Gene available even when
    /// databases were built from raw INFO strings instead of pre-expanded EAV rows.
    private static func expandStructuredINFOFieldIfNeeded(
        key: String,
        value: String,
        into result: inout [String: String]
    ) {
        let template: [String]
        switch key {
        case "CSQ":
            template = csqSubFieldTemplate
        case "ANN":
            template = annSubFieldTemplate
        default:
            return
        }

        let entries = value.split(separator: ",", omittingEmptySubsequences: true)
        guard let firstEntry = entries.first else { return }
        let subValues = firstEntry.split(separator: "|", omittingEmptySubsequences: false)
        guard !subValues.isEmpty else { return }

        for (index, fieldName) in template.enumerated() where index < subValues.count {
            let trimmed = String(subValues[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result["\(key)_\(fieldName)"] = trimmed
        }

        if entries.count > 1 {
            result["\(key)_entries"] = String(entries.count)
        }

        // Compatibility aliases used by smart tokens/query UI.
        if key == "ANN" {
            if let consequence = result["ANN_Annotation"] {
                result["ANN_Consequence"] = consequence
            }
            if let impact = result["ANN_Annotation_Impact"] {
                result["ANN_IMPACT"] = impact
            }
            if let gene = result["ANN_Gene_Name"] {
                result["ANN_Gene"] = gene
            }
        }
    }

    /// Batch-fetches INFO dictionaries for multiple variant IDs.
    ///
    /// More efficient than calling `infoValues(variantId:)` per-variant.
    /// Returns a dictionary mapping variant ID to its INFO key-value pairs.
    public func batchInfoValues(variantIds: [Int64]) -> [Int64: [String: String]] {
        guard let db, !variantIds.isEmpty else { return [:] }
        var result: [Int64: [String: String]] = [:]
        let uniqueIds = Array(Set(variantIds))
        let chunkSize = 500 // Keep well below SQLite bind-variable limits.

        if variantInfoSkipped {
            // Parse raw INFO from the variants table.
            for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
                let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT id, info FROM variants WHERE id IN (\(placeholders))"
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                for (i, id) in chunk.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(i + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let variantId = sqlite3_column_int64(stmt, 0)
                    if let cStr = sqlite3_column_text(stmt, 1) {
                        result[variantId] = Self.parseRawINFOString(String(cString: cStr))
                    }
                }
            }
            return result
        }

        for chunkStart in stride(from: 0, to: uniqueIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uniqueIds.count)
            let chunk = Array(uniqueIds[chunkStart..<chunkEnd])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT variant_id, key, value FROM variant_info WHERE variant_id IN (\(placeholders))"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let variantId = sqlite3_column_int64(stmt, 0)
                let key = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let value = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                result[variantId, default: [:]][key] = value
                var expanded = result[variantId, default: [:]]
                Self.expandStructuredINFOFieldIfNeeded(key: key, value: value, into: &expanded)
                result[variantId] = expanded
            }
        }
        return result
    }

    /// Returns distinct non-empty values for an INFO key, limited and sorted by frequency.
    public func distinctInfoValues(forKey key: String, limit: Int = 21) -> [String] {
        guard let db, limit > 0 else { return [] }
        let sql = """
            SELECT value, COUNT(*) AS c
            FROM variant_info
            WHERE key COLLATE NOCASE = ? AND TRIM(value) != ''
            GROUP BY value
            ORDER BY c DESC, value COLLATE NOCASE ASC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqliteBindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: cStr))
            }
        }
        return values
    }

    // MARK: - Sample Source File Queries

    /// Returns the source filename for a specific sample.
    public func sourceFile(forSample name: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT source_file FROM samples WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqliteBindText(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// Returns all source filenames keyed by sample name.
    public func allSourceFiles() -> [String: String] {
        guard let db else { return [:] }
        let sql = "SELECT name, source_file FROM samples ORDER BY name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let file = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            if let file, !name.isEmpty {
                result[name] = file
            }
        }
        return result
    }

    // MARK: - Sample Metadata Queries

    /// Returns metadata for a specific sample as a dictionary.
    public func sampleMetadata(name: String) -> [String: String] {
        guard let db else { return [:] }
        let sql = "SELECT metadata FROM samples WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        sqliteBindText(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [:] }
        guard let jsonStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    /// Returns all sample names with their metadata.
    public func allSampleMetadata() -> [(name: String, metadata: [String: String])] {
        guard let db else { return [] }
        let sql = "SELECT name, metadata FROM samples ORDER BY name"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var results: [(name: String, metadata: [String: String])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            var metadata: [String: String] = [:]
            if let jsonStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                metadata = dict
            }
            results.append((name: name, metadata: metadata))
        }
        return results
    }

    /// Returns all distinct metadata field names across all samples.
    public func metadataFieldNames() -> [String] {
        let allMeta = allSampleMetadata()
        var fieldSet = Set<String>()
        for (_, metadata) in allMeta {
            fieldSet.formUnion(metadata.keys)
        }
        return fieldSet.sorted()
    }

    /// Updates metadata for a specific sample.
    public func updateSampleMetadata(name: String, metadata: [String: String]) throws {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: metadata)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

        let sql = "UPDATE samples SET metadata = ? WHERE name = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare update statement")
        }
        sqliteBindText(stmt, 1, jsonStr)
        sqliteBindText(stmt, 2, name)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw VariantDatabaseError.createFailed("Failed to update sample metadata for '\(name)'")
        }
    }

    /// Imports sample metadata from a TSV or CSV file.
    ///
    /// The file must have a header row. The first column is the sample name (must match
    /// VCF sample names in the database). Remaining columns become metadata key-value pairs.
    ///
    /// - Parameters:
    ///   - url: URL to the metadata file
    ///   - format: File format (.tsv or .csv)
    /// - Returns: Number of samples updated
    @discardableResult
    public func importSampleMetadata(from url: URL, format: MetadataFormat) throws -> Int {
        guard let db, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing")
        }

        let rows: [[String]]
        switch format {
        case .tsv:
            rows = try parseTSV(url: url)
        case .csv:
            rows = try parseCSV(url: url)
        case .excel:
            throw VariantDatabaseError.createFailed("Excel import requires CoreXLSX — use importSampleMetadataFromExcel()")
        }

        guard rows.count >= 2 else { return 0 } // Need header + at least one data row
        let rawHeaders = rows[0].map(normalizeImportedCell)
        guard rawHeaders.count >= 2 else { return 0 } // Need sample name + at least one field

        // Accept common sample-name header aliases and fall back to first column.
        let sampleHeaderAliases = Set(["sample", "sample_name", "sample id", "sample_id", "name"])
        let sampleNameColumnIndex = rawHeaders.firstIndex {
            sampleHeaderAliases.contains($0.lowercased())
        } ?? 0
        let sourceHeaderAliases = Set(["source", "source_file", "source file", "vcf_source", "vcf file", "vcf_file"])
        let sourceFileColumnIndex = rawHeaders.firstIndex {
            sourceHeaderAliases.contains($0.lowercased())
        }

        let metadataColumns: [(index: Int, key: String)] = rawHeaders.enumerated().compactMap { idx, header in
            guard idx != sampleNameColumnIndex, idx != sourceFileColumnIndex else { return nil }
            let key = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return (idx, key)
        }
        guard !metadataColumns.isEmpty else { return 0 }

        let sampleSourceSQL = "SELECT name, source_file FROM samples"
        var sampleSourceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sampleSourceSQL, -1, &sampleSourceStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample-source lookup statement")
        }
        defer { sqlite3_finalize(sampleSourceStmt) }

        var pairLookup: [String: String] = [:]
        var canonicalSourceLookup: [String: String] = [:]
        var sampleToSources: [String: Set<String>] = [:]
        while sqlite3_step(sampleSourceStmt) == SQLITE_ROW {
            let sampleName = sqlite3_column_text(sampleSourceStmt, 0).map { String(cString: $0) } ?? ""
            let sourceFile = sqlite3_column_text(sampleSourceStmt, 1).map { String(cString: $0) } ?? ""
            if sampleName.isEmpty { continue }
            let normalizedSample = normalizeSampleName(sampleName)
            let normalizedSource = normalizeImportedCell(sourceFile).lowercased()
            let pairKey = "\(normalizedSample)|\(normalizedSource)"
            pairLookup[pairKey] = sampleName
            canonicalSourceLookup[pairKey] = sourceFile
            sampleToSources[normalizedSample, default: []].insert(normalizedSource)
        }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        let updateSQLByPair = "UPDATE samples SET metadata = ? WHERE name = ? AND COALESCE(source_file, '') = ?"
        let updateSQLByName = "UPDATE samples SET metadata = ? WHERE name = ?"
        var updateStmtByPair: OpaquePointer?
        var updateStmtByName: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQLByPair, -1, &updateStmtByPair, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.createFailed("Failed to prepare update statement")
        }
        guard sqlite3_prepare_v2(db, updateSQLByName, -1, &updateStmtByName, nil) == SQLITE_OK else {
            sqlite3_finalize(updateStmtByPair)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.createFailed("Failed to prepare fallback update statement")
        }
        defer {
            sqlite3_finalize(updateStmtByPair)
            sqlite3_finalize(updateStmtByName)
        }
        var updateStmt: OpaquePointer?

        var updatedCount = 0
        var skippedAmbiguousCount = 0
        for row in rows.dropFirst() {
            guard sampleNameColumnIndex < row.count else { continue }
            let importedSampleName = normalizeImportedCell(row[sampleNameColumnIndex])
            guard !importedSampleName.isEmpty else { continue }
            let normalizedSampleName = normalizeSampleName(importedSampleName)
            guard let possibleSources = sampleToSources[normalizedSampleName] else {
                variantDBLogger.info("importSampleMetadata: Skipping unknown sample '\(importedSampleName, privacy: .public)'")
                continue
            }

            var importedSourceFile: String?
            if let sourceIndex = sourceFileColumnIndex, sourceIndex < row.count {
                let value = normalizeImportedCell(row[sourceIndex])
                if !value.isEmpty {
                    importedSourceFile = value
                }
            }
            let normalizedImportedSource = importedSourceFile.map { normalizeImportedCell($0).lowercased() }

            let resolvedSampleName: String
            let resolvedSourceForUpdate: String
            var usePairUpdate = false
            if let normalizedImportedSource {
                let pairKey = "\(normalizedSampleName)|\(normalizedImportedSource)"
                guard let resolved = pairLookup[pairKey] else {
                    variantDBLogger.info(
                        "importSampleMetadata: Skipping sample '\(importedSampleName, privacy: .public)' with unmatched source '\(importedSourceFile ?? "", privacy: .public)'"
                    )
                    continue
                }
                resolvedSampleName = resolved
                resolvedSourceForUpdate = canonicalSourceLookup[pairKey] ?? (importedSourceFile ?? "")
                usePairUpdate = true
            } else if possibleSources.count == 1 {
                let onlySource = possibleSources.first ?? ""
                let pairKey = "\(normalizedSampleName)|\(onlySource)"
                guard let resolved = pairLookup[pairKey] else { continue }
                resolvedSampleName = resolved
                resolvedSourceForUpdate = canonicalSourceLookup[pairKey] ?? onlySource
                usePairUpdate = sourceFileColumnIndex != nil
            } else {
                skippedAmbiguousCount += 1
                variantDBLogger.info(
                    "importSampleMetadata: Skipping ambiguous sample '\(importedSampleName, privacy: .public)' (provide source_file column)"
                )
                continue
            }

            // Build metadata dictionary from remaining columns
            var metadata: [String: String] = [:]
            for (index, key) in metadataColumns where index < row.count {
                let value = normalizeImportedCell(row[index])
                if !value.isEmpty {
                    metadata[key] = value
                }
            }

            // Merge with existing metadata
            var existing = sampleMetadata(name: resolvedSampleName)
            existing.merge(metadata) { _, new in new }

            let jsonData = try JSONSerialization.data(withJSONObject: existing)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            updateStmt = usePairUpdate ? updateStmtByPair : updateStmtByName
            sqlite3_reset(updateStmt)
            sqliteBindText(updateStmt, 1, jsonStr)
            sqliteBindText(updateStmt, 2, resolvedSampleName)
            if usePairUpdate {
                sqliteBindText(updateStmt, 3, resolvedSourceForUpdate)
            }

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                updatedCount += 1
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if skippedAmbiguousCount > 0 {
            variantDBLogger.info("importSampleMetadata: Skipped \(skippedAmbiguousCount) ambiguous rows missing source_file")
        }
        variantDBLogger.info("importSampleMetadata: Updated \(updatedCount) samples from \(url.lastPathComponent)")
        return updatedCount
    }

    // MARK: - TSV/CSV Parsing

    private func parseTSV(url: URL) throws -> [[String]] {
        let content = try readTextFileForMetadataImport(url: url)
        return parseDelimitedRows(content, delimiter: "\t")
    }

    private func parseCSV(url: URL) throws -> [[String]] {
        let content = try readTextFileForMetadataImport(url: url)
        return parseDelimitedRows(content, delimiter: ",")
    }

    /// Parses delimited text (TSV/CSV), honoring quoted fields for the active delimiter.
    private func parseDelimitedRows(_ content: String, delimiter: Character) -> [[String]] {
        content
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { parseDelimitedLine(String($0), delimiter: delimiter) }
    }

    /// Parses a single delimited line, handling quoted fields with embedded delimiters.
    private func parseDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var prevWasQuote = false
        for char in line {
            if inQuotes {
                if char == "\"" {
                    if prevWasQuote {
                        current.append("\"")
                        prevWasQuote = false
                    } else {
                        prevWasQuote = true
                    }
                } else if char == delimiter && prevWasQuote {
                    inQuotes = false
                    prevWasQuote = false
                    fields.append(current)
                    current = ""
                } else {
                    if prevWasQuote {
                        inQuotes = false
                        prevWasQuote = false
                    }
                    current.append(char)
                }
            } else {
                if char == "\"" && current.isEmpty {
                    inQuotes = true
                    prevWasQuote = false
                } else if char == delimiter {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            }
        }
        // Handle final field
        if prevWasQuote { inQuotes = false }
        fields.append(current)
        return fields
    }

    private func readTextFileForMetadataImport(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        throw VariantDatabaseError.createFailed("Unable to decode metadata file '\(url.lastPathComponent)' as UTF-8/UTF-16 text")
    }

    /// Normalizes imported cells by trimming whitespace/newlines and stripping UTF BOM.
    private func normalizeImportedCell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    /// Canonical sample-name key used for robust sample matching on import.
    private func normalizeSampleName(_ value: String) -> String {
        normalizeImportedCell(value).lowercased()
    }

    // MARK: - Static Creation (for bundle building)

    /// Creates a new variant database from a VCF file.
    ///
    /// Parses all variant records from the VCF, classifies them by type,
    /// and inserts them into a SQLite database with spatial indexes.
    // MARK: - Variant Bookmarks

    /// Whether the variant_bookmarks table exists.
    private var hasBookmarkTable: Bool = false

    /// Ensures the variant_bookmarks table exists, creating it if needed.
    /// Requires the database to be opened in read-write mode.
    private func ensureBookmarkTable() {
        guard let db, !hasBookmarkTable else { return }
        if VariantDatabase.tableExists(db: db, name: "variant_bookmarks") {
            hasBookmarkTable = true
            return
        }
        guard isReadOnly == false else { return }
        let sql = """
            CREATE TABLE IF NOT EXISTS variant_bookmarks (
                variant_id INTEGER PRIMARY KEY,
                flag_type TEXT DEFAULT 'star',
                note TEXT DEFAULT '',
                created_at TEXT DEFAULT (datetime('now'))
            )
            """
        sqlite3_exec(db, sql, nil, nil, nil)
        hasBookmarkTable = true
    }

    /// Toggles a bookmark on a variant. Returns the new bookmarked state.
    @discardableResult
    public func toggleBookmark(variantId: Int64, flag: String = "star") -> Bool {
        ensureBookmarkTable()
        guard let db, hasBookmarkTable else { return false }
        if isBookmarked(variantId: variantId) {
            removeBookmark(variantId: variantId)
            return false
        } else {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO variant_bookmarks (variant_id, flag_type) VALUES (?, ?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, variantId)
                sqliteBindText(stmt, 2, flag)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return true
        }
    }

    /// Returns true if the given variant is bookmarked.
    public func isBookmarked(variantId: Int64) -> Bool {
        ensureBookmarkTable()
        guard let db, hasBookmarkTable else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM variant_bookmarks WHERE variant_id = ?"
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, variantId)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        return false
    }

    /// Returns all bookmarked variant IDs.
    public func bookmarkedVariantIds() -> Set<Int64> {
        ensureBookmarkTable()
        guard let db, hasBookmarkTable else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT variant_id FROM variant_bookmarks"
        defer { sqlite3_finalize(stmt) }
        var ids = Set<Int64>()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.insert(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    /// Returns all bookmarks with their notes.
    public func allBookmarks() -> [(variantId: Int64, flag: String, note: String, createdAt: String)] {
        ensureBookmarkTable()
        guard let db, hasBookmarkTable else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT variant_id, flag_type, note, created_at FROM variant_bookmarks ORDER BY created_at DESC"
        defer { sqlite3_finalize(stmt) }
        var results: [(variantId: Int64, flag: String, note: String, createdAt: String)] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let vid = sqlite3_column_int64(stmt, 0)
                let flag = sqlite3_column_text(stmt, 1).map(String.init(cString:)) ?? "star"
                let note = sqlite3_column_text(stmt, 2).map(String.init(cString:)) ?? ""
                let created = sqlite3_column_text(stmt, 3).map(String.init(cString:)) ?? ""
                results.append((vid, flag, note, created))
            }
        }
        return results
    }

    /// Removes a bookmark.
    public func removeBookmark(variantId: Int64) {
        guard let db, hasBookmarkTable else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM variant_bookmarks WHERE variant_id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, variantId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Returns variant records for all bookmarked variants using a JOIN (efficient).
    public func bookmarkedVariants() -> [VariantDatabaseRecord] {
        ensureBookmarkTable()
        guard let db, hasBookmarkTable else { return [] }

        let sql = """
            SELECT v.id, v.chromosome, v.position, v.end_pos, v.variant_id, v.ref, v.alt, \
            v.variant_type, v.quality, v.filter, v.info, v.sample_count \
            FROM variants v \
            INNER JOIN variant_bookmarks b ON v.id = b.variant_id \
            ORDER BY v.chromosome, v.position
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        return readVariantRows(stmt: stmt!)
    }

    /// Updates the note on a bookmark.
    public func updateBookmarkNote(variantId: Int64, note: String) {
        guard let db, hasBookmarkTable else { return }
        var stmt: OpaquePointer?
        let sql = "UPDATE variant_bookmarks SET note = ? WHERE variant_id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqliteBindText(stmt, 1, note)
            sqlite3_bind_int64(stmt, 2, variantId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private static func resolveImportProfile(_ requested: VCFImportProfile, inputFileSize: Int64) -> VCFImportProfile {
        guard requested == .auto else { return requested }
        let physicalRAMGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)
        let inputGiB = Double(max(0, inputFileSize)) / Double(1 << 30)
        // Very large files or large-ish files on limited RAM: ultra-low-memory with
        // upfront indexes to avoid multi-GB sorts during post-insert index creation.
        if inputGiB >= 5.0 || (inputGiB >= 2.0 && physicalRAMGiB <= 16) {
            return .ultraLowMemory
        }
        if physicalRAMGiB <= 12 || inputGiB >= 1.5 {
            return .lowMemory
        }
        return .fast
    }

    /// All index statements used by `createFromVCF`, ordered from cheapest to most
    /// expensive.  The ordering ensures that if index creation is interrupted, the
    /// most important indexes (variants region) will already exist.
    private static let allIndexStatements: [(name: String, sql: String)] = [
        ("idx_variants_region", "CREATE INDEX IF NOT EXISTS idx_variants_region ON variants(chromosome, position, end_pos)"),
        ("idx_variants_type", "CREATE INDEX IF NOT EXISTS idx_variants_type ON variants(variant_type)"),
        ("idx_variants_id", "CREATE INDEX IF NOT EXISTS idx_variants_id ON variants(variant_id COLLATE NOCASE)"),
        ("idx_samples_name", "CREATE INDEX IF NOT EXISTS idx_samples_name ON samples(name)"),
        ("idx_genotypes_variant", "CREATE INDEX IF NOT EXISTS idx_genotypes_variant ON genotypes(variant_id)"),
        ("idx_genotypes_sample", "CREATE INDEX IF NOT EXISTS idx_genotypes_sample ON genotypes(sample_name)"),
        ("idx_variant_info_key", "CREATE INDEX IF NOT EXISTS idx_variant_info_key ON variant_info(key)"),
        ("idx_variant_info_key_value", "CREATE INDEX IF NOT EXISTS idx_variant_info_key_value ON variant_info(key, value)"),
    ]

    private static func importTuning(for profile: VCFImportProfile) -> ImportTuning {
        switch profile {
        case .lowMemory:
            return ImportTuning(
                workerThreads: 1,
                cacheKB: 4 * 1024,
                pageSizeKB: 4,
                writeBudget: 8_000,
                minWriteBudget: 2_000,
                shrinkEveryCommits: 1,
                shrinkEveryCommit: true,
                memoryProbeVariantInterval: 5_000,
                memoryPressureThresholdFraction: 0.62,
                memoryPressureRelaxFraction: 0.42,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: false,
                connectionResetInterval: 0
            )
        case .fast:
            return ImportTuning(
                workerThreads: max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)),
                cacheKB: 32 * 1024,
                pageSizeKB: 4,
                writeBudget: 80_000,
                minWriteBudget: 8_000,
                shrinkEveryCommits: 6,
                shrinkEveryCommit: false,
                memoryProbeVariantInterval: 10_000,
                memoryPressureThresholdFraction: 0.70,
                memoryPressureRelaxFraction: 0.50,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: false,
                connectionResetInterval: 0
            )
        case .ultraLowMemory:
            // Designed for multi-GB VCFs that produce 50GB+ databases.
            // Key differences from other profiles:
            //  - NO indexes during insert (deferred to a separate phase/process)
            //  - NO variant_info EAV table (raw INFO stored in variants.info)
            //  - synchronous = NORMAL to prevent dirty page accumulation in macOS UBC
            //  - Periodic connection reset to fight malloc fragmentation
            //  - 32KB page size to reduce B-tree depth
            //  - Large write budget (no index overhead = fast commits)
            return ImportTuning(
                workerThreads: 1,
                cacheKB: 4 * 1024,
                pageSizeKB: 32,
                writeBudget: 12_000,
                minWriteBudget: 1_500,
                shrinkEveryCommits: 1,
                shrinkEveryCommit: true,
                memoryProbeVariantInterval: 2_000,
                memoryPressureThresholdFraction: 0.55,
                memoryPressureRelaxFraction: 0.38,
                createIndexesUpFront: false,
                maxVariantInfoKeysPerVariant: 0,
                skipVariantInfo: true,
                connectionResetInterval: 2_000_000
            )
        case .auto:
            // Auto is resolved before this method is called.
            return importTuning(for: .lowMemory)
        }
    }

    /// Optionally parses per-sample genotypes.
    ///
    /// - Parameters:
    ///   - vcfURL: URL to the VCF file (plain text or .vcf.gz)
    ///   - outputURL: URL for the SQLite database to create
    ///   - parseGenotypes: If true, parse and store per-sample genotype data
    ///   - sourceFile: Optional source filename to store in the samples table
    ///   - progressHandler: Optional progress callback (fraction, message)
    /// - Returns: Number of variant records inserted
    @discardableResult
    public static func createFromVCF(
        vcfURL: URL,
        outputURL: URL,
        parseGenotypes: Bool = true,
        sourceFile: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        importProfile: VCFImportProfile = .auto,
        deferIndexBuild: Bool = false,
        partitionByChromosome: Bool = false,
        onlyChromosome: String? = nil
    ) throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: vcfURL.path)[.size] as? Int64) ?? 0
        let ext = vcfURL.pathExtension.lowercased()
        let estimatedUncompressedSize = ext == "gz"
            ? estimateGzipUncompressedSize(url: vcfURL, compressedSize: fileSize)
            : 0
        // For compressed VCFs, profile auto-selection should use an estimate of the
        // real parse workload instead of the smaller compressed byte size.
        let profileInputSize = (ext == "gz" && estimatedUncompressedSize > 0)
            ? estimatedUncompressedSize
            : fileSize
        let resolvedProfile = resolveImportProfile(importProfile, inputFileSize: profileInputSize)
        let tuning = importTuning(for: resolvedProfile)

        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Performance pragmas — FK enforcement OFF during bulk import (we control insert order;
        // variants are always inserted before genotypes). Enabling FKs here would force SQLite to
        // validate every genotype INSERT against the variants table, adding significant overhead.

        // page_size MUST be set before any tables are created. A larger page size (32KB) reduces
        // B-tree depth by 1-2 levels, which means fewer pages pinned simultaneously during inserts.
        if tuning.pageSizeKB != 4 {
            sqlite3_exec(db, "PRAGMA page_size = \(tuning.pageSizeKB * 1024)", nil, nil, nil)
        }

        // DELETE journal mode provides crash recovery (unlike OFF) without accumulating dirty
        // pages in the macOS Unified Buffer Cache (UBC) the way WAL mode does.  WAL defers
        // writing back to the main DB file, causing the UBC to count those dirty pages against
        // the process RSS — leading to OOM kills on multi-GB imports.  DELETE mode writes
        // directly to the main DB file on each COMMIT.
        sqlite3_exec(db, "PRAGMA journal_mode = DELETE", nil, nil, nil)
        // synchronous = NORMAL forces fsync at each COMMIT, which prevents dirty page accumulation
        // in the macOS Unified Buffer Cache (UBC). With synchronous = OFF on multi-hour imports,
        // the UBC can accumulate tens of GB of dirty pages that the jetsam OOM killer counts
        // against the process, leading to SIGKILL.  NORMAL adds ~5% overhead but bounds memory.
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = \(tuning.workerThreads)", nil, nil, nil)

        sqlite3_exec(db, "PRAGMA cache_size = -\(tuning.cacheKB)", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_spill = ON", nil, nil, nil)
        // Disable memory-mapped I/O — as the DB file grows during import, an mmap region would
        // inflate RSS proportionally. Standard read/write I/O with the small cache above is fine.
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        // temp_store = FILE (default) — index-building sorts spill to disk instead of consuming
        // unbounded RAM. On SSD the speed penalty is negligible; on low-memory machines this
        // prevents the 8 post-import CREATE INDEX statements from exhausting physical memory.
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)

        // Create v3 schema
        let schema = """
        CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chromosome TEXT NOT NULL,
            position INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            variant_id TEXT NOT NULL,
            ref TEXT NOT NULL,
            alt TEXT NOT NULL,
            variant_type TEXT NOT NULL,
            quality REAL,
            filter TEXT,
            info TEXT,
            sample_count INTEGER DEFAULT 0
        );
        CREATE TABLE genotypes (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            sample_name TEXT NOT NULL,
            genotype TEXT,
            allele1 INTEGER,
            allele2 INTEGER,
            is_phased INTEGER DEFAULT 0,
            depth INTEGER,
            genotype_quality INTEGER,
            allele_depths TEXT,
            raw_fields TEXT,
            PRIMARY KEY (variant_id, sample_name)
        );
        CREATE TABLE samples (
            name TEXT PRIMARY KEY,
            display_name TEXT,
            source_file TEXT,
            metadata TEXT
        );
        CREATE TABLE variant_info_defs (
            key TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            number TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE variant_info (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (variant_id, key)
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw VariantDatabaseError.createFailed(msg)
        }

        // Insert metadata flags for v3 import optimizations.
        Self.insertMetadataRow(db, key: "schema_version", value: "3")
        Self.insertMetadataRow(db, key: "omit_homref", value: "true")
        Self.insertMetadataRow(db, key: "import_state", value: "inserting")
        Self.insertMetadataRow(db, key: "import_source", value: vcfURL.lastPathComponent)
        Self.insertMetadataRow(db, key: "import_profile", value: resolvedProfile.rawValue)
        if tuning.skipVariantInfo {
            Self.insertMetadataRow(db, key: "skip_variant_info", value: "true")
        }

        // For ultra-low-memory profile: cap SQLite heap and create indexes upfront so
        // they are maintained incrementally during inserts, avoiding multi-GB sorts.
        if resolvedProfile == .ultraLowMemory {
            sqlite3_soft_heap_limit64(256 * 1024 * 1024)
        }

        if tuning.createIndexesUpFront {
            for (name, sql) in Self.allIndexStatements {
                var idxErr: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, sql, nil, nil, &idxErr)
                if let idxErr {
                    let msg = String(cString: idxErr)
                    sqlite3_free(idxErr)
                    variantDBLogger.warning("createFromVCF: Upfront index '\(name)' failed: \(msg)")
                }
            }
            variantDBLogger.info("createFromVCF: Created \(Self.allIndexStatements.count) indexes upfront for incremental maintenance")
        }

        var txnErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &txnErr)
        if let txnErr {
            let msg = String(cString: txnErr)
            sqlite3_free(txnErr)
            variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION failed: \(msg)")
        }

        let insertVariantSQL = """
        INSERT INTO variants (chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertVariantStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertVariantSQL, -1, &insertVariantStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare variant INSERT statement")
        }
        defer { sqlite3_finalize(insertVariantStmt) }

        let insertGenotypeSQL = """
        INSERT INTO genotypes (variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertGenotypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertGenotypeSQL, -1, &insertGenotypeStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare genotype INSERT statement")
        }
        defer { sqlite3_finalize(insertGenotypeStmt) }

        let insertSampleSQL = "INSERT OR IGNORE INTO samples (name, display_name, source_file, metadata) VALUES (?, ?, ?, '{}')"
        var insertSampleStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSampleSQL, -1, &insertSampleStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample INSERT statement")
        }
        defer { sqlite3_finalize(insertSampleStmt) }

        // variant_info statements are only needed when NOT skipping variant_info.
        // For ultraLowMemory, we skip the EAV table entirely and store raw INFO in variants.info.
        var insertInfoDefStmt: OpaquePointer?
        var insertInfoStmt: OpaquePointer?
        if !tuning.skipVariantInfo {
            let insertInfoDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, insertInfoDefSQL, -1, &insertInfoDefStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info def INSERT statement")
            }

            let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK else {
                throw VariantDatabaseError.createFailed("Failed to prepare info INSERT statement")
            }
        }
        defer {
            sqlite3_finalize(insertInfoDefStmt)
            sqlite3_finalize(insertInfoStmt)
        }

        let updateSampleCountSQL = "UPDATE variants SET sample_count = ? WHERE id = ?"
        var updateSampleCountStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSampleCountSQL, -1, &updateSampleCountStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample_count UPDATE statement")
        }
        defer { sqlite3_finalize(updateSampleCountStmt) }

        var insertCount = 0
        var sampleNames: [String] = []
        var adaptiveWriteBudget = tuning.writeBudget
        let adaptiveWriteBudgetStep = max(500, tuning.writeBudget / 10)
        let shrinkEveryCommits = max(1, tuning.shrinkEveryCommits)
        var wasCancelled = false
        var writesSinceCommit = 0
        var transactionCommitCount = 0

        // Track all structured INFO fields with pipe-delimited sub-fields (key → sub-field names)
        var structuredInfoFields: [String: [String]] = [:]

        // Collect contig lengths from ##contig header lines for chromosome alias mapping
        var contigLengths: [String: Int64] = [:]

        let profileLabel: String = switch resolvedProfile {
        case .lowMemory: "Low Memory"
        case .fast: "Fast"
        case .auto: "Auto"
        case .ultraLowMemory: "Ultra Low Memory"
        }
        progressHandler?(0.05, "Parsing VCF (\(profileLabel) profile)...")

        @inline(__always)
        func isCancelled() -> Bool {
            shouldCancel?() == true
        }

        @inline(__always)
        func releaseSQLiteMemory(forceShrink: Bool = false) {
            _ = sqlite3_db_release_memory(db)
            if forceShrink {
                sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
            }
        }

        /// Adaptive memory-pressure controller:
        /// - Force COMMIT+shrink when RSS crosses a high watermark.
        /// - Reduce write budget under pressure (more frequent commits).
        /// - Gradually relax budget once RSS drops.
        func memoryPressureFlush() {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return }
            let residentBytes = UInt64(info.resident_size)
            let physicalRAM = ProcessInfo.processInfo.physicalMemory
            let highThreshold = UInt64(Double(physicalRAM) * tuning.memoryPressureThresholdFraction)
            let relaxThreshold = UInt64(Double(physicalRAM) * tuning.memoryPressureRelaxFraction)

            if residentBytes > highThreshold {
                adaptiveWriteBudget = max(tuning.minWriteBudget, adaptiveWriteBudget / 2)
                commitImportTransaction(reopen: true, forceShrink: true)
                variantDBLogger.warning(
                    "createFromVCF: Memory pressure (resident \(residentBytes / (1024 * 1024)) MB / \(physicalRAM / (1024 * 1024)) MB), budget=\(adaptiveWriteBudget), forced commit+shrink"
                )
                return
            }

            if residentBytes < relaxThreshold, adaptiveWriteBudget < tuning.writeBudget {
                adaptiveWriteBudget = min(tuning.writeBudget, adaptiveWriteBudget + adaptiveWriteBudgetStep)
            }
        }

        func commitImportTransaction(reopen: Bool, forceShrink: Bool = false) {
            var commitErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "COMMIT", nil, nil, &commitErr)
            if let commitErr {
                let msg = String(cString: commitErr)
                sqlite3_free(commitErr)
                variantDBLogger.warning("createFromVCF: COMMIT failed: \(msg), issuing ROLLBACK")
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }

            transactionCommitCount += 1
            writesSinceCommit = 0
            let shouldShrinkNow =
                forceShrink ||
                tuning.shrinkEveryCommit ||
                (transactionCommitCount % shrinkEveryCommits == 0)
            releaseSQLiteMemory(forceShrink: shouldShrinkNow)

            if reopen {
                var beginErr: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &beginErr)
                if let beginErr {
                    let msg = String(cString: beginErr)
                    sqlite3_free(beginErr)
                    variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION failed: \(msg)")
                }
            }
        }

        @inline(__always)
        func rotateImportTransactionIfNeeded() {
            guard writesSinceCommit >= adaptiveWriteBudget else { return }
            commitImportTransaction(reopen: true)
        }

        let maxPartitionChromosomes = 512

        @inline(__always)
        func streamVCFLines(
            onProgress: ((Double) -> Void)? = nil,
            _ handler: (Substring) -> Void
        ) throws -> Bool {
            if ext == "gz" {
                return try streamGzipLines(
                    url: vcfURL,
                    estimatedUncompressedSize: estimatedUncompressedSize,
                    shouldCancel: shouldCancel,
                    onProgress: onProgress,
                    handler
                )
            }
            return try streamPlainLines(
                url: vcfURL,
                totalFileSize: fileSize,
                shouldCancel: shouldCancel,
                onProgress: onProgress,
                handler
            )
        }

        func parseLine(
            _ line: Substring,
            parseHeaders: Bool,
            activeChromosome: String?
        ) {
            guard !line.isEmpty, !wasCancelled else { return }

            if line.first == "#" {
                guard parseHeaders else { return }

                // Parse ##INFO=<...> header lines for structured INFO definitions
                if line.hasPrefix("##INFO=") {
                    // When skipping variant_info, we don't need to parse or store INFO defs
                    if !tuning.skipVariantInfo, let insertInfoDefStmt {
                        let content = line.dropFirst(7)
                        if let def = parseINFODefinition(content) {
                            sqlite3_reset(insertInfoDefStmt)
                            sqliteBindText(insertInfoDefStmt, 1, def.id)
                            sqliteBindText(insertInfoDefStmt, 2, def.type)
                            sqliteBindText(insertInfoDefStmt, 3, def.number)
                            sqliteBindText(insertInfoDefStmt, 4, def.description)
                            sqlite3_step(insertInfoDefStmt)
                            writesSinceCommit += 1

                            // Detect structured fields with pipe-delimited sub-fields from Description
                            // e.g., CSQ: "...Format: Allele|Consequence|IMPACT|SYMBOL|Gene|..."
                            if let formatRange = def.description.range(of: "Format: ", options: .caseInsensitive) {
                                let formatStr = String(def.description[formatRange.upperBound...])
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                                let subFields = formatStr.split(separator: "|").map(String.init)
                                if subFields.count >= 2 {
                                    structuredInfoFields[def.id] = subFields
                                    // Register each sub-field as a separate info def
                                    for subField in subFields {
                                        let subKey = "\(def.id)_\(subField)"
                                        sqlite3_reset(insertInfoDefStmt)
                                        sqliteBindText(insertInfoDefStmt, 1, subKey)
                                        sqliteBindText(insertInfoDefStmt, 2, "String")
                                        sqliteBindText(insertInfoDefStmt, 3, ".")
                                        sqliteBindText(insertInfoDefStmt, 4, "\(def.id) sub-field: \(subField)")
                                        sqlite3_step(insertInfoDefStmt)
                                        writesSinceCommit += 1
                                    }
                                    variantDBLogger.info("createFromVCF: Found structured INFO field '\(def.id)' with \(subFields.count) sub-fields")
                                }
                            }
                        }
                        rotateImportTransactionIfNeeded()
                    }
                    return
                }

                // Parse ##contig=<ID=...,length=...> lines for chromosome length info
                if line.hasPrefix("##contig=") {
                    let content = line.dropFirst(9)
                    // Parse <ID=chr1,length=248956422> format
                    let inner = content.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    var id: String?
                    var length: Int64?
                    for part in inner.split(separator: ",") {
                        let kv = part.split(separator: "=", maxSplits: 1)
                        guard kv.count == 2 else { continue }
                        let key = kv[0].trimmingCharacters(in: .whitespaces)
                        let val = kv[1].trimmingCharacters(in: .whitespaces)
                        if key.lowercased() == "id" { id = val }
                        else if key.lowercased() == "length" { length = Int64(val) }
                    }
                    if let id, let length {
                        contigLengths[id] = length
                    }
                    return
                }

                // Skip other meta-information lines
                if line.hasPrefix("##") { return }

                // Parse header line for sample names
                if line.hasPrefix("#CHROM") {
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    if fields.count > 9 {
                        sampleNames = fields.dropFirst(9).map(String.init)
                        // Insert sample records
                        let srcFile = sourceFile ?? vcfURL.lastPathComponent
                        for sampleName in sampleNames {
                            sqlite3_reset(insertSampleStmt)
                            sqliteBindText(insertSampleStmt, 1, sampleName)
                            sqliteBindText(insertSampleStmt, 2, sampleName)
                            sqliteBindText(insertSampleStmt, 3, srcFile)
                            sqlite3_step(insertSampleStmt)
                            writesSinceCommit += 1
                        }
                        variantDBLogger.info("createFromVCF: Found \(sampleNames.count) samples")
                    }

                    // Store contig lengths from ##contig header lines for chromosome alias mapping.
                    // These provide exact chromosome lengths for reliable matching when VCF chromosome
                    // names differ from the reference (e.g., "1" vs "NC_048383.1").
                    if !contigLengths.isEmpty {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: contigLengths.mapValues { NSNumber(value: $0) }),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            Self.insertMetadataRow(db, key: "contig_lengths", value: jsonString, replace: true)
                            writesSinceCommit += 1
                            variantDBLogger.info("createFromVCF: Stored \(contigLengths.count) contig lengths from VCF header")
                        }
                    }

                    rotateImportTransactionIfNeeded()
                    return
                }

                return
            }

            // Parse variant line
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { return }

            let chromosome = String(fields[0])
            if let activeChromosome, chromosome != activeChromosome {
                return
            }
            guard let pos1based = Int(fields[1]), pos1based >= 1 else { return }
            let position = pos1based - 1  // Convert to 0-based

            let rawID = fields[2]
            let variantID = rawID == "." ? "\(chromosome)_\(pos1based)" : String(rawID)

            let refField = fields[3]
            let altField = fields[4]
            let ref = String(refField)
            let alt = String(altField)
            let qualStr = fields[5]
            let quality: Double? = qualStr == "." ? nil : Double(qualStr)
            let filter = fields[6] == "." ? nil : String(fields[6])

            let variantType = classifyVariant(ref: refField, altField: altField)

            let infoField = fields[7]
            let endPos: Int
            if let endValue = parseINFOEnd(infoField) {
                endPos = endValue
            } else {
                endPos = position + ref.count
            }
            let infoStr: Substring? = fields[7] == "." ? nil : fields[7]

            // Insert variant (sample_count initially 0; updated after genotype pass).
            sqlite3_reset(insertVariantStmt)
            sqliteBindText(insertVariantStmt, 1, chromosome)
            sqlite3_bind_int64(insertVariantStmt, 2, Int64(position))
            sqlite3_bind_int64(insertVariantStmt, 3, Int64(endPos))
            sqliteBindText(insertVariantStmt, 4, variantID)
            sqliteBindText(insertVariantStmt, 5, ref)
            sqliteBindText(insertVariantStmt, 6, alt)
            sqliteBindText(insertVariantStmt, 7, variantType)
            if let q = quality {
                sqlite3_bind_double(insertVariantStmt, 8, q)
            } else {
                sqlite3_bind_null(insertVariantStmt, 8)
            }
            sqliteBindTextOrNull(insertVariantStmt, 9, filter)
            // When skipVariantInfo is true, store raw INFO string in variants.info since
            // the EAV table is not populated.  Otherwise leave NULL (redundant with EAV).
            if tuning.skipVariantInfo, let infoStr {
                sqliteBindText(insertVariantStmt, 10, String(infoStr))
            } else {
                sqlite3_bind_null(insertVariantStmt, 10)
            }
            sqlite3_bind_int(insertVariantStmt, 11, 0)

            guard sqlite3_step(insertVariantStmt) == SQLITE_DONE else {
                variantDBLogger.warning("Failed to insert variant: \(variantID)")
                return
            }
            let variantRowId = sqlite3_last_insert_rowid(db)
            insertCount += 1
            writesSinceCommit += 1

            // Periodic adaptive memory pressure check.
            if insertCount % tuning.memoryProbeVariantInterval == 0 {
                memoryPressureFlush()
            }

            // Periodic deep memory reset to fight malloc fragmentation over long imports.
            // Commits the current transaction, releases all SQLite memory, and asks the OS
            // allocator to return freed pages to the kernel.
            if tuning.connectionResetInterval > 0,
               insertCount % tuning.connectionResetInterval == 0 {
                commitImportTransaction(reopen: false, forceShrink: true)
                // On Darwin, ask all malloc zones to return freed pages to the kernel.
                // This fights heap fragmentation from billions of small alloc/free cycles.
                malloc_zone_pressure_relief(nil, 0)
                variantDBLogger.info("createFromVCF: Deep memory reset at \(insertCount) variants")
                // Reopen transaction.
                var beginErr: UnsafeMutablePointer<CChar>?
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, &beginErr)
                if let beginErr {
                    let msg = String(cString: beginErr)
                    sqlite3_free(beginErr)
                    variantDBLogger.warning("createFromVCF: BEGIN TRANSACTION after reset failed: \(msg)")
                }
            }

            // Insert structured INFO key-value pairs into variant_info EAV table.
            // Skipped entirely for ultraLowMemory — raw INFO is stored in variants.info instead.
            if !tuning.skipVariantInfo, let insertInfoStmt {
                let infoKeyLimit = tuning.maxVariantInfoKeysPerVariant
                if let infoStr, infoStr != "." {
                    var infoKeysInserted = 0
                    for field in infoStr.split(separator: ";") {
                        if infoKeyLimit > 0 && infoKeysInserted >= infoKeyLimit { break }

                        let parts = field.split(separator: "=", maxSplits: 1)
                        let key: String
                        let value: Substring
                        if parts.count == 2 {
                            key = String(parts[0])
                            value = parts[1]
                        } else if parts.count == 1 {
                            key = String(parts[0])
                            value = "true"
                        } else {
                            continue
                        }

                        // Check if this is a structured field with pipe-delimited sub-fields (e.g., CSQ)
                        if let subFieldNames = structuredInfoFields[key] {
                            // Split by comma for multiple entries (e.g., multiple transcripts)
                            let entries = value.split(separator: ",")
                            // Use only the first entry for the primary sub-field values
                            // (store the full raw value too for completeness)
                            if let firstEntry = entries.first {
                                let subValues = firstEntry.split(separator: "|", omittingEmptySubsequences: false)
                                for (idx, subFieldName) in subFieldNames.enumerated() {
                                    let subValue = idx < subValues.count ? subValues[idx] : ""
                                    guard !subValue.isEmpty else { continue }
                                    let subKey = "\(key)_\(subFieldName)"
                                    sqlite3_reset(insertInfoStmt)
                                    sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                                    sqliteBindText(insertInfoStmt, 2, subKey)
                                    sqliteBindText(insertInfoStmt, 3, String(subValue))
                                    sqlite3_step(insertInfoStmt)
                                    writesSinceCommit += 1
                                }
                            }
                            // Also store entry count if multiple transcripts
                            if entries.count > 1 {
                                sqlite3_reset(insertInfoStmt)
                                sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                                sqliteBindText(insertInfoStmt, 2, "\(key)_entries")
                                sqliteBindText(insertInfoStmt, 3, String(entries.count))
                                sqlite3_step(insertInfoStmt)
                                writesSinceCommit += 1
                            }
                        } else {
                            // Standard scalar INFO field
                            sqlite3_reset(insertInfoStmt)
                            sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                            sqliteBindText(insertInfoStmt, 2, key)
                            sqliteBindText(insertInfoStmt, 3, String(value))
                            sqlite3_step(insertInfoStmt)
                            writesSinceCommit += 1
                        }
                        infoKeysInserted += 1
                    }
                }
            }

            // Single-pass: parse genotypes, INSERT non-hom-ref, and count called samples.
            if parseGenotypes && fields.count > 9 && !sampleNames.isEmpty {
                let formatStr = fields[8]
                let formatFields = formatStr.split(separator: ":", omittingEmptySubsequences: false)
                let gtIndex = formatFields.firstIndex(where: { $0 == "GT" })
                let dpIndex = formatFields.firstIndex(where: { $0 == "DP" })
                let gqIndex = formatFields.firstIndex(where: { $0 == "GQ" })
                let adIndex = formatFields.firstIndex(where: { $0 == "AD" })
                var calledCount = 0

                for sampleIdx in 0..<sampleNames.count {
                    let fieldIdx = 9 + sampleIdx
                    guard fieldIdx < fields.count else { break }
                    let sampleData = fields[fieldIdx]
                    if sampleData == "." || sampleData == "./." || sampleData == ".|." { continue }

                    let sampleFields = sampleData.split(separator: ":", omittingEmptySubsequences: false)
                    if gtIndex == nil {
                        // FORMAT can omit GT for some callsets; treat non-empty sample payload as called
                        // for sample_count even though we cannot infer zygosity or hom-ref omission.
                        if sampleFields.contains(where: { !$0.isEmpty && $0 != "." }) {
                            calledCount += 1
                        }
                        continue
                    }

                    // Parse GT
                    var allele1 = -1
                    var allele2 = -1
                    var isPhased = false
                    var rawGT: String?
                    if let gtIdx = gtIndex, gtIdx < sampleFields.count {
                        let gt = sampleFields[gtIdx]
                        rawGT = String(gt)
                        let separator: Character = gt.contains("|") ? "|" : "/"
                        isPhased = separator == "|"
                        let alleles = gt.split(separator: separator)
                        if alleles.count >= 1 {
                            allele1 = alleles[0] == "." ? -1 : (Int(alleles[0]) ?? -1)
                        }
                        if alleles.count >= 2 {
                            allele2 = alleles[1] == "." ? -1 : (Int(alleles[1]) ?? -1)
                        } else if alleles.count == 1 {
                            // Haploid calls are rendered as homozygous for display purposes.
                            allele2 = allele1
                        }
                    }

                    // Count called sample (at least one non-missing allele)
                    if allele1 >= 0 || allele2 >= 0 {
                        calledCount += 1
                    } else {
                        continue  // No-call — skip genotype INSERT too
                    }

                    // Skip hom-ref genotypes (0/0) — inferred from absence.
                    // This typically eliminates ~90% of genotype rows.
                    if allele1 == 0 && allele2 == 0 { continue }

                    // Parse DP
                    var depth: Int?
                    if let dpIdx = dpIndex, dpIdx < sampleFields.count {
                        let dpStr = sampleFields[dpIdx]
                        if dpStr != "." { depth = Int(dpStr) }
                    }

                    // Parse GQ
                    var gq: Int?
                    if let gqIdx = gqIndex, gqIdx < sampleFields.count {
                        let gqStr = sampleFields[gqIdx]
                        if gqStr != "." { gq = Int(gqStr) }
                    }

                    // Parse AD
                    var ad: String?
                    if let adIdx = adIndex, adIdx < sampleFields.count {
                        let adStr = sampleFields[adIdx]
                        if adStr != "." { ad = String(adStr) }
                    }

                    sqlite3_reset(insertGenotypeStmt)
                    sqlite3_bind_int64(insertGenotypeStmt, 1, variantRowId)
                    sqliteBindText(insertGenotypeStmt, 2, sampleNames[sampleIdx])
                    sqliteBindTextOrNull(insertGenotypeStmt, 3, rawGT)
                    sqlite3_bind_int(insertGenotypeStmt, 4, Int32(allele1))
                    sqlite3_bind_int(insertGenotypeStmt, 5, Int32(allele2))
                    sqlite3_bind_int(insertGenotypeStmt, 6, isPhased ? 1 : 0)
                    if let dp = depth {
                        sqlite3_bind_int(insertGenotypeStmt, 7, Int32(dp))
                    } else {
                        sqlite3_bind_null(insertGenotypeStmt, 7)
                    }
                    if let g = gq {
                        sqlite3_bind_int(insertGenotypeStmt, 8, Int32(g))
                    } else {
                        sqlite3_bind_null(insertGenotypeStmt, 8)
                    }
                    sqliteBindTextOrNull(insertGenotypeStmt, 9, ad)
                    // v3: Don't store raw_fields (redundant with individual GT/DP/GQ/AD columns).
                    sqlite3_bind_null(insertGenotypeStmt, 10)

                    sqlite3_step(insertGenotypeStmt)
                    writesSinceCommit += 1
                }

                // Update the variant's sample_count now that we know the called count.
                if calledCount > 0 {
                    sqlite3_reset(updateSampleCountStmt)
                    sqlite3_bind_int(updateSampleCountStmt, 1, Int32(calledCount))
                    sqlite3_bind_int64(updateSampleCountStmt, 2, variantRowId)
                    sqlite3_step(updateSampleCountStmt)
                    writesSinceCommit += 1
                }
            }

            rotateImportTransactionIfNeeded()
        }

        var partitionChromosomeOrder: [String] = []
        var importedByChromosome = false

        if partitionByChromosome, onlyChromosome == nil {
            progressHandler?(0.06, "Reading chromosome list from VCF header...")
            partitionChromosomeOrder = try readContigsFromVCFHeader(
                url: vcfURL,
                maxChromosomes: maxPartitionChromosomes
            )
            if partitionChromosomeOrder.isEmpty {
                variantDBLogger.info(
                    "createFromVCF: No usable ##contig chromosome list found; falling back to single-pass import"
                )
            }
        }

        if partitionByChromosome, onlyChromosome == nil, !partitionChromosomeOrder.isEmpty {
            importedByChromosome = true
            var parseHeadersOnThisPass = true
            let totalChromosomes = partitionChromosomeOrder.count

            for (chromIndex, chromosome) in partitionChromosomeOrder.enumerated() {
                if isCancelled() {
                    wasCancelled = true
                    break
                }

                let beforeRatio = Double(chromIndex) / Double(max(1, totalChromosomes))
                let chromWeight = 1.0 / Double(max(1, totalChromosomes))
                let byteProgress: (Double) -> Void = { fraction in
                    let clamped = max(0.0, min(1.0, fraction))
                    let global = 0.15 + (beforeRatio + (chromWeight * clamped)) * 0.75
                    progressHandler?(
                        global,
                        "Importing chromosome \(chromIndex + 1) of \(totalChromosomes): \(chromosome) (\(insertCount) variants)..."
                    )
                }

                wasCancelled = try streamVCFLines(onProgress: byteProgress) { line in
                    parseLine(
                        line,
                        parseHeaders: parseHeadersOnThisPass,
                        activeChromosome: chromosome
                    )
                }
                parseHeadersOnThisPass = false
                wasCancelled = wasCancelled || isCancelled()
                if wasCancelled { break }

                let completedFraction = 0.15 + (Double(chromIndex + 1) / Double(max(1, totalChromosomes))) * 0.75
                progressHandler?(completedFraction, "Imported chromosome \(chromIndex + 1) of \(totalChromosomes): \(chromosome)")

                if chromIndex + 1 < totalChromosomes {
                    commitImportTransaction(reopen: true, forceShrink: true)
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        } else {
            // Read VCF content with byte-based progress tracking.
            // Both plain and .vcf.gz VCFs use line-by-line streaming to avoid large memory spikes.
            let byteProgress: (Double) -> Void = { fraction in
                progressHandler?(0.05 + fraction * 0.85, "Parsing variants (\(insertCount))...")
            }
            wasCancelled = try streamVCFLines(onProgress: byteProgress) { line in
                parseLine(line, parseHeaders: true, activeChromosome: onlyChromosome)
            }
        }

        wasCancelled = wasCancelled || isCancelled()

        if wasCancelled {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.cancelled
        }

        let partitionMode: String
        if importedByChromosome {
            partitionMode = "per-chromosome"
        } else if onlyChromosome != nil {
            partitionMode = "single-chromosome"
        } else {
            partitionMode = "single-pass"
        }
        Self.insertMetadataRow(db, key: "import_partition_mode", value: partitionMode, replace: true)

        // Finalize all parsed rows before index creation, then explicitly release heap/cache.
        commitImportTransaction(reopen: false, forceShrink: true)

        // Record variant count and transition to indexing state.
        Self.insertMetadataRow(db, key: "import_variant_count", value: "\(insertCount)", replace: true)
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'indexing' WHERE key = 'import_state'", nil, nil, nil)

        if deferIndexBuild && resolvedProfile == .ultraLowMemory {
            Self.insertMetadataRow(db, key: "index_build_deferred", value: "true", replace: true)
            progressHandler?(0.92, "Insert phase complete, deferring index build...")
            variantDBLogger.info("createFromVCF: Deferred index build for ultra-low-memory staged import")
            return insertCount
        }

        if !tuning.createIndexesUpFront {
            // Filter out variant_info indexes when the EAV table was skipped.
            let indexesToBuild = tuning.skipVariantInfo
                ? Self.allIndexStatements.filter { !$0.name.contains("variant_info") }
                : Self.allIndexStatements

            if !indexesToBuild.isEmpty {
                progressHandler?(0.92, "Creating indexes...")

                // Reduce cache before bulk index creation to leave more RAM for SQLite's
                // sort algorithm (sorts spill to temp files via temp_store = FILE).
                sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
                releaseSQLiteMemory(forceShrink: true)

                // Build indexes outside the long-running import transaction and shrink between each.
                // Uses IF NOT EXISTS + ordered cheapest-first so a resume after crash
                // skips already-created indexes and the most important ones exist first.
                for (i, (name, sql)) in indexesToBuild.enumerated() {
                    if isCancelled() {
                        wasCancelled = true
                        break
                    }
                    let indexProgress = 0.92 + (Double(i) / Double(indexesToBuild.count)) * 0.07
                    progressHandler?(indexProgress, "Creating index \(i + 1) of \(indexesToBuild.count)...")
                    var idxErr: UnsafeMutablePointer<CChar>?
                    sqlite3_exec(db, sql, nil, nil, &idxErr)
                    if let idxErr {
                        let msg = String(cString: idxErr)
                        sqlite3_free(idxErr)
                        variantDBLogger.warning("createFromVCF: Index '\(name)' creation failed: \(msg)")
                    }
                    Self.insertMetadataRow(db, key: "idx_\(name)", value: "created", replace: true)
                    releaseSQLiteMemory(forceShrink: true)
                }

                if wasCancelled {
                    throw VariantDatabaseError.cancelled
                }
            }
        }
        releaseSQLiteMemory(forceShrink: true)

        // Build persistent SmartToken filter tables for instant chip loading on open.
        if !wasCancelled {
            progressHandler?(0.99, "Building filter indexes...")
            Self.createSmartTokenTables(
                db: db,
                skipVariantInfo: tuning.skipVariantInfo
            )
            releaseSQLiteMemory(forceShrink: true)
        }

        // Mark import complete.
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)

        progressHandler?(1.0, "Done (\(insertCount) variants, \(sampleNames.count) samples)")

        variantDBLogger.info("Created variant database with \(insertCount) variants, \(sampleNames.count) samples at \(outputURL.lastPathComponent)")
        return insertCount
    }

    /// Backward-compatible overload retained to preserve cross-module symbol compatibility.
    @discardableResult
    public static func createFromVCF(
        vcfURL: URL,
        outputURL: URL,
        parseGenotypes: Bool,
        sourceFile: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?,
        importProfile: VCFImportProfile
    ) throws -> Int {
        try createFromVCF(
            vcfURL: vcfURL,
            outputURL: outputURL,
            parseGenotypes: parseGenotypes,
            sourceFile: sourceFile,
            progressHandler: progressHandler,
            shouldCancel: shouldCancel,
            importProfile: importProfile,
            deferIndexBuild: false
        )
    }

    /// Backward-compatible overload without genotype parsing or progress.
    @discardableResult
    public static func createFromVCF(vcfURL: URL, outputURL: URL) throws -> Int {
        try createFromVCF(vcfURL: vcfURL, outputURL: outputURL, parseGenotypes: true, progressHandler: nil)
    }

    /// Creates persistent SmartToken filter tables during import.
    ///
    /// Column-based tables (PASS, SNV, Indel, Quality≥30) are always created.
    /// EAV-based tables (DP≥10, Rare, ClinVar, High Impact) are only created when
    /// `variant_info` is populated (i.e. not `skipVariantInfo`).
    private static func createSmartTokenTables(db: OpaquePointer, skipVariantInfo: Bool) {
        struct TableDef {
            let name: String
            let sql: String
            let idColumn: String
            let indexSQL: String
        }

        var tables: [TableDef] = [
            TableDef(
                name: "_tok_pass",
                sql: "CREATE TABLE IF NOT EXISTS _tok_pass AS SELECT id FROM variants WHERE filter = 'PASS'",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_pass ON _tok_pass(id)"
            ),
            TableDef(
                name: "_tok_snv",
                sql: "CREATE TABLE IF NOT EXISTS _tok_snv AS SELECT id FROM variants WHERE variant_type IN ('SNV','snv','SNP','snp')",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_snv ON _tok_snv(id)"
            ),
            TableDef(
                name: "_tok_indel",
                sql: "CREATE TABLE IF NOT EXISTS _tok_indel AS SELECT id FROM variants WHERE variant_type IN ('Indel','indel','INS','DEL','Insertion','Deletion')",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_indel ON _tok_indel(id)"
            ),
            TableDef(
                name: "_tok_qual30",
                sql: "CREATE TABLE IF NOT EXISTS _tok_qual30 AS SELECT id FROM variants WHERE quality >= 30",
                idColumn: "id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_qual30 ON _tok_qual30(id)"
            ),
        ]

        if skipVariantInfo {
            tables.append(TableDef(
                name: "_tok_bio_hi",
                sql: "CREATE TABLE IF NOT EXISTS _tok_bio_hi AS \(biologicalHighImpactRawInfoSQL())",
                idColumn: "variant_id",
                indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_bio_hi ON _tok_bio_hi(variant_id)"
            ))
        }

        if !skipVariantInfo {
            // Check which INFO keys are available from variant_info_defs
            var availableKeys: Set<String> = []
            var keyStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key FROM variant_info_defs", -1, &keyStmt, nil) == SQLITE_OK {
                while sqlite3_step(keyStmt!) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(keyStmt!, 0) {
                        availableKeys.insert(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(keyStmt)

            if availableKeys.contains("DP") {
                tables.append(TableDef(
                    name: "_tok_dp10",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_dp10 AS SELECT DISTINCT variant_id FROM variant_info WHERE key = 'DP' AND CAST(value AS REAL) >= 10",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_dp10 ON _tok_dp10(variant_id)"
                ))
            }

            let afKeys = ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF", "MAX_AF"]
            if let afKey = afKeys.first(where: { availableKeys.contains($0) }) {
                tables.append(TableDef(
                    name: "_tok_rare",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_rare AS SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(afKey)' AND CAST(value AS REAL) < 0.01",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_rare ON _tok_rare(variant_id)"
                ))
            }

            let clinvarKeys = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
            if let clinvarKey = clinvarKeys.first(where: { availableKeys.contains($0) }) {
                tables.append(TableDef(
                    name: "_tok_clinvar",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_clinvar AS SELECT DISTINCT variant_id FROM variant_info WHERE key = '\(clinvarKey)' AND value LIKE '%athogenic%'",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_clinvar ON _tok_clinvar(variant_id)"
                ))
            }

            // High impact
            let impactKeys = impactInfoKeys
            let hasImpactKey = !impactKeys.allSatisfy { !availableKeys.contains($0) }
            if hasImpactKey {
                let keyList = impactKeys.map { "'\($0)'" }.joined(separator: ",")
                tables.append(TableDef(
                    name: "_high_impact",
                    sql: "CREATE TABLE IF NOT EXISTS _high_impact AS SELECT DISTINCT variant_id FROM variant_info WHERE key IN (\(keyList)) AND value = 'HIGH'",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx_hi ON _high_impact(variant_id)"
                ))
            }

            // Biologically high-impact variants:
            // IMPACT=HIGH plus severe consequence terms.
            let consequenceKeys = impactConsequenceInfoKeys.filter { availableKeys.contains($0) }
            if hasImpactKey || !consequenceKeys.isEmpty {
                let tokenSQL = biologicalHighImpactTokenSQL(
                    impactKeys: impactKeys,
                    consequenceKeys: consequenceKeys.isEmpty ? impactConsequenceInfoKeys : consequenceKeys
                )
                tables.append(TableDef(
                    name: "_tok_bio_hi",
                    sql: "CREATE TABLE IF NOT EXISTS _tok_bio_hi AS \(tokenSQL)",
                    idColumn: "variant_id",
                    indexSQL: "CREATE INDEX IF NOT EXISTS _idx__tok_bio_hi ON _tok_bio_hi(variant_id)"
                ))
            }
        }

        for table in tables {
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, table.sql, nil, nil, &err)
            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                variantDBLogger.warning("createSmartTokenTables: \(table.name) failed: \(msg)")
                continue
            }
            sqlite3_exec(db, table.indexSQL, nil, nil, nil)
            variantDBLogger.info("createSmartTokenTables: created \(table.name)")
        }
    }

    // MARK: - Resume Interrupted Import

    /// Read a metadata value from an existing variant database without opening
    /// a full `VariantDatabase` instance.
    /// Returns `nil` if the database doesn't exist, can't be opened, or lacks the key.
    public static func metadataValue(at dbURL: URL, key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return readMetadataValue(db, key: key)
    }

    /// Read the `import_state` value from an existing variant database.
    /// Returns `nil` if the database doesn't exist or has no `import_state` key.
    public static func importState(at dbURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return readMetadataValue(db, key: "import_state")
    }

    /// Check whether a database file at the given URL contains a `variants` table.
    /// Used as a fallback when `importState` returns nil (e.g. corrupted metadata)
    /// to detect a partial import that may be recoverable.
    public static func hasVariantsTable(at dbURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='variants'", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    /// Returns ordered chromosome IDs from VCF `##contig` header lines.
    ///
    /// This only reads the VCF header and stops at `#CHROM` (or first variant line).
    /// Returns an empty list when `##contig` lines are absent.
    public static func contigsInVCFHeader(
        url: URL,
        maxChromosomes: Int = 512
    ) throws -> [String] {
        try readContigsFromVCFHeader(url: url, maxChromosomes: maxChromosomes)
    }

    /// Merges a chromosome-scoped import database into an existing destination import DB.
    ///
    /// Expects both databases to use the v3 schema produced by `createFromVCF`.
    /// Variant row IDs from `sourceDBURL` are offset and appended so genotype/info
    /// foreign-key relationships remain intact.
    ///
    /// - Returns: Number of variants appended from source.
    @discardableResult
    public static func mergeImportedDatabase(
        into destinationDBURL: URL,
        from sourceDBURL: URL
    ) throws -> Int {
        var destDB: OpaquePointer?
        guard sqlite3_open(destinationDBURL.path, &destDB) == SQLITE_OK, let destDB else {
            let msg = destDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destDB)
            throw VariantDatabaseError.createFailed("Failed to open destination database for merge: \(msg)")
        }
        defer { sqlite3_close(destDB) }

        func exec(_ sql: String, on db: OpaquePointer, context: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &err)
            if let err {
                let msg = String(cString: err)
                sqlite3_free(err)
                throw VariantDatabaseError.createFailed("\(context): \(msg)")
            }
        }

        // Ensure merge writes are deterministic and low-overhead.
        sqlite3_exec(destDB, "PRAGMA foreign_keys = OFF", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA journal_mode = DELETE", nil, nil, nil)

        let sourceAlias = "srcmerge"
        let escapedSourcePath = sourceDBURL.path.replacingOccurrences(of: "'", with: "''")
        try exec("ATTACH DATABASE '\(escapedSourcePath)' AS \(sourceAlias)", on: destDB, context: "Attach source DB")
        defer {
            sqlite3_exec(destDB, "DETACH DATABASE \(sourceAlias)", nil, nil, nil)
        }

        // Profile consistency check.
        let destSkipInfo = readMetadataValue(destDB, key: "skip_variant_info")
        let sourceSkipInfo = readAttachedMetadataValue(db: destDB, alias: sourceAlias, key: "skip_variant_info")
        if destSkipInfo != sourceSkipInfo {
            throw VariantDatabaseError.invalidSchema(
                "Cannot merge databases with different skip_variant_info modes (\(destSkipInfo ?? "nil") vs \(sourceSkipInfo ?? "nil"))"
            )
        }

        let appendedVariants = attachedVariantCount(db: destDB, alias: sourceAlias)
        if appendedVariants == 0 {
            return 0
        }

        let existingMaxID = maxVariantID(db: destDB)

        try exec("BEGIN TRANSACTION", on: destDB, context: "Begin merge transaction")
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(destDB, "ROLLBACK", nil, nil, nil)
            }
        }

        try exec(
            """
            INSERT INTO variants (
                id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            )
            SELECT
                id + \(existingMaxID), chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            FROM \(sourceAlias).variants
            """,
            on: destDB,
            context: "Merge variants"
        )

        try exec(
            """
            INSERT INTO genotypes (
                variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
            )
            SELECT
                variant_id + \(existingMaxID), sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields
            FROM \(sourceAlias).genotypes
            """,
            on: destDB,
            context: "Merge genotypes"
        )

        try exec(
            """
            INSERT OR REPLACE INTO samples (name, display_name, source_file, metadata)
            SELECT name, display_name, source_file, metadata
            FROM \(sourceAlias).samples
            """,
            on: destDB,
            context: "Merge samples"
        )

        if destSkipInfo != "true" {
            try exec(
                """
                INSERT OR REPLACE INTO variant_info (variant_id, key, value)
                SELECT variant_id + \(existingMaxID), key, value
                FROM \(sourceAlias).variant_info
                """,
                on: destDB,
                context: "Merge variant_info"
            )
        }

        try exec(
            """
            INSERT OR REPLACE INTO variant_info_defs (key, type, number, description)
            SELECT key, type, number, description
            FROM \(sourceAlias).variant_info_defs
            """,
            on: destDB,
            context: "Merge variant_info_defs"
        )

        // Merge contig length metadata.
        let mergedContigs = mergeContigLengthsJSON(
            lhs: readMetadataValue(destDB, key: "contig_lengths"),
            rhs: readAttachedMetadataValue(db: destDB, alias: sourceAlias, key: "contig_lengths")
        )
        if let mergedContigs {
            Self.insertMetadataRow(destDB, key: "contig_lengths", value: mergedContigs, replace: true)
        }

        // Token cache tables are import-time snapshots; invalidate so stale caches
        // are not used after appending additional chromosome partitions.
        try exec("DROP TABLE IF EXISTS _tok_pass", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_snv", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_indel", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_qual30", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_dp10", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_rare", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_clinvar", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _tok_bio_hi", on: destDB, context: "Drop token cache table")
        try exec("DROP TABLE IF EXISTS _high_impact", on: destDB, context: "Drop token cache table")

        // Keep import state resumable and import count accurate.
        let totalCount = currentVariantCount(destDB)
        Self.insertMetadataRow(destDB, key: "import_variant_count", value: "\(totalCount)", replace: true)
        Self.insertMetadataRow(destDB, key: "import_state", value: "indexing", replace: true)
        Self.insertMetadataRow(destDB, key: "import_partition_mode", value: "helper-subprocess-per-chromosome", replace: true)

        // Keep AUTOINCREMENT sequence aligned with appended explicit IDs.
        try exec(
            """
            INSERT OR REPLACE INTO sqlite_sequence(name, seq)
            VALUES ('variants', (SELECT COALESCE(MAX(id), 0) FROM variants))
            """,
            on: destDB,
            context: "Update sqlite_sequence"
        )

        try exec("COMMIT", on: destDB, context: "Commit merge transaction")
        committed = true
        _ = sqlite3_db_release_memory(destDB)
        sqlite3_exec(destDB, "PRAGMA shrink_memory", nil, nil, nil)

        return appendedVariants
    }

    /// Resume an interrupted VCF import by creating any missing indexes.
    ///
    /// When `createFromVCF` is killed (e.g. by the OOM killer) the database may
    /// contain all variant data but lack some or all indexes.  This method reads
    /// `import_state` from `db_metadata`, determines which indexes already exist,
    /// and creates the missing ones with conservative memory settings.
    ///
    /// - Returns: The variant count from the database, or 0 if unknown.
    @discardableResult
    public static func resumeImport(
        existingDBURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(existingDBURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Failed to open database for resume: \(msg)")
        }
        defer { sqlite3_close(db) }

        let state = readMetadataValue(db, key: "import_state")
        guard state == "indexing" else {
            switch state {
            case "complete":
                return currentVariantCount(db)
            case "inserting":
                // At this stage we cannot know whether all variant rows were inserted.
                // Resuming by only building indexes can silently produce truncated DBs.
                throw VariantDatabaseError.invalidSchema(
                    "Cannot resume while import_state is 'inserting'; restart full import from source VCF"
                )
            case nil:
                throw VariantDatabaseError.invalidSchema(
                    "Cannot resume with missing import_state metadata; restart full import from source VCF"
                )
            default:
                throw VariantDatabaseError.invalidSchema("Cannot resume: import_state is '\(state ?? "nil")'")
            }
        }

        variantDBLogger.info("resumeImport: Resuming from state '\(state ?? "nil")', building missing indexes")

        // Conservative PRAGMAs for index creation.
        sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = 1", nil, nil, nil)
        sqlite3_soft_heap_limit64(256 * 1024 * 1024)

        // Determine which indexes already exist.
        let existingIndexes = listExistingIndexes(db)

        // If variant_info was skipped during import, don't try to create its indexes.
        let skipVariantInfo = readMetadataValue(db, key: "skip_variant_info") == "true"
        let applicableIndexes = skipVariantInfo
            ? allIndexStatements.filter { !$0.name.contains("variant_info") }
            : allIndexStatements
        let neededIndexes = applicableIndexes.filter { !existingIndexes.contains($0.name) }
        if neededIndexes.isEmpty {
            variantDBLogger.info("resumeImport: All indexes already exist")
            sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)
            return currentVariantCount(db)
        }

        for (i, (name, sql)) in neededIndexes.enumerated() {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }
            let fraction = Double(i) / Double(neededIndexes.count)
            progressHandler?(fraction, "Creating index \(i + 1) of \(neededIndexes.count) (\(name))...")
            var idxErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &idxErr)
            if let idxErr {
                let msg = String(cString: idxErr)
                sqlite3_free(idxErr)
                variantDBLogger.warning("resumeImport: Index '\(name)' failed: \(msg)")
            }
            sqlite3_exec(db, "INSERT OR REPLACE INTO db_metadata VALUES ('idx_\(name)', 'created')", nil, nil, nil)
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
        }

        sqlite3_exec(db, "UPDATE db_metadata SET value = 'complete' WHERE key = 'import_state'", nil, nil, nil)
        let count = currentVariantCount(db)
        progressHandler?(1.0, "Resume complete (\(count) variants)")
        variantDBLogger.info("resumeImport: Complete, \(count) variants")
        return count
    }

    private static func currentVariantCount(_ db: OpaquePointer) -> Int {
        if let metadataCount = readMetadataValue(db, key: "import_variant_count"),
           let parsed = Int(metadataCount),
           parsed >= 0 {
            return parsed
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func maxVariantID(db: OpaquePointer) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM variants", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func attachedVariantCount(db: OpaquePointer, alias: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(alias).variants"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func readAttachedMetadataValue(db: OpaquePointer, alias: String, key: String) -> String? {
        let sql = "SELECT value FROM \(alias).db_metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private static func mergeContigLengthsJSON(lhs: String?, rhs: String?) -> String? {
        func parse(_ json: String?) -> [String: Int64] {
            guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            var result: [String: Int64] = [:]
            for (key, value) in raw {
                if let n = value as? NSNumber {
                    result[key] = n.int64Value
                } else if let s = value as? String, let n = Int64(s) {
                    result[key] = n
                }
            }
            return result
        }

        var merged = parse(lhs)
        for (key, value) in parse(rhs) {
            if merged[key] == nil {
                merged[key] = value
            }
        }
        guard !merged.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: merged.mapValues { NSNumber(value: $0) },
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Inserts or replaces a key-value pair in db_metadata using parameterized binding
    /// to prevent SQL injection from user-controlled values (filenames, chromosome names, etc).
    @discardableResult
    private static func insertMetadataRow(_ db: OpaquePointer, key: String, value: String, replace: Bool = false) -> Bool {
        let sql = replace
            ? "INSERT OR REPLACE INTO db_metadata VALUES (?, ?)"
            : "INSERT INTO db_metadata VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqliteBindText(stmt, 1, key)
        sqliteBindText(stmt, 2, value)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE
    }

    private static func readMetadataValue(_ db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM db_metadata WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private static func listExistingIndexes(_ db: OpaquePointer) -> Set<String> {
        var result = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'index'", -1, &stmt, nil) == SQLITE_OK else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                result.insert(String(cString: cStr))
            }
        }
        return result
    }

    // MARK: - Post-Import EAV Materialization

    /// Materializes the `variant_info` EAV table from raw INFO strings stored in
    /// `variants.info`.  Designed for databases created with the `ultraLowMemory`
    /// profile where `skipVariantInfo` was true.
    ///
    /// Runs in bounded memory: reads variants in batches by rowid cursor, parses
    /// each INFO string, and batch-inserts into `variant_info`.  Progress is
    /// tracked in `db_metadata` for independent resumability.
    ///
    /// After all rows are materialized, populates `variant_info_defs` with inferred
    /// field definitions, creates the `variant_info` indexes, and clears the
    /// `skip_variant_info` flag so downstream code switches to EAV queries.
    ///
    /// - Parameters:
    ///   - existingDBURL: URL to the existing variant database
    ///   - progressHandler: Optional progress callback (fraction, message)
    ///   - shouldCancel: Optional cancellation check
    /// - Returns: Number of EAV rows inserted
    @discardableResult
    public static func materializeVariantInfo(
        existingDBURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(existingDBURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Failed to open database for materialization: \(msg)")
        }
        defer { sqlite3_close(db) }

        // Preconditions.
        let importState = readMetadataValue(db, key: "import_state")
        guard importState == "complete" else {
            throw VariantDatabaseError.invalidSchema(
                "Cannot materialize: import_state is '\(importState ?? "nil")' (expected 'complete')")
        }
        let skipFlag = readMetadataValue(db, key: "skip_variant_info")
        guard skipFlag == "true" else {
            // Not a skipVariantInfo database — EAV was already populated during import.
            return 0
        }
        // Idempotent: if already materialized, return immediately.
        if readMetadataValue(db, key: "materialize_state") == "complete" {
            return 0
        }

        // Conservative PRAGMAs for bounded memory.
        sqlite3_exec(db, "PRAGMA cache_size = -1024", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = FILE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size = 0", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA threads = 1", nil, nil, nil)
        sqlite3_soft_heap_limit64(256 * 1024 * 1024)

        // Resume point: read cursor from previous run if any.
        let lastIdStr = readMetadataValue(db, key: "materialize_last_variant_id")
        var lastProcessedId: Int64 = Int64(lastIdStr ?? "0") ?? 0

        // Total variant count for progress reporting (MAX(id) is O(1) on rowid).
        var maxIdStmt: OpaquePointer?
        defer { sqlite3_finalize(maxIdStmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(id) FROM variants", -1, &maxIdStmt, nil) == SQLITE_OK,
              sqlite3_step(maxIdStmt) == SQLITE_ROW else {
            throw VariantDatabaseError.createFailed("Failed to query MAX(id) for materialization")
        }
        let maxId = sqlite3_column_int64(maxIdStmt, 0)
        sqlite3_finalize(maxIdStmt)
        maxIdStmt = nil

        guard maxId > 0 else {
            // Empty database — nothing to materialize.
            Self.insertMetadataRow(db, key: "materialize_state", value: "complete", replace: true)
            sqlite3_exec(db, "UPDATE db_metadata SET value = 'false' WHERE key = 'skip_variant_info'", nil, nil, nil)
            return 0
        }

        // Mark state.
        Self.insertMetadataRow(db, key: "materialize_state", value: "materializing", replace: true)

        variantDBLogger.info("materializeVariantInfo: Starting from id \(lastProcessedId), maxId \(maxId)")
        progressHandler?(0.0, "Materializing INFO fields...")

        // Prepare statements.
        let selectSQL = """
            SELECT id, info FROM variants
            WHERE id > ? AND info IS NOT NULL AND info != '.'
            ORDER BY id ASC
            LIMIT 5000
            """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare SELECT for materialization")
        }
        defer { sqlite3_finalize(selectStmt) }

        let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
        var insertInfoStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare INSERT for materialization")
        }
        defer { sqlite3_finalize(insertInfoStmt) }

        var totalEAVRows = 0
        var distinctKeys = Set<String>()
        let batchSize = 5000

        // Batch loop.
        while true {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            sqlite3_reset(selectStmt)
            sqlite3_bind_int64(selectStmt, 1, lastProcessedId)

            var batchCount = 0
            var batchLastId: Int64 = lastProcessedId

            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let variantId = sqlite3_column_int64(selectStmt, 0)
                guard let infoCStr = sqlite3_column_text(selectStmt, 1) else { continue }
                let infoString = String(cString: infoCStr)

                let parsed = parseRawINFOString(infoString)
                for (key, value) in parsed {
                    sqlite3_reset(insertInfoStmt)
                    sqlite3_bind_int64(insertInfoStmt, 1, variantId)
                    sqliteBindText(insertInfoStmt, 2, key)
                    sqliteBindText(insertInfoStmt, 3, value)
                    sqlite3_step(insertInfoStmt)
                    totalEAVRows += 1
                    distinctKeys.insert(key)
                }

                batchLastId = variantId
                batchCount += 1
            }

            // No more rows — exit loop.
            if batchCount == 0 {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                break
            }

            // Update cursor and commit.
            lastProcessedId = batchLastId
            Self.insertMetadataRow(db, key: "materialize_last_variant_id", value: "\(lastProcessedId)", replace: true)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            // Release memory.
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)

            // Progress.
            let fraction = min(0.90, Double(lastProcessedId) / Double(maxId) * 0.90)
            progressHandler?(fraction, "Materializing INFO fields (\(totalEAVRows) rows)...")
        }

        variantDBLogger.info("materializeVariantInfo: Inserted \(totalEAVRows) EAV rows, \(distinctKeys.count) distinct keys")

        // Populate variant_info_defs from discovered keys.
        progressHandler?(0.90, "Recording INFO field definitions...")
        let insertDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, 'String', '.', 'Inferred from data')"
        var insertDefStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertDefSQL, -1, &insertDefStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare info_defs INSERT for materialization")
        }
        defer { sqlite3_finalize(insertDefStmt) }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for key in distinctKeys.sorted() {
            sqlite3_reset(insertDefStmt)
            sqliteBindText(insertDefStmt, 1, key)
            sqlite3_step(insertDefStmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        // Create variant_info indexes.
        progressHandler?(0.92, "Creating variant_info indexes...")
        let variantInfoIndexes = allIndexStatements.filter { $0.name.contains("variant_info") }
        for (i, (name, sql)) in variantInfoIndexes.enumerated() {
            if shouldCancel?() == true {
                throw VariantDatabaseError.cancelled
            }
            let indexProgress = 0.92 + (Double(i) / Double(max(1, variantInfoIndexes.count))) * 0.06
            progressHandler?(indexProgress, "Creating index \(name)...")
            var idxErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &idxErr)
            if let idxErr {
                let msg = String(cString: idxErr)
                sqlite3_free(idxErr)
                variantDBLogger.warning("materializeVariantInfo: Index '\(name)' failed: \(msg)")
            }
            _ = sqlite3_db_release_memory(db)
            sqlite3_exec(db, "PRAGMA shrink_memory", nil, nil, nil)
        }

        // Finalize: mark complete, clear cursor, flip skip flag.
        Self.insertMetadataRow(db, key: "materialize_state", value: "complete", replace: true)
        sqlite3_exec(db, "DELETE FROM db_metadata WHERE key = 'materialize_last_variant_id'", nil, nil, nil)
        sqlite3_exec(db, "UPDATE db_metadata SET value = 'false' WHERE key = 'skip_variant_info'", nil, nil, nil)

        progressHandler?(1.0, "Materialization complete (\(totalEAVRows) INFO rows, \(distinctKeys.count) keys)")
        variantDBLogger.info("materializeVariantInfo: Complete — \(totalEAVRows) rows, \(distinctKeys.count) keys")
        return totalEAVRows
    }

    // MARK: - Region Extraction

    /// Extracts variants (and optionally genotypes) from a region into a new database.
    ///
    /// Coordinate transform: positions are shifted by `-extractionStart` so the new
    /// database is zero-based relative to the extracted sub-sequence.
    ///
    /// - Parameters:
    ///   - chromosome: Source chromosome name.
    ///   - chromosomeAliases: Alternate chromosome names to try when source and
    ///     variant-track naming schemes differ (for example `NC_041760.1` vs `7`).
    ///   - start: 0-based start of extraction region.
    ///   - end: 0-based exclusive end of extraction region.
    ///   - outputURL: Where to create the new database.
    ///   - newChromosome: Chromosome name in the new database (defaults to source name).
    ///   - sampleFilter: Optional set of sample names to include. `nil` = all samples.
    /// - Returns: Number of variants written.
    @discardableResult
    public func extractRegion(
        chromosome: String,
        chromosomeAliases: [String] = [],
        start: Int,
        end: Int,
        outputURL: URL,
        newChromosome: String? = nil,
        sampleFilter: Set<String>? = nil
    ) throws -> Int {
        guard let sourceDB = self.db else {
            throw VariantDatabaseError.createFailed("Source database is not open")
        }

        try? FileManager.default.removeItem(at: outputURL)

        var destDB: OpaquePointer?
        guard sqlite3_open(outputURL.path, &destDB) == SQLITE_OK, let destDB else {
            let msg = destDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(destDB)
            throw VariantDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(destDB) }

        sqlite3_exec(destDB, "PRAGMA journal_mode = OFF", nil, nil, nil)
        sqlite3_exec(destDB, "PRAGMA synchronous = OFF", nil, nil, nil)

        let schema = """
        CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chromosome TEXT NOT NULL,
            position INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            variant_id TEXT NOT NULL,
            ref TEXT NOT NULL,
            alt TEXT NOT NULL,
            variant_type TEXT NOT NULL,
            quality REAL,
            filter TEXT,
            info TEXT,
            sample_count INTEGER DEFAULT 0
        );
        CREATE TABLE genotypes (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            sample_name TEXT NOT NULL,
            genotype TEXT,
            allele1 INTEGER,
            allele2 INTEGER,
            is_phased INTEGER DEFAULT 0,
            depth INTEGER,
            genotype_quality INTEGER,
            allele_depths TEXT,
            raw_fields TEXT,
            PRIMARY KEY (variant_id, sample_name)
        );
        CREATE TABLE samples (
            name TEXT PRIMARY KEY,
            display_name TEXT,
            source_file TEXT,
            metadata TEXT
        );
        CREATE TABLE variant_info_defs (
            key TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            number TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE variant_info (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (variant_id, key)
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(destDB, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw VariantDatabaseError.createFailed(msg)
        }

        Self.insertMetadataRow(destDB, key: "schema_version", value: "3")
        Self.insertMetadataRow(destDB, key: "extracted_from_region", value: "\(chromosome):\(start)-\(end)")

        sqlite3_exec(destDB, "BEGIN TRANSACTION", nil, nil, nil)

        // Prepare insert statements
        let insertVariantSQL = """
        INSERT INTO variants (chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertVariantStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, insertVariantSQL, -1, &insertVariantStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare variant INSERT")
        }
        defer { sqlite3_finalize(insertVariantStmt) }

        let insertGenotypeSQL = """
        INSERT INTO genotypes (variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertGenotypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, insertGenotypeSQL, -1, &insertGenotypeStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare genotype INSERT")
        }
        defer { sqlite3_finalize(insertGenotypeStmt) }

        let updateSampleCountSQL = "UPDATE variants SET sample_count = ? WHERE id = ?"
        var updateSampleCountStmt: OpaquePointer?
        guard sqlite3_prepare_v2(destDB, updateSampleCountSQL, -1, &updateSampleCountStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare sample_count UPDATE")
        }
        defer { sqlite3_finalize(updateSampleCountStmt) }

        let targetChrom = newChromosome ?? chromosome

        // Build alias-aware chromosome candidates so extraction still works when the
        // source reference and variant track use different chromosome naming schemes.
        let availableChromosomes = Set(allChromosomes())
        var seenChromCandidates = Set<String>()
        var chromosomeCandidates: [String] = []

        func appendChromosomeCandidate(_ token: String) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard availableChromosomes.contains(trimmed) else { return }
            guard seenChromCandidates.insert(trimmed).inserted else { return }
            chromosomeCandidates.append(trimmed)
        }

        func aliasExpansions(for token: String) -> [String] {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            var ordered: [String] = [trimmed]
            var seen = Set<String>(ordered)

            func append(_ value: String) {
                guard !value.isEmpty else { return }
                guard seen.insert(value).inserted else { return }
                ordered.append(value)
            }

            if let dot = trimmed.firstIndex(of: ".") {
                append(String(trimmed[..<dot]))
            }
            if trimmed.hasPrefix("chr") {
                append(String(trimmed.dropFirst(3)))
            } else {
                append("chr" + trimmed)
            }
            return ordered
        }

        for token in [chromosome] + chromosomeAliases {
            for expansion in aliasExpansions(for: token) {
                appendChromosomeCandidate(expansion)
            }
        }

        // Preserve old behavior when no candidate matches the source DB chromosome set.
        if chromosomeCandidates.isEmpty {
            chromosomeCandidates = [chromosome]
        }

        let chromosomePlaceholders = Array(repeating: "?", count: chromosomeCandidates.count).joined(separator: ",")

        // Stream source variants in-region without hard caps so large selections are complete.
        let variantQuerySQL = """
        SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
        FROM variants
        WHERE chromosome IN (\(chromosomePlaceholders)) AND position < ? AND end_pos > ?
        ORDER BY position, id
        """
        var variantQueryStmt: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB, variantQuerySQL, -1, &variantQueryStmt, nil) == SQLITE_OK, let variantQueryStmt else {
            throw VariantDatabaseError.createFailed("Failed to prepare source variant query")
        }
        defer { sqlite3_finalize(variantQueryStmt) }
        var bindIndex: Int32 = 1
        for queryChromosome in chromosomeCandidates {
            sqliteBindText(variantQueryStmt, bindIndex, queryChromosome)
            bindIndex += 1
        }
        sqlite3_bind_int64(variantQueryStmt, bindIndex, Int64(end))
        bindIndex += 1
        sqlite3_bind_int64(variantQueryStmt, bindIndex, Int64(start))

        var insertCount = 0
        var samplesWithGenotypes = Set<String>()
        var sourceToDestVariantIds: [(Int64, Int64)] = []

        while sqlite3_step(variantQueryStmt) == SQLITE_ROW {
            let sourceVariantId = sqlite3_column_int64(variantQueryStmt, 0)
            let sourcePosition = Int(sqlite3_column_int64(variantQueryStmt, 2))
            let sourceEnd = Int(sqlite3_column_int64(variantQueryStmt, 3))
            let variantID = sqlite3_column_text(variantQueryStmt, 4).map { String(cString: $0) } ?? ""
            let ref = sqlite3_column_text(variantQueryStmt, 5).map { String(cString: $0) } ?? ""
            let alt = sqlite3_column_text(variantQueryStmt, 6).map { String(cString: $0) } ?? ""
            let variantType = sqlite3_column_text(variantQueryStmt, 7).map { String(cString: $0) } ?? "SNP"
            let quality: Double? = sqlite3_column_type(variantQueryStmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(variantQueryStmt, 8)
            let filter = sqlite3_column_text(variantQueryStmt, 9).map { String(cString: $0) }
            let info = sqlite3_column_text(variantQueryStmt, 10).map { String(cString: $0) }

            // Shift coordinates relative to extraction start
            let newPosition = max(0, sourcePosition - start)
            let newEnd = min(end - start, sourceEnd - start)
            guard newEnd > newPosition || (variantType == "SNP" && newEnd == newPosition) else { continue }
            let effectiveEnd = max(newPosition + 1, newEnd)

            sqlite3_reset(insertVariantStmt)
            sqliteBindText(insertVariantStmt, 1, targetChrom)
            sqlite3_bind_int64(insertVariantStmt, 2, Int64(newPosition))
            sqlite3_bind_int64(insertVariantStmt, 3, Int64(effectiveEnd))
            sqliteBindText(insertVariantStmt, 4, variantID)
            sqliteBindText(insertVariantStmt, 5, ref)
            sqliteBindText(insertVariantStmt, 6, alt)
            sqliteBindText(insertVariantStmt, 7, variantType)
            if let q = quality {
                sqlite3_bind_double(insertVariantStmt, 8, q)
            } else {
                sqlite3_bind_null(insertVariantStmt, 8)
            }
            if let f = filter {
                sqliteBindText(insertVariantStmt, 9, f)
            } else {
                sqlite3_bind_null(insertVariantStmt, 9)
            }
            if let info {
                sqliteBindText(insertVariantStmt, 10, info)
            } else {
                sqlite3_bind_null(insertVariantStmt, 10)
            }
            // Set zero first, then update after genotype filtering.
            sqlite3_bind_int(insertVariantStmt, 11, 0)

            guard sqlite3_step(insertVariantStmt) == SQLITE_DONE else { continue }
            let newVariantId = sqlite3_last_insert_rowid(destDB)
            insertCount += 1

            // Track source-to-dest ID mapping for variant_info copy
            sourceToDestVariantIds.append((sourceVariantId, newVariantId))

            // Copy genotypes (filtered by sample if requested)
            let genotypes = self.genotypes(forVariantId: sourceVariantId)
            var insertedGenotypeCount = 0
            for gt in genotypes {
                if let filter = sampleFilter, !filter.contains(gt.sampleName) { continue }

                sqlite3_reset(insertGenotypeStmt)
                sqlite3_bind_int64(insertGenotypeStmt, 1, newVariantId)
                sqliteBindText(insertGenotypeStmt, 2, gt.sampleName)
                if let g = gt.genotype {
                    sqliteBindText(insertGenotypeStmt, 3, g)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 3)
                }
                sqlite3_bind_int(insertGenotypeStmt, 4, Int32(gt.allele1))
                sqlite3_bind_int(insertGenotypeStmt, 5, Int32(gt.allele2))
                sqlite3_bind_int(insertGenotypeStmt, 6, gt.isPhased ? 1 : 0)
                if let d = gt.depth {
                    sqlite3_bind_int(insertGenotypeStmt, 7, Int32(d))
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 7)
                }
                if let gq = gt.genotypeQuality {
                    sqlite3_bind_int(insertGenotypeStmt, 8, Int32(gq))
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 8)
                }
                if let ad = gt.alleleDepths {
                    sqliteBindText(insertGenotypeStmt, 9, ad)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 9)
                }
                if let rf = gt.rawFields {
                    sqliteBindText(insertGenotypeStmt, 10, rf)
                } else {
                    sqlite3_bind_null(insertGenotypeStmt, 10)
                }
                if sqlite3_step(insertGenotypeStmt) == SQLITE_DONE {
                    insertedGenotypeCount += 1
                    samplesWithGenotypes.insert(gt.sampleName)
                }
            }

            // Keep sample_count consistent with filtered genotype rows in extracted DB.
            sqlite3_reset(updateSampleCountStmt)
            sqlite3_bind_int(updateSampleCountStmt, 1, Int32(insertedGenotypeCount))
            sqlite3_bind_int64(updateSampleCountStmt, 2, newVariantId)
            _ = sqlite3_step(updateSampleCountStmt)
        }

        // Copy variant_info EAV entries for extracted variants
        let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
        var insertInfoStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK {
            for (sourceId, newId) in sourceToDestVariantIds {
                let infoVals = self.infoValues(variantId: sourceId)
                for (key, value) in infoVals {
                    sqlite3_reset(insertInfoStmt)
                    sqlite3_bind_int64(insertInfoStmt, 1, newId)
                    sqliteBindText(insertInfoStmt, 2, key)
                    sqliteBindText(insertInfoStmt, 3, value)
                    sqlite3_step(insertInfoStmt)
                }
            }
        }
        sqlite3_finalize(insertInfoStmt)

        // Copy variant_info_defs from source
        let insertInfoDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, ?, ?)"
        var insertInfoDefStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertInfoDefSQL, -1, &insertInfoDefStmt, nil) == SQLITE_OK {
            for def in self.infoKeys() {
                sqlite3_reset(insertInfoDefStmt)
                sqliteBindText(insertInfoDefStmt, 1, def.key)
                sqliteBindText(insertInfoDefStmt, 2, def.type)
                sqliteBindText(insertInfoDefStmt, 3, def.number)
                sqliteBindText(insertInfoDefStmt, 4, def.description)
                sqlite3_step(insertInfoDefStmt)
            }
        }
        sqlite3_finalize(insertInfoDefStmt)

        // Insert sample records (preserve display/source/metadata fields when available).
        let sampleNamesToCopy: [String] = {
            if let sampleFilter {
                return sampleFilter.sorted()
            }
            return sampleNames()
        }()

        let insertSampleSQL = """
        INSERT OR REPLACE INTO samples (name, display_name, source_file, metadata)
        VALUES (?, ?, ?, ?)
        """
        var insertSampleStmt: OpaquePointer?
        let selectSampleSQL = "SELECT name, display_name, source_file, metadata FROM samples WHERE name = ?"
        var selectSampleStmt: OpaquePointer?
        if sqlite3_prepare_v2(destDB, insertSampleSQL, -1, &insertSampleStmt, nil) == SQLITE_OK,
           sqlite3_prepare_v2(sourceDB, selectSampleSQL, -1, &selectSampleStmt, nil) == SQLITE_OK {
            for name in sampleNamesToCopy {
                sqlite3_reset(selectSampleStmt)
                sqliteBindText(selectSampleStmt, 1, name)

                var resolvedName = name
                var displayName: String?
                var sourceFile: String?
                var metadataJSON: String?
                if sqlite3_step(selectSampleStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(selectSampleStmt, 0) { resolvedName = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 1) { displayName = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 2) { sourceFile = String(cString: c) }
                    if let c = sqlite3_column_text(selectSampleStmt, 3) { metadataJSON = String(cString: c) }
                }

                sqlite3_reset(insertSampleStmt)
                sqliteBindText(insertSampleStmt, 1, resolvedName)
                sqliteBindTextOrNull(insertSampleStmt, 2, displayName)
                sqliteBindTextOrNull(insertSampleStmt, 3, sourceFile)
                sqliteBindTextOrNull(insertSampleStmt, 4, metadataJSON)
                sqlite3_step(insertSampleStmt)
            }
        }
        sqlite3_finalize(selectSampleStmt)
        sqlite3_finalize(insertSampleStmt)

        sqlite3_exec(destDB, "COMMIT", nil, nil, nil)

        // Create indexes
        sqlite3_exec(destDB, "CREATE INDEX IF NOT EXISTS idx_variants_chrom_pos ON variants(chromosome, position)", nil, nil, nil)
        sqlite3_exec(destDB, "CREATE INDEX IF NOT EXISTS idx_variants_chrom_region ON variants(chromosome, position, end_pos)", nil, nil, nil)
        sqlite3_exec(destDB, "CREATE INDEX IF NOT EXISTS idx_genotypes_sample ON genotypes(sample_name)", nil, nil, nil)
        sqlite3_exec(destDB, "CREATE INDEX IF NOT EXISTS idx_variant_info_key ON variant_info(key)", nil, nil, nil)
        sqlite3_exec(destDB, "CREATE INDEX IF NOT EXISTS idx_variant_info_key_value ON variant_info(key, value)", nil, nil, nil)

        variantDBLogger.info("extractRegion: Extracted \(insertCount) variants (\(samplesWithGenotypes.count) samples with genotypes) from \(chromosome):\(start)-\(end)")
        return insertCount
    }

    // MARK: - VCF Line Streaming

    /// Reads chromosome IDs from VCF `##contig` header lines without scanning the full file.
    ///
    /// Returns an ordered unique list of contig IDs. If the file has no usable
    /// `##contig` metadata, returns an empty array.
    private static func readContigsFromVCFHeader(
        url: URL,
        maxChromosomes: Int = 512
    ) throws -> [String] {
        @inline(__always)
        func parseHeaderLine(
            _ line: String,
            ordered: inout [String],
            seen: inout Set<String>
        ) -> Bool {
            if line.hasPrefix("#CHROM") {
                return false
            }
            if line.hasPrefix("##contig="),
               let contigID = parseContigID(fromContigHeaderLine: line),
               seen.insert(contigID).inserted {
                ordered.append(contigID)
                if ordered.count >= maxChromosomes {
                    // Too many contigs for practical per-chromosome replay.
                    return false
                }
            } else if !line.hasPrefix("#") {
                // First variant row reached before #CHROM (malformed header); stop.
                return false
            }
            return true
        }

        var ordered: [String] = []
        var seen = Set<String>()
        let ext = url.pathExtension.lowercased()

        if ext == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let fileHandle = pipe.fileHandleForReading
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }

            var buffer = Data()
            var keepReading = true
            while keepReading {
                let chunk = fileHandle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                buffer.append(chunk)

                var lineStart = buffer.startIndex
                while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    keepReading = parseHeaderLine(line, ordered: &ordered, seen: &seen)
                    lineStart = buffer.index(after: newlineIdx)
                    if !keepReading { break }
                }
                if lineStart > buffer.startIndex {
                    buffer.removeSubrange(..<lineStart)
                }
            }
            return ordered
        }

        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw VariantDatabaseError.createFailed("Cannot open VCF file: \(url.lastPathComponent)")
        }
        defer { fileHandle.closeFile() }

        var buffer = Data()
        var keepReading = true
        while keepReading {
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                let lineData = buffer[lineStart..<newlineIdx]
                let line = String(decoding: lineData, as: UTF8.self)
                keepReading = parseHeaderLine(line, ordered: &ordered, seen: &seen)
                lineStart = buffer.index(after: newlineIdx)
                if !keepReading { break }
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }
        return ordered
    }

    /// Parses a contig ID from a VCF `##contig=<...>` header line.
    private static func parseContigID(fromContigHeaderLine line: String) -> String? {
        guard line.hasPrefix("##contig=") else { return nil }
        let payload = line.dropFirst(9)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !payload.isEmpty else { return nil }

        for part in payload.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare("ID") == .orderedSame {
                let raw = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Streams lines from a plain-text VCF file using buffered I/O.
    ///
    /// Avoids loading the entire file into memory, which can fail for multi-GB VCFs.
    /// Reports byte-level progress when `totalFileSize` is provided.
    private static func streamPlainLines(
        url: URL,
        totalFileSize: Int64 = 0,
        shouldCancel: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw VariantDatabaseError.createFailed("Cannot open VCF file: \(url.lastPathComponent)")
        }
        defer { fh.closeFile() }

        var buffer = Data()
        var bytesRead: Int64 = 0
        var lastProgress = -1.0
        var lastEmitTime = Date.distantPast
        var cancelled = false
        let chunkSize = 256 * 1024  // 256 KB read chunks
        while true {
            if shouldCancel?() == true {
                cancelled = true
                break
            }
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            if totalFileSize > 0 {
                emitThrottledProgress(
                    Double(bytesRead) / Double(totalFileSize),
                    onProgress: onProgress,
                    lastProgress: &lastProgress,
                    lastEmitTime: &lastEmitTime
                )
            }

            // Parse all complete lines in-buffer, then drop the consumed prefix once.
            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) {
                autoreleasepool {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    handler(Substring(line))
                }
                lineStart = buffer.index(after: newlineIdx)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }

        if !cancelled, !buffer.isEmpty {
            autoreleasepool {
                let tail = String(decoding: buffer, as: UTF8.self)
                handler(Substring(tail))
            }
        }

        if !cancelled, totalFileSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }
        return cancelled
    }

    /// Streams lines from a gzip-compressed VCF using `gzip -dc`.
    ///
    /// Reports approximate progress based on decompressed bytes vs estimated uncompressed size.
    private static func streamGzipLines(
        url: URL,
        estimatedUncompressedSize: Int64 = 0,
        shouldCancel: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let fileHandle = pipe.fileHandleForReading
        var buffer = Data()
        var bytesRead: Int64 = 0
        var lastProgress = -1.0
        var lastEmitTime = Date.distantPast
        var cancelled = false
        while true {
            if shouldCancel?() == true {
                cancelled = true
                process.terminate()
                break
            }
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            if estimatedUncompressedSize > 0 {
                emitThrottledProgress(
                    Double(bytesRead) / Double(estimatedUncompressedSize),
                    onProgress: onProgress,
                    lastProgress: &lastProgress,
                    lastEmitTime: &lastEmitTime
                )
            }

            var lineStart = buffer.startIndex
            while let newlineIdx = buffer[lineStart...].firstIndex(of: 0x0A) { // "\n"
                autoreleasepool {
                    let lineData = buffer[lineStart..<newlineIdx]
                    let line = String(decoding: lineData, as: UTF8.self)
                    handler(Substring(line))
                }
                lineStart = buffer.index(after: newlineIdx)
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(..<lineStart)
            }
        }

        if !cancelled, !buffer.isEmpty {
            autoreleasepool {
                let tail = String(decoding: buffer, as: UTF8.self)
                handler(Substring(tail))
            }
        }

        if !cancelled, estimatedUncompressedSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }

        process.waitUntilExit()
        if !cancelled, process.terminationStatus != 0 {
            throw VariantDatabaseError.createFailed("Failed to decompress \(url.lastPathComponent) (gzip exit code \(process.terminationStatus))")
        }
        return cancelled
    }

    /// Estimates uncompressed size for a gzip file using ISIZE footer with heuristic fallback.
    static func estimateGzipUncompressedSize(url: URL, compressedSize: Int64) -> Int64 {
        let fallback = max(1, compressedSize * 8)
        guard compressedSize >= 4, let fh = FileHandle(forReadingAtPath: url.path) else {
            return fallback
        }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: UInt64(compressedSize - 4))
        let footer = fh.readData(ofLength: 4)
        guard footer.count == 4 else { return fallback }

        let bytes = [UInt8](footer)
        let isize = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        // Sanity check: ISIZE is uint32 so wraps at 4 GB, and bgzip multi-member
        // files report only the last member's size. If the footer value is smaller
        // than the compressed size, it's almost certainly wrong for text data —
        // fall back to the heuristic.
        guard isize > 0 else { return fallback }
        let estimate = Int64(isize)
        return estimate >= compressedSize ? estimate : fallback
    }

    /// Emits progress updates with simple coalescing to avoid flooding UI callbacks.
    private static func emitThrottledProgress(
        _ rawProgress: Double,
        onProgress: ((Double) -> Void)?,
        lastProgress: inout Double,
        lastEmitTime: inout Date
    ) {
        guard let onProgress else { return }
        let progress = max(0.0, min(1.0, rawProgress))
        let now = Date()
        let shouldEmit =
            lastProgress < 0 ||
            progress >= 1.0 ||
            (progress - lastProgress) >= 0.01 ||
            now.timeIntervalSince(lastEmitTime) >= 0.15
        guard shouldEmit else { return }
        lastProgress = max(lastProgress, progress)
        lastEmitTime = now
        onProgress(lastProgress)
    }

    // MARK: - Variant Classification

    /// Classifies a variant based on ref/alt alleles.
    static func classifyVariant(ref: String, alts: [String]) -> String {
        guard let firstAlt = alts.first, !firstAlt.isEmpty, firstAlt != "." else {
            return VariantType.reference.rawValue
        }

        if ref.count == 1 && firstAlt.count == 1 {
            return VariantType.snp.rawValue
        } else if ref.count > firstAlt.count {
            return VariantType.deletion.rawValue
        } else if ref.count < firstAlt.count {
            return VariantType.insertion.rawValue
        } else if ref.count == firstAlt.count && ref.count > 1 {
            return VariantType.mnp.rawValue
        } else {
            return VariantType.complex.rawValue
        }
    }

    /// Classifies a variant using the first ALT allele without allocating intermediate strings.
    static func classifyVariant(ref: Substring, altField: Substring) -> String {
        guard let firstAlt = altField.split(separator: ",", omittingEmptySubsequences: false).first,
              !firstAlt.isEmpty,
              firstAlt != "."
        else {
            return VariantType.reference.rawValue
        }

        if ref.count == 1 && firstAlt.count == 1 {
            return VariantType.snp.rawValue
        } else if ref.count > firstAlt.count {
            return VariantType.deletion.rawValue
        } else if ref.count < firstAlt.count {
            return VariantType.insertion.rawValue
        } else if ref.count == firstAlt.count && ref.count > 1 {
            return VariantType.mnp.rawValue
        } else {
            return VariantType.complex.rawValue
        }
    }

    /// Parses a VCF ##INFO=<ID=X,Number=Y,Type=Z,Description="..."> header line.
    ///
    /// Sync version of the parser in VCFReader (which uses async APIs).
    /// Returns nil if the line cannot be parsed.
    private static func parseINFODefinition(_ str: Substring) -> (id: String, type: String, number: String, description: String)? {
        let content = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if content.hasPrefix("<"), content.hasSuffix(">"), content.count >= 2 {
            normalized = String(content.dropFirst().dropLast())
        } else {
            normalized = content
        }

        var dict: [String: String] = [:]

        var current = ""
        var fields: [String] = []
        var inQuotes = false
        var isEscaped = false

        for char in normalized {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }
            if inQuotes, char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == ",", !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    fields.append(trimmed)
                }
                current = ""
                continue
            }
            current.append(char)
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty {
            fields.append(trailing)
        }

        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\\\", with: "\\")
            dict[key] = value
        }

        guard let id = dict["ID"], let type = dict["Type"], let number = dict["Number"] else { return nil }
        return (id: id, type: type, number: number, description: dict["Description"] ?? "")
    }

    /// Parses the END value from a VCF INFO field string.
    private static func parseINFOEnd<S: StringProtocol>(_ info: S) -> Int? {
        guard !(info.count == 1 && info.first == ".") else { return nil }
        for pair in info.split(separator: ";") {
            if pair.hasPrefix("END=") {
                let value = pair.dropFirst(4)
                if let endVal = Int(value) {
                    // VCF END is 1-based inclusive; 0-based exclusive = endVal
                    return endVal
                }
            }
        }
        return nil
    }

    // MARK: - SQL Helpers

    /// Executes a SQL statement and throws on failure.
    private func executeSQL(_ sql: String) throws {
        guard let db else {
            throw VariantDatabaseError.createFailed("Database not open")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw VariantDatabaseError.createFailed("\(sql): \(msg)")
        }
    }
}

// MARK: - Errors

public enum VariantDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case invalidSchema(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open variant database: \(msg)"
        case .createFailed(let msg): return "Failed to create variant database: \(msg)"
        case .invalidSchema(let msg): return "Invalid variant database schema: \(msg)"
        case .cancelled: return "VCF import was cancelled"
        }
    }
}
