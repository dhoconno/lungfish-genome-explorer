// VariantDatabase+Query.swift - Region queries
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

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
            variantDBBindText(stmt, idx, value)
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

        variantDBBindText(stmt, 1, chromosome)
        sqlite3_bind_int64(stmt, 2, Int64(end))
        sqlite3_bind_int64(stmt, 3, Int64(start))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Queries variants matching the per-sample smart-filter grammar.
    public func query(smartFilter text: String, limit: Int = 5000) throws -> [VariantDatabaseRecord] {
        try query(smartFilter: VariantSmartFilter.parse(text), limit: limit)
    }

    /// Queries variants matching a parsed per-sample smart-filter.
    public func query(smartFilter filter: VariantSmartFilter, limit: Int = 5000) throws -> [VariantDatabaseRecord] {
        guard let db else { return [] }
        let compiled = try filter.compileSQL(limit: limit)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, compiled.sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw VariantDatabaseError.openFailed(message)
        }
        for (index, binding) in compiled.bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .text(let value):
                variantDBBindText(stmt, parameterIndex, value)
            case .double(let value):
                sqlite3_bind_double(stmt, parameterIndex, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, parameterIndex, Int64(value))
            }
        }
        return readVariantRows(stmt: stmt!)
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
            let boundValue = op == .like ? SQLiteLikePattern.contains(value) : value
            bindings.append((valueParam, boundValue))

            let cast = "CAST(vi.value AS REAL)"
            let cmp: String
            switch op {
            case .gt:   cmp = "\(cast) > CAST(? AS REAL)"
            case .gte:  cmp = "\(cast) >= CAST(? AS REAL)"
            case .lt:   cmp = "\(cast) < CAST(? AS REAL)"
            case .lte:  cmp = "\(cast) <= CAST(? AS REAL)"
            case .eq:   cmp = "vi.value = ?"
            case .neq:  cmp = "vi.value != ?"
            case .like: cmp = "vi.value LIKE ? ESCAPE '\\'"
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
        smartFilter: VariantSmartFilter? = nil,
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
        var bindings: [(Int32, VariantSmartBinding)] = []
        var paramIndex: Int32 = 1

        if let chromosome {
            conditions.append("variants.chromosome = ?")
            bindings.append((paramIndex, .text(chromosome)))
            paramIndex += 1
        }

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ? ESCAPE '\\'")
            bindings.append((paramIndex, .text(SQLiteLikePattern.contains(nameFilter))))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, .text(t)))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.map { _ in "?" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, .text(sampleName)))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings.map { ($0.0, .text($0.1)) })
        }

        if let smartFilter {
            guard let compiledSmartFilter = try? smartFilter.compileSQLConditions() else { return [] }
            conditions.append(contentsOf: compiledSmartFilter.conditions)
            for binding in compiledSmartFilter.bindings {
                bindings.append((paramIndex, binding))
                paramIndex += 1
            }
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
            variantDBBindSmartBinding(stmt, idx, value)
        }

        return readVariantRows(stmt: stmt!)
    }

    /// Tracks which WHERE clauses are superseded by pre-materialized token JOINs.
    struct SupersededFilters {
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
        smartFilter: VariantSmartFilter? = nil,
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
        var bindings: [(Int32, VariantSmartBinding)] = []
        var paramIndex: Int32 = 1

        if let chromosome {
            conditions.append("variants.chromosome = ?")
            bindings.append((paramIndex, .text(chromosome)))
            paramIndex += 1
        }

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ? ESCAPE '\\'")
            bindings.append((paramIndex, .text(SQLiteLikePattern.contains(nameFilter))))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, .text(t)))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.map { _ in "?" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, .text(sampleName)))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings.map { ($0.0, .text($0.1)) })
        }

        if let smartFilter {
            guard let compiledSmartFilter = try? smartFilter.compileSQLConditions() else { return 0 }
            conditions.append(contentsOf: compiledSmartFilter.conditions)
            for binding in compiledSmartFilter.bindings {
                bindings.append((paramIndex, binding))
                paramIndex += 1
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (idx, value) in bindings {
            variantDBBindSmartBinding(stmt, idx, value)
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
        smartFilter: VariantSmartFilter? = nil,
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
        var bindings: [(Int32, VariantSmartBinding)] = [(1, .text(chromosome))]
        let intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("\(colPrefix)variant_id LIKE ?\(paramIndex) ESCAPE '\\'")
            bindings.append((paramIndex, .text(SQLiteLikePattern.contains(nameFilter))))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("\(colPrefix)variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, .text(t)))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, .text(sampleName)))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings.map { ($0.0, .text($0.1)) })
        }

        if let smartFilter {
            guard let compiledSmartFilter = try? smartFilter.compileSQLConditions() else { return [] }
            conditions.append(contentsOf: compiledSmartFilter.conditions)
            for binding in compiledSmartFilter.bindings {
                bindings.append((paramIndex, binding))
                paramIndex += 1
            }
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY \(colPrefix)chromosome, \(colPrefix)position LIMIT \(limit)"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        for (idx, value) in bindings {
            variantDBBindSmartBinding(stmt, idx, value)
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
        smartFilter: VariantSmartFilter? = nil,
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
        var bindings: [(Int32, VariantSmartBinding)] = [(1, .text(chromosome))]
        let intBindings: [(Int32, Int)] = [(2, end), (3, start)]
        var paramIndex: Int32 = 4

        if !nameFilter.isEmpty {
            conditions.append("variants.variant_id LIKE ?\(paramIndex) ESCAPE '\\'")
            bindings.append((paramIndex, .text(SQLiteLikePattern.contains(nameFilter))))
            paramIndex += 1
        }

        if !types.isEmpty && !supersededFilters.typesSuperseded {
            let placeholders = types.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("variants.variant_type IN (\(placeholders))")
            for t in types.sorted() {
                bindings.append((paramIndex, .text(t)))
                paramIndex += 1
            }
        }

        if !sampleNames.isEmpty {
            let sortedNames = sampleNames.sorted()
            let placeholders = sortedNames.enumerated().map { "?\(paramIndex + Int32($0.offset))" }.joined(separator: ",")
            conditions.append("EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND g.sample_name IN (\(placeholders)))")
            for sampleName in sortedNames {
                bindings.append((paramIndex, .text(sampleName)))
                paramIndex += 1
            }
        }

        for filter in effectiveInfoFilters {
            let (filterSQL, filterBindings) = filter.sqlCondition(paramIndex: &paramIndex)
            conditions.append(filterSQL)
            bindings.append(contentsOf: filterBindings.map { ($0.0, .text($0.1)) })
        }

        if let smartFilter {
            guard let compiledSmartFilter = try? smartFilter.compileSQLConditions() else { return 0 }
            conditions.append(contentsOf: compiledSmartFilter.conditions)
            for binding in compiledSmartFilter.bindings {
                bindings.append((paramIndex, binding))
                paramIndex += 1
            }
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        for (idx, value) in bindings {
            variantDBBindSmartBinding(stmt, idx, value)
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

        let sql = "SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants WHERE variant_id LIKE ? ESCAPE '\\' ORDER BY variant_id COLLATE NOCASE LIMIT ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        variantDBBindText(stmt, 1, SQLiteLikePattern.contains(idFilter))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        return readVariantRows(stmt: stmt!)
    }

}
