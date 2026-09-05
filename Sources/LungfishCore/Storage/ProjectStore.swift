// ProjectStore.swift - SQLite-based project persistence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import CommonCrypto
import Darwin
import Foundation
import SQLite3
import os.log

/// Effective access is enforced by storage, including metadata writes.
public enum ProjectAccessMode: Sendable, Equatable {
    case readOnly
    case writable
}

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
/// All SQLite access, complete transactions, snapshot validation, and leases are
/// serialized by one recursive lock shared by live handles of a canonical project.
/// The unchecked conformance is confined to this lock-protected storage owner;
/// no pointer or mutable SQLite state is exposed to callers.
public final class ProjectStore: @unchecked Sendable {

    // MARK: - Properties

    /// The project directory URL
    public let projectURL: URL
    public let accessMode: ProjectAccessMode
    private let snapshotDirectory: URL?
    private let writerLease: ProjectStoreWriterLease?
    private let synchronization: ProjectStoreSynchronization
    private let deferCleanup: Bool
    private static let synchronizationRegistry = ProjectStoreSynchronizationRegistry()


    /// The SQLite database connection
    /// Never escapes this class; every access owns the project synchronization lock.
    private var db: OpaquePointer?

    /// Logger for store operations
    private static let logger = Logger(
        subsystem: "com.lungfish.browser",
        category: "ProjectStore"
    )

    /// Schema version for migrations
    private static let schemaVersion = 1

    private let iso8601FormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private let sqliteDateFormatterWithFractionalSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Initialization

