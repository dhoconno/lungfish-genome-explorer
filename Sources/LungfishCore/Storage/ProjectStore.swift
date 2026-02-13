// ProjectStore.swift - SQLite-based project persistence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import SQLite3
import os.log

// MARK: - ProjectStore

/// SQLite-based storage for Lungfish project data.
///
/// ProjectStore provides efficient, disk-based persistence for:
/// - Genomic sequences with diff-based version tracking
/// - Annotations and their relationships to sequences
/// - Project metadata and settings
/// - Edit history across sessions
///
/// ## Design Philosophy
///
/// Rather than storing full sequence copies for each version, we store:
/// 1. The original sequence once
/// 2. Compact diffs (VCF-like deltas) for each change
/// 3. Content hashes for integrity verification
///
/// This approach is inspired by git's object storage model and can reduce
/// storage requirements by 90%+ for typical editing workflows.
///
/// ## Example
///
/// ```swift
/// let store = try ProjectStore(at: projectURL)
///
/// // Store a sequence
/// let sequenceId = try store.storeSequence(
///     name: "chr1",
///     content: sequenceData,
///     metadata: ["organism": "Homo sapiens"]
/// )
///
/// // Record an edit
/// try store.recordEdit(
///     sequenceId: sequenceId,
///     diff: diff,
///     message: "Fixed SNP at position 12345"
/// )
///
/// // Retrieve version history
/// let history = try store.getVersionHistory(for: sequenceId)
/// ```
@MainActor
public final class ProjectStore {

    // MARK: - Properties

    /// The project directory URL
    public let projectURL: URL

    /// The SQLite database connection
    /// Note: nonisolated(unsafe) is needed because deinit in Swift 6 requires access to this
    /// for cleanup, but OpaquePointer is not Sendable. The db is only accessed from MainActor.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Logger for store operations
    private static let logger = Logger(
        subsystem: "com.lungfish.browser",
        category: "ProjectStore"
    )

    /// Schema version for migrations
    private static let schemaVersion = 1

    // MARK: - Initialization

