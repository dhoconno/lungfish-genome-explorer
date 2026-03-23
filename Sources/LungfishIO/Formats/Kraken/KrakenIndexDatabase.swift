// KrakenIndexDatabase.swift - SQLite index for Kraken2 per-read output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

/// Logger for Kraken index database operations.
private let logger = Logger(subsystem: LogSubsystem.io, category: "KrakenIndex")

// MARK: - Safe SQLite Text Binding

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
///
/// Uses `withCString` to keep the C string alive for the duration of the bind call,
/// combined with `SQLITE_TRANSIENT` so SQLite copies the bytes immediately.
/// This prevents dangling pointer bugs from temporary NSString conversions.
private func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

// MARK: - KrakenIndexDatabaseError

/// Errors that can occur during Kraken index database operations.
public enum KrakenIndexDatabaseError: Error, LocalizedError, Sendable {

    /// The database file could not be opened.
    case openFailed(String)

    /// The database could not be created during build.
    case buildFailed(String)

    /// The source Kraken2 output file could not be read.
    case sourceReadError(URL, String)

    /// The source Kraken2 output file is empty or contains no parseable lines.
    case emptySource

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "Failed to open Kraken index database: \(msg)"
        case .buildFailed(let msg):
            return "Failed to build Kraken index database: \(msg)"
        case .sourceReadError(let url, let detail):
            return "Cannot read Kraken2 output at \(url.lastPathComponent): \(detail)"
        case .emptySource:
            return "Kraken2 output file is empty or contains no parseable reads"
        }
    }
}

// MARK: - KrakenIndexDatabase

/// A SQLite sidecar index for Kraken2 per-read classification output files.
///
/// Kraken2 per-read output files can be very large (millions of reads). Loading
/// the entire file into memory to filter by taxonomy ID is expensive. This class
/// builds a SQLite index alongside the `.kraken` file, enabling instant lookups
/// of read IDs by taxonomy ID without loading the full file.
///
/// ## Schema
///
/// ```sql
/// CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
/// CREATE TABLE reads (
///     rowid INTEGER PRIMARY KEY,
///     read_id TEXT NOT NULL,
///     tax_id INTEGER NOT NULL,
///     read_length INTEGER NOT NULL,
///     classified INTEGER NOT NULL
/// );
/// CREATE INDEX idx_reads_tax_id ON reads(tax_id);
/// CREATE TABLE tax_counts (
///     tax_id INTEGER PRIMARY KEY,
///     read_count INTEGER NOT NULL
/// );
/// ```
///
/// ## Usage
///
/// ```swift
/// // Build an index for a Kraken2 output file
/// let krakenURL = URL(fileURLWithPath: "sample.kraken")
/// let indexURL = KrakenIndexDatabase.indexURL(for: krakenURL)
/// try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
///
/// // Query the index
/// let db = try KrakenIndexDatabase(url: indexURL)
/// let humanReads = try db.readIds(forTaxIds: [9606])
/// let counts = db.allTaxCounts()
/// db.close()
/// ```
///
/// ## Thread Safety
///
/// This class is `@unchecked Sendable`. The read-only path opens with
/// `SQLITE_OPEN_NOMUTEX` and is intended for single-threaded access from
/// whichever isolation domain owns the instance. The build path is a static
/// method that owns its connection for the duration of the build.
public final class KrakenIndexDatabase: @unchecked Sendable {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let url: URL

    // MARK: - Schema Constants

    private static let schemaVersion = "1"

    /// Batch size for bulk inserts during index building.
    private static let insertBatchSize = 50_000

    /// Buffer size for reading the source file (4 MB).
    private static let readBufferSize = 4 * 1024 * 1024

    // MARK: - Read API

