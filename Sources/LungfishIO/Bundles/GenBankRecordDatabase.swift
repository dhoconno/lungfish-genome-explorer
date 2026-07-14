// GenBankRecordDatabase.swift - Indexed GenBank record metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

/// A compact, queryable representation of record headers and feature qualifiers
/// from a multi-record GenBank reference.
public final class GenBankRecordDatabase: @unchecked Sendable {
    public struct FieldDefinition: Sendable, Equatable {
        public let key: String
        public let displayTitle: String
        public let valueType: String
        public let sourceCategory: String
        public let preferredOrder: Int

        public init(
            key: String,
            displayTitle: String,
            valueType: String,
            sourceCategory: String,
            preferredOrder: Int
        ) {
            self.key = key
            self.displayTitle = displayTitle
            self.valueType = valueType
            self.sourceCategory = sourceCategory
            self.preferredOrder = preferredOrder
        }
    }

    public struct RecordRow: Sendable, Equatable {
        public let id: Int64
        public let sequenceName: String
        public let sequenceLength: Int
        public let sourceOrdinal: Int
        /// Display-ready values. Distinct stored values are joined in source order.
        public let values: [String: String]

        public init(
            id: Int64,
            sequenceName: String,
            sequenceLength: Int,
            sourceOrdinal: Int,
            values: [String: String]
        ) {
            self.id = id
            self.sequenceName = sequenceName
            self.sequenceLength = sequenceLength
            self.sourceOrdinal = sourceOrdinal
            self.values = values
        }
    }

    public struct CreateResult: Sendable, Equatable {
        public let recordCount: Int
        public let fieldCount: Int

