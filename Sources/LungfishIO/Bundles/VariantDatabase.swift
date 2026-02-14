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
    /// Auto-increment row ID (nil for legacy databases without id column)
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

/// Reads variant data from a SQLite database embedded in a .lungfishref bundle.
///
/// The database is created during bundle building from VCF files, providing instant
/// random-access queries by genomic region without requiring a tabix/CSI index reader.
///
/// Schema (v2 — with genotype and sample tables):
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
/// CREATE TABLE genotypes (
///     variant_id INTEGER NOT NULL REFERENCES variants(id),
///     sample_name TEXT NOT NULL,
///     genotype TEXT,
///     allele1 INTEGER,
///     allele2 INTEGER,
///     is_phased INTEGER DEFAULT 0,
///     depth INTEGER,
///     genotype_quality INTEGER,
///     allele_depths TEXT,
///     raw_fields TEXT,
///     PRIMARY KEY (variant_id, sample_name)
/// );
/// CREATE TABLE samples (
///     name TEXT PRIMARY KEY,
///     display_name TEXT,
///     metadata TEXT
/// );
/// ```
public final class VariantDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// The URL of the database file.
    public var databaseURL: URL { url }
    /// Whether this database has the v2 schema (id column, genotypes, samples tables).
    private let hasV2Schema: Bool
    /// Whether the samples table has a source_file column.
    private let hasSourceFileColumn: Bool
    /// Whether the database is opened read-only.
    private let isReadOnly: Bool
    /// Whether the variant_info EAV table exists (for structured INFO field queries).
    private let hasInfoTable: Bool
    /// Whether hom-ref (0/0) genotypes are omitted from the genotypes table (v3 import optimization).
    /// When true, absence of a genotype row for a sample at a variant site means hom-ref, not no-call.
    public let omitHomref: Bool

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
        // Enforce FK constraints so genotype rows cannot be orphaned.
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        // Detect v2 schema by checking for genotypes table
        self.hasV2Schema = VariantDatabase.tableExists(db: db!, name: "genotypes")
        // Detect source_file column in samples table
        self.hasSourceFileColumn = hasV2Schema && VariantDatabase.columnExists(db: db!, table: "samples", column: "source_file")
        // Detect variant_info EAV table
        self.hasInfoTable = VariantDatabase.tableExists(db: db!, name: "variant_info")
        // Detect v3 import optimization (hom-ref genotypes omitted)
        self.omitHomref = VariantDatabase.metadataValue(db: db!, key: "omit_homref") == "true"
        variantDBLogger.info("Opened variant database: \(url.lastPathComponent) (v2=\(self.hasV2Schema), sourceFile=\(self.hasSourceFileColumn), infoTable=\(self.hasInfoTable), omitHomref=\(self.omitHomref))")
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

    /// Reads a value from the db_metadata table, returning nil if the table or key doesn't exist.
    private static func metadataValue(db: OpaquePointer, key: String) -> String? {
        guard tableExists(db: db, name: "db_metadata") else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM db_metadata WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqliteBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// Checks whether a column exists in a table.
    private static func columnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                if String(cString: name) == column { return true }
            }
        }
        return false
    }

    /// Whether the id column exists in the variants table.
    private var hasIdColumn: Bool { hasV2Schema }

    // MARK: - Metadata Queries

    /// Returns the total number of variants in the database.
    public func totalCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns all distinct variant type strings (SNP, INS, DEL, MNP, COMPLEX, REF).
    public func allTypes() -> [String] {
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
    public func allChromosomes() -> [String] {
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
    ///
    /// Used for chromosome name alias matching by comparing max variant positions
    /// against reference chromosome lengths.
    public func chromosomeMaxPositions() -> [String: Int] {
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

        let idSelect = hasIdColumn ? "id, " : ""
        let sampleCountSelect = hasV2Schema ? ", sample_count" : ""
        var sql = "SELECT \(idSelect)chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info\(sampleCountSelect) FROM variants"
        var conditions: [String] = []
        var bindingsText: [(Int32, String)] = []
        var bindingsDouble: [(Int32, Double)] = []
        var paramIndex: Int32 = 1

        conditions.append("chromosome = ?")
        bindingsText.append((paramIndex, chromosome))
        paramIndex += 1

        conditions.append("position < ?")
        bindingsDouble.append((paramIndex, Double(end)))
        paramIndex += 1

        conditions.append("end_pos > ?")
        bindingsDouble.append((paramIndex, Double(start)))
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

    /// Queries variants with optional type filter, name filter, and INFO filters.
    public func queryForTable(nameFilter: String = "", types: Set<String> = [], infoFilters: [InfoFilter] = [], limit: Int = 5000) -> [VariantDatabaseRecord] {
        guard let db else { return [] }
        if !infoFilters.isEmpty && !hasInfoTable { return [] }

        let idSelect = hasIdColumn ? "id, " : ""
        let sampleCountSelect = hasV2Schema ? ", sample_count" : ""
        var sql = "SELECT \(idSelect)chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info\(sampleCountSelect) FROM variants"
        var conditions: [String] = []
        var bindings: [(Int32, String)] = []
        var paramIndex: Int32 = 1

        if !nameFilter.isEmpty {
            conditions.append("variant_id LIKE ?")
            bindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if hasInfoTable {
            for filter in infoFilters {
                let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
                conditions.append(filterSQL)
                bindings.append(contentsOf: filterBindings)
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY chromosome, position LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        for (idx, value) in bindings {
            sqliteBindText(stmt, idx, value)
        }

        return readVariantRows(stmt: stmt!)
    }

    /// Returns variant count matching optional filters.
    public func queryCountForTable(nameFilter: String = "", types: Set<String> = [], infoFilters: [InfoFilter] = []) -> Int {
        guard let db else { return 0 }
        if !infoFilters.isEmpty && !hasInfoTable { return 0 }

        var sql = "SELECT COUNT(*) FROM variants"
        var conditions: [String] = []
        var bindings: [(Int32, String)] = []
        var paramIndex: Int32 = 1

        if !nameFilter.isEmpty {
            conditions.append("variant_id LIKE ?")
            bindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if hasInfoTable {
            for filter in infoFilters {
                let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
                conditions.append(filterSQL)
                bindings.append(contentsOf: filterBindings)
            }
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
        limit: Int = 5000
    ) -> [VariantDatabaseRecord] {
        guard let db else { return [] }
        if !infoFilters.isEmpty && !hasInfoTable { return [] }

        let idSelect = hasIdColumn ? "id, " : ""
        let sampleCountSelect = hasV2Schema ? ", sample_count" : ""
        var sql = "SELECT \(idSelect)chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info\(sampleCountSelect) FROM variants"
        var conditions: [String] = ["chromosome = ?1", "position < ?2", "end_pos > ?3"]
        var textBindings: [(Int32, String)] = [(1, chromosome)]
        var intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("variant_id LIKE ?\(paramIndex)")
            textBindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("variant_type IN (\(placeholders))")
            for t in types.sorted() {
                textBindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if hasInfoTable {
            for filter in infoFilters {
                let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
                conditions.append(filterSQL)
                textBindings.append(contentsOf: filterBindings)
            }
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY chromosome, position LIMIT \(limit)"

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
        infoFilters: [InfoFilter] = []
    ) -> Int {
        guard let db else { return 0 }
        if !infoFilters.isEmpty && !hasInfoTable { return 0 }

        var sql = "SELECT COUNT(*) FROM variants"
        var conditions: [String] = ["chromosome = ?1", "position < ?2", "end_pos > ?3"]
        var textBindings: [(Int32, String)] = [(1, chromosome)]
        var intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("variant_id LIKE ?\(paramIndex)")
            textBindings.append((paramIndex, "%\(nameFilter)%"))
            paramIndex += 1
        }

        if !types.isEmpty {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("variant_type IN (\(placeholders))")
            for t in types.sorted() {
                textBindings.append((paramIndex, t))
                paramIndex += 1
            }
        }

        if hasInfoTable {
            for filter in infoFilters {
                let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
                conditions.append(filterSQL)
                textBindings.append(contentsOf: filterBindings)
            }
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

        let idSelect = hasIdColumn ? "id, " : ""
        let sampleCountSelect = hasV2Schema ? ", sample_count" : ""
        let sql = "SELECT \(idSelect)chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info\(sampleCountSelect) FROM variants WHERE variant_id LIKE ? ORDER BY variant_id COLLATE NOCASE LIMIT ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqliteBindText(stmt, 1, "%\(idFilter)%")
        sqlite3_bind_int(stmt, 2, Int32(limit))

        return readVariantRows(stmt: stmt!)
    }

    /// Reads variant rows from a prepared statement, handling both v1 and v2 schemas.
    private func readVariantRows(stmt: OpaquePointer) -> [VariantDatabaseRecord] {
        var results: [VariantDatabaseRecord] = []
        let offset: Int32 = hasIdColumn ? 1 : 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId: Int64? = hasIdColumn ? sqlite3_column_int64(stmt, 0) : nil
            let chrom = sqlite3_column_text(stmt, 0 + offset).map { String(cString: $0) } ?? ""
            let pos = Int(sqlite3_column_int64(stmt, 1 + offset))
            let endPos = Int(sqlite3_column_int64(stmt, 2 + offset))
            let vid = sqlite3_column_text(stmt, 3 + offset).map { String(cString: $0) } ?? ""
            let ref = sqlite3_column_text(stmt, 4 + offset).map { String(cString: $0) } ?? ""
            let alt = sqlite3_column_text(stmt, 5 + offset).map { String(cString: $0) } ?? ""
            let vtype = sqlite3_column_text(stmt, 6 + offset).map { String(cString: $0) } ?? "SNP"
            let quality: Double? = sqlite3_column_type(stmt, 7 + offset) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7 + offset)
            let filter = sqlite3_column_text(stmt, 8 + offset).map { String(cString: $0) }
            let info = sqlite3_column_text(stmt, 9 + offset).map { String(cString: $0) }
            let sampleCount: Int = hasV2Schema ? Int(sqlite3_column_int64(stmt, 10 + offset)) : 0

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
        guard let db, hasV2Schema else { return [] }
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
        guard let db, hasV2Schema else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns genotype records for a specific variant (by row ID).
    public func genotypes(forVariantId variantRowId: Int64) -> [GenotypeRecord] {
        guard let db, hasV2Schema else { return [] }
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
        guard let db, hasV2Schema else { return [:] }
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
        guard let db, hasV2Schema else { return [] }
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
        guard let db, hasV2Schema else { return [] }

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
        let variantIDs = variants.compactMap(\.id)
        guard !variantIDs.isEmpty else {
            return variants.map { ($0, []) }
        }
        let placeholders = variantIDs.map { _ in "?" }.joined(separator: ",")
        let genotypeSQL = """
            SELECT variant_id, sample_name, genotype, allele1, allele2,
                   is_phased, depth, genotype_quality, allele_depths, raw_fields
            FROM genotypes
            WHERE variant_id IN (\(placeholders))
            ORDER BY variant_id, sample_name
            """
        var genotypeStmt: OpaquePointer?
        defer { sqlite3_finalize(genotypeStmt) }
        guard sqlite3_prepare_v2(db, genotypeSQL, -1, &genotypeStmt, nil) == SQLITE_OK else {
            variantDBLogger.error("genotypesInRegion: Failed to prepare genotype query")
            return variants.map { ($0, []) }
        }
        for (idx, variantID) in variantIDs.enumerated() {
            sqlite3_bind_int64(genotypeStmt, Int32(idx + 1), variantID)
        }
        let genotypeRows = readGenotypeRows(stmt: genotypeStmt!)
        let genotypeMap = Dictionary(grouping: genotypeRows, by: \.variantRowId)
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
            if hasInfoTable {
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
            }
            if hasV2Schema {
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
            if hasInfoTable {
                try executeSQL("DELETE FROM variant_info")
            }
            if hasV2Schema {
                try executeSQL("DELETE FROM genotypes")
            }
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
    public func totalVariantCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM variants", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Structured INFO Queries

    /// Returns INFO field definitions from the variant_info_defs table.
    ///
    /// These are parsed from VCF `##INFO=<...>` header lines during import.
    /// Returns empty array for legacy databases without the variant_info table.
    public func infoKeys() -> [(key: String, type: String, number: String, description: String)] {
        guard let db, hasInfoTable else { return [] }
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
        return results
    }

    /// Returns true if the given INFO key has at least one non-empty value in `variant_info`.
    public func hasNonEmptyInfoValue(forKey key: String) -> Bool {
        guard let db, hasInfoTable else { return false }
        let sql = "SELECT 1 FROM variant_info WHERE key = ? AND TRIM(value) != '' LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqliteBindText(stmt, 1, key)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Returns all INFO key-value pairs for a specific variant.
    ///
    /// Falls back to parsing the raw INFO string for legacy databases.
    public func infoValues(variantId: Int64) -> [String: String] {
        guard let db else { return [:] }
        if hasInfoTable {
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
            }
            return result
        }
        // Legacy fallback: parse raw INFO string
        let sql = "SELECT info FROM variants WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        sqlite3_bind_int64(stmt, 1, variantId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rawInfo = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              rawInfo != "." else { return [:] }
        var result: [String: String] = [:]
        for field in rawInfo.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            } else if parts.count == 1 {
                result[String(parts[0])] = "true"
            }
        }
        return result
    }

    /// Batch-fetches INFO dictionaries for multiple variant IDs.
    ///
    /// More efficient than calling `infoValues(variantId:)` per-variant.
    /// Returns a dictionary mapping variant ID to its INFO key-value pairs.
    public func batchInfoValues(variantIds: [Int64]) -> [Int64: [String: String]] {
        guard let db, hasInfoTable, !variantIds.isEmpty else { return [:] }
        var result: [Int64: [String: String]] = [:]
        let uniqueIds = Array(Set(variantIds))
        let chunkSize = 500 // Keep well below SQLite bind-variable limits.

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
            }
        }
        return result
    }

    /// Returns distinct non-empty values for an INFO key, limited and sorted by frequency.
    public func distinctInfoValues(forKey key: String, limit: Int = 21) -> [String] {
        guard let db, hasInfoTable, limit > 0 else { return [] }
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
        guard let db, hasV2Schema, hasSourceFileColumn else { return nil }
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
        guard let db, hasV2Schema, hasSourceFileColumn else { return [:] }
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
        guard let db, hasV2Schema else { return [:] }
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
        guard let db, hasV2Schema else { return [] }
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
        guard let db, hasV2Schema, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing or missing v2 schema")
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
        guard let db, hasV2Schema, !isReadOnly else {
            throw VariantDatabaseError.createFailed("Database not open for writing or missing v2 schema")
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
        let headers = rows[0]
        guard headers.count >= 2 else { return 0 } // Need sample name + at least one field

        let existingSamples = Set(sampleNames())

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        let updateSQL = "UPDATE samples SET metadata = ? WHERE name = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw VariantDatabaseError.createFailed("Failed to prepare update statement")
        }
        defer { sqlite3_finalize(updateStmt) }

        var updatedCount = 0
        for row in rows.dropFirst() {
            guard !row.isEmpty else { continue }
            let sampleName = row[0]
            guard existingSamples.contains(sampleName) else {
                variantDBLogger.info("importSampleMetadata: Skipping unknown sample '\(sampleName, privacy: .public)'")
                continue
            }

            // Build metadata dictionary from remaining columns
            var metadata: [String: String] = [:]
            for (i, header) in headers.dropFirst().enumerated() {
                let valueIndex = i + 1
                if valueIndex < row.count {
                    let value = row[valueIndex]
                    if !value.isEmpty {
                        metadata[header] = value
                    }
                }
            }

            // Merge with existing metadata
            var existing = sampleMetadata(name: sampleName)
            existing.merge(metadata) { _, new in new }

            let jsonData = try JSONSerialization.data(withJSONObject: existing)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

            sqlite3_reset(updateStmt)
            sqliteBindText(updateStmt, 1, jsonStr)
            sqliteBindText(updateStmt, 2, sampleName)

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                updatedCount += 1
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        variantDBLogger.info("importSampleMetadata: Updated \(updatedCount) samples from \(url.lastPathComponent)")
        return updatedCount
    }

    // MARK: - TSV/CSV Parsing

    private func parseTSV(url: URL) throws -> [[String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private func parseCSV(url: URL) throws -> [[String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rows: [[String]] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            rows.append(parseCSVLine(String(line)))
        }
        return rows
    }

    /// Parses a single CSV line, handling quoted fields with embedded commas.
    private func parseCSVLine(_ line: String) -> [String] {
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
                } else if char == "," && prevWasQuote {
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
                } else if char == "," {
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
                sqlite3_bind_text(stmt, 2, (flag as NSString).utf8String, -1, nil)
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

        let idSelect = hasIdColumn ? "v.id, " : ""
        let sampleCountSelect = hasV2Schema ? ", v.sample_count" : ""
        let sql = """
            SELECT \(idSelect)v.chromosome, v.position, v.end_pos, v.variant_id, v.ref, v.alt, \
            v.variant_type, v.quality, v.filter, v.info\(sampleCountSelect) \
            FROM variants v \
            INNER JOIN variant_bookmarks b ON v.\(hasIdColumn ? "id" : "rowid") = b.variant_id \
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
            sqlite3_bind_text(stmt, 1, (note as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, variantId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
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
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

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
        sqlite3_exec(db, "PRAGMA journal_mode = OFF", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = OFF", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -64000", nil, nil, nil)

        // Create v2 schema
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
        sqlite3_exec(db, "INSERT INTO db_metadata VALUES ('schema_version', '3')", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO db_metadata VALUES ('omit_homref', 'true')", nil, nil, nil)

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

        let insertInfoDefSQL = "INSERT OR REPLACE INTO variant_info_defs (key, type, number, description) VALUES (?, ?, ?, ?)"
        var insertInfoDefStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertInfoDefSQL, -1, &insertInfoDefStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare info def INSERT statement")
        }
        defer { sqlite3_finalize(insertInfoDefStmt) }

        let insertInfoSQL = "INSERT OR REPLACE INTO variant_info (variant_id, key, value) VALUES (?, ?, ?)"
        var insertInfoStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertInfoSQL, -1, &insertInfoStmt, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Failed to prepare info INSERT statement")
        }
        defer { sqlite3_finalize(insertInfoStmt) }

        var insertCount = 0
        var sampleNames: [String] = []
        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: vcfURL.path)[.size] as? Int64) ?? 0

        // CSQ (VEP Consequence) sub-field names parsed from ##INFO=<ID=CSQ,...,Description="...Format: A|B|C">
        var csqFieldNames: [String] = []
        // Track all structured INFO fields with pipe-delimited sub-fields (key → sub-field names)
        var structuredInfoFields: [String: [String]] = [:]

        progressHandler?(0.05, "Parsing VCF...")

        func parseLine(_ line: Substring) {
            guard !line.isEmpty else { return }

            // Parse ##INFO=<...> header lines for structured INFO definitions
            if line.hasPrefix("##INFO=") {
                let content = line.dropFirst(7)
                if let def = parseINFODefinition(content) {
                    sqlite3_reset(insertInfoDefStmt)
                    sqliteBindText(insertInfoDefStmt, 1, def.id)
                    sqliteBindText(insertInfoDefStmt, 2, def.type)
                    sqliteBindText(insertInfoDefStmt, 3, def.number)
                    sqliteBindText(insertInfoDefStmt, 4, def.description)
                    sqlite3_step(insertInfoDefStmt)

                    // Detect structured fields with pipe-delimited sub-fields from Description
                    // e.g., CSQ: "...Format: Allele|Consequence|IMPACT|SYMBOL|Gene|..."
                    if let formatRange = def.description.range(of: "Format: ", options: .caseInsensitive) {
                        let formatStr = String(def.description[formatRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        let subFields = formatStr.split(separator: "|").map(String.init)
                        if subFields.count >= 2 {
                            structuredInfoFields[def.id] = subFields
                            if def.id == "CSQ" {
                                csqFieldNames = subFields
                            }
                            // Register each sub-field as a separate info def
                            for subField in subFields {
                                let subKey = "\(def.id)_\(subField)"
                                sqlite3_reset(insertInfoDefStmt)
                                sqliteBindText(insertInfoDefStmt, 1, subKey)
                                sqliteBindText(insertInfoDefStmt, 2, "String")
                                sqliteBindText(insertInfoDefStmt, 3, ".")
                                sqliteBindText(insertInfoDefStmt, 4, "\(def.id) sub-field: \(subField)")
                                sqlite3_step(insertInfoDefStmt)
                            }
                            variantDBLogger.info("createFromVCF: Found structured INFO field '\(def.id)' with \(subFields.count) sub-fields")
                        }
                    }
                }
                return
            }

            // Skip other meta-information lines
            if line.hasPrefix("##") { return }

            // Parse header line for sample names
            if line.hasPrefix("#CHROM") {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count > 9 {
                    sampleNames = Array(fields.dropFirst(9))
                    // Insert sample records
                    let srcFile = sourceFile ?? vcfURL.lastPathComponent
                    for sampleName in sampleNames {
                        sqlite3_reset(insertSampleStmt)
                        sqliteBindText(insertSampleStmt, 1, sampleName)
                        sqliteBindText(insertSampleStmt, 2, sampleName)
                        sqliteBindText(insertSampleStmt, 3, srcFile)
                        sqlite3_step(insertSampleStmt)
                    }
                    variantDBLogger.info("createFromVCF: Found \(sampleNames.count) samples")
                }
                return
            }

            // Parse variant line
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8 else { return }

            let chromosome = fields[0]
            guard let pos1based = Int(fields[1]), pos1based >= 1 else { return }
            let position = pos1based - 1  // Convert to 0-based

            let rawID = fields[2]
            let variantID = rawID == "." ? "\(chromosome)_\(pos1based)" : rawID

            let ref = fields[3]
            let alt = fields[4]
            let qualStr = fields[5]
            let quality: Double? = qualStr == "." ? nil : Double(qualStr)
            let filter = fields[6] == "." ? nil : fields[6]

            let altAlleles = alt.split(separator: ",").map(String.init)
            let variantType = classifyVariant(ref: ref, alts: altAlleles)

            let infoField = fields[7]
            let endPos: Int
            if let endValue = parseINFOEnd(infoField) {
                endPos = endValue
            } else {
                endPos = position + ref.count
            }
            let infoStr = fields[7] == "." ? nil : fields[7]

            // Parse genotype data to count called samples (non-missing GT).
            var genotypeCount = 0
            var formatFields: [String] = []
            if parseGenotypes && fields.count > 9 && !sampleNames.isEmpty {
                let formatStr = fields[8]
                formatFields = formatStr.split(separator: ":").map(String.init)
                let gtIndex = formatFields.firstIndex(of: "GT")
                for sampleIdx in 0..<sampleNames.count {
                    let fieldIdx = 9 + sampleIdx
                    guard fieldIdx < fields.count else { break }
                    let sampleData = fields[fieldIdx]
                    if sampleData == "." || sampleData == "./." || sampleData == ".|." { continue }
                    guard let gtIdx = gtIndex else { continue }
                    let sampleFields = sampleData.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard gtIdx < sampleFields.count else { continue }
                    let gt = sampleFields[gtIdx]
                    if gt == "." || gt == "./." || gt == ".|." { continue }
                    let separator: Character = gt.contains("|") ? "|" : "/"
                    let alleles = gt.split(separator: separator).map(String.init)
                    if alleles.count >= 2 {
                        let a1 = alleles[0] == "." ? -1 : (Int(alleles[0]) ?? -1)
                        let a2 = alleles[1] == "." ? -1 : (Int(alleles[1]) ?? -1)
                        if a1 >= 0 || a2 >= 0 {
                            genotypeCount += 1
                        }
                    } else if alleles.count == 1 {
                        let a1 = alleles[0] == "." ? -1 : (Int(alleles[0]) ?? -1)
                        if a1 >= 0 {
                            genotypeCount += 1
                        }
                    } else {
                        genotypeCount += 1
                    }
                }
            }

            // Insert variant
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
            // v3: Don't store raw INFO string (redundant with variant_info EAV table).
            sqlite3_bind_null(insertVariantStmt, 10)
            sqlite3_bind_int(insertVariantStmt, 11, Int32(genotypeCount))

            guard sqlite3_step(insertVariantStmt) == SQLITE_DONE else {
                variantDBLogger.warning("Failed to insert variant: \(variantID)")
                return
            }
            let variantRowId = sqlite3_last_insert_rowid(db)
            insertCount += 1

            // Insert structured INFO key-value pairs into variant_info EAV table
            if let infoStr, infoStr != "." {
                for field in infoStr.split(separator: ";") {
                    let parts = field.split(separator: "=", maxSplits: 1)
                    let key: String
                    let value: String
                    if parts.count == 2 {
                        key = String(parts[0])
                        value = String(parts[1])
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
                            let subValues = firstEntry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                            for (idx, subFieldName) in subFieldNames.enumerated() {
                                let subValue = idx < subValues.count ? subValues[idx] : ""
                                guard !subValue.isEmpty else { continue }
                                let subKey = "\(key)_\(subFieldName)"
                                sqlite3_reset(insertInfoStmt)
                                sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                                sqliteBindText(insertInfoStmt, 2, subKey)
                                sqliteBindText(insertInfoStmt, 3, subValue)
                                sqlite3_step(insertInfoStmt)
                            }
                        }
                        // Also store entry count if multiple transcripts
                        if entries.count > 1 {
                            sqlite3_reset(insertInfoStmt)
                            sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                            sqliteBindText(insertInfoStmt, 2, "\(key)_entries")
                            sqliteBindText(insertInfoStmt, 3, String(entries.count))
                            sqlite3_step(insertInfoStmt)
                        }
                    } else {
                        // Standard scalar INFO field
                        sqlite3_reset(insertInfoStmt)
                        sqlite3_bind_int64(insertInfoStmt, 1, variantRowId)
                        sqliteBindText(insertInfoStmt, 2, key)
                        sqliteBindText(insertInfoStmt, 3, value)
                        sqlite3_step(insertInfoStmt)
                    }
                }
            }

            // Insert genotype records for each sample
            if parseGenotypes && !formatFields.isEmpty && !sampleNames.isEmpty {
                let gtIndex = formatFields.firstIndex(of: "GT")
                let dpIndex = formatFields.firstIndex(of: "DP")
                let gqIndex = formatFields.firstIndex(of: "GQ")
                let adIndex = formatFields.firstIndex(of: "AD")

                for sampleIdx in 0..<sampleNames.count {
                    let fieldIdx = 9 + sampleIdx
                    guard fieldIdx < fields.count else { break }
                    let sampleData = fields[fieldIdx]
                    if sampleData == "." || sampleData == "./." || sampleData == ".|." { continue }

                    let sampleFields = sampleData.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

                    // Parse GT
                    var allele1 = -1
                    var allele2 = -1
                    var isPhased = false
                    var rawGT: String?
                    if let gtIdx = gtIndex, gtIdx < sampleFields.count {
                        let gt = sampleFields[gtIdx]
                        rawGT = gt
                        let separator: Character = gt.contains("|") ? "|" : "/"
                        isPhased = separator == "|"
                        let alleles = gt.split(separator: separator).map(String.init)
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

                    // v3: Skip hom-ref genotypes (0/0) — inferred from absence.
                    // This typically eliminates ~90% of genotype rows.
                    if allele1 == 0 && allele2 == 0 { continue }

                    // Parse AD
                    var ad: String?
                    if let adIdx = adIndex, adIdx < sampleFields.count {
                        let adStr = sampleFields[adIdx]
                        if adStr != "." { ad = adStr }
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
                }
            }

        }

        // Read VCF content with byte-based progress tracking.
        // Both plain and .vcf.gz VCFs use line-by-line streaming to avoid large memory spikes.
        let ext = vcfURL.pathExtension.lowercased()
        let byteProgress: (Double) -> Void = { fraction in
            progressHandler?(0.05 + fraction * 0.85, "Parsing variants (\(insertCount))...")
        }
        if ext == "gz" {
            let estimatedSize = estimateGzipUncompressedSize(url: vcfURL, compressedSize: fileSize)
            try streamGzipLines(url: vcfURL, estimatedUncompressedSize: estimatedSize, onProgress: byteProgress) { line in
                parseLine(line)
            }
        } else {
            try streamPlainLines(url: vcfURL, totalFileSize: fileSize, onProgress: byteProgress) { line in
                parseLine(line)
            }
        }

        progressHandler?(0.92, "Creating indexes...")

        // Create indexes after bulk insert (faster). Log any failures.
        let indexStatements = [
            "CREATE INDEX idx_variants_region ON variants(chromosome, position, end_pos)",
            "CREATE INDEX idx_variants_type ON variants(variant_type)",
            "CREATE INDEX idx_variants_id ON variants(variant_id COLLATE NOCASE)",
            "CREATE INDEX idx_genotypes_sample ON genotypes(sample_name)",
            "CREATE INDEX idx_genotypes_variant ON genotypes(variant_id)",
            "CREATE INDEX idx_samples_name ON samples(name)",
            "CREATE INDEX idx_variant_info_key ON variant_info(key)",
            "CREATE INDEX idx_variant_info_key_value ON variant_info(key, value)",
        ]
        for indexSQL in indexStatements {
            var idxErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, indexSQL, nil, nil, &idxErr)
            if let idxErr {
                let msg = String(cString: idxErr)
                sqlite3_free(idxErr)
                variantDBLogger.warning("createFromVCF: Index creation failed: \(msg)")
            }
        }

        var commitErr: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "COMMIT", nil, nil, &commitErr)
        if let commitErr {
            let msg = String(cString: commitErr)
            sqlite3_free(commitErr)
            variantDBLogger.error("createFromVCF: COMMIT failed: \(msg)")
        }

        progressHandler?(1.0, "Done (\(insertCount) variants, \(sampleNames.count) samples)")

        variantDBLogger.info("Created variant database with \(insertCount) variants, \(sampleNames.count) samples at \(outputURL.lastPathComponent)")
        return insertCount
    }

    /// Backward-compatible overload without genotype parsing or progress.
    @discardableResult
    public static func createFromVCF(vcfURL: URL, outputURL: URL) throws -> Int {
        try createFromVCF(vcfURL: vcfURL, outputURL: outputURL, parseGenotypes: true, progressHandler: nil)
    }

    // MARK: - VCF Line Streaming

    /// Streams lines from a plain-text VCF file using buffered I/O.
    ///
    /// Avoids loading the entire file into memory, which can fail for multi-GB VCFs.
    /// Reports byte-level progress when `totalFileSize` is provided.
    private static func streamPlainLines(
        url: URL,
        totalFileSize: Int64 = 0,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw VariantDatabaseError.createFailed("Cannot open VCF file: \(url.lastPathComponent)")
        }
        defer { fh.closeFile() }

        var buffer = Data()
        var bytesRead: Int64 = 0
        var lastProgress = -1.0
        var lastEmitTime = Date.distantPast
        let chunkSize = 256 * 1024  // 256 KB read chunks
        while true {
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

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIdx)
                if let line = String(data: lineData, encoding: .utf8) {
                    handler(Substring(line))
                }
                buffer.removeSubrange(...newlineIdx)
            }
        }

        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
            handler(Substring(tail))
        }

        if totalFileSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }
    }

    /// Streams lines from a gzip-compressed VCF using `gzip -dc`.
    ///
    /// Reports approximate progress based on decompressed bytes vs estimated uncompressed size.
    private static func streamGzipLines(
        url: URL,
        estimatedUncompressedSize: Int64 = 0,
        onProgress: ((Double) -> Void)? = nil,
        _ handler: (Substring) -> Void
    ) throws {
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
        while true {
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

            while let newlineIdx = buffer.firstIndex(of: 0x0A) { // "\n"
                let lineData = buffer.prefix(upTo: newlineIdx)
                if let line = String(data: lineData, encoding: .utf8) {
                    handler(Substring(line))
                }
                buffer.removeSubrange(...newlineIdx)
            }
        }

        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
            handler(Substring(tail))
        }

        if estimatedUncompressedSize > 0 {
            emitThrottledProgress(
                1.0,
                onProgress: onProgress,
                lastProgress: &lastProgress,
                lastEmitTime: &lastEmitTime
            )
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VariantDatabaseError.createFailed("Failed to decompress \(url.lastPathComponent) (gzip exit code \(process.terminationStatus))")
        }
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
    private static func parseINFOEnd(_ info: String) -> Int? {
        guard info != "." else { return nil }
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

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open variant database: \(msg)"
        case .createFailed(let msg): return "Failed to create variant database: \(msg)"
        }
    }
}
