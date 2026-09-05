import Foundation
import Darwin
import SQLite3

/// A retained SQLite connection for publication, including resumable databases
/// whose import_state is not complete. It exposes no scientific query API.
public final class SQLitePublicationHandle {
    private let db: OpaquePointer
    private let writable: Bool

    public init(url: URL, writable: Bool = false) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VariantDatabaseError.openFailed("Publication requires a regular SQLite file at \(url.path)")
        }
        var connection: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let path = try SQLitePublicationSupport.openPath(url)
        let status = sqlite3_open_v2(path, &connection, flags, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite publication handle"
            if let connection { sqlite3_close(connection) }
            throw VariantDatabaseError.openFailed("SQLite open failed (\(status)) at \(path): \(message)")
        }
        db = connection
        self.writable = writable
    }

    deinit { sqlite3_close(db) }

    public func dataVersion() throws -> Int64 { try SQLitePublicationSupport.dataVersion(db) }
    public func writeSnapshot(to destination: URL) throws { try SQLitePublicationSupport.snapshot(db, to: destination) }
    public func restoreSnapshot(from source: URL) throws {
        guard writable else { throw VariantDatabaseError.openFailed("Publication handle is read-only") }
        try SQLitePublicationSupport.restore(from: source, to: db)
    }
    public func checkpoint() throws {
        guard writable else { throw VariantDatabaseError.openFailed("Publication handle is read-only") }
        try SQLitePublicationSupport.checkpoint(db)
    }
}

extension VariantDatabase {
    /// Changes only when another connection commits. Compare values obtained
    /// from this same retained handle; our own mutations do not advance it.
    public func publicationDataVersion() throws -> Int64 {
        guard let db else { throw VariantDatabaseError.openFailed("Database is closed") }
        return try SQLitePublicationSupport.dataVersion(db)
    }

    /// SQLite owns the read transaction, including committed pages still in WAL.
    public func writePublicationSnapshot(to destination: URL) throws {
        guard let db else { throw VariantDatabaseError.openFailed("Database is closed") }
        try SQLitePublicationSupport.snapshot(db, to: destination)
    }

    /// Restores through SQLite, preserving the inode used by existing readers.
    public func restorePublicationSnapshot(from source: URL) throws {
        guard let db, !isReadOnly else { throw VariantDatabaseError.openFailed("Database is not writable") }
        try SQLitePublicationSupport.restore(from: source, to: db)
    }

    public func checkpointForPublication() throws {
        guard let db, !isReadOnly else { throw VariantDatabaseError.openFailed("Database is not writable") }
        try SQLitePublicationSupport.checkpoint(db)
    }
}

private enum SQLitePublicationSupport {
    // Foundation URL resolution/appending canonicalizes /private/var back to
    // /var on macOS. Keep realpath's parent as a plain string for NOFOLLOW;
    // the leaf stays unresolved and cannot redirect the database open.
    static func openPath(_ url: URL) throws -> String {
        guard let parent = url.deletingLastPathComponent().path.withCString({ realpath($0, nil) }) else {
            throw VariantDatabaseError.openFailed("Cannot resolve SQLite publication parent: \(url.deletingLastPathComponent().path), errno \(errno)")
        }
        defer { free(parent) }
        return String(cString: parent) + "/" + url.lastPathComponent
    }

    static func dataVersion(_ db: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw VariantDatabaseError.openFailed("Cannot read publication revision: \(String(cString: sqlite3_errmsg(db)))")
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func snapshot(_ db: OpaquePointer, to destination: URL) throws {
        var target: OpaquePointer?
        let path = try openPath(destination)
        let status = sqlite3_open_v2(path, &target,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let target { sqlite3_close(target) } }
        guard status == SQLITE_OK, let target else {
            throw VariantDatabaseError.createFailed("Cannot open recovery snapshot (\(status)/\(target.map { sqlite3_extended_errcode($0) } ?? -1)) at \(path): \(target.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")")
        }
        try copy(from: db, to: target)
        // Backup inherits WAL mode. Finalize this private copy as a standalone
        // database before reopening it read-only (required by macOS SQLite).
        guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Cannot finalize recovery snapshot: \(String(cString: sqlite3_errmsg(target)))")
        }
    }

    static func restore(from source: URL, to db: OpaquePointer) throws {
        var snapshot: OpaquePointer?
        let path = try openPath(source)
        let status = sqlite3_open_v2(path, &snapshot, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let snapshot { sqlite3_close(snapshot) } }
        guard status == SQLITE_OK, let snapshot else {
            throw VariantDatabaseError.openFailed("Cannot open recovery snapshot (\(status)/\(snapshot.map { sqlite3_extended_errcode($0) } ?? -1)) at \(path): \(snapshot.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")")
        }
        try copy(from: snapshot, to: db)
        try checkpoint(db)
    }

    static func checkpoint(_ db: OpaquePointer) throws {
        var logFrames: Int32 = 0
        var completedFrames: Int32 = 0
        let status = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &completedFrames)
        guard status == SQLITE_OK else { throw VariantDatabaseError.createFailed("Publication checkpoint failed: \(String(cString: sqlite3_errmsg(db)))") }
    }

    private static func copy(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw VariantDatabaseError.createFailed("Snapshot initialization failed: \(String(cString: sqlite3_errmsg(destination)))")
        }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else {
            throw VariantDatabaseError.createFailed("Snapshot copy failed (\(copied)/\(finished)): \(String(cString: sqlite3_errmsg(destination)))")
        }
    }
}
