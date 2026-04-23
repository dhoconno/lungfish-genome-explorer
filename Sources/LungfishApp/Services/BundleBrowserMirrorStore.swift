// BundleBrowserMirrorStore.swift - Project-local SQLite mirror for browser summaries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum BundleBrowserMirrorStoreError: Error, LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case encodeFailed(Error)
    case decodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .statementFailed(let message),
             .executionFailed(let message):
            return message
        case .encodeFailed(let error),
             .decodeFailed(let error):
            return error.localizedDescription
        }
    }
}

final class BundleBrowserMirrorStore {
    private let db: OpaquePointer
    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(projectURL: URL) throws {
        let cacheDirectoryURL = projectURL.appendingPathComponent(".lungfish-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)

        self.databaseURL = cacheDirectoryURL.appendingPathComponent("bundle-browser.sqlite")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open \(databaseURL.path)"
            sqlite3_close(handle)
            throw BundleBrowserMirrorStoreError.openFailed(message)
        }
        self.db = handle

        try execute(
            """
            CREATE TABLE IF NOT EXISTS browser_summaries (
                bundle_key TEXT PRIMARY KEY,
                summary_json BLOB NOT NULL,
                updated_at TEXT NOT NULL
            );
            """
        )
    }

    deinit {
        sqlite3_close(db)
    }

    func fetch(bundleKey: String) throws -> BundleBrowserSummary? {
        let statement = try prepare("SELECT summary_json FROM browser_summaries WHERE bundle_key = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }

        bindText(bundleKey, at: 1, into: statement)

        let step = sqlite3_step(statement)
        switch step {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            do {
                return try decoder.decode(BundleBrowserSummary.self, from: data)
            } catch {
                throw BundleBrowserMirrorStoreError.decodeFailed(error)
            }
        case SQLITE_DONE:
            return nil
        default:
            throw BundleBrowserMirrorStoreError.executionFailed(lastErrorMessage())
        }
    }

    func upsert(summary: BundleBrowserSummary, bundleKey: String) throws {
        let data: Data
        do {
            data = try encoder.encode(summary)
        } catch {
            throw BundleBrowserMirrorStoreError.encodeFailed(error)
        }

        let statement = try prepare(
            """
            INSERT INTO browser_summaries (bundle_key, summary_json, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(bundle_key) DO UPDATE SET
                summary_json = excluded.summary_json,
                updated_at = excluded.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(bundleKey, at: 1, into: statement)
        bindBlob(data, at: 2, into: statement)
        bindText(ISO8601DateFormatter().string(from: Date()), at: 3, into: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BundleBrowserMirrorStoreError.executionFailed(lastErrorMessage())
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw BundleBrowserMirrorStoreError.executionFailed(lastErrorMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BundleBrowserMirrorStoreError.statementFailed(lastErrorMessage())
        }
        return statement
    }

    private func bindText(_ value: String, at index: Int32, into statement: OpaquePointer?) {
        value.withCString { text in
            sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
        }
    }

    private func bindBlob(_ data: Data, at index: Int32, into statement: OpaquePointer?) {
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