        public init(recordCount: Int, fieldCount: Int) {
            self.recordCount = recordCount
            self.fieldCount = fieldCount
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case openFailed(String)
        case invalidSchema(String)
        case unsupportedSchemaVersion(found: Int, expected: Int)
        case operationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                return "Unable to open GenBank record database: \(message)"
            case .invalidSchema(let message):
                return "Invalid GenBank record database schema: \(message)"
            case .unsupportedSchemaVersion(let found, let expected):
                return "Unsupported GenBank record database schema version \(found); expected \(expected)"
            case .operationFailed(let message):
                return "GenBank record database operation failed: \(message)"
            }
        }
    }

    public static let schemaVersion = 1
    private static let requiredTables = ["metadata", "records", "field_definitions", "field_values"]
    private static let requiredColumns: [String: Set<String>] = [
        "metadata": ["key", "value"],
        "records": ["id", "sequence_name", "sequence_length", "source_ordinal"],
        "field_definitions": ["key", "display_title", "value_type", "source_category", "preferred_order"],
        "field_values": ["record_id", "field_key", "value_ordinal", "value"]
    ]
    private static let requiredIndexes = ["idx_field_values_key_value", "idx_field_values_record_key"]
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public let databaseURL: URL
    private var database: OpaquePointer?

    public init(url: URL) throws {
        databaseURL = url
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let message = self.database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(self.database)
            self.database = nil
            throw Error.openFailed(message)
        }
        do {
            try Self.validateSchema(database)
        } catch {
            sqlite3_close(database)
            self.database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    /// Creates a new database, replacing an existing file at `url`.
    @discardableResult
    public static func create(records: [GenBankRecord], at url: URL) throws -> CreateResult {
        let recordValues = records.map(Self.collectValues)
        let definitions = makeFieldDefinitions(from: recordValues)
        let stagingURL = SQLiteDatabasePublication.stagingURL(for: url)
        defer { SQLiteDatabasePublication.removeDatabase(at: stagingURL) }

        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw Error.operationFailed("Create database directory: \(error.localizedDescription)")
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            stagingURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(database)
            throw Error.openFailed(message)
        }

        do {
            try execute(database, sql: "PRAGMA foreign_keys = ON")
            try execute(database, sql: schemaSQL)
            try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
            do {
                try insertMetadata(database)
                try insertDefinitions(definitions, database: database)
                try insertRecords(records, values: recordValues, database: database)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        } catch {
            sqlite3_close(database)
            throw error
        }

        guard sqlite3_close(database) == SQLITE_OK else {
            throw Error.operationFailed("Close staged database before publication")
        }
        do {
            try SQLiteDatabasePublication.publish(stagingURL: stagingURL, to: url)
        } catch {
            throw Error.operationFailed("Publish database: \(error.localizedDescription)")
        }

        return CreateResult(recordCount: records.count, fieldCount: definitions.count)
    }

    public func fieldDefinitions() throws -> [FieldDefinition] {
        guard let database else { throw Error.openFailed("Database is closed") }
        let sql = """
            SELECT key, display_title, value_type, source_category, preferred_order
            FROM field_definitions
            ORDER BY preferred_order, key COLLATE NOCASE, key
            """
        var statement: OpaquePointer?
        try Self.prepare(database, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var definitions: [FieldDefinition] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            definitions.append(FieldDefinition(
                key: Self.text(statement, column: 0),
                displayTitle: Self.text(statement, column: 1),
                valueType: Self.text(statement, column: 2),
                sourceCategory: Self.text(statement, column: 3),
                preferredOrder: Int(sqlite3_column_int64(statement, 4))
            ))
        }
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw Error.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return definitions
    }

    public func records() throws -> [RecordRow] {
        guard let database else { throw Error.openFailed("Database is closed") }
        let sql = """
            SELECT r.id, r.sequence_name, r.sequence_length, r.source_ordinal,
                   fv.field_key, fv.value
            FROM records r
            LEFT JOIN field_values fv ON fv.record_id = r.id
            LEFT JOIN field_definitions fd ON fd.key = fv.field_key
            ORDER BY r.source_ordinal, r.id, fd.preferred_order, fv.field_key COLLATE NOCASE, fv.value_ordinal
            """
        var statement: OpaquePointer?
        try Self.prepare(database, sql: sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        struct PendingRow {
            var id: Int64
            var sequenceName: String
            var sequenceLength: Int
            var sourceOrdinal: Int
            var values: [String: [String]]
        }
        var rows: [RecordRow] = []
        var pending: PendingRow?

        func appendPending() {
            guard let pending else { return }
            rows.append(RecordRow(
                id: pending.id,
                sequenceName: pending.sequenceName,
                sequenceLength: pending.sequenceLength,
                sourceOrdinal: pending.sourceOrdinal,
                values: pending.values.mapValues { $0.joined(separator: "; ") }
            ))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            if pending?.id != id {
                appendPending()
                pending = PendingRow(
                    id: id,
                    sequenceName: Self.text(statement, column: 1),
                    sequenceLength: Int(sqlite3_column_int64(statement, 2)),
                    sourceOrdinal: Int(sqlite3_column_int64(statement, 3)),
                    values: [:]
                )
            }
            if sqlite3_column_type(statement, 4) != SQLITE_NULL {
                let key = Self.text(statement, column: 4)
                pending?.values[key, default: []].append(Self.text(statement, column: 5))
            }
        }
        appendPending()
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw Error.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        return rows
    }

    private struct CollectedValues {
        var orderedKeys: [String] = []
        var valuesByKey: [String: [String]] = [:]
        private var seenValuesByKey: [String: Set<String>] = [:]

        mutating func append(key: String, values: [String]) {
            if valuesByKey[key] == nil {
                orderedKeys.append(key)
                valuesByKey[key] = []
                seenValuesByKey[key] = []
            }
            for value in values where seenValuesByKey[key, default: []].insert(value).inserted {
                valuesByKey[key, default: []].append(value)
            }
        }
    }

    private static func collectValues(from record: GenBankRecord) -> CollectedValues {
        var collected = CollectedValues()
        for field in record.recordFields.sorted(by: { $0.ordinal < $1.ordinal }) {
            collected.append(key: "record.\(field.key)", values: [field.value])
        }
        for annotation in record.annotations {
            for key in annotation.qualifiers.keys.sorted(by: caseInsensitiveLessThan) {
                collected.append(key: "feature.\(key)", values: annotation.qualifiers[key]?.values ?? [])
            }
        }
        return collected
    }

    private static func makeFieldDefinitions(from records: [CollectedValues]) -> [FieldDefinition] {
        var allValues: [String: [String]] = [:]
        for record in records {
            for key in record.orderedKeys {
                allValues[key, default: []].append(contentsOf: record.valuesByKey[key] ?? [])
            }
        }

        let sortedKeys = allValues.keys.sorted { lhs, rhs in
            let leftRank = preferredRank(for: lhs)
            let rightRank = preferredRank(for: rhs)
            if leftRank != rightRank { return leftRank < rightRank }
            return caseInsensitiveLessThan(lhs, rhs)
        }
        return sortedKeys.enumerated().map { index, key in
            let values = allValues[key] ?? []
            let nonEmpty = values.filter { !$0.isEmpty }
            let numeric = !nonEmpty.isEmpty && nonEmpty.allSatisfy { Double($0) != nil }
            return FieldDefinition(
                key: key,
                displayTitle: displayTitle(for: key),
                valueType: numeric ? "number" : "text",
                sourceCategory: key.hasPrefix("feature.") ? "feature" : "record",
                preferredOrder: index
            )
        }
    }

    private static func preferredRank(for key: String) -> Int {
        let preferred = [
            "feature.allele", "feature.gene", "record.DEFINITION", "record.ACCESSION",
            "record.ORGANISM", "feature.product",
            "record.LOCUS.NAME", "record.LOCUS.LENGTH", "record.LOCUS.MOLECULE_TYPE",
            "record.LOCUS.TOPOLOGY", "record.LOCUS.DIVISION", "record.LOCUS.DATE"
        ]
        if let index = preferred.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            return index
        }
        if key.lowercased().hasPrefix("record.locus.") { return preferred.count }
        return preferred.count + 1
    }

    private static func displayTitle(for key: String) -> String {
        let unnamespaced = key.split(separator: ".", maxSplits: 1).last.map(String.init) ?? key
        return unnamespaced
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { component in
                let lower = component.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func caseInsensitiveLessThan(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.compare(rhs, options: [.caseInsensitive, .numeric])
        return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
    }

    private static let schemaSQL = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE records (id INTEGER PRIMARY KEY, sequence_name TEXT NOT NULL UNIQUE, sequence_length INTEGER NOT NULL, source_ordinal INTEGER NOT NULL);
        CREATE TABLE field_definitions (key TEXT PRIMARY KEY, display_title TEXT NOT NULL, value_type TEXT NOT NULL, source_category TEXT NOT NULL, preferred_order INTEGER NOT NULL);
        CREATE TABLE field_values (record_id INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE, field_key TEXT NOT NULL REFERENCES field_definitions(key), value_ordinal INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY (record_id,field_key,value_ordinal));
        CREATE INDEX idx_field_values_key_value ON field_values(field_key,value COLLATE NOCASE);
        CREATE INDEX idx_field_values_record_key ON field_values(record_id,field_key);
        """

    private static func insertMetadata(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare(database, sql: "INSERT INTO metadata(key, value) VALUES (?, ?)", statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind("schema_version", to: statement, index: 1, database: database)
        try bind(String(schemaVersion), to: statement, index: 2, database: database)
        try stepDone(statement, database: database)
    }

    private static func insertDefinitions(_ definitions: [FieldDefinition], database: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare(database, sql: "INSERT INTO field_definitions(key, display_title, value_type, source_category, preferred_order) VALUES (?, ?, ?, ?, ?)", statement: &statement)
        defer { sqlite3_finalize(statement) }
        for definition in definitions {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(definition.key, to: statement, index: 1, database: database)
            try bind(definition.displayTitle, to: statement, index: 2, database: database)
            try bind(definition.valueType, to: statement, index: 3, database: database)
            try bind(definition.sourceCategory, to: statement, index: 4, database: database)
            sqlite3_bind_int64(statement, 5, Int64(definition.preferredOrder))
            try stepDone(statement, database: database)
        }
    }

    private static func insertRecords(
        _ records: [GenBankRecord],
        values: [CollectedValues],
        database: OpaquePointer
    ) throws {
        var recordStatement: OpaquePointer?
        var valueStatement: OpaquePointer?
        try prepare(database, sql: "INSERT INTO records(sequence_name, sequence_length, source_ordinal) VALUES (?, ?, ?)", statement: &recordStatement)
        try prepare(database, sql: "INSERT INTO field_values(record_id, field_key, value_ordinal, value) VALUES (?, ?, ?, ?)", statement: &valueStatement)
        defer {
            sqlite3_finalize(recordStatement)
            sqlite3_finalize(valueStatement)
        }

        for (sourceOrdinal, record) in records.enumerated() {
            sqlite3_reset(recordStatement)
            sqlite3_clear_bindings(recordStatement)
            try bind(record.sequence.name, to: recordStatement, index: 1, database: database)
            sqlite3_bind_int64(recordStatement, 2, Int64(record.sequence.length))
            sqlite3_bind_int64(recordStatement, 3, Int64(sourceOrdinal))
            try stepDone(recordStatement, database: database)
            let recordID = sqlite3_last_insert_rowid(database)

            for key in values[sourceOrdinal].orderedKeys {
                for (valueOrdinal, value) in (values[sourceOrdinal].valuesByKey[key] ?? []).enumerated() {
                    sqlite3_reset(valueStatement)
                    sqlite3_clear_bindings(valueStatement)
                    sqlite3_bind_int64(valueStatement, 1, recordID)
                    try bind(key, to: valueStatement, index: 2, database: database)
                    sqlite3_bind_int64(valueStatement, 3, Int64(valueOrdinal))
                    try bind(value, to: valueStatement, index: 4, database: database)
                    try stepDone(valueStatement, database: database)
                }
            }
        }
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        for table in requiredTables where !tableExists(database, name: table) {
            throw Error.invalidSchema("Missing required table: \(table)")
        }
        for table in requiredTables {
            let columns = columnsForTable(database, table: table)
            let missing = (requiredColumns[table] ?? []).subtracting(columns)
            guard missing.isEmpty else {
                throw Error.invalidSchema(
                    "\(table) table missing required columns: \(missing.sorted().joined(separator: ", "))"
                )
            }
        }
        var statement: OpaquePointer?
        try prepare(database, sql: "SELECT value FROM metadata WHERE key = 'schema_version' LIMIT 1", statement: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Error.invalidSchema("Missing metadata schema_version")
        }
        let versionText = text(statement, column: 0)
        guard let version = Int(versionText) else {
            throw Error.invalidSchema("Invalid metadata schema_version: \(versionText)")
        }
        guard version == schemaVersion else {
            throw Error.unsupportedSchemaVersion(found: version, expected: schemaVersion)
        }
        let missingIndexes = requiredIndexes.filter { !indexExists(database, name: $0) }
        guard missingIndexes.isEmpty else {
            throw Error.invalidSchema("Missing required indexes: \(missingIndexes.joined(separator: ", "))")
        }
    }

    private static func tableExists(_ database: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnsForTable(_ database: OpaquePointer, table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(statement, column: 1))
        }
        return columns
    }

    private static func indexExists(_ database: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw Error.operationFailed(message)
        }
    }

    private static func prepare(_ database: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer?, index: Int32, database: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw Error.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func stepDone(_ statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Error.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func text(_ statement: OpaquePointer?, column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
