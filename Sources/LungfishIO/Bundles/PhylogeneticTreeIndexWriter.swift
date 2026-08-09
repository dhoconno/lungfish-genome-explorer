import CryptoKit
import Foundation
import SQLite3

enum TreeIndexWriter {
    static func write(normalizedTree: PhylogeneticTreeNormalizedTree, to url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let db { sqlite3_close(db) }
            throw PhylogeneticTreeBundleError.sqliteIndexFailed(message)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE nodes (
          id TEXT PRIMARY KEY,
          parent_id TEXT,
          raw_label TEXT,
          display_label TEXT NOT NULL,
          is_tip INTEGER NOT NULL,
          branch_length REAL,
          cumulative_divergence REAL,
          descendant_tip_count INTEGER NOT NULL,
          metadata_json TEXT NOT NULL,
          support_raw TEXT,
          support_interpretation TEXT
        );
        CREATE INDEX nodes_parent_idx ON nodes(parent_id);
        CREATE INDEX nodes_tip_idx ON nodes(is_tip, display_label);
        """
        try exec(schema, db: db)
        try exec("BEGIN TRANSACTION", db: db)
        do {
            try exec(
                "INSERT INTO metadata(key, value) VALUES ('schemaVersion', '1'), ('treeID', '\(normalizedTree.treeID)')",
                db: db
            )
            let insertSQL = """
            INSERT INTO nodes(
              id, parent_id, raw_label, display_label, is_tip, branch_length,
              cumulative_divergence, descendant_tip_count, metadata_json,
              support_raw, support_interpretation
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw PhylogeneticTreeBundleError.sqliteIndexFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for node in normalizedTree.nodes {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, node.id)
                bindOptionalText(stmt, 2, node.parentID)
                bindOptionalText(stmt, 3, node.rawLabel)
                bindText(stmt, 4, node.displayLabel)
                sqlite3_bind_int(stmt, 5, node.isTip ? 1 : 0)
                bindOptionalDouble(stmt, 6, node.branchLength)
                bindOptionalDouble(stmt, 7, node.cumulativeDivergence)
                sqlite3_bind_int64(stmt, 8, Int64(node.descendantTipCount))
                let metadataJSON = String(data: try encoder.encode(node.metadata), encoding: .utf8) ?? "{}"
                bindText(stmt, 9, metadataJSON)
                bindOptionalText(stmt, 10, node.support?.rawValue)
                bindOptionalText(stmt, 11, node.support?.interpretation)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw PhylogeneticTreeBundleError.sqliteIndexFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw PhylogeneticTreeBundleError.sqliteIndexFailed(message)
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, sqliteTransientDestructor)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
