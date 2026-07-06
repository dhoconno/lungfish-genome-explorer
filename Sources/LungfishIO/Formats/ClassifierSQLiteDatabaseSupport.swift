// ClassifierSQLiteDatabaseSupport.swift - Shared SQLite build hardening helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

enum ClassifierSQLiteDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case validationFailed(String)
    case publishFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Classifier SQLite database open failed: \(message)"
        case .validationFailed(let message):
            return "Classifier SQLite database validation failed: \(message)"
        case .publishFailed(let message):
            return "Classifier SQLite database publish failed: \(message)"
        }
    }
}

enum ClassifierSQLiteDatabaseSupport {
    static let stateTableName = "lungfish_database_state"
    static let buildStateKey = "build_state"
    static let buildStateBuilding = "building"
    static let buildStateComplete = "complete"

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func stagingURL(for finalURL: URL) -> URL {
        SQLiteDatabasePublication.stagingURL(for: finalURL)
    }

    static func openWritableDatabase(at url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        removeSQLiteDatabase(at: url)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw ClassifierSQLiteDatabaseError.openFailed(message)
        }
        return db
    }

    static func configureForBulkImport(_ db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -65536", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY", nil, nil, nil)
    }

    static func markBuildState(_ state: String, db: OpaquePointer) throws {
        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS \(stateTableName) (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not ensure \(stateTableName): \(message)"
            )
        }

        let sql = "INSERT OR REPLACE INTO \(stateTableName) (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not prepare build_state update: \(message)"
            )
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, buildStateKey)
        bindText(stmt, 2, state)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not update build_state to \(state): \(message)"
            )
        }
    }

    static func finalizeSuccessfulBuild(
        db: OpaquePointer,
        requiredTables: [String],
        requiredIndexes: [String]
    ) throws {
        try runQuickCheck(db)
        try markBuildState(buildStateComplete, db: db)
        try validateReadyDatabase(
            db: db,
            requiredTables: requiredTables,
            requiredIndexes: requiredIndexes,
            allowLegacyMissingBuildState: false
        )
        try checkpointAndDisableWAL(db)
    }

    static func validateReadyDatabase(
        db: OpaquePointer,
        requiredTables: [String],
        requiredIndexes: [String],
        allowLegacyMissingBuildState: Bool = false
    ) throws {
        let tables = try sqliteMasterNames(db: db, type: "table")
        if tables.contains(stateTableName) {
            let buildState = try stateValue(db: db, key: buildStateKey)
            if buildState == buildStateComplete {
                // Explicitly completed current-format database.
            } else if buildState == nil, allowLegacyMissingBuildState {
                // Legacy databases can have the state table but predate build_state.
            } else {
                let observed = buildState ?? "missing"
                throw ClassifierSQLiteDatabaseError.validationFailed(
                    "\(stateTableName).\(buildStateKey) must be \(buildStateComplete), found \(observed)"
                )
            }
        } else if !allowLegacyMissingBuildState {
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Missing required tables: \(stateTableName)"
            )
        }

        let missingTables = requiredTables.filter { table in
            if table == stateTableName, allowLegacyMissingBuildState {
                return false
            }
            return !tables.contains(table)
        }
        guard missingTables.isEmpty else {
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Missing required tables: \(missingTables.sorted().joined(separator: ", "))"
            )
        }

        let indexes = try sqliteMasterNames(db: db, type: "index")
        let missingIndexes = requiredIndexes.filter { !indexes.contains($0) }
        guard missingIndexes.isEmpty else {
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Missing required indexes: \(missingIndexes.sorted().joined(separator: ", "))"
            )
        }
    }

    static func buildState(db: OpaquePointer) throws -> String? {
        let tables = try sqliteMasterNames(db: db, type: "table")
        guard tables.contains(stateTableName) else {
            return nil
        }
        return try stateValue(db: db, key: buildStateKey)
    }

    static func publish(stagingURL: URL, to finalURL: URL) throws {
        do {
            try SQLiteDatabasePublication.publish(stagingURL: stagingURL, to: finalURL)
        } catch {
            throw ClassifierSQLiteDatabaseError.publishFailed(error.localizedDescription)
        }
    }

    static func removeSQLiteDatabase(at url: URL) {
        SQLiteDatabasePublication.removeDatabase(at: url)
    }

    private static func runQuickCheck(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not run quick_check: \(message)"
            )
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let resultPointer = sqlite3_column_text(stmt, 0) else {
            throw ClassifierSQLiteDatabaseError.validationFailed("quick_check returned no result")
        }
        let result = String(cString: resultPointer)
        guard result == "ok" else {
            throw ClassifierSQLiteDatabaseError.validationFailed("quick_check failed: \(result)")
        }
    }

    private static func checkpointAndDisableWAL(_ db: OpaquePointer) throws {
        let checkpointResult = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            nil,
            nil
        )
        guard checkpointResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not checkpoint WAL: \(message)"
            )
        }
        guard sqlite3_exec(db, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not switch journal mode to DELETE: \(message)"
            )
        }
    }

    private static func stateValue(db: OpaquePointer, key: String) throws -> String? {
        let sql = "SELECT value FROM \(stateTableName) WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not read \(stateTableName).\(key): \(message)"
            )
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, key)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let valuePointer = sqlite3_column_text(stmt, 0) else {
                return nil
            }
            return String(cString: valuePointer)
        case SQLITE_DONE:
            return nil
        default:
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not read \(stateTableName).\(key): \(message)"
            )
        }
    }

    private static func sqliteMasterNames(db: OpaquePointer, type: String) throws -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClassifierSQLiteDatabaseError.validationFailed(
                "Could not inspect sqlite_master: \(message)"
            )
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, type)
        var names = Set<String>()
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let namePointer = sqlite3_column_text(stmt, 0) {
                    names.insert(String(cString: namePointer))
                }
            case SQLITE_DONE:
                return names
            default:
                let message = String(cString: sqlite3_errmsg(db))
                throw ClassifierSQLiteDatabaseError.validationFailed(
                    "Could not read sqlite_master \(type) names: \(message)"
                )
            }
        }
    }

    private static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        _ = text.withCString { cString in
            sqlite3_bind_text(stmt, index, cString, -1, transientDestructor)
        }
    }
}