    /// Creates or opens a project store at the specified location.
    ///
    /// - Parameter url: The project directory URL
    /// - Throws: `ProjectStoreError` if the store cannot be created or opened
    public init(at url: URL) throws {
        self.projectURL = url

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        // Migrate from old project.db to hidden .project.db if needed
        let legacyDBPath = url.appendingPathComponent("project.db")
        let hiddenDBPath = url.appendingPathComponent(".project.db")
        
        if FileManager.default.fileExists(atPath: legacyDBPath.path) &&
           !FileManager.default.fileExists(atPath: hiddenDBPath.path) {
            do {
                try FileManager.default.moveItem(at: legacyDBPath, to: hiddenDBPath)
                Self.logger.info("ProjectStore: Migrated project.db to .project.db")
            } catch {
                Self.logger.warning("ProjectStore: Failed to migrate database: \(error.localizedDescription, privacy: .public)")
                // Fall back to legacy path if migration fails
            }
        }

        // Open database (prefer hidden, fall back to legacy)
        let dbPath: String
        if FileManager.default.fileExists(atPath: hiddenDBPath.path) {
            dbPath = hiddenDBPath.path
        } else if FileManager.default.fileExists(atPath: legacyDBPath.path) {
            dbPath = legacyDBPath.path
        } else {
            // New project - use hidden path
            dbPath = hiddenDBPath.path
        }

        var dbPointer: OpaquePointer?
        let result = sqlite3_open_v2(
            dbPath,
            &dbPointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let db = dbPointer else {
            let message = String(cString: sqlite3_errmsg(dbPointer))
            throw ProjectStoreError.databaseError(message: "Failed to open database: \(message)")
        }

        self.db = db

        // Configure SQLite for performance
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA cache_size = -64000") // 64MB cache

        // Initialize schema
        try initializeSchema()

        Self.logger.info("Opened project store at \(url.path, privacy: .public)")
    }

    deinit {
        if let db = db {
            // Checkpoint WAL to reclaim disk space before closing
            var walFrameCount: Int32 = 0
            var checkpointedFrames: Int32 = 0
            sqlite3_wal_checkpoint_v2(
                db,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &walFrameCount,
                &checkpointedFrames
            )
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Schema Management

    private func initializeSchema() throws {
        let currentVersion = try getSchemaVersion()

        if currentVersion < Self.schemaVersion {
            try createTables()
            try setSchemaVersion(Self.schemaVersion)
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
        try query("PRAGMA user_version") { stmt in
            version = Int(sqlite3_column_int(stmt, 0))
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    private func createTables() throws {
        // Sequences table - stores original sequence content
        try execute("""
            CREATE TABLE IF NOT EXISTS sequences (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                original_content BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                alphabet TEXT NOT NULL DEFAULT 'dna',
                length INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                modified_at TEXT NOT NULL DEFAULT (datetime('now')),
                metadata TEXT
            )
        """)

        // Versions table - stores version snapshots with diffs
        try execute("""
            CREATE TABLE IF NOT EXISTS versions (
                id TEXT PRIMARY KEY,
                sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
                version_number INTEGER NOT NULL,
                parent_hash TEXT,
                content_hash TEXT NOT NULL,
                diff_data BLOB NOT NULL,
                message TEXT,
                author TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                metadata TEXT,
                UNIQUE(sequence_id, version_number),
                UNIQUE(sequence_id, content_hash)
            )
        """)

        // Version chain index for efficient history traversal
        try execute("""
            CREATE INDEX IF NOT EXISTS idx_versions_sequence
            ON versions(sequence_id, version_number ASC)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_versions_parent
            ON versions(parent_hash)
        """)

        // Annotations table
        try execute("""
            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY,
                sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                name TEXT NOT NULL,
                start_position INTEGER NOT NULL,
                end_position INTEGER NOT NULL,
                strand TEXT DEFAULT '+',
                qualifiers TEXT,
                color TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                modified_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_annotations_sequence
            ON annotations(sequence_id, start_position)
        """)

        // Current state table - tracks which version is checked out
        try execute("""
            CREATE TABLE IF NOT EXISTS current_state (
                sequence_id TEXT PRIMARY KEY REFERENCES sequences(id) ON DELETE CASCADE,
                version_hash TEXT,
                version_index INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Project metadata table
        try execute("""
            CREATE TABLE IF NOT EXISTS project_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)

        // Edit log for audit trail
        try execute("""
            CREATE TABLE IF NOT EXISTS edit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
                operation TEXT NOT NULL,
                position INTEGER,
                length INTEGER,
                bases TEXT,
                timestamp TEXT NOT NULL DEFAULT (datetime('now')),
                session_id TEXT
            )
        """)

        Self.logger.info("Database schema initialized (version \(Self.schemaVersion))")
    }

    // MARK: - Sequence Operations

    /// Stores a new sequence in the project.
    ///
    /// - Parameters:
    ///   - name: The sequence name
    ///   - content: The sequence content
    ///   - alphabet: The sequence alphabet (dna, rna, protein)
    ///   - metadata: Optional metadata dictionary
    /// - Returns: The sequence ID
    @discardableResult
    public func storeSequence(
        name: String,
        content: String,
        alphabet: String = "dna",
        metadata: [String: String]? = nil
    ) throws -> UUID {
        let id = UUID()
        let contentHash = computeHash(content)
        let metadataJSON = try metadata.map { try JSONEncoder().encode($0) }

        try execute("""
            INSERT INTO sequences (id, name, original_content, content_hash, alphabet, length, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            id.uuidString,
            name,
            content.data(using: .utf8)!,
            contentHash,
            alphabet,
            content.count,
            metadataJSON as Any
        ])

        // Initialize current state
        try execute("""
            INSERT INTO current_state (sequence_id, version_hash, version_index)
            VALUES (?, NULL, 0)
        """, parameters: [id.uuidString])

        Self.logger.info("Stored sequence '\(name, privacy: .public)' with ID \(id.uuidString)")
        return id
    }

    /// Retrieves a sequence by ID.
    ///
    /// - Parameter id: The sequence ID
    /// - Returns: The sequence content and metadata, or nil if not found
    public func getSequence(id: UUID) throws -> StoredSequence? {
        var result: StoredSequence?

        try query("""
            SELECT s.id, s.name, s.original_content, s.content_hash, s.alphabet, s.length, s.metadata,
                   cs.version_hash, cs.version_index
            FROM sequences s
            LEFT JOIN current_state cs ON s.id = cs.sequence_id
            WHERE s.id = ?
        """, parameters: [id.uuidString]) { stmt in
            result = try parseStoredSequence(from: stmt)
        }

        return result
    }

    /// Lists all sequences in the project.
    public func listSequences() throws -> [SequenceSummary] {
        var results: [SequenceSummary] = []

        try query("""
            SELECT s.id, s.name, s.alphabet, s.length, s.created_at, s.modified_at,
                   (SELECT COUNT(*) FROM versions v WHERE v.sequence_id = s.id) as version_count
            FROM sequences s
            ORDER BY s.name
        """) { stmt in
            let summary = SequenceSummary(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!,
                name: String(cString: sqlite3_column_text(stmt, 1)),
                alphabet: String(cString: sqlite3_column_text(stmt, 2)),
                length: Int(sqlite3_column_int64(stmt, 3)),
                createdAt: parseDate(String(cString: sqlite3_column_text(stmt, 4))),
                modifiedAt: parseDate(String(cString: sqlite3_column_text(stmt, 5))),
                versionCount: Int(sqlite3_column_int(stmt, 6))
            )
            results.append(summary)
        }

        return results
    }

    // MARK: - Version Operations

    /// Records a new version of a sequence.
    ///
    /// - Parameters:
    ///   - sequenceId: The sequence ID
    ///   - diff: The diff from the previous version
    ///   - newContentHash: Hash of the new content
    ///   - message: Optional commit message
    ///   - author: Optional author name
    /// - Returns: The version ID
    @discardableResult
    public func recordVersion(
        sequenceId: UUID,
        diff: SequenceDiff,
        newContentHash: String,
        message: String? = nil,
        author: String? = nil
    ) throws -> UUID {
        // Get current version hash and count
        var parentHash: String?
        var currentVersionCount: Int = 0
        try query("""
            SELECT version_hash, version_index FROM current_state WHERE sequence_id = ?
        """, parameters: [sequenceId.uuidString]) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                parentHash = String(cString: sqlite3_column_text(stmt, 0))
            }
            currentVersionCount = Int(sqlite3_column_int(stmt, 1))
        }

        // The new version number is currentVersionCount + 1 (0 is original, 1 is first edit, etc.)
        let newVersionNumber = currentVersionCount + 1

        // Encode diff
        let diffData = try JSONEncoder().encode(diff)

        // Insert version
        let versionId = UUID()
        try execute("""
            INSERT INTO versions (id, sequence_id, version_number, parent_hash, content_hash, diff_data, message, author)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            versionId.uuidString,
            sequenceId.uuidString,
            newVersionNumber,
            parentHash as Any,
            newContentHash,
            diffData,
            message as Any,
            author as Any
        ])

        // Update current state
        let versionIndex = newVersionNumber
        try execute("""
            UPDATE current_state
            SET version_hash = ?, version_index = ?
            WHERE sequence_id = ?
        """, parameters: [newContentHash, versionIndex, sequenceId.uuidString])

        // Update sequence modified timestamp
        try execute("""
            UPDATE sequences SET modified_at = datetime('now') WHERE id = ?
        """, parameters: [sequenceId.uuidString])

        Self.logger.info("Recorded version \(versionIndex) for sequence \(sequenceId.uuidString)")
        return versionId
    }

    /// Gets the version history for a sequence.
    public func getVersionHistory(for sequenceId: UUID) throws -> [StoredVersion] {
        var versions: [StoredVersion] = []

        try query("""
            SELECT id, parent_hash, content_hash, diff_data, message, author, created_at
            FROM versions
            WHERE sequence_id = ?
            ORDER BY version_number ASC
        """, parameters: [sequenceId.uuidString]) { stmt in
            let version = try parseStoredVersion(from: stmt)
            versions.append(version)
        }

        return versions
    }

    /// Gets the current version index for a sequence.
    public func getCurrentVersionIndex(for sequenceId: UUID) throws -> Int {
        var index: Int = 0
        try query("""
            SELECT version_index FROM current_state WHERE sequence_id = ?
        """, parameters: [sequenceId.uuidString]) { stmt in
            index = Int(sqlite3_column_int(stmt, 0))
        }
        return index
    }

    /// Reconstructs the sequence content at a specific version.
    public func reconstructSequence(id: UUID, atVersion versionIndex: Int) throws -> String {
        // Get original content
        guard let stored = try getSequence(id: id) else {
            throw ProjectStoreError.sequenceNotFound(id: id)
        }

        var content = stored.originalContent

        // Apply diffs up to the specified version
        let versions = try getVersionHistory(for: id)
        let versionsToApply = min(versionIndex, versions.count)

        for i in 0..<versionsToApply {
            content = try versions[i].diff.apply(to: content)
        }

        return content
    }

    /// Checks out a specific version of a sequence.
    public func checkoutVersion(sequenceId: UUID, versionIndex: Int) throws {
        let versions = try getVersionHistory(for: sequenceId)
        let versionHash: String?

        if versionIndex == 0 {
            versionHash = nil
        } else if versionIndex <= versions.count {
            versionHash = versions[versionIndex - 1].contentHash
        } else {
            throw ProjectStoreError.invalidVersionIndex(index: versionIndex)
        }

        try execute("""
            UPDATE current_state
            SET version_hash = ?, version_index = ?
            WHERE sequence_id = ?
        """, parameters: [versionHash as Any, versionIndex, sequenceId.uuidString])
    }

    // MARK: - Edit Log Operations

    /// Records an edit operation for audit purposes.
    public func logEdit(
        sequenceId: UUID,
        operation: String,
        position: Int?,
        length: Int?,
        bases: String?,
        sessionId: String?
    ) throws {
        try execute("""
            INSERT INTO edit_log (sequence_id, operation, position, length, bases, session_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, parameters: [
            sequenceId.uuidString,
            operation,
            position as Any,
            length as Any,
            bases as Any,
            sessionId as Any
        ])
    }

    /// Gets recent edits for a sequence.
    public func getRecentEdits(sequenceId: UUID, limit: Int = 100) throws -> [EditLogEntry] {
        var entries: [EditLogEntry] = []

        try query("""
            SELECT id, operation, position, length, bases, timestamp, session_id
            FROM edit_log
            WHERE sequence_id = ?
            ORDER BY id DESC
            LIMIT ?
        """, parameters: [sequenceId.uuidString, limit]) { stmt in
            let entry = EditLogEntry(
                id: Int(sqlite3_column_int64(stmt, 0)),
                operation: String(cString: sqlite3_column_text(stmt, 1)),
                position: sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil,
                length: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil,
                bases: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil,
                timestamp: parseDate(String(cString: sqlite3_column_text(stmt, 5))),
                sessionId: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            )
            entries.append(entry)
        }

        return entries
    }

    // MARK: - Annotation Operations

    /// Stores an annotation.
    @discardableResult
    public func storeAnnotation(
        sequenceId: UUID,
        type: String,
        name: String,
        startPosition: Int,
        endPosition: Int,
        strand: String = "+",
        qualifiers: [String: String]? = nil,
        color: String? = nil
    ) throws -> UUID {
        let id = UUID()
        let qualifiersJSON = try qualifiers.map { try JSONEncoder().encode($0) }

        try execute("""
            INSERT INTO annotations (id, sequence_id, type, name, start_position, end_position, strand, qualifiers, color)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            id.uuidString,
            sequenceId.uuidString,
            type,
            name,
            startPosition,
            endPosition,
            strand,
            qualifiersJSON as Any,
            color as Any
        ])

        return id
    }

    /// Gets annotations for a sequence in a range.
    public func getAnnotations(
        sequenceId: UUID,
        inRange range: Range<Int>? = nil
    ) throws -> [StoredAnnotation] {
        var annotations: [StoredAnnotation] = []

        var sql = """
            SELECT id, type, name, start_position, end_position, strand, qualifiers, color
            FROM annotations
            WHERE sequence_id = ?
        """
        var params: [Any] = [sequenceId.uuidString]

        if let range = range {
            sql += " AND end_position >= ? AND start_position < ?"
            params.append(range.lowerBound)
            params.append(range.upperBound)
        }

        sql += " ORDER BY start_position"

        try query(sql, parameters: params) { stmt in
            let annotation = try parseStoredAnnotation(from: stmt)
            annotations.append(annotation)
        }

        return annotations
    }

    // MARK: - Project Metadata

    /// Sets a project metadata value.
    public func setMetadata(key: String, value: String) throws {
        try execute("""
            INSERT OR REPLACE INTO project_metadata (key, value) VALUES (?, ?)
        """, parameters: [key, value])
    }

    /// Gets a project metadata value.
    public func getMetadata(key: String) throws -> String? {
        var value: String?
        try query("""
            SELECT value FROM project_metadata WHERE key = ?
        """, parameters: [key]) { stmt in
            value = String(cString: sqlite3_column_text(stmt, 0))
        }
        return value
    }

    // MARK: - Helper Methods

    private func getVersionCount(for sequenceId: UUID) throws -> Int {
        var count: Int = 0
        try query("""
            SELECT COUNT(*) FROM versions WHERE sequence_id = ?
        """, parameters: [sequenceId.uuidString]) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    private func computeHash(_ content: String) -> String {
        let data = Data(content.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func parseDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? Date()
    }

    private func parseStoredSequence(from stmt: OpaquePointer?) throws -> StoredSequence {
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        let contentBlob = sqlite3_column_blob(stmt, 2)
        let contentLength = sqlite3_column_bytes(stmt, 2)
        let contentData = Data(bytes: contentBlob!, count: Int(contentLength))
        let content = String(data: contentData, encoding: .utf8) ?? ""

        var metadata: [String: String]?
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
            let metadataBlob = sqlite3_column_blob(stmt, 6)
            let metadataLength = sqlite3_column_bytes(stmt, 6)
            let metadataData = Data(bytes: metadataBlob!, count: Int(metadataLength))
            metadata = try? JSONDecoder().decode([String: String].self, from: metadataData)
        }

        return StoredSequence(
            id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!,
            name: String(cString: sqlite3_column_text(stmt, 1)),
            originalContent: content,
            contentHash: String(cString: sqlite3_column_text(stmt, 3)),
            alphabet: String(cString: sqlite3_column_text(stmt, 4)),
            length: Int(sqlite3_column_int64(stmt, 5)),
            metadata: metadata,
            currentVersionHash: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil,
            currentVersionIndex: Int(sqlite3_column_int(stmt, 8))
        )
    }

    private func parseStoredVersion(from stmt: OpaquePointer?) throws -> StoredVersion {
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        let diffBlob = sqlite3_column_blob(stmt, 3)
        let diffLength = sqlite3_column_bytes(stmt, 3)
        let diffData = Data(bytes: diffBlob!, count: Int(diffLength))
        let diff = try JSONDecoder().decode(SequenceDiff.self, from: diffData)

        return StoredVersion(
            id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!,
            parentHash: sqlite3_column_type(stmt, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 1)) : nil,
            contentHash: String(cString: sqlite3_column_text(stmt, 2)),
            diff: diff,
            message: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil,
            author: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil,
            createdAt: parseDate(String(cString: sqlite3_column_text(stmt, 6)))
        )
    }

    private func parseStoredAnnotation(from stmt: OpaquePointer?) throws -> StoredAnnotation {
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        var qualifiers: [String: String]?
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
            let qualBlob = sqlite3_column_blob(stmt, 6)
            let qualLength = sqlite3_column_bytes(stmt, 6)
            let qualData = Data(bytes: qualBlob!, count: Int(qualLength))
            qualifiers = try? JSONDecoder().decode([String: String].self, from: qualData)
        }

        return StoredAnnotation(
            id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!,
            type: String(cString: sqlite3_column_text(stmt, 1)),
            name: String(cString: sqlite3_column_text(stmt, 2)),
            startPosition: Int(sqlite3_column_int(stmt, 3)),
            endPosition: Int(sqlite3_column_int(stmt, 4)),
            strand: String(cString: sqlite3_column_text(stmt, 5)),
            qualifiers: qualifiers,
            color: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
        )
    }

    // MARK: - WAL Checkpointing

    /// Checkpoints the WAL file to reclaim disk space.
    ///
    /// In WAL mode, changes accumulate in a separate WAL file. Checkpointing
    /// moves those changes back to the main database file and truncates the WAL.
    /// This should be called periodically or when closing to prevent the WAL
    /// file from growing unbounded.
    ///
    /// - Parameter mode: The checkpoint mode. Defaults to `.truncate` which
    ///   checkpoints all frames and truncates the WAL file to zero bytes.
    public func checkpoint(mode: CheckpointMode = .truncate) {
        guard let db = db else { return }

        let modeValue: Int32
        switch mode {
        case .passive:
            modeValue = SQLITE_CHECKPOINT_PASSIVE
        case .full:
            modeValue = SQLITE_CHECKPOINT_FULL
        case .restart:
            modeValue = SQLITE_CHECKPOINT_RESTART
        case .truncate:
            modeValue = SQLITE_CHECKPOINT_TRUNCATE
        }

        var walFrameCount: Int32 = 0
        var checkpointedFrames: Int32 = 0

        let result = sqlite3_wal_checkpoint_v2(
            db,
            nil,  // checkpoint all attached databases
            modeValue,
            &walFrameCount,
            &checkpointedFrames
        )

        if result == SQLITE_OK {
            if walFrameCount > 0 {
                Self.logger.info("WAL checkpoint: \(checkpointedFrames)/\(walFrameCount) frames checkpointed")
            }
        } else {
            let message = String(cString: sqlite3_errmsg(db))
            Self.logger.warning("WAL checkpoint failed: \(message, privacy: .public)")
        }
    }

    /// WAL checkpoint modes.
    public enum CheckpointMode {
        /// Checkpoint as many frames as possible without waiting.
        case passive
        /// Checkpoint all frames, waiting for readers to finish.
        case full
        /// Like full, but also ensures the WAL is reset.
        case restart
        /// Like restart, but also truncates the WAL file to zero bytes.
        case truncate
    }

    // MARK: - SQL Execution

    private func execute(_ sql: String, parameters: [Any] = []) throws {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProjectStoreError.queryError(message: "Prepare failed: \(message)")
        }

        defer { sqlite3_finalize(stmt) }

        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            try bindParameter(stmt, at: bindIndex, value: param)
        }

        // Accept both SQLITE_DONE (no rows) and SQLITE_ROW (PRAGMA/RETURNING results)
        // We drain any rows but don't process them
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            stepResult = sqlite3_step(stmt)
        }

        guard stepResult == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProjectStoreError.queryError(message: "Execute failed: \(message)")
        }
    }

    private func query(_ sql: String, parameters: [Any] = [], handler: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProjectStoreError.queryError(message: "Prepare failed: \(message)")
        }

        defer { sqlite3_finalize(stmt) }

        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            try bindParameter(stmt, at: bindIndex, value: param)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            try handler(stmt)
        }
    }

    private func bindParameter(_ stmt: OpaquePointer?, at index: Int32, value: Any) throws {
        switch value {
        case is NSNull:
            sqlite3_bind_null(stmt, index)
        case let string as String:
            sqlite3_bind_text(stmt, index, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case let int as Int:
            sqlite3_bind_int64(stmt, index, Int64(int))
        case let int64 as Int64:
            sqlite3_bind_int64(stmt, index, int64)
        case let double as Double:
            sqlite3_bind_double(stmt, index, double)
        case let data as Data:
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        case let optional as Optional<Any>:
            if case .none = optional {
                sqlite3_bind_null(stmt, index)
            } else if let unwrapped = optional {
                try bindParameter(stmt, at: index, value: unwrapped)
            }
        default:
            sqlite3_bind_null(stmt, index)
        }
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto

// MARK: - Supporting Types

/// A stored sequence with metadata.
public struct StoredSequence: Sendable {
    public let id: UUID
    public let name: String
    public let originalContent: String
    public let contentHash: String
    public let alphabet: String
    public let length: Int
    public let metadata: [String: String]?
    public let currentVersionHash: String?
    public let currentVersionIndex: Int
}

/// Summary information for a sequence.
public struct SequenceSummary: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let alphabet: String
    public let length: Int
    public let createdAt: Date
    public let modifiedAt: Date
    public let versionCount: Int
}

/// A stored version with diff data.
public struct StoredVersion: Sendable {
    public let id: UUID
    public let parentHash: String?
    public let contentHash: String
    public let diff: SequenceDiff
    public let message: String?
    public let author: String?
    public let createdAt: Date
}

/// An edit log entry.
public struct EditLogEntry: Sendable, Identifiable {
    public let id: Int
    public let operation: String
    public let position: Int?
    public let length: Int?
    public let bases: String?
    public let timestamp: Date
    public let sessionId: String?
}

/// A stored annotation.
public struct StoredAnnotation: Sendable, Identifiable {
    public let id: UUID
    public let type: String
    public let name: String
    public let startPosition: Int
    public let endPosition: Int
    public let strand: String
    public let qualifiers: [String: String]?
    public let color: String?
}

// MARK: - ProjectStoreError

/// Errors that can occur during project store operations.
public enum ProjectStoreError: Error, LocalizedError, Sendable {
    case databaseError(message: String)
    case queryError(message: String)
    case sequenceNotFound(id: UUID)
    case versionNotFound(hash: String)
    case invalidVersionIndex(index: Int)
    case serializationError(message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseError(let message):
            return "Database error: \(message)"
        case .queryError(let message):
            return "Query error: \(message)"
        case .sequenceNotFound(let id):
            return "Sequence not found: \(id)"
        case .versionNotFound(let hash):
            return "Version not found: \(hash)"
        case .invalidVersionIndex(let index):
            return "Invalid version index: \(index)"
        case .serializationError(let message):
            return "Serialization error: \(message)"
        }
    }
}
