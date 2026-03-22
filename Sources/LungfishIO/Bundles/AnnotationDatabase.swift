// AnnotationDatabase.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

/// Logger for annotation database operations
private let dbLogger = Logger(subsystem: LogSubsystem.io, category: "AnnotationDatabase")

// MARK: - AnnotationDatabaseRecord

/// A single annotation record from the SQLite database.
public struct AnnotationDatabaseRecord: Sendable {
    public let name: String
    public let type: String
    public let chromosome: String
    public let start: Int
    public let end: Int
    public let strand: String
    /// GFF3 attributes string (semicolon-delimited key=value pairs), if available.
    public let attributes: String?
    /// Number of blocks (BED12 column 9). Nil for single-interval features.
    public let blockCount: Int?
    /// Comma-separated block sizes (BED12 column 10), e.g. "120,300,200".
    public let blockSizes: String?
    /// Comma-separated block starts relative to `start` (BED12 column 11), e.g. "0,500,2000".
    public let blockStarts: String?
    /// Gene name extracted from the GFF3 `gene` attribute, for cross-feature search.
    public let geneName: String?

    public init(name: String, type: String, chromosome: String, start: Int, end: Int, strand: String, attributes: String? = nil, blockCount: Int? = nil, blockSizes: String? = nil, blockStarts: String? = nil, geneName: String? = nil) {
        self.name = name
        self.type = type
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.strand = strand
        self.attributes = attributes
        self.blockCount = blockCount
        self.blockSizes = blockSizes
        self.blockStarts = blockStarts
        self.geneName = geneName
    }
}

// MARK: - AnnotationDatabaseRecord → SequenceAnnotation

extension AnnotationDatabaseRecord {
    /// Converts this database record to a `SequenceAnnotation` for rendering.
    ///
    /// Block data (blockCount/blockSizes/blockStarts) is used to create multi-interval
    /// annotations for discontinuous features (e.g., mRNA with exons). When block data
    /// is absent (v2 schema or single-interval features), a single interval is created.
    public func toAnnotation() -> SequenceAnnotation {
        let annotationType = AnnotationType.from(rawString: type) ?? .gene

        let strandValue: Strand
        switch strand {
        case "+": strandValue = .forward
        case "-": strandValue = .reverse
        default: strandValue = .unknown
        }

        // Build intervals from BED12 block data if available
        var intervals: [AnnotationInterval]
        if let bc = blockCount, bc > 1,
           let sizes = blockSizes, let starts = blockStarts {
            let sizeArr = sizes.split(separator: ",").compactMap { Int($0) }
            let startArr = starts.split(separator: ",").compactMap { Int($0) }
            if sizeArr.count >= bc && startArr.count >= bc {
                intervals = (0..<bc).map { i in
                    AnnotationInterval(
                        start: start + startArr[i],
                        end: start + startArr[i] + sizeArr[i]
                    )
                }
            } else {
                intervals = [AnnotationInterval(start: start, end: end)]
            }
        } else {
            intervals = [AnnotationInterval(start: start, end: end)]
        }

        // Parse qualifiers from GFF3-style attributes
        var qualifiers: [String: AnnotationQualifier] = [:]
        if let attrs = attributes {
            for pair in attrs.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    qualifiers[key] = AnnotationQualifier(value)
                }
            }
        }

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            chromosome: chromosome,
            intervals: intervals,
            strand: strandValue,
            qualifiers: qualifiers
        )
    }
}

// MARK: - AnnotationDatabase (Reader)

/// Reads annotation metadata from a SQLite database embedded in a .lungfishref bundle.
///
/// The database is created during bundle building and provides instant search/filter
/// over annotation names, types, and coordinates without scanning BigBed R-trees.
///
/// Schema (v4):
/// ```sql
/// CREATE TABLE annotations (
///     name TEXT NOT NULL,
///     type TEXT NOT NULL,
///     chromosome TEXT NOT NULL,
///     start INTEGER NOT NULL,
///     end INTEGER NOT NULL,
///     strand TEXT NOT NULL DEFAULT '.',
///     attributes TEXT,
///     block_count INTEGER,
///     block_sizes TEXT,
///     block_starts TEXT,
///     gene_name TEXT
/// );
/// ```
public final class AnnotationDatabase: @unchecked Sendable {

    private static let expectedSchemaVersion = 4
    private static let requiredAnnotationColumns: Set<String> = [
        "name", "type", "chromosome", "start", "end", "strand",
        "attributes", "block_count", "block_sizes", "block_starts", "gene_name"
    ]

    private var db: OpaquePointer?
    private let url: URL

