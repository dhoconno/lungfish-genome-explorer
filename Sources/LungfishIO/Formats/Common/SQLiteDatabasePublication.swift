// SQLiteDatabasePublication.swift - Atomic publication helpers for SQLite outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

enum SQLiteDatabasePublicationError: Error, LocalizedError {
    case publishFailed(String)

    var errorDescription: String? {
        switch self {
        case .publishFailed(let message):
            return "SQLite database publish failed: \(message)"
        }
    }
}

enum SQLiteDatabasePublication {
    static func stagingURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(finalURL.lastPathComponent).\(UUID().uuidString).building",
                isDirectory: false
            )
    }

    static func publish(stagingURL: URL, to finalURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            checkpointAndRemoveSQLiteSidecars(at: stagingURL)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                checkpointAndRemoveSQLiteSidecars(at: finalURL)
                _ = try FileManager.default.replaceItemAt(
                    finalURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            }
            removeSQLiteSidecars(at: finalURL)
            removeSQLiteSidecars(at: stagingURL)
        } catch {
            throw SQLiteDatabasePublicationError.publishFailed(error.localizedDescription)
        }
    }

    static func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeSQLiteSidecars(at: url)
    }

    private static func checkpointAndRemoveSQLiteSidecars(at url: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
        sqlite3_close(db)
        removeSQLiteSidecars(at: url)
    }

    private static func removeSQLiteSidecars(at url: URL) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}