    /// Compatibility initializer: creates only when the directory does not exist.
    /// Existing stores are opened without implicit migration.
    public convenience init(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try self.init(opening: url, access: .writable)
        } else {
            try self.init(creating: url)
        }
    }

    public convenience init(creating url: URL) throws {
        let synchronization = Self.synchronizationRegistry.domain(for: url)
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.databaseError(message: "Project already exists: \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(url.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let lease = try Self.acquireWriterLease(at: url)
            try self.init(projectURL: url, databaseURL: url.appendingPathComponent(".project.db"),
                          access: .writable, snapshot: nil, lease: lease, create: true)
        } catch {
            // Creation owns this newly created directory; no pre-existing data is removed.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public convenience init(opening url: URL, access: ProjectAccessMode = .writable, deferCleanup: Bool = false, validateBeforeWrite: (() throws -> Void)? = nil) throws {
        let synchronization = Self.synchronizationRegistry.domain(for: url)
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        let source = try Self.databaseURL(at: url)
        let snapshot = try Self.snapshot(of: source)
        do {
            let inspection = try ProjectStore(projectURL: url, databaseURL: snapshot.database,
                access: .readOnly, snapshot: snapshot.directory, lease: nil, create: false)
            let version = try inspection.getSchemaVersion()
            guard version == Self.schemaVersion else {
                if version == 0 {
                    throw ProjectStoreError.migrationRequired(found: version, supported: Self.schemaVersion)
                }
                throw ProjectStoreError.databaseError(message: "Unsupported project schema \(version); supported schema is \(Self.schemaVersion)")
            }
            if access == .readOnly {
                try self.init(projectURL: url, databaseURL: snapshot.database,
                              access: access, snapshot: snapshot.directory, lease: nil, create: false, deferCleanup: deferCleanup)
                // Both handles share the snapshot until this initializer returns. The
                // inspection handle must not delete it before the retained connection.
                inspection.retainsSnapshot = false
            } else {
                let lease = try Self.acquireWriterLease(at: url)
                guard try Self.sourceFingerprint(source) == snapshot.fingerprint else {
                    throw ProjectStoreError.databaseError(message: "Project changed during access validation. Reopen it.")
                }
                try validateBeforeWrite?()
                try self.init(projectURL: url, databaseURL: source, access: access,
                              snapshot: nil, lease: lease, create: false, deferCleanup: deferCleanup)
            }
        } catch {
            try? FileManager.default.removeItem(at: snapshot.directory)
            throw error
        }
    }

    /// Explicit schema/layout migration. The complete source database set is
    /// retained in a recovery directory before publication. No open calls this.
    public static func migrate(at url: URL, access: ProjectAccessMode = .writable, validateBeforeWrite: (() throws -> Void)? = nil) throws {
        let synchronization = Self.synchronizationRegistry.domain(for: url)
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard access == .writable else {
            throw ProjectStoreError.databaseError(message: "Migration requires writable access")
        }
        guard !ownsWriterLease(at: url) else {
            throw ProjectStoreError.databaseError(message: "Close project writers before migration")
        }
        let source = try databaseURL(at: url)
        let snapshot = try snapshot(of: source)
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        let inspection = try ProjectStore(projectURL: url, databaseURL: snapshot.database,
            access: .readOnly, snapshot: nil, lease: nil, create: false)
        let version = try inspection.getSchemaVersion()
        guard (0...schemaVersion).contains(version) else {
            throw ProjectStoreError.databaseError(message: "Unsupported project schema \(version)")
        }
        let lease = try acquireWriterLease(at: url)
        defer { withExtendedLifetime(lease) {} }
        guard try sourceFingerprint(source) == snapshot.fingerprint else {
            throw ProjectStoreError.databaseError(message: "Project changed before migration")
        }
        try validateBeforeWrite?()
        let started = Date()
        let recovery = url.appendingPathComponent(".lungfish/migrations/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        for suffix in snapshot.fingerprint.keys {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path + suffix),
                to: recovery.appendingPathComponent("source.db" + suffix))
        }
        guard try sourceFingerprint(source) == snapshot.fingerprint,
              try sourceFingerprint(recovery.appendingPathComponent("source.db")) == snapshot.fingerprint else {
            throw ProjectStoreError.databaseError(message: "Project changed while retaining migration recovery data at \(recovery.path)")
        }
        // Migrate a private copy and verify it before publishing any database pages.
        let staged = try ProjectStore(projectURL: url, databaseURL: snapshot.database,
            access: .writable, snapshot: nil, lease: nil, create: false, migrate: true)
        var integrity = ""
        try staged.query("PRAGMA integrity_check") { stmt in
            if let text = sqlite3_column_text(stmt, 0) { integrity = String(cString: text) }
        }
        guard integrity == "ok" else {
            throw ProjectStoreError.databaseError(message: "Migration integrity check failed; recovery retained at \(recovery.path)")
        }
        let destination = url.appendingPathComponent(".project.db")
        let provenanceURL = recovery.appendingPathComponent("provenance.json")
        let inputFiles: [[String: Any]] = try snapshot.fingerprint.map { suffix, hash in
            let input = URL(fileURLWithPath: source.path + suffix)
            return ["path": input.path, "sha256": hash,
                    "sizeBytes": try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                    "recoveryPath": recovery.appendingPathComponent("source.db" + suffix).path]
        }
        var provenance: [String: Any] = [
            "schemaVersion": 1,
            "workflow": "Lungfish.ProjectStore.migrate",
            "workflowVersion": "1",
            "toolVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            "invocation": "ProjectFile.migrate(at: URL(fileURLWithPath: \(String(reflecting: url.path))), access: .writable)",
            "argv": ProcessInfo.processInfo.arguments,
            "options": ["access": "writable", "sourceSchema": version, "targetSchema": schemaVersion, "retainRecovery": true],
            "runtime": ["os": ProcessInfo.processInfo.operatingSystemVersionString, "sqlite": String(cString: sqlite3_libversion())],
            "inputs": inputFiles, "outputPath": destination.path,
            "startedAt": ISO8601DateFormatter().string(from: started),
            "status": "prepared", "stderr": ""
        ]
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
            .write(to: provenanceURL, options: .atomic)
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        var published = false
        do {
            // SQLite backup publishes the schema in one SQLite transaction. This
            // preserves atomic recovery even when the destination has WAL files.
            var target: OpaquePointer?
            let result = sqlite3_open_v2(destination.path, &target,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let target else {
                if let target { sqlite3_close_v2(target) }
                throw ProjectStoreError.databaseError(message: "Cannot open migration destination")
            }
            do {
                guard let backup = sqlite3_backup_init(target, "main", staged.db, "main") else {
                    throw ProjectStoreError.databaseError(message: String(cString: sqlite3_errmsg(target)))
                }
                let step = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                guard step == SQLITE_DONE, finish == SQLITE_OK else {
                    throw ProjectStoreError.databaseError(message: "Migration publication failed (SQLite \(step)/\(finish))")
                }
            } catch {
                sqlite3_close_v2(target)
                throw error
            }
            sqlite3_close_v2(target)
            published = true
            provenance["outputs"] = try sourceFingerprint(destination).map { suffix, hash in
                let output = URL(fileURLWithPath: destination.path + suffix)
                return ["path": output.path, "sha256": hash,
                        "sizeBytes": try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0] as [String: Any]
            }
            provenance["status"] = "completed"
            provenance["exitStatus"] = 0
            provenance["wallTimeSeconds"] = Date().timeIntervalSince(started)
            try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
                .write(to: provenanceURL, options: .atomic)
        } catch {
            if !destinationExisted, !published {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    let partial = URL(fileURLWithPath: destination.path + suffix)
                    if FileManager.default.fileExists(atPath: partial.path) {
                        try? FileManager.default.removeItem(at: partial)
                    }
                }
            }
            throw ProjectStoreError.databaseError(message: "Migration did not finish: \(error.localizedDescription). Source recovery and prepared provenance retained at \(recovery.path)")
        }
    }

    private var retainsSnapshot = true

    private init(projectURL: URL, databaseURL: URL, access: ProjectAccessMode,
                 snapshot: URL?, lease: ProjectStoreWriterLease?, create: Bool, migrate: Bool = false, deferCleanup: Bool = false) throws {
        self.deferCleanup = deferCleanup
        self.synchronization = Self.synchronizationRegistry.domain(for: projectURL)
        self.projectURL = projectURL
        self.accessMode = access
        self.snapshotDirectory = snapshot
        self.writerLease = lease
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(databaseURL.path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let pointer { sqlite3_close_v2(pointer) }
            throw ProjectStoreError.databaseError(message: message)
        }
        self.db = pointer
        if access == .readOnly {
            try execute("PRAGMA query_only = ON")
        } else {
            // Validate again on the final connection before persistent pragmas.
            let version = try getSchemaVersion()
            guard create || version == Self.schemaVersion || (migrate && version == 0) else {
                throw ProjectStoreError.databaseError(message: "Unsupported project schema \(version)")
            }
            try execute("PRAGMA foreign_keys = ON")
            if create || migrate {
                try withTransaction {
                    try createTables()
                    try setSchemaVersion(Self.schemaVersion)
                }
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    private static func databaseURL(at url: URL) throws -> URL {
        for name in [".project.db", "project.db"] {
            let candidate = url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw ProjectStoreError.databaseError(message: "Missing project database in \(url.path)")
    }

    private static func sourceFingerprint(_ source: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for suffix in ["", "-wal", "-journal"] {
            let path = source.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var context = CC_SHA256_CTX()
            CC_SHA256_Init(&context)
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                _ = data.withUnsafeBytes { CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(data.count)) }
            }
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256_Final(&digest, &context)
            result[suffix] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private static func snapshot(of source: URL) throws -> (directory: URL, database: URL, fingerprint: [String: String]) {
        let before = try sourceFingerprint(source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LungfishProjectInspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("project.db")
        do {
            for suffix in before.keys {
                let copy = URL(fileURLWithPath: database.path + suffix)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path + suffix), to: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            guard try sourceFingerprint(source) == before,
                  try sourceFingerprint(database) == before else {
                throw ProjectStoreError.databaseError(message: "Project changed during inspection. Reopen it when its writer is idle.")
            }
            return (directory, database, before)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func ownsWriterLease(at url: URL) -> Bool {
        let synchronization = synchronizationRegistry.domain(for: url)
        synchronization.leaseLock.lock()
        defer { synchronization.leaseLock.unlock() }
        guard let lease = synchronization.writerLease else { return false }
        return (try? ProjectLockManager().readLock(at: lease.lockURL)) == lease.record
    }

    private static func acquireWriterLease(at url: URL) throws -> ProjectStoreWriterLease {
        let synchronization = synchronizationRegistry.domain(for: url)
        synchronization.leaseLock.lock()
        defer { synchronization.leaseLock.unlock() }
        if let existing = synchronization.writerLease {
            guard (try? ProjectLockManager().readLock(at: existing.lockURL)) == existing.record else {
                throw ProjectStoreError.databaseError(message: "Project writer lease changed; reopen read-only")
            }
            return existing
        }
        let manager = ProjectLockManager()
        let lockURL = ProjectLockManager.lockURL(for: url)
        let record = ProjectLockRecord.current(projectURL: url, mode: "write", toolName: "Lungfish ProjectStore", appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
        guard case .missing = try manager.readLockResult(at: lockURL),
              try manager.acquireLock(record, to: lockURL) else {
            throw ProjectStoreError.databaseError(message: "Project has a writer lock; open read-only or explicitly resolve the existing lock.")
        }
        let lease = ProjectStoreWriterLease(lockURL: lockURL, record: record, synchronization: synchronization)
        synchronization.writerLease = lease
        return lease
    }

    deinit {
        let cleanup = ProjectStoreCleanup(database: db,
            snapshotDirectory: retainsSnapshot ? snapshotDirectory : nil,
            synchronization: synchronization, writerLease: writerLease)
        if deferCleanup { ProjectStoreCleanup.queue.async { cleanup.perform() } }
        else { cleanup.perform() }
    }

    // MARK: - Schema Management

    private func getSchemaVersion() throws -> Int {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        var version: Int = 0
        try query("PRAGMA user_version") { stmt in
            version = Int(sqlite3_column_int(stmt, 0))
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        try execute("PRAGMA user_version = \(version)")
    }

    private func createTables() throws {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        let id = UUID()
        let contentHash = computeHash(content)
        let metadataJSON = try metadata.map { try JSONEncoder().encode($0) }

        try withTransaction {
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
        }

        Self.logger.info("Stored sequence '\(name, privacy: .public)' with ID \(id.uuidString)")
        return id
    }

    /// Retrieves a sequence by ID.
    ///
    /// - Parameter id: The sequence ID
    /// - Returns: The sequence content and metadata, or nil if not found
    public func getSequence(id: UUID) throws -> StoredSequence? {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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

    private func sequenceExists(id: UUID) throws -> Bool {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        var exists = false
        try query("SELECT 1 FROM sequences WHERE id = ? LIMIT 1", parameters: [id.uuidString]) { _ in
            exists = true
        }
        return exists
    }

    /// Lists all sequences in the project.
    public func listSequences() throws -> [SequenceSummary] {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        var results: [SequenceSummary] = []

        try query("""
            SELECT s.id, s.name, s.alphabet, s.length, s.created_at, s.modified_at,
                   (SELECT COUNT(*) FROM versions v WHERE v.sequence_id = s.id) as version_count
            FROM sequences s
            ORDER BY s.name
        """) { stmt in
            let summary = SequenceSummary(
                id: try requiredUUIDColumn(stmt, 0, name: "sequences.id"),
                name: try requiredTextColumn(stmt, 1, name: "sequences.name"),
                alphabet: try requiredTextColumn(stmt, 2, name: "sequences.alphabet"),
                length: Int(sqlite3_column_int64(stmt, 3)),
                createdAt: parseDate(try requiredTextColumn(stmt, 4, name: "sequences.created_at")),
                modifiedAt: parseDate(try requiredTextColumn(stmt, 5, name: "sequences.modified_at")),
                versionCount: Int(sqlite3_column_int(stmt, 6))
            )
            results.append(summary)
        }

        return results
    }

    /// Returns one consistent selected-content value without exposing SQLite/UI objects.
    /// Cache lookup happens under the same read transaction as version and annotations.
    public func sequenceSnapshot(id: UUID, cachedContent: (String) -> String? = { _ in nil }) throws -> ProjectSequenceSnapshot {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        try execute("BEGIN DEFERRED")
        do {
            var name = ""
            var alphabet = ""
            var versionIndex = 0
            var cacheKey: String?
            try query("""
                SELECT s.name, s.alphabet, s.content_hash, cs.version_hash, COALESCE(cs.version_index, 0)
                FROM sequences s LEFT JOIN current_state cs ON s.id = cs.sequence_id WHERE s.id = ?
                """, parameters: [id.uuidString]) { stmt in
                name = try requiredTextColumn(stmt, 0, name: "sequences.name")
                alphabet = try requiredTextColumn(stmt, 1, name: "sequences.alphabet")
                let originalHash = try requiredTextColumn(stmt, 2, name: "sequences.content_hash")
                let versionHash = try optionalTextColumn(stmt, 3, name: "current_state.version_hash") ?? originalHash
                versionIndex = Int(sqlite3_column_int(stmt, 4))
                cacheKey = "\(id.uuidString):\(originalHash):\(versionHash):\(versionIndex)"
            }
            guard let cacheKey else { throw ProjectStoreError.sequenceNotFound(id: id) }
            let cached = cachedContent(cacheKey)
            let content = try cached ?? reconstructSequence(id: id, atVersion: versionIndex)
            let annotations = try getAnnotations(sequenceId: id)
            try execute("COMMIT")
            return ProjectSequenceSnapshot(id: id, name: name, alphabet: alphabet,
                content: content, annotations: annotations, cacheKey: cacheKey, usedCachedContent: cached != nil)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        // Encode diff
        let diffData = try JSONEncoder().encode(diff)

        return try withTransaction {
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
    }

    /// Gets the version history for a sequence.
    public func getVersionHistory(for sequenceId: UUID) throws -> [StoredVersion] {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard versionIndex >= 0 else {
            throw ProjectStoreError.invalidVersionIndex(index: versionIndex)
        }

        // Get original content
        guard let stored = try getSequence(id: id) else {
            throw ProjectStoreError.sequenceNotFound(id: id)
        }

        var content = stored.originalContent

        // Apply diffs up to the specified version
        let versions = try getVersionHistory(for: id)
        guard versionIndex <= versions.count else {
            throw ProjectStoreError.invalidVersionIndex(index: versionIndex)
        }

        for i in 0..<versionIndex {
            content = try versions[i].diff.apply(to: content)
        }

        return content
    }

    /// Checks out a specific version of a sequence.
    public func checkoutVersion(sequenceId: UUID, versionIndex: Int) throws {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard versionIndex >= 0 else {
            throw ProjectStoreError.invalidVersionIndex(index: versionIndex)
        }
        guard try sequenceExists(id: sequenceId) else {
            throw ProjectStoreError.sequenceNotFound(id: sequenceId)
        }

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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
    func setMetadata(key: String, value: String) throws {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        try execute("""
            INSERT OR REPLACE INTO project_metadata (key, value) VALUES (?, ?)
        """, parameters: [key, value])
    }

    /// Gets a project metadata value.
    func getMetadata(key: String) throws -> String? {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        var value: String?
        try query("""
            SELECT value FROM project_metadata WHERE key = ?
        """, parameters: [key]) { stmt in
            value = String(cString: sqlite3_column_text(stmt, 0))
        }
        return value
    }

    // MARK: - Helper Methods

    private func computeHash(_ content: String) -> String {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        let data = Data(content.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func parseDate(_ string: String) -> Date {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        if let date = self.iso8601FormatterWithFractionalSeconds.date(from: string)
            ?? self.iso8601Formatter.date(from: string)
            ?? self.sqliteDateFormatterWithFractionalSeconds.date(from: string)
            ?? self.sqliteDateFormatter.date(from: string) {
            return date
        }

        if let unixTimestamp = Double(string) {
            return Date(timeIntervalSince1970: unixTimestamp)
        }

        Self.logger.warning("Failed to parse stored date '\(string, privacy: .public)'; falling back to current time")
        return Date()
    }

    private func parseStoredSequence(from stmt: OpaquePointer?) throws -> StoredSequence {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        let contentData = try requiredBlobColumn(stmt, 2, name: "sequences.original_content")
        guard let content = String(data: contentData, encoding: .utf8) else {
            throw ProjectStoreError.queryError(
                message: "Invalid UTF-8 in required column sequences.original_content"
            )
        }

        var metadata: [String: String]?
        if let metadataData = try optionalBlobColumn(stmt, 6, name: "sequences.metadata") {
            metadata = try? JSONDecoder().decode([String: String].self, from: metadataData)
        }

        return StoredSequence(
            id: try requiredUUIDColumn(stmt, 0, name: "sequences.id"),
            name: try requiredTextColumn(stmt, 1, name: "sequences.name"),
            originalContent: content,
            contentHash: try requiredTextColumn(stmt, 3, name: "sequences.content_hash"),
            alphabet: try requiredTextColumn(stmt, 4, name: "sequences.alphabet"),
            length: Int(sqlite3_column_int64(stmt, 5)),
            metadata: metadata,
            currentVersionHash: try optionalTextColumn(stmt, 7, name: "current_state.version_hash"),
            currentVersionIndex: Int(sqlite3_column_int(stmt, 8))
        )
    }

    private func parseStoredVersion(from stmt: OpaquePointer?) throws -> StoredVersion {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        let diffData = try requiredBlobColumn(stmt, 3, name: "versions.diff_data")
        let diff = try JSONDecoder().decode(SequenceDiff.self, from: diffData)

        return StoredVersion(
            id: try requiredUUIDColumn(stmt, 0, name: "versions.id"),
            parentHash: try optionalTextColumn(stmt, 1, name: "versions.parent_hash"),
            contentHash: try requiredTextColumn(stmt, 2, name: "versions.content_hash"),
            diff: diff,
            message: try optionalTextColumn(stmt, 4, name: "versions.message"),
            author: try optionalTextColumn(stmt, 5, name: "versions.author"),
            createdAt: parseDate(try requiredTextColumn(stmt, 6, name: "versions.created_at"))
        )
    }

    private func parseStoredAnnotation(from stmt: OpaquePointer?) throws -> StoredAnnotation {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt = stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement")
        }

        var qualifiers: [String: String]?
        if let qualData = try optionalBlobColumn(stmt, 6, name: "annotations.qualifiers") {
            qualifiers = try? JSONDecoder().decode([String: String].self, from: qualData)
        }

        return StoredAnnotation(
            id: try requiredUUIDColumn(stmt, 0, name: "annotations.id"),
            type: try requiredTextColumn(stmt, 1, name: "annotations.type"),
            name: try requiredTextColumn(stmt, 2, name: "annotations.name"),
            startPosition: Int(sqlite3_column_int(stmt, 3)),
            endPosition: Int(sqlite3_column_int(stmt, 4)),
            strand: try requiredTextColumn(stmt, 5, name: "annotations.strand"),
            qualifiers: qualifiers,
            color: try optionalTextColumn(stmt, 7, name: "annotations.color")
        )
    }

    private func requiredUUIDColumn(_ stmt: OpaquePointer?, _ index: Int32, name: String) throws -> UUID {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        let value = try requiredTextColumn(stmt, index, name: name)
        guard let uuid = UUID(uuidString: value) else {
            throw ProjectStoreError.queryError(message: "Invalid UUID in \(name): \(value)")
        }
        return uuid
    }

    private func requiredTextColumn(_ stmt: OpaquePointer?, _ index: Int32, name: String) throws -> String {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement while reading \(name)")
        }
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let text = sqlite3_column_text(stmt, index) else {
            throw ProjectStoreError.queryError(message: "Missing required text column \(name)")
        }
        return String(cString: text)
    }

    private func optionalTextColumn(_ stmt: OpaquePointer?, _ index: Int32, name: String) throws -> String? {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement while reading \(name)")
        }
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else {
            return nil
        }
        guard let text = sqlite3_column_text(stmt, index) else {
            throw ProjectStoreError.queryError(message: "Invalid text column \(name)")
        }
        return String(cString: text)
    }

    private func requiredBlobColumn(_ stmt: OpaquePointer?, _ index: Int32, name: String) throws -> Data {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement while reading \(name)")
        }
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else {
            throw ProjectStoreError.queryError(message: "Missing required blob column \(name)")
        }
        let byteCount = sqlite3_column_bytes(stmt, index)
        guard byteCount > 0 else {
            return Data()
        }
        guard let blob = sqlite3_column_blob(stmt, index) else {
            throw ProjectStoreError.queryError(message: "Invalid blob column \(name)")
        }
        return Data(bytes: blob, count: Int(byteCount))
    }

    private func optionalBlobColumn(_ stmt: OpaquePointer?, _ index: Int32, name: String) throws -> Data? {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard let stmt else {
            throw ProjectStoreError.queryError(message: "Invalid statement while reading \(name)")
        }
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else {
            return nil
        }
        return try requiredBlobColumn(stmt, index, name: name)
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
    func checkpoint(mode: CheckpointMode = .truncate) {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        guard accessMode == .writable, let db = db else { return }

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
    enum CheckpointMode {
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
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

        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            try handler(stmt)
            stepResult = sqlite3_step(stmt)
        }

        guard stepResult == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProjectStoreError.queryError(message: "Query failed: \(message)")
        }
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            do {
                try execute("ROLLBACK")
            } catch {
                Self.logger.warning("Rollback failed after transaction error: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// The SQLite transient-destructor sentinel: tells SQLite to copy the bound bytes immediately.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindParameter(_ stmt: OpaquePointer?, at index: Int32, value: Any) throws {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        switch value {
        case is NSNull:
            sqlite3_bind_null(stmt, index)
        case let string as String:
            sqlite3_bind_text(stmt, index, string, -1, Self.SQLITE_TRANSIENT)
        case let int as Int:
            sqlite3_bind_int64(stmt, index, Int64(int))
        case let int64 as Int64:
            sqlite3_bind_int64(stmt, index, int64)
        case let double as Double:
            sqlite3_bind_double(stmt, index, double)
        case let data as Data:
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT)
            }
        case let optional as Optional<Any>:
            if case .none = optional {
                sqlite3_bind_null(stmt, index)
            } else if let unwrapped = optional {
                try bindParameter(stmt, at: index, value: unwrapped)
            }
        default:
            throw ProjectStoreError.serializationError(
                message: "Unsupported SQLite bind parameter type: \(type(of: value))"
            )
        }
    }
}

// MARK: - Supporting Types

/// A stored sequence with metadata.
public struct ProjectSequenceSnapshot: Sendable {
    public let id: UUID
    public let name: String
    public let alphabet: String
    public let content: String
    public let annotations: [StoredAnnotation]
    public let cacheKey: String
    public let usedCachedContent: Bool
}

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
    case migrationRequired(found: Int, supported: Int)
    case queryError(message: String)
    case sequenceNotFound(id: UUID)
    case versionNotFound(hash: String)
    case invalidVersionIndex(index: Int)
    case serializationError(message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseError(let message):
            return "Database error: \(message)"
        case .migrationRequired(let found, let supported):
            return "Project schema \(found) requires explicit migration to schema \(supported). Source recovery data will be retained."
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

private final class ProjectStoreWriterLease: @unchecked Sendable {
    let lockURL: URL
    let record: ProjectLockRecord
    private let synchronization: ProjectStoreSynchronization
    init(lockURL: URL, record: ProjectLockRecord, synchronization: ProjectStoreSynchronization) {
        self.lockURL = lockURL
        self.record = record
        self.synchronization = synchronization
    }
    deinit {
        synchronization.leaseLock.lock()
        defer { synchronization.leaseLock.unlock() }
        let manager = ProjectLockManager()
        if (try? manager.readLock(at: lockURL)) == record {
            try? manager.removeLockIfPresent(at: lockURL)
        }
    }
}

private final class ProjectStoreSynchronization: @unchecked Sendable {
    let lock = NSRecursiveLock()
    let leaseLock = NSRecursiveLock()
    // Access only while leaseLock is held. Each live store retains this domain.
    weak var writerLease: ProjectStoreWriterLease?
}

private final class ProjectStoreSynchronizationRegistry: @unchecked Sendable {
    private struct WeakDomain { weak var value: ProjectStoreSynchronization? }
    private let lock = NSLock()
    private var domains: [String: WeakDomain] = [:]

    func domain(for url: URL) -> ProjectStoreSynchronization {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = domains[key]?.value { return existing }
        if domains.count > 128 { domains = domains.filter { $0.value.value != nil } }
        let domain = ProjectStoreSynchronization()
        domains[key] = WeakDomain(value: domain)
        return domain
    }
}

/// The async UI path hands only storage resources to this cleanup job. Legacy
/// synchronous APIs retain immediate cleanup, including last-writer lease tests.
private final class ProjectStoreCleanup: @unchecked Sendable {
    static let queue = DispatchQueue(label: "org.lungfish.project-storage-cleanup", qos: .utility, attributes: .concurrent)
    let database: OpaquePointer?
    let snapshotDirectory: URL?
    let synchronization: ProjectStoreSynchronization
    let writerLease: ProjectStoreWriterLease?
    init(database: OpaquePointer?, snapshotDirectory: URL?, synchronization: ProjectStoreSynchronization, writerLease: ProjectStoreWriterLease?) {
        self.database = database
        self.snapshotDirectory = snapshotDirectory
        self.synchronization = synchronization
        self.writerLease = writerLease
    }
    func perform() {
        synchronization.lock.lock()
        defer { synchronization.lock.unlock() }
        if let database { sqlite3_close_v2(database) }
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        withExtendedLifetime(writerLease) {}
    }
}
