// AnnotationDatabase.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import os.log

/// Logger for annotation database operations
private let dbLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationDatabase")

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

    public init(name: String, type: String, chromosome: String, start: Int, end: Int, strand: String, attributes: String? = nil) {
        self.name = name
        self.type = type
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.strand = strand
        self.attributes = attributes
    }
}

// MARK: - AnnotationDatabase (Reader)

/// Reads annotation metadata from a SQLite database embedded in a .lungfishref bundle.
///
/// The database is created during bundle building and provides instant search/filter
/// over annotation names, types, and coordinates without scanning BigBed R-trees.
///
/// Schema (v2):
/// ```sql
/// CREATE TABLE annotations (
///     name TEXT NOT NULL,
///     type TEXT NOT NULL,
///     chromosome TEXT NOT NULL,
///     start INTEGER NOT NULL,
///     end INTEGER NOT NULL,
///     strand TEXT NOT NULL DEFAULT '.',
///     attributes TEXT
/// );
/// CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE);
/// CREATE INDEX idx_annotations_type ON annotations(type);
/// CREATE INDEX idx_annotations_chrom ON annotations(chromosome);
/// ```
public final class AnnotationDatabase: @unchecked Sendable {

    private var db: OpaquePointer?
    private let url: URL

    /// Whether the database has the `attributes` column (v2 schema).
    private let hasAttributesColumn: Bool

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

        // Detect schema version by checking if `attributes` column exists
        hasAttributesColumn = AnnotationDatabase.columnExists(db: db, table: "annotations", column: "attributes")

        dbLogger.info("Opened annotation database: \(url.lastPathComponent) (hasAttributes=\(self.hasAttributesColumn))")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Checks if a column exists in a table.
    private static func columnExists(db: OpaquePointer?, table: String, column: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT \(column) FROM \(table) LIMIT 0"
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
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

        var sql = "SELECT name, type, chromosome, start, end, strand FROM annotations"
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            conditions.append("name LIKE ?")
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

            results.append(AnnotationDatabaseRecord(
                name: name, type: type, chromosome: chrom,
                start: start, end: end, strand: strand
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
            conditions.append("name LIKE ?")
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
    /// Returns the full record including attributes (if the database has the v2 schema).
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

        let columns = hasAttributesColumn
            ? "name, type, chromosome, start, end, strand, attributes"
            : "name, type, chromosome, start, end, strand"

        let sql = "SELECT \(columns) FROM annotations WHERE name = ? AND chromosome = ? AND start = ? AND end = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (chromosome as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, Int64(start))
        sqlite3_bind_int64(stmt, 4, Int64(end))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let rName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let rType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let rChrom = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let rStart = Int(sqlite3_column_int64(stmt, 3))
        let rEnd = Int(sqlite3_column_int64(stmt, 4))
        let rStrand = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "."
        let rAttrs: String? = hasAttributesColumn
            ? sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            : nil

        return AnnotationDatabaseRecord(
            name: rName, type: rType, chromosome: rChrom,
            start: rStart, end: rEnd, strand: rStrand,
            attributes: rAttrs
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

        let columns = hasAttributesColumn
            ? "name, type, chromosome, start, end, strand, attributes"
            : "name, type, chromosome, start, end, strand"

        let sql = """
        SELECT \(columns)
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
            let rAttrs: String? = hasAttributesColumn
                ? sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                : nil

            results.append(AnnotationDatabaseRecord(
                name: rName, type: rType, chromosome: rChrom,
                start: rStart, end: rEnd, strand: rStrand,
                attributes: rAttrs
            ))
        }

        return results
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
    /// Only selected feature types are indexed (exons, introns, UTR are excluded).
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

        // Create schema (v2 with attributes column)
        let schema = """
        CREATE TABLE annotations (
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            chromosome TEXT NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            strand TEXT NOT NULL DEFAULT '.',
            attributes TEXT
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw AnnotationDatabaseError.createFailed(msg)
        }

        // Indexable types (gene-level only, matching AnnotationSearchIndex)
        let indexableTypes: Set<String> = [
            "gene", "mRNA", "transcript", "region", "promoter", "enhancer",
            "primer", "primer_pair", "amplicon", "SNP", "variation",
            "restriction_site", "repeat_region", "origin_of_replication",
            "misc_feature", "silencer", "terminator", "polyA_signal",
            // Protein processing
            "CDS", "mat_peptide", "sig_peptide", "transit_peptide",
            // UTRs
            "5'UTR", "3'UTR", "five_prime_UTR", "three_prime_UTR",
            // Regulatory & binding
            "regulatory", "ncRNA", "misc_binding", "protein_bind",
            // Structural
            "stem_loop",
            // GenBank raw key aliases
            "primer_bind",
        ]

        // Begin transaction for bulk insert
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let insertSQL = "INSERT INTO annotations (name, type, chromosome, start, end, strand, attributes) VALUES (?, ?, ?, ?, ?, ?, ?)"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed("Failed to prepare INSERT statement")
        }
        defer { sqlite3_finalize(insertStmt) }

        let content = try String(contentsOf: bedURL, encoding: .utf8)
        var insertCount = 0
        var seenKeys = Set<String>()

        for line in content.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { continue }

            let chrom = String(fields[0])
            let start = Int(fields[1]) ?? 0
            let end = Int(fields[2]) ?? 0
            let name = String(fields[3])

            guard !name.isEmpty, name != "unknown" else { continue }

            let strand = fields.count > 5 ? String(fields[5]) : "."

            // Extract type from column 12 (0-indexed) if present, otherwise infer
            let type: String
            if fields.count > 12 {
                type = String(fields[12])
            } else {
                type = "gene"
            }

            // Extract GFF3 attributes from column 13 if present
            let attributes: String?
            if fields.count > 13 {
                let attr = String(fields[13])
                attributes = attr.isEmpty ? nil : attr
            } else {
                attributes = nil
            }

            // Only index gene-level features
            guard indexableTypes.contains(type) else { continue }

            // Deduplicate by name+type+chrom+start+end (type included so gene and CDS
            // at the same coordinates are both kept)
            let key = "\(name)|\(type)|\(chrom)|\(start)|\(end)"
            guard seenKeys.insert(key).inserted else { continue }

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

        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        dbLogger.info("Created annotation database with \(insertCount) records at \(outputURL.lastPathComponent)")
        return insertCount
    }
}

// MARK: - Errors

public enum AnnotationDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open annotation database: \(msg)"
        case .createFailed(let msg): return "Failed to create annotation database: \(msg)"
        }
    }
}