    /// Opens an existing annotation database for reading.
    ///
    /// - Parameter url: URL to the SQLite database file
    /// - Throws: If the database cannot be opened
    public init(url: URL) throws {
        self.url = url
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw AnnotationDatabaseError.openFailed(msg)
        }
        guard let db else {
            throw AnnotationDatabaseError.openFailed("Database handle is nil")
        }

        try Self.validateSchema(db: db)

        dbLogger.info("Opened annotation database: \(url.lastPathComponent)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func validateSchema(db: OpaquePointer) throws {
        guard tableExists(db: db, name: "annotations") else {
            throw AnnotationDatabaseError.invalidSchema("Missing required table: annotations")
        }
        guard tableExists(db: db, name: "db_metadata") else {
            throw AnnotationDatabaseError.invalidSchema("Missing required table: db_metadata")
        }
        let columns = columnsForTable(db: db, table: "annotations")
        guard requiredAnnotationColumns.isSubset(of: columns) else {
            let missing = requiredAnnotationColumns.subtracting(columns).sorted().joined(separator: ", ")
            throw AnnotationDatabaseError.invalidSchema("annotations table missing required columns: \(missing)")
        }
        guard let version = schemaVersion(db: db) else {
            throw AnnotationDatabaseError.invalidSchema("Missing db_metadata schema_version")
        }
        guard version == expectedSchemaVersion else {
            throw AnnotationDatabaseError.invalidSchema(
                "Unsupported schema_version \(version); expected \(expectedSchemaVersion)"
            )
        }
    }

    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnsForTable(db: OpaquePointer, table: String) -> Set<String> {
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

    /// Returns the total number of annotations in the database.
    public func totalCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM annotations", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns all distinct annotation type strings.
    public func allTypes() -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT type FROM annotations ORDER BY type", -1, &stmt, nil) == SQLITE_OK else { return [] }

        var types: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                types.append(String(cString: cStr))
            }
        }
        return types
    }

    /// Queries annotations matching the given filters.
    ///
    /// - Parameters:
    ///   - nameFilter: Case-insensitive substring match on name (empty = no filter)
    ///   - types: Set of type strings to include (empty = all types)
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching annotation records
    public func query(nameFilter: String = "", types: Set<String> = [], limit: Int = 5000) -> [AnnotationDatabaseRecord] {
        guard let db else { return [] }

        var sql = "SELECT name, type, chromosome, start, end, strand, gene_name FROM annotations"
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            conditions.append("(name LIKE ? OR gene_name LIKE ?)")
            bindings.append("%\(nameFilter)%")
            bindings.append("%\(nameFilter)%")
        }
        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append(t)
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY name COLLATE NOCASE"
        sql += " LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLogger.error("Failed to prepare query: \(sql)")
            return []
        }

        for (i, binding) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (binding as NSString).utf8String, -1, nil)
        }

        var results: [AnnotationDatabaseRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let chrom = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let start = Int(sqlite3_column_int64(stmt, 3))
            let end = Int(sqlite3_column_int64(stmt, 4))
            let strand = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "."
            let geneName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

            results.append(AnnotationDatabaseRecord(
                name: name, type: type, chromosome: chrom,
                start: start, end: end, strand: strand,
                geneName: geneName
            ))
        }

        return results
    }

    /// Returns the count of annotations matching the given filters (without fetching rows).
    public func queryCount(nameFilter: String = "", types: Set<String> = []) -> Int {
        guard let db else { return 0 }

        var sql = "SELECT COUNT(*) FROM annotations"
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            conditions.append("(name LIKE ? OR gene_name LIKE ?)")
            bindings.append("%\(nameFilter)%")
            bindings.append("%\(nameFilter)%")
        }
        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append(t)
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (i, binding) in bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (binding as NSString).utf8String, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Annotation Lookup

    /// Looks up a single annotation by name, chromosome, and coordinates.
    ///
    /// Returns the full record including attributes and block data.
    /// Used for enriching hover tooltips and inspector details with GFF3 metadata.
    ///
    /// - Parameters:
    ///   - name: Annotation name
    ///   - chromosome: Chromosome name
    ///   - start: Start coordinate (0-based)
    ///   - end: End coordinate
    /// - Returns: The matching record, or nil if not found
    public func lookupAnnotation(name: String, chromosome: String, start: Int, end: Int) -> AnnotationDatabaseRecord? {
        guard let db else { return nil }

        // v4 schema: fixed column order
        let sql = """
        SELECT name, type, chromosome, start, end, strand, attributes,
               block_count, block_sizes, block_starts, gene_name
        FROM annotations
        WHERE (name = ? OR gene_name = ?) AND chromosome = ? AND start = ? AND end = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (chromosome as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 4, Int64(start))
        sqlite3_bind_int64(stmt, 5, Int64(end))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let rName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let rType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let rChrom = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let rStart = Int(sqlite3_column_int64(stmt, 3))
        let rEnd = Int(sqlite3_column_int64(stmt, 4))
        let rStrand = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "."
        let rAttrs = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let bcType = sqlite3_column_type(stmt, 7)
        let rBlockCount = bcType != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 7)) : nil
        let rBlockSizes = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let rBlockStarts = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let rGeneName = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

        return AnnotationDatabaseRecord(
            name: rName, type: rType, chromosome: rChrom,
            start: rStart, end: rEnd, strand: rStrand,
            attributes: rAttrs,
            blockCount: rBlockCount, blockSizes: rBlockSizes, blockStarts: rBlockStarts,
            geneName: rGeneName
        )
    }

    /// Queries annotations in a genomic region for type enrichment.
    ///
    /// Returns all annotations overlapping the specified region. Used to enrich
    /// BigBed features with correct types at read time.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start coordinate (0-based)
    ///   - end: End coordinate
    ///   - limit: Maximum results (default 10000)
    /// - Returns: Array of matching records with attributes
    public func queryByRegion(chromosome: String, start: Int, end: Int, limit: Int = 10000) -> [AnnotationDatabaseRecord] {
        guard let db else { return [] }

        // v4 schema: fixed column order
        let sql = """
        SELECT name, type, chromosome, start, end, strand, attributes,
               block_count, block_sizes, block_starts, gene_name
        FROM annotations
        WHERE chromosome = ? AND end > ? AND start < ?
        ORDER BY start ASC, end ASC, name COLLATE NOCASE ASC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLogger.error("Failed to prepare queryByRegion: \(sql)")
            return []
        }

        sqlite3_bind_text(stmt, 1, (chromosome as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, Int64(start))
        sqlite3_bind_int64(stmt, 3, Int64(end))
        sqlite3_bind_int64(stmt, 4, Int64(limit))

        var results: [AnnotationDatabaseRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let rType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let rChrom = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let rStart = Int(sqlite3_column_int64(stmt, 3))
            let rEnd = Int(sqlite3_column_int64(stmt, 4))
            let rStrand = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "."
            let rAttrs = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let bcType = sqlite3_column_type(stmt, 7)
            let rBlockCount = bcType != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 7)) : nil
            let rBlockSizes = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let rBlockStarts = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let rGeneName = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

            results.append(AnnotationDatabaseRecord(
                name: rName, type: rType, chromosome: rChrom,
                start: rStart, end: rEnd, strand: rStrand,
                attributes: rAttrs,
                blockCount: rBlockCount, blockSizes: rBlockSizes, blockStarts: rBlockStarts,
                geneName: rGeneName
            ))
        }

        return results
    }

    /// Returns all chromosome names present in the annotations table.
    public func allChromosomes() -> [String] {
        guard let db else { return [] }
        let sql = "SELECT DISTINCT chromosome FROM annotations ORDER BY chromosome"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    // MARK: - Attribute Parsing

    /// Parses a GFF3-style attributes string into a dictionary.
    ///
    /// Format: `key1=value1;key2=value2;key3=value3`
    /// Values are URL-decoded (percent-encoded spaces, commas, etc.).
    ///
    /// - Parameter attrs: Raw attributes string
    /// - Returns: Dictionary of key-value pairs
    public static func parseAttributes(_ attrs: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in attrs.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            result[key] = value
        }
        return result
    }

    // MARK: - Static Creation (for bundle building)

    /// Creates a new annotation database from BED file content.
    ///
    /// Parses BED lines (tab-separated) extracting: chromosome (col 0), start (col 1),
    /// end (col 2), name (col 3), strand (col 5), feature type (col 12 if present),
    /// and GFF3 attributes (col 13 if present).
    ///
    /// - Parameters:
    ///   - bedURL: URL to the BED file
    ///   - outputURL: URL for the SQLite database to create
    /// - Returns: Number of records inserted
    @discardableResult
    public static func createFromBED(bedURL: URL, outputURL: URL) throws -> Int {
        // Remove existing database
        try? FileManager.default.removeItem(at: outputURL)

        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw AnnotationDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Create schema (v4 with attributes, block columns, and gene_name)
        let schema = """
        CREATE TABLE annotations (
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            chromosome TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            strand TEXT NOT NULL DEFAULT '.',
            attributes TEXT,
            block_count INTEGER,
            block_sizes TEXT,
            block_starts TEXT,
            gene_name TEXT
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw AnnotationDatabaseError.createFailed(msg)
        }
        sqlite3_exec(db, "INSERT INTO db_metadata VALUES ('schema_version', '4')", nil, nil, nil)

        // Begin transaction for bulk insert
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed("Failed to prepare INSERT statement")
        }
        defer { sqlite3_finalize(insertStmt) }

        let content = try String(contentsOf: bedURL, encoding: .utf8)
        var insertCount = 0

        for line in content.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { continue }

            let chrom = String(fields[0])
            let start = Int(fields[1]) ?? 0
            let end = Int(fields[2]) ?? 0
            let strand = fields.count > 5 ? String(fields[5]) : "."

            // Extract BED12 block data (columns 9-11, 0-indexed)
            let blockCount: Int? = fields.count > 9 ? Int(fields[9]) : nil
            let blockSizes: String? = fields.count > 10 ? String(fields[10]) : nil
            let blockStarts: String? = fields.count > 11 ? String(fields[11]) : nil

            // Extract type from column 12 (0-indexed) if present, otherwise infer
            let type: String
            if fields.count > 12 {
                type = String(fields[12])
            } else {
                type = "gene"
            }

            let rawName = String(fields[3])
            let name: String
            if rawName.isEmpty {
                name = "\(type):\(chrom):\(start)-\(end)"
            } else {
                name = rawName
            }

            // Extract GFF3 attributes from column 13 if present
            let attributes: String?
            if fields.count > 13 {
                let attr = String(fields[13])
                attributes = attr.isEmpty ? nil : attr
            } else {
                attributes = nil
            }

            // Extract gene_name from attributes
            let geneName: String?
            if let attributes {
                let parsed = parseAttributes(attributes)
                geneName = parsed["gene"]
            } else {
                geneName = nil
            }

            sqlite3_reset(insertStmt)
            sqlite3_bind_text(insertStmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (type as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 3, (chrom as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(insertStmt, 4, Int64(start))
            sqlite3_bind_int64(insertStmt, 5, Int64(end))
            sqlite3_bind_text(insertStmt, 6, (strand as NSString).utf8String, -1, nil)
            if let attributes {
                sqlite3_bind_text(insertStmt, 7, (attributes as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 7)
            }
            if let blockCount {
                sqlite3_bind_int64(insertStmt, 8, Int64(blockCount))
            } else {
                sqlite3_bind_null(insertStmt, 8)
            }
            if let blockSizes {
                sqlite3_bind_text(insertStmt, 9, (blockSizes as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 9)
            }
            if let blockStarts {
                sqlite3_bind_text(insertStmt, 10, (blockStarts as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 10)
            }
            if let geneName {
                sqlite3_bind_text(insertStmt, 11, (geneName as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 11)
            }

            if sqlite3_step(insertStmt) != SQLITE_DONE {
                dbLogger.warning("Failed to insert annotation: \(name)")
            }
            insertCount += 1
        }

        // Create indexes after bulk insert (faster than indexing during inserts)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_type ON annotations(type)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_chrom ON annotations(chromosome)", nil, nil, nil)
        // Composite index for fast genomic interval queries (chromosome + coordinate range)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_region ON annotations(chromosome, start, end)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_gene_name ON annotations(gene_name COLLATE NOCASE)", nil, nil, nil)

        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        dbLogger.info("Created annotation database with \(insertCount) records at \(outputURL.lastPathComponent)")
        return insertCount
    }

    // MARK: - Static Creation from GFF3

    /// Creates a new annotation database directly from a GFF3 file.
    ///
    /// This bypasses the intermediate BED format entirely, parsing GFF3 features
    /// and inserting them into SQLite with parent-child aggregation for transcript
    /// block data. Transcript-level features (mRNA, transcript, etc.) collect exon
    /// children into BED12-style blocks; CDS children define thickStart/thickEnd.
    ///
    /// - Parameters:
    ///   - gffURL: URL to the GFF3 file (must be decompressed)
    ///   - outputURL: URL for the SQLite database to create
    ///   - chromosomeSizes: Optional chromosome size map for coordinate clipping
    /// - Returns: Number of records inserted
    @discardableResult
    public static func createFromGFF3(
        gffURL: URL,
        outputURL: URL,
        chromosomeSizes: [(String, Int64)]? = nil
    ) async throws -> Int {
        try? FileManager.default.removeItem(at: outputURL)

        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw AnnotationDatabaseError.createFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Create schema (v4 with gene_name)
        let schema = """
        CREATE TABLE annotations (
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            chromosome TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            strand TEXT NOT NULL DEFAULT '.',
            attributes TEXT,
            block_count INTEGER,
            block_sizes TEXT,
            block_starts TEXT,
            gene_name TEXT
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw AnnotationDatabaseError.createFailed(msg)
        }
        sqlite3_exec(db, "INSERT INTO db_metadata VALUES ('schema_version', '4')", nil, nil, nil)

        let chromSizeMap: [String: Int64]?
        if let sizes = chromosomeSizes {
            chromSizeMap = Dictionary(uniqueKeysWithValues: sizes)
        } else {
            chromSizeMap = nil
        }

        // Indexable types — superset of createFromBED's set, plus GFF3-specific transcript types
        let indexableTypes: Set<String> = [
            "gene", "mRNA", "transcript", "region", "promoter", "enhancer",
            "primer", "primer_pair", "amplicon", "SNP", "variation",
            "restriction_site", "repeat_region", "origin_of_replication",
            "misc_feature", "silencer", "terminator", "polyA_signal",
            "CDS", "mat_peptide", "sig_peptide", "transit_peptide",
            "5'UTR", "3'UTR", "five_prime_UTR", "three_prime_UTR",
            "regulatory", "ncRNA", "misc_binding", "protein_bind",
            "stem_loop", "primer_bind",
            // GFF3 transcript types (multi-exon transcripts need indexing)
            "lnc_RNA", "rRNA", "tRNA", "snRNA", "snoRNA", "miRNA",
            "primary_transcript", "V_gene_segment", "D_gene_segment",
            "J_gene_segment", "C_gene_segment",
        ]

        // Transcript-level types whose children get aggregated into blocks
        let transcriptTypes: Set<String> = [
            "mRNA", "transcript", "lnc_RNA", "rRNA", "tRNA", "snRNA", "snoRNA",
            "miRNA", "ncRNA", "primary_transcript", "V_gene_segment",
            "D_gene_segment", "J_gene_segment", "C_gene_segment",
        ]
        let exonTypes: Set<String> = ["exon"]
        let cdsTypes: Set<String> = ["CDS"]

        // ── Pass 1: Read all features and build parent-child index ──
        struct ParsedFeature {
            let seqid: String
            let featureType: String
            let start: Int        // 1-based
            let end: Int          // 1-based inclusive
            let strand: String
            let id: String?
            let parentID: String?
            let name: String
            let attributes: [String: String]
        }

        var allFeatures: [ParsedFeature] = []
        var childrenByParent: [String: [Int]] = [:]

        for try await line in gffURL.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("##FASTA") { break }
                continue
            }

            let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9 else { continue }

            guard let start = Int(fields[3]), let end = Int(fields[4]) else { continue }

            let strand: String
            switch fields[6] {
            case "+": strand = "+"
            case "-": strand = "-"
            default: strand = "."
            }

            let attrs = parseGFF3Attributes(fields[8])
            let name = attrs["Name"] ?? attrs["ID"] ?? fields[2]

            let feature = ParsedFeature(
                seqid: fields[0],
                featureType: fields[2],
                start: start,
                end: end,
                strand: strand,
                id: attrs["ID"],
                parentID: attrs["Parent"],
                name: name,
                attributes: attrs
            )

            let index = allFeatures.count
            allFeatures.append(feature)

            if let parentStr = attrs["Parent"] {
                // GFF3 Parent can be comma-separated (e.g., "mRNA1,mRNA2" for shared exons)
                for parentID in parentStr.split(separator: ",").map(String.init) {
                    childrenByParent[parentID, default: []].append(index)
                }
            }
        }

        dbLogger.info("createFromGFF3: Parsed \(allFeatures.count) features from \(gffURL.lastPathComponent)")

        // Group features by GFF3 ID for same-ID merging (e.g., CDS with multiple intervals)
        var featuresByID: [String: [Int]] = [:]
        for (index, feature) in allFeatures.enumerated() {
            if let id = feature.id {
                featuresByID[id, default: []].append(index)
            }
        }

        // ── Pass 2: Build database records with parent-child aggregation ──
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed("Failed to prepare INSERT statement")
        }
        defer { sqlite3_finalize(insertStmt) }

        var insertCount = 0
        var seenKeys = Set<String>()
        var processedIDs = Set<String>()

        /// Helper: serialize GFF3 attributes (excluding ID and Parent) with percent-encoding.
        func serializeAttributes(_ attrs: [String: String]) -> String? {
            var attrPairs: [String] = []
            for (key, value) in attrs.sorted(by: { $0.key < $1.key }) {
                if key == "ID" || key == "Parent" { continue }
                let encoded = value
                    .replacingOccurrences(of: "%", with: "%25")
                    .replacingOccurrences(of: ";", with: "%3B")
                    .replacingOccurrences(of: "=", with: "%3D")
                    .replacingOccurrences(of: "&", with: "%26")
                    .replacingOccurrences(of: ",", with: "%2C")
                attrPairs.append("\(key)=\(encoded)")
            }
            return attrPairs.isEmpty ? nil : attrPairs.joined(separator: ";")
        }

        /// Helper: bind all 11 columns and execute the INSERT.
        func insertRecord(
            name: String, type: String, seqid: String,
            chromStart: Int, chromEnd: Int, strand: String,
            attrString: String?, blockCount: Int?,
            blockSizesStr: String?, blockStartsStr: String?,
            geneName: String?
        ) {
            sqlite3_reset(insertStmt)
            sqlite3_bind_text(insertStmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (type as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 3, (seqid as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(insertStmt, 4, Int64(chromStart))
            sqlite3_bind_int64(insertStmt, 5, Int64(chromEnd))
            sqlite3_bind_text(insertStmt, 6, (strand as NSString).utf8String, -1, nil)
            if let attrString {
                sqlite3_bind_text(insertStmt, 7, (attrString as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 7)
            }
            if let blockCount {
                sqlite3_bind_int64(insertStmt, 8, Int64(blockCount))
            } else {
                sqlite3_bind_null(insertStmt, 8)
            }
            if let blockSizesStr {
                sqlite3_bind_text(insertStmt, 9, (blockSizesStr as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 9)
            }
            if let blockStartsStr {
                sqlite3_bind_text(insertStmt, 10, (blockStartsStr as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 10)
            }
            if let geneName {
                sqlite3_bind_text(insertStmt, 11, (geneName as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 11)
            }

            if sqlite3_step(insertStmt) != SQLITE_DONE {
                dbLogger.warning("Failed to insert annotation: \(name)")
            }
            insertCount += 1
        }

        for feature in allFeatures {
            // Only index selected types
            guard indexableTypes.contains(feature.featureType) else { continue }

            let geneName = feature.attributes["gene"]

            // ── Same-ID merging: CDS features sharing a GFF3 ID are intervals of one CDS ──
            if let featureID = feature.id,
               let siblings = featuresByID[featureID],
               siblings.count > 1,
               feature.featureType == "CDS",
               !transcriptTypes.contains(feature.featureType) {

                // Already merged this ID? Skip.
                guard processedIDs.insert(featureID).inserted else { continue }

                // Merge all same-ID features into a single BED12 entry
                let siblingFeatures = siblings.map { allFeatures[$0] }

                // Compute merged span (0-based)
                let allStarts = siblingFeatures.map { $0.start - 1 }
                let allEnds = siblingFeatures.map { $0.end }
                var mergedStart = allStarts.min()!
                var mergedEnd = allEnds.max()!

                // Clip to chromosome boundaries
                if let chromSize = chromSizeMap?[feature.seqid] {
                    mergedStart = max(0, min(mergedStart, Int(chromSize)))
                    mergedEnd = max(mergedStart, min(mergedEnd, Int(chromSize)))
                }

                // Build BED12 blocks from sorted intervals
                let sortedIntervals = zip(allStarts, allEnds)
                    .map { (start: $0, end: $1) }
                    .sorted { $0.start < $1.start }

                var clippedBlocks: [(size: Int, start: Int)] = []
                for interval in sortedIntervals {
                    let clippedStart = max(interval.start, mergedStart)
                    let clippedEnd = min(interval.end, mergedEnd)
                    if clippedEnd > clippedStart {
                        clippedBlocks.append((
                            size: clippedEnd - clippedStart,
                            start: clippedStart - mergedStart
                        ))
                    }
                }

                let blockCount: Int?
                let blockSizesStr: String?
                let blockStartsStr: String?
                if clippedBlocks.count > 1 {
                    blockCount = clippedBlocks.count
                    blockSizesStr = clippedBlocks.map { "\($0.size)" }.joined(separator: ",")
                    blockStartsStr = clippedBlocks.map { "\($0.start)" }.joined(separator: ",")
                } else {
                    blockCount = nil
                    blockSizesStr = nil
                    blockStartsStr = nil
                }

                // Use attributes from the first occurrence
                let attrString = serializeAttributes(feature.attributes)

                // Deduplicate (using merged coordinates)
                let key = "\(feature.name)|\(feature.featureType)|\(feature.seqid)|\(mergedStart)|\(mergedEnd)"
                guard seenKeys.insert(key).inserted else { continue }

                insertRecord(
                    name: feature.name, type: feature.featureType, seqid: feature.seqid,
                    chromStart: mergedStart, chromEnd: mergedEnd, strand: feature.strand,
                    attrString: attrString, blockCount: blockCount,
                    blockSizesStr: blockSizesStr, blockStartsStr: blockStartsStr,
                    geneName: geneName
                )
                continue
            }

            // ── Transcript-level features: aggregate child exons into blocks ──
            let attrString = serializeAttributes(feature.attributes)

            var chromStart = feature.start - 1
            var chromEnd = feature.end
            if let chromSize = chromSizeMap?[feature.seqid] {
                chromStart = max(0, min(chromStart, Int(chromSize)))
                chromEnd = max(chromStart, min(chromEnd, Int(chromSize)))
            }

            var blockCount: Int? = nil
            var blockSizesStr: String? = nil
            var blockStartsStr: String? = nil

            if transcriptTypes.contains(feature.featureType),
               let featureID = feature.id,
               let childIndices = childrenByParent[featureID] {

                var exonIntervals: [(start: Int, end: Int)] = []
                var cdsIntervals: [(start: Int, end: Int)] = []

                for childIdx in childIndices {
                    let child = allFeatures[childIdx]
                    if exonTypes.contains(child.featureType) {
                        exonIntervals.append((start: child.start - 1, end: child.end))
                    } else if cdsTypes.contains(child.featureType) {
                        cdsIntervals.append((start: child.start - 1, end: child.end))
                    }
                }

                let blockIntervals = exonIntervals.isEmpty ? cdsIntervals : exonIntervals

                if blockIntervals.count > 1 {
                    let sortedIntervals = blockIntervals.sorted { $0.start < $1.start }

                    var clippedBlocks: [(size: Int, start: Int)] = []
                    for exon in sortedIntervals {
                        let clippedStart = max(exon.start, chromStart)
                        let clippedEnd = min(exon.end, chromEnd)
                        if clippedEnd > clippedStart {
                            clippedBlocks.append((size: clippedEnd - clippedStart, start: clippedStart - chromStart))
                        }
                    }

                    if clippedBlocks.count > 1 {
                        blockCount = clippedBlocks.count
                        blockSizesStr = clippedBlocks.map { "\($0.size)" }.joined(separator: ",")
                        blockStartsStr = clippedBlocks.map { "\($0.start)" }.joined(separator: ",")
                    }
                }
            }

            // Deduplicate
            let key = "\(feature.name)|\(feature.featureType)|\(feature.seqid)|\(chromStart)|\(chromEnd)"
            guard seenKeys.insert(key).inserted else { continue }

            insertRecord(
                name: feature.name, type: feature.featureType, seqid: feature.seqid,
                chromStart: chromStart, chromEnd: chromEnd, strand: feature.strand,
                attrString: attrString, blockCount: blockCount,
                blockSizesStr: blockSizesStr, blockStartsStr: blockStartsStr,
                geneName: geneName
            )
        }

        // Create indexes
        sqlite3_exec(db, "CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_type ON annotations(type)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_chrom ON annotations(chromosome)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_region ON annotations(chromosome, start, end)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX idx_annotations_gene_name ON annotations(gene_name COLLATE NOCASE)", nil, nil, nil)

        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        dbLogger.info("Created GFF3 annotation database with \(insertCount) records at \(outputURL.lastPathComponent)")
        return insertCount
    }

    /// Parses GFF3 attributes string into a dictionary.
    private static func parseGFF3Attributes(_ attributeString: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for pair in attributeString.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
                let value = String(kv[1])
                    .replacingOccurrences(of: "%3B", with: ";")
                    .replacingOccurrences(of: "%3D", with: "=")
                    .replacingOccurrences(of: "%26", with: "&")
                    .replacingOccurrences(of: "%2C", with: ",")
                    .replacingOccurrences(of: "%25", with: "%")
                attributes[key] = value
            }
        }
        return attributes
    }
}

// MARK: - Errors

// MARK: - Coordinate Transformation for Extraction

extension AnnotationDatabaseRecord {

    /// Transforms this record's coordinates from source chromosome space to
    /// extracted sequence space.
    ///
    /// Handles single-interval and multi-block (BED12) annotations. Clips intervals
    /// to the extraction region boundaries. Returns nil if the annotation is fully
    /// outside the extraction region after clipping.
    ///
    /// - Parameters:
    ///   - extractionStart: Effective start of the extraction region (0-based inclusive)
    ///   - extractionEnd: Effective end of the extraction region (0-based exclusive)
    ///   - isReverseComplement: Whether the extracted sequence was reverse-complemented
    ///   - newChromosome: Chromosome name in the new bundle (from .fai)
    /// - Returns: A new record with transformed coordinates, or nil if fully clipped away
    public func transformed(
        extractionStart: Int,
        extractionEnd: Int,
        isReverseComplement: Bool,
        newChromosome: String
    ) -> AnnotationDatabaseRecord? {
        let seqLength = extractionEnd - extractionStart

        // Parse blocks into absolute intervals
        var absoluteBlocks: [(start: Int, end: Int)]
        if let bc = blockCount, bc > 1,
           let sizes = blockSizes, let starts = blockStarts {
            let sizeArr = sizes.split(separator: ",").compactMap { Int($0) }
            let startArr = starts.split(separator: ",").compactMap { Int($0) }
            let count = min(bc, min(sizeArr.count, startArr.count))
            absoluteBlocks = (0..<count).map { i in
                (start: start + startArr[i], end: start + startArr[i] + sizeArr[i])
            }
        } else {
            absoluteBlocks = [(start: start, end: end)]
        }

        // Clip blocks to extraction region
        var clippedBlocks: [(start: Int, end: Int)] = []
        for block in absoluteBlocks {
            let clippedStart = max(block.start, extractionStart)
            let clippedEnd = min(block.end, extractionEnd)
            if clippedEnd > clippedStart {
                clippedBlocks.append((start: clippedStart, end: clippedEnd))
            }
        }

        guard !clippedBlocks.isEmpty else { return nil }

        // Transform to new coordinate system
        var transformedBlocks: [(start: Int, end: Int)]
        let newStrand: String

        if isReverseComplement {
            transformedBlocks = clippedBlocks.map { block in
                (start: extractionEnd - block.end, end: extractionEnd - block.start)
            }
            transformedBlocks.reverse()
            switch strand {
            case "+": newStrand = "-"
            case "-": newStrand = "+"
            default: newStrand = strand
            }
        } else {
            transformedBlocks = clippedBlocks.map { block in
                (start: block.start - extractionStart, end: block.end - extractionStart)
            }
            newStrand = strand
        }

        let newStart = transformedBlocks.map(\.start).min()!
        let newEnd = transformedBlocks.map(\.end).max()!

        // Recompute BED12 block fields relative to newStart
        let newBlockCount: Int?
        let newBlockSizes: String?
        let newBlockStarts: String?

        if transformedBlocks.count > 1 {
            newBlockCount = transformedBlocks.count
            newBlockSizes = transformedBlocks.map { "\($0.end - $0.start)" }.joined(separator: ",") + ","
            newBlockStarts = transformedBlocks.map { "\($0.start - newStart)" }.joined(separator: ",") + ","
        } else {
            newBlockCount = nil
            newBlockSizes = nil
            newBlockStarts = nil
        }

        return AnnotationDatabaseRecord(
            name: name,
            type: type,
            chromosome: newChromosome,
            start: newStart,
            end: newEnd,
            strand: newStrand,
            attributes: attributes,
            blockCount: newBlockCount,
            blockSizes: newBlockSizes,
            blockStarts: newBlockStarts,
            geneName: geneName
        )
    }

    /// Serializes this record as a BED12+ tab-separated line compatible with
    /// `AnnotationDatabase.createFromBED()`.
    ///
    /// Format: chrom, start, end, name, score, strand, thickStart, thickEnd, rgb,
    /// blockCount, blockSizes, blockStarts, type, attributes
    public func toBED12PlusLine() -> String {
        let bc = blockCount ?? 1
        let bs = blockSizes ?? "\(end - start),"
        let bst = blockStarts ?? "0,"

        let fields: [String] = [
            chromosome,
            "\(start)",
            "\(end)",
            name,
            "0",
            strand,
            "\(start)",
            "\(end)",
            "0,0,0",
            "\(bc)",
            bs,
            bst,
            type,
            attributes ?? ""
        ]
        return fields.joined(separator: "\t")
    }
}

public enum AnnotationDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case invalidSchema(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open annotation database: \(msg)"
        case .createFailed(let msg): return "Failed to create annotation database: \(msg)"
        case .invalidSchema(let msg): return "Invalid annotation database schema: \(msg)"
        }
    }
}
