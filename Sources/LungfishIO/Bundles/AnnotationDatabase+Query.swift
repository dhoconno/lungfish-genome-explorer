// AnnotationDatabase+Query.swift - SQLite-backed annotation metadata database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

private let annotationSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AnnotationDatabase {

    /// Returns the total number of annotations in the database.
    public func totalCount(allowedChromosomes: Set<String>? = nil) -> Int {
        if allowedChromosomes?.isEmpty == true { return 0 }
        guard let db else { return 0 }

        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard prepareChromosomeScope(allowedChromosomes, db: db) else { return 0 }

        let scopePredicate = allowedChromosomes == nil
            ? ""
            : " WHERE EXISTS (SELECT 1 FROM query_chromosome_scope AS scope WHERE scope.chromosome = annotations.chromosome)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM annotations\(scopePredicate)", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns all distinct annotation type strings.
    public func allTypes(allowedChromosomes: Set<String>? = nil) -> [String] {
        if allowedChromosomes?.isEmpty == true { return [] }
        guard let db else { return [] }

        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard prepareChromosomeScope(allowedChromosomes, db: db) else { return [] }

        let scopePredicate = allowedChromosomes == nil
            ? ""
            : " WHERE EXISTS (SELECT 1 FROM query_chromosome_scope AS scope WHERE scope.chromosome = annotations.chromosome)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT DISTINCT type FROM annotations\(scopePredicate) ORDER BY type"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

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

        connectionLock.lock()
        defer { connectionLock.unlock() }

        var sql = """
        SELECT rowid, name, type, chromosome, start, end, strand, attributes,
               block_count, block_sizes, block_starts, gene_name
        FROM annotations
        """
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            let pattern = SQLiteLikePattern.contains(nameFilter)
            conditions.append("(name LIKE ? ESCAPE '\\' OR gene_name LIKE ? ESCAPE '\\')")
            bindings.append(pattern)
            bindings.append(pattern)
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
            results.append(AnnotationDatabase.decodeRecord(stmt))
        }

        return results
    }

    public func queryForTable(
        nameFilter: String = "",
        types: Set<String> = [],
        chromosome: String? = nil,
        regionStart: Int? = nil,
        regionEnd: Int? = nil,
        strand: String? = nil,
        columnFilters: [ColumnFilterClause] = [],
        allowedChromosomes: Set<String>? = nil,
        limit: Int = 5000
    ) -> [AnnotationDatabaseRecord] {
        if allowedChromosomes?.isEmpty == true { return [] }
        guard let db else { return [] }

        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard prepareChromosomeScope(allowedChromosomes, db: db) else { return [] }

        var sql = """
        SELECT rowid, name, type, chromosome, start, end, strand, attributes,
               block_count, block_sizes, block_starts, gene_name
        FROM annotations
        """
        let queryParts = annotationTableQueryParts(
            nameFilter: nameFilter,
            types: types,
            chromosome: chromosome,
            regionStart: regionStart,
            regionEnd: regionEnd,
            strand: strand,
            columnFilters: columnFilters
        )
        var conditions = queryParts.conditions
        if allowedChromosomes != nil {
            conditions.append(
                "EXISTS (SELECT 1 FROM query_chromosome_scope AS scope WHERE scope.chromosome = annotations.chromosome)"
            )
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY name COLLATE NOCASE"
        sql += " LIMIT \(max(0, limit))"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLogger.error("Failed to prepare table query: \(sql)")
            return []
        }

        for (i, binding) in queryParts.bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (binding as NSString).utf8String, -1, nil)
        }

        var results: [AnnotationDatabaseRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(AnnotationDatabase.decodeRecord(stmt))
        }

        return results
    }

    /// Replaces the connection-local chromosome scope using bound inserts.
    /// A savepoint provides transaction semantics without breaking an existing
    /// outer transaction on a read-write database.
    private func prepareChromosomeScope(_ chromosomes: Set<String>?, db: OpaquePointer) -> Bool {
        guard let chromosomes else { return true }

        let createSQL = """
        CREATE TEMP TABLE IF NOT EXISTS query_chromosome_scope (
            chromosome TEXT PRIMARY KEY
        )
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            dbLogger.error("Failed to create annotation chromosome scope table")
            return false
        }
        guard sqlite3_exec(db, "SAVEPOINT populate_query_chromosome_scope", nil, nil, nil) == SQLITE_OK else {
            dbLogger.error("Failed to begin annotation chromosome scope population")
            return false
        }

        var savepointOpen = true
        defer {
            if savepointOpen {
                sqlite3_exec(db, "ROLLBACK TO populate_query_chromosome_scope", nil, nil, nil)
                sqlite3_exec(db, "RELEASE populate_query_chromosome_scope", nil, nil, nil)
            }
        }

        guard sqlite3_exec(db, "DELETE FROM query_chromosome_scope", nil, nil, nil) == SQLITE_OK else {
            dbLogger.error("Failed to clear annotation chromosome scope")
            return false
        }

        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO query_chromosome_scope (chromosome) VALUES (?)",
            -1,
            &insertStatement,
            nil
        ) == SQLITE_OK else {
            dbLogger.error("Failed to prepare annotation chromosome scope insert")
            return false
        }

        for chromosome in chromosomes.sorted() {
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)
            sqlite3_bind_text(
                insertStatement,
                1,
                (chromosome as NSString).utf8String,
                -1,
                annotationSQLiteTransient
            )
            guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                dbLogger.error("Failed to insert an annotation chromosome scope value")
                return false
            }
        }

        guard sqlite3_exec(db, "RELEASE populate_query_chromosome_scope", nil, nil, nil) == SQLITE_OK else {
            dbLogger.error("Failed to commit annotation chromosome scope population")
            return false
        }
        savepointOpen = false
        return true
    }

    /// Returns the count of annotations matching the given filters (without fetching rows).
    public func queryCount(nameFilter: String = "", types: Set<String> = []) -> Int {
        guard let db else { return 0 }

        connectionLock.lock()
        defer { connectionLock.unlock() }

        var sql = "SELECT COUNT(*) FROM annotations"
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            let pattern = SQLiteLikePattern.contains(nameFilter)
            conditions.append("(name LIKE ? ESCAPE '\\' OR gene_name LIKE ? ESCAPE '\\')")
            bindings.append(pattern)
            bindings.append(pattern)
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

    public func queryCountForTable(
        nameFilter: String = "",
        types: Set<String> = [],
        chromosome: String? = nil,
        regionStart: Int? = nil,
        regionEnd: Int? = nil,
        strand: String? = nil,
        columnFilters: [ColumnFilterClause] = []
    ) -> Int {
        guard let db else { return 0 }

        connectionLock.lock()
        defer { connectionLock.unlock() }

        var sql = "SELECT COUNT(*) FROM annotations"
        let queryParts = annotationTableQueryParts(
            nameFilter: nameFilter,
            types: types,
            chromosome: chromosome,
            regionStart: regionStart,
            regionEnd: regionEnd,
            strand: strand,
            columnFilters: columnFilters
        )
        if !queryParts.conditions.isEmpty {
            sql += " WHERE " + queryParts.conditions.joined(separator: " AND ")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (i, binding) in queryParts.bindings.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (binding as NSString).utf8String, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func annotationTableQueryParts(
        nameFilter: String,
        types: Set<String>,
        chromosome: String?,
        regionStart: Int?,
        regionEnd: Int?,
        strand: String?,
        columnFilters: [ColumnFilterClause]
    ) -> (conditions: [String], bindings: [String]) {
        var conditions: [String] = []
        var bindings: [String] = []

        if !nameFilter.isEmpty {
            let pattern = SQLiteLikePattern.contains(nameFilter)
            conditions.append("(name LIKE ? ESCAPE '\\' OR gene_name LIKE ? ESCAPE '\\')")
            bindings.append(pattern)
            bindings.append(pattern)
        }
        if !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append(t)
            }
        }
        if let chromosome, !chromosome.isEmpty {
            conditions.append("chromosome = ? COLLATE NOCASE")
            bindings.append(chromosome)
        }
        if let regionStart {
            conditions.append("end > ?")
            bindings.append("\(regionStart)")
        }
        if let regionEnd {
            conditions.append("start < ?")
            bindings.append("\(regionEnd)")
        }
        if let strand, !strand.isEmpty {
            conditions.append("strand = ? COLLATE NOCASE")
            bindings.append(strand)
        }
        for filter in columnFilters {
            appendAnnotationColumnFilter(filter, conditions: &conditions, bindings: &bindings)
        }

        return (conditions, bindings)
    }

    private func appendAnnotationColumnFilter(
        _ filter: ColumnFilterClause,
        conditions: inout [String],
        bindings: inout [String]
    ) {
        switch filter.key {
        case "name":
            appendTextColumnFilter("name", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "type":
            appendTextColumnFilter("type", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "chromosome":
            appendTextColumnFilter("chromosome", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "strand":
            appendTextColumnFilter("strand", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "start":
            appendNumericColumnFilter("start", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "end":
            appendNumericColumnFilter("end", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        case "size":
            appendNumericColumnFilter("(end - start)", op: filter.op, value: filter.value, conditions: &conditions, bindings: &bindings)
        default:
            break
        }
    }

    private func appendTextColumnFilter(
        _ column: String,
        op: String,
        value: String,
        conditions: inout [String],
        bindings: inout [String]
    ) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch op {
        case "=":
            if normalized.isEmpty {
                conditions.append("(\(column) IS NULL OR \(column) = '')")
            } else {
                conditions.append("\(column) = ? COLLATE NOCASE")
                bindings.append(normalized)
            }
        case "!=":
            if normalized.isEmpty {
                conditions.append("(\(column) IS NOT NULL AND \(column) != '')")
            } else {
                conditions.append("\(column) != ? COLLATE NOCASE")
                bindings.append(normalized)
            }
        case "!~":
            guard !normalized.isEmpty else { return }
            conditions.append("\(column) COLLATE NOCASE NOT LIKE ? ESCAPE '\\'")
            bindings.append(SQLiteLikePattern.contains(normalized))
        case "^=":
            guard !normalized.isEmpty else { return }
            conditions.append("\(column) COLLATE NOCASE LIKE ? ESCAPE '\\'")
            bindings.append(SQLiteLikePattern.prefix(normalized))
        case "$=":
            guard !normalized.isEmpty else { return }
            conditions.append("\(column) COLLATE NOCASE LIKE ? ESCAPE '\\'")
            bindings.append(SQLiteLikePattern.suffix(normalized))
        default:
            guard !normalized.isEmpty else { return }
            conditions.append("\(column) COLLATE NOCASE LIKE ? ESCAPE '\\'")
            bindings.append(SQLiteLikePattern.contains(normalized))
        }
    }

    private func appendNumericColumnFilter(
        _ expression: String,
        op: String,
        value: String,
        conditions: inout [String],
        bindings: inout [String]
    ) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            if op == "=" {
                conditions.append("1 = 0")
            }
            return
        }
        guard Double(normalized) != nil else {
            conditions.append("CAST(\(expression) AS TEXT) COLLATE NOCASE LIKE ? ESCAPE '\\'")
            bindings.append(SQLiteLikePattern.contains(normalized))
            return
        }

        switch op {
        case ">":
            conditions.append("\(expression) > ?")
        case ">=":
            conditions.append("\(expression) >= ?")
        case "<":
            conditions.append("\(expression) < ?")
        case "<=":
            conditions.append("\(expression) <= ?")
        case "!=":
            conditions.append("\(expression) != ?")
        default:
            conditions.append("\(expression) = ?")
        }
        bindings.append(normalized)
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

        connectionLock.lock()
        defer { connectionLock.unlock() }

        // v4 schema: fixed column order
        let sql = """
        SELECT rowid, name, type, chromosome, start, end, strand, attributes,
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

        return AnnotationDatabase.decodeRecord(stmt)
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

        connectionLock.lock()
        defer { connectionLock.unlock() }

        // v4 schema: fixed column order
        let sql = """
        SELECT rowid, name, type, chromosome, start, end, strand, attributes,
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
            results.append(AnnotationDatabase.decodeRecord(stmt))
        }

        return results
    }

    /// Returns all chromosome names present in the annotations table.
    public func allChromosomes() -> [String] {
        guard let db else { return [] }

        connectionLock.lock()
        defer { connectionLock.unlock() }
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
}
