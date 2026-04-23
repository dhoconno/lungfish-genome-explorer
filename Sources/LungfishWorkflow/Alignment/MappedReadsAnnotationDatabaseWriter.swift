// MappedReadsAnnotationDatabaseWriter.swift - SQLite writer for mapped-read annotations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import SQLite3

public enum MappedReadsAnnotationDatabaseWriter {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    public static func write(
        rows: [MappedReadsAnnotationRow],
        to outputURL: URL,
        metadata: [String: String] = [:]
    ) throws -> Int {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        var db: OpaquePointer?
        let rc = sqlite3_open(outputURL.path, &db)
        guard rc == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw AnnotationDatabaseError.createFailed(message)
        }
        defer { sqlite3_close(db) }

        try execute(
            """
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
            """,
            db: db
        )

        try insertMetadata(["schema_version": "4"].merging(metadata) { _, new in new }, into: db)
        try execute("BEGIN TRANSACTION", db: db)

        let insertSQL = """
        INSERT INTO annotations
            (name, type, chromosome, start, end, strand, attributes, block_count, block_sizes, block_starts, gene_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed("Failed to prepare annotation INSERT: \(sqliteError(db))")
        }
        defer { sqlite3_finalize(insertStmt) }

        var insertedCount = 0
        do {
            for row in rows {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)
                bindText(insertStmt, 1, row.name)
                bindText(insertStmt, 2, row.type)
                bindText(insertStmt, 3, row.chromosome)
                sqlite3_bind_int64(insertStmt, 4, Int64(row.start))
                sqlite3_bind_int64(insertStmt, 5, Int64(row.end))
                bindText(insertStmt, 6, row.strand)
                let serializedAttributes = serializeAttributes(row.attributes)
                if serializedAttributes.isEmpty {
                    sqlite3_bind_null(insertStmt, 7)
                } else {
                    bindText(insertStmt, 7, serializedAttributes)
                }
                sqlite3_bind_null(insertStmt, 8)
                sqlite3_bind_null(insertStmt, 9)
                sqlite3_bind_null(insertStmt, 10)
                if let geneName = row.attributes["gene"] {
                    bindText(insertStmt, 11, geneName)
                } else {
                    sqlite3_bind_null(insertStmt, 11)
                }

                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw AnnotationDatabaseError.createFailed("Failed to insert annotation '\(row.name)': \(sqliteError(db))")
                }
                insertedCount += 1
            }

            try execute("COMMIT", db: db)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }

        try execute("CREATE INDEX idx_annotations_name ON annotations(name COLLATE NOCASE)", db: db)
        try execute("CREATE INDEX idx_annotations_type ON annotations(type)", db: db)
        try execute("CREATE INDEX idx_annotations_chrom ON annotations(chromosome)", db: db)
        try execute("CREATE INDEX idx_annotations_region ON annotations(chromosome, start, end)", db: db)
        try execute("CREATE INDEX idx_annotations_gene_name ON annotations(gene_name COLLATE NOCASE)", db: db)

        return insertedCount
    }

    public static func serializeAttributes(_ attributes: [String: String]) -> String {
        attributes
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(percentEncodeAttributeValue(value))"
            }
            .joined(separator: ";")
    }

    private static func insertMetadata(_ metadata: [String: String], into db: OpaquePointer) throws {
        let sql = "INSERT OR REPLACE INTO db_metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw AnnotationDatabaseError.createFailed("Failed to prepare metadata INSERT: \(sqliteError(db))")
        }
        defer { sqlite3_finalize(stmt) }

        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw AnnotationDatabaseError.createFailed("Failed to insert metadata '\(key)': \(sqliteError(db))")
            }
        }
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message: String
            if let errMsg {
                message = String(cString: errMsg)
                sqlite3_free(errMsg)
            } else {
                message = sqliteError(db)
            }
            throw AnnotationDatabaseError.createFailed(message)
        }
    }

    private static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private static func sqliteError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func percentEncodeAttributeValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