    /// Opens an existing Kraken index database for reading.
    ///
    /// - Parameter url: URL to the `.kraken.idx.sqlite` file.
    /// - Throws: ``KrakenIndexDatabaseError/openFailed(_:)`` if the file cannot
    ///   be opened or does not contain a valid schema.
    public init(url: URL) throws {
        self.url = url
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            db = nil
            throw KrakenIndexDatabaseError.openFailed(msg)
        }
        logger.info("Opened Kraken index database: \(url.lastPathComponent, privacy: .public)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Closes the database connection.
    ///
    /// After calling this method, all query methods return empty results.
    /// It is safe to call this method multiple times.
    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    /// Returns the set of read IDs classified to any of the given taxonomy IDs.
    ///
    /// This query uses the `idx_reads_tax_id` index for efficient lookup.
    ///
    /// - Parameter taxIds: The set of taxonomy IDs to query.
    /// - Returns: A set of read ID strings.
    /// - Throws: ``KrakenIndexDatabaseError/openFailed(_:)`` if a query error
    ///   occurs.
    public func readIds(forTaxIds taxIds: Set<Int>) throws -> Set<String> {
        guard let db else { return [] }
        guard !taxIds.isEmpty else { return [] }

        var result = Set<String>()

        // Query one tax_id at a time to keep prepared statements simple and
        // leverage the index on tax_id.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "SELECT read_id FROM reads WHERE tax_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw KrakenIndexDatabaseError.openFailed("Query failed: \(msg)")
        }

        for taxId in taxIds {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(taxId))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    result.insert(String(cString: cStr))
                }
            }
        }

        return result
    }

    /// Returns the number of reads classified to the given taxonomy ID.
    ///
    /// Uses the pre-computed `tax_counts` table for O(1) lookup.
    ///
    /// - Parameter taxId: The taxonomy ID to query.
    /// - Returns: The read count, or 0 if the taxonomy ID is not present.
    public func readCount(forTaxId taxId: Int) -> Int {
        guard let db else { return 0 }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "SELECT read_count FROM tax_counts WHERE tax_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, Int64(taxId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns a dictionary mapping every taxonomy ID to its read count.
    ///
    /// Uses the pre-computed `tax_counts` table.
    ///
    /// - Returns: A dictionary of `[taxId: readCount]`.
    public func allTaxCounts() -> [Int: Int] {
        guard let db else { return [:] }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "SELECT tax_id, read_count FROM tax_counts"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }

        var counts: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let taxId = Int(sqlite3_column_int64(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            counts[taxId] = count
        }
        return counts
    }

    // MARK: - Build API

    /// Builds a SQLite index from a Kraken2 per-read output file.
    ///
    /// The build process:
    /// 1. Deletes any existing index at `indexURL`.
    /// 2. Creates the database with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`.
    /// 3. Sets WAL journal mode and synchronous = NORMAL for write performance.
    /// 4. Creates the schema (tables only, no indexes yet).
    /// 5. Reads the `.kraken` file with buffered 4 MB chunks.
    /// 6. Inserts in batches of 50,000 within explicit transactions.
    /// 7. Populates `tax_counts` from `reads` with `INSERT...SELECT...GROUP BY`.
    /// 8. Creates indexes (faster than maintaining during bulk insert).
    /// 9. Writes metadata rows.
    /// 10. Checkpoints WAL to collapse to a single file.
    /// 11. Closes the database.
    ///
    /// - Parameters:
    ///   - krakenURL: URL to the Kraken2 per-read output file.
    ///   - indexURL: URL for the SQLite index file to create.
    ///   - progress: Optional progress callback receiving (fraction, message).
    /// - Throws: ``KrakenIndexDatabaseError`` if the source file cannot be read
    ///   or the database cannot be created.
    public static func build(
        from krakenURL: URL,
        to indexURL: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        // Step 1: Delete existing index.
        try? FileManager.default.removeItem(at: indexURL)

        // Get source file size for progress reporting and metadata.
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: krakenURL.path)
        let sourceSize = (fileAttributes?[.size] as? Int64) ?? 0

        progress?(0.0, "Opening Kraken2 output...")

        // Step 2: Open database for writing.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(indexURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw KrakenIndexDatabaseError.buildFailed(msg)
        }
        defer { sqlite3_close(db) }

        // Step 3: Performance pragmas.
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA locking_mode = EXCLUSIVE", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size = -8192", nil, nil, nil)  // 8 MB page cache

        // Step 4: Create schema (tables only, indexes deferred).
        let schema = """
        CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE reads (
            rowid INTEGER PRIMARY KEY,
            read_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            read_length INTEGER NOT NULL,
            classified INTEGER NOT NULL
        );
        CREATE TABLE tax_counts (
            tax_id INTEGER PRIMARY KEY,
            read_count INTEGER NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, schema, nil, nil, &errMsg)
        if let errMsg {
            let msg = String(cString: errMsg)
            sqlite3_free(errMsg)
            throw KrakenIndexDatabaseError.buildFailed("Schema creation failed: \(msg)")
        }

        // Step 5 & 6: Read source file and insert in batches.
        progress?(0.05, "Parsing reads...")

        guard let fileHandle = FileHandle(forReadingAtPath: krakenURL.path) else {
            throw KrakenIndexDatabaseError.sourceReadError(
                krakenURL, "Cannot open file for reading"
            )
        }
        defer { fileHandle.closeFile() }

        // Prepare the insert statement.
        var insertStmt: OpaquePointer?
        let insertSQL = "INSERT INTO reads (read_id, tax_id, read_length, classified) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw KrakenIndexDatabaseError.buildFailed("Prepare insert failed: \(msg)")
        }
        defer { sqlite3_finalize(insertStmt) }

        var totalReads = 0
        var classifiedReads = 0
        var batchCount = 0
        var bytesRead: Int64 = 0
        var leftover = ""

        // Begin first transaction.
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        while true {
            let chunk = fileHandle.readData(ofLength: readBufferSize)
            if chunk.isEmpty && leftover.isEmpty { break }

            bytesRead += Int64(chunk.count)

            // Combine leftover from previous chunk with new data.
            let text: String
            if chunk.isEmpty {
                text = leftover
                leftover = ""
            } else {
                guard let chunkStr = String(data: chunk, encoding: .utf8) else {
                    continue
                }
                text = leftover + chunkStr
                leftover = ""
            }

            // Split into lines. The last element may be incomplete if the chunk
            // did not end on a newline boundary.
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)

            // If the chunk did not end with a newline, the last element is a
            // partial line -- save it for the next iteration.
            if !chunk.isEmpty && !text.hasSuffix("\n") && lines.count > 1 {
                leftover = String(lines.removeLast())
            } else if !chunk.isEmpty && lines.last?.isEmpty == true {
                // Trailing newline produces an empty final element -- remove it.
                lines.removeLast()
            }

            for line in lines {
                if line.isEmpty { continue }

                // Parse: C\treadId\ttaxId\tlength\tkmerHits
                // Split with maxSplits:3 since we only need first 4 columns.
                let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard columns.count >= 4 else { continue }

                let statusStr = columns[0]
                guard statusStr == "C" || statusStr == "U" else { continue }

                let classified: Int32 = statusStr == "C" ? 1 : 0
                let readId = String(columns[1])

                guard let taxId = Int64(columns[2]) else { continue }

                // Handle paired-end read lengths (e.g., "150|150").
                let lengthStr = columns[3]
                // The 4th column may contain more tabs (kmer hits follow),
                // but we split with maxSplits:3 so columns[3] is everything
                // after the third tab. We need just the length portion before
                // any further tab.
                let lengthPortion: Substring
                if let tabIdx = lengthStr.firstIndex(of: "\t") {
                    lengthPortion = lengthStr[lengthStr.startIndex..<tabIdx]
                } else {
                    lengthPortion = lengthStr[...]
                }
                let readLength: Int64
                if lengthPortion.contains("|") {
                    let parts = lengthPortion.split(separator: "|")
                    readLength = parts.compactMap { Int64($0) }.reduce(0, +)
                } else {
                    readLength = Int64(lengthPortion) ?? 0
                }

                // Bind and insert.
                sqlite3_reset(insertStmt)
                sqliteBindText(insertStmt, 1, readId)
                sqlite3_bind_int64(insertStmt, 2, taxId)
                sqlite3_bind_int64(insertStmt, 3, readLength)
                sqlite3_bind_int(insertStmt, 4, classified)

                let stepRC = sqlite3_step(insertStmt)
                if stepRC != SQLITE_DONE {
                    logger.warning("Insert failed for read: rc=\(stepRC)")
                    continue
                }

                totalReads += 1
                if classified == 1 { classifiedReads += 1 }
                batchCount += 1

                // Commit batch and start new transaction.
                if batchCount >= insertBatchSize {
                    sqlite3_exec(db, "COMMIT", nil, nil, nil)
                    sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
                    batchCount = 0

                    // Report progress based on bytes read.
                    if sourceSize > 0 {
                        let fraction = min(Double(bytesRead) / Double(sourceSize), 0.85)
                        progress?(fraction, "Indexed \(totalReads) reads...")
                    }
                }
            }

            // If the original chunk was empty, we processed leftover and are done.
            if chunk.isEmpty { break }
        }

        // Commit any remaining rows.
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        guard totalReads > 0 else {
            // Clean up the empty database file.
            // Note: db is closed by defer, so just remove the file afterward.
            throw KrakenIndexDatabaseError.emptySource
        }

        logger.info("Parsed \(totalReads) reads (\(classifiedReads) classified)")

        // Step 7: Populate tax_counts from reads.
        progress?(0.88, "Computing taxonomy counts...")
        let aggregateSQL = """
        INSERT INTO tax_counts (tax_id, read_count)
        SELECT tax_id, COUNT(*) FROM reads GROUP BY tax_id
        """
        sqlite3_exec(db, aggregateSQL, nil, nil, nil)

        // Step 8: Create indexes (faster to build after all inserts).
        progress?(0.92, "Building indexes...")
        sqlite3_exec(db, "CREATE INDEX idx_reads_tax_id ON reads(tax_id)", nil, nil, nil)

        // Step 9: Write metadata.
        progress?(0.96, "Writing metadata...")
        insertMetadataRow(db, key: "schema_version", value: schemaVersion)
        insertMetadataRow(db, key: "source_file", value: krakenURL.lastPathComponent)
        insertMetadataRow(db, key: "source_size", value: String(sourceSize))
        insertMetadataRow(db, key: "created_at", value: ISO8601DateFormatter().string(from: Date()))
        insertMetadataRow(db, key: "total_reads", value: String(totalReads))
        insertMetadataRow(db, key: "classified_reads", value: String(classifiedReads))

        // Step 10: Checkpoint WAL to collapse to a single file.
        progress?(0.98, "Finalizing...")
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)

        // Step 11: Close handled by defer.
        progress?(1.0, "Index complete: \(totalReads) reads")
        logger.info("Built Kraken index: \(totalReads) reads")
    }

    // MARK: - Staleness Check

    /// Checks whether the index at `indexURL` is valid for the given source file.
    ///
    /// Validity requires:
    /// 1. The index file exists.
    /// 2. The source file size matches the `source_size` stored in metadata.
    ///
    /// - Parameters:
    ///   - indexURL: URL to the index database file.
    ///   - krakenURL: URL to the source Kraken2 output file.
    /// - Returns: `true` if the index is valid and up-to-date.
    public static func isValid(at indexURL: URL, for krakenURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return false
        }

        // Open the index read-only to check metadata.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(indexURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        // Read stored source size.
        guard let storedSizeStr = readMetadataValue(db, key: "source_size"),
              let storedSize = Int64(storedSizeStr) else {
            return false
        }

        // Compare with current source file size.
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: krakenURL.path)
        guard let currentSize = fileAttributes?[.size] as? Int64 else {
            return false
        }

        return storedSize == currentSize
    }

    // MARK: - Index URL Convention

    /// Returns the conventional index URL for a given Kraken2 output file.
    ///
    /// For `sample.kraken`, the index is `sample.kraken.idx.sqlite`.
    ///
    /// - Parameter krakenURL: URL to the Kraken2 output file.
    /// - Returns: The URL where the index database should be stored.
    public static func indexURL(for krakenURL: URL) -> URL {
        krakenURL.appendingPathExtension("idx.sqlite")
    }

    // MARK: - Private Helpers

    /// Inserts a key-value pair into the db_metadata table.
    @discardableResult
    private static func insertMetadataRow(
        _ db: OpaquePointer,
        key: String,
        value: String
    ) -> Bool {
        let sql = "INSERT INTO db_metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqliteBindText(stmt, 1, key)
        sqliteBindText(stmt, 2, value)
        let stepRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return stepRC == SQLITE_DONE
    }

    /// Reads a value from the db_metadata table.
    private static func readMetadataValue(_ db: OpaquePointer, key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM db_metadata WHERE key = ?",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }
}
