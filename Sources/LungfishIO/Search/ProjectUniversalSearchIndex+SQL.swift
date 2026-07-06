// ProjectUniversalSearchIndex+SQL.swift - SQLite-backed project-scoped universal search catalog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

extension ProjectUniversalSearchIndex {

    // MARK: - Insert Helpers

    func insertEntity(
        _ row: EntityRow,
        attributes: [String: Any],
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let now = Int(Date().timeIntervalSince1970)

        var searchTerms: [String] = [row.title, row.kind, row.format ?? "", row.subtitle ?? ""]
        for (_, value) in attributes {
            if let text = valueAsString(value) {
                searchTerms.append(text)
            }
        }
        let searchText = searchTerms
            .joined(separator: " ")
            .lowercased()

        try execute(
            """
            INSERT OR REPLACE INTO us_entities (
                id, kind, title, subtitle, format, rel_path, url, mtime, size_bytes, indexed_at, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                row.id,
                row.kind,
                row.title,
                row.subtitle as Any,
                row.format as Any,
                row.relPath,
                row.url.path,
                row.mtime as Any,
                row.sizeBytes as Any,
                now,
                searchText,
            ]
        )

        entityCount += 1
        perKindCounts[row.kind, default: 0] += 1

        for (key, value) in attributes {
            try insertAttribute(entityID: row.id, key: key, value: value)
            attributeCount += 1
        }
    }

    func insertAttribute(entityID: String, key: String, value: Any) throws {
        guard let stringValue = valueAsString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stringValue.isEmpty else {
            return
        }

        let normalizedKey = normalizeKey(key)
        let normalizedValue = stringValue.lowercased()

        let numberValue: Double?
        if let directNumber = value as? NSNumber {
            numberValue = directNumber.doubleValue
        } else {
            numberValue = Double(normalizedValue)
        }

        let boolValue: Int?
        if let bool = value as? Bool {
            boolValue = bool ? 1 : 0
        } else if normalizedValue == "true" || normalizedValue == "yes" || normalizedValue == "1" {
            boolValue = 1
        } else if normalizedValue == "false" || normalizedValue == "no" || normalizedValue == "0" {
            boolValue = 0
        } else {
            boolValue = nil
        }

        let dateEpoch = parseDateEpochSeconds(value)

        let valueType: String
        if dateEpoch != nil {
            valueType = "date"
        } else if numberValue != nil {
            valueType = "number"
        } else if boolValue != nil {
            valueType = "bool"
        } else {
            valueType = "text"
        }

        try execute(
            """
            INSERT OR REPLACE INTO us_attributes (
                entity_id, key, value, number_value, date_value, bool_value, value_type
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                entityID,
                normalizedKey,
                normalizedValue,
                numberValue as Any,
                dateEpoch as Any,
                boolValue as Any,
                valueType,
            ]
        )
    }

    // MARK: - SQL

    func createSchemaIfNeeded() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT,
                format TEXT,
                rel_path TEXT NOT NULL,
                url TEXT NOT NULL,
                mtime REAL,
                size_bytes INTEGER,
                indexed_at INTEGER NOT NULL,
                search_text TEXT NOT NULL
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_attributes (
                entity_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                number_value REAL,
                date_value INTEGER,
                bool_value INTEGER,
                value_type TEXT NOT NULL,
                PRIMARY KEY(entity_id, key, value),
                FOREIGN KEY(entity_id) REFERENCES us_entities(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_kind ON us_entities(kind)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_format ON us_entities(format)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_rel_path ON us_entities(rel_path)")

        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_value ON us_attributes(key, value)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_number ON us_attributes(key, number_value)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_date ON us_attributes(key, date_value)")
    }

    func execute(_ sql: String, parameters: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }

        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            try bind(statement, index: Int32(index + 1), value: parameter)
        }

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }

        guard result == SQLITE_DONE else {
            throw databaseError()
        }
    }

    func queryRows(
        _ sql: String,
        parameters: [Any] = [],
        _ body: (OpaquePointer?) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            try bind(statement, index: Int32(index + 1), value: parameter)
        }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try body(statement)
                continue
            }
            if result == SQLITE_DONE {
                return
            }
            throw databaseError()
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try queryRows(sql) { stmt in
            value = Int(sqlite3_column_int64(stmt, 0))
        }
        return value
    }

    func setMetadata(key: String, value: String) throws {
        try execute(
            "INSERT OR REPLACE INTO us_metadata (key, value) VALUES (?, ?)",
            parameters: [key, value]
        )
    }

    func metadataValue(for key: String) throws -> String? {
        var value: String?
        try queryRows("SELECT value FROM us_metadata WHERE key = ? LIMIT 1", parameters: [key]) { stmt in
            if let text = sqlite3_column_text(stmt, 0) {
                value = String(cString: text)
            }
        }
        return value
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: Any) throws {
        let boundValue = unwrapOptional(value)
        let result: Int32
        switch boundValue {
        case nil, is NSNull:
            result = sqlite3_bind_null(statement, index)

        case let text as String:
            result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)

        case let int as Int:
            result = sqlite3_bind_int64(statement, index, Int64(int))

        case let int64 as Int64:
            result = sqlite3_bind_int64(statement, index, int64)

        case let double as Double:
            result = sqlite3_bind_double(statement, index, double)

        case let bool as Bool:
            result = sqlite3_bind_int(statement, index, bool ? 1 : 0)

        case let date as Date:
            result = sqlite3_bind_int64(statement, index, Int64(date.timeIntervalSince1970))

        default:
            result = sqlite3_bind_null(statement, index)
        }

        guard result == SQLITE_OK else {
            throw databaseError()
        }
    }

    private var SQLITE_TRANSIENT: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        return mirror.children.first?.value
    }

    private func databaseError() -> ProjectUniversalSearchError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .databaseQueryFailed(message)
    }
}
