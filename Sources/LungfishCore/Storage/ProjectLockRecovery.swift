// ProjectLockRecovery.swift - Explicit, archived project lock recovery
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// An immutable capture of the precise lock the user is being asked to recover.
public struct ProjectLockRecoverySnapshot: Sendable {
    public let projectURL: URL
    public let readResult: ProjectLockReadResult
    fileprivate let bytes: Data?

    public static func capture(projectURL: URL) throws -> Self {
        let projectURL = projectURL.standardizedFileURL
        let lockURL = ProjectLockManager.lockURL(for: projectURL)
        guard let bytes = try readBytes(at: lockURL) else {
            return Self(projectURL: projectURL, readResult: .missing, bytes: nil)
        }
        let result: ProjectLockReadResult
        do {
            result = .valid(try JSONDecoder().decode(ProjectLockRecord.self, from: bytes))
        } catch {
            result = .corrupted(ProjectLockCorruption(lockURL: lockURL, reason: error.localizedDescription))
        }
        return Self(projectURL: projectURL, readResult: result, bytes: bytes)
    }

    fileprivate static func readBytes(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}

public struct ProjectLockRecoveryResult: Sendable {
    public let archiveURL: URL
    public let recoveryRecordURL: URL
}

public enum ProjectLockRecoveryError: Error, LocalizedError {
    case changedLock
    case activeLock
    case occupiedGate

    public var errorDescription: String? {
        switch self {
        case .changedLock: "The project lock changed after it was inspected. Inspect it again before recovery."
        case .activeLock: "A running local process owns this project lock. Close its project before recovery."
        case .occupiedGate: "Another lock recovery is in progress. The existing recovery lock was preserved."
        }
    }
}

public enum ProjectLockRecovery {
    /// Call only after the user explicitly confirms recovery of the captured lock.
    /// Unknown and corrupt locks require this explicit decision; active local locks
    /// cannot be recovered. No project database or scientific payload is changed.
    public static func recover(snapshot: ProjectLockRecoverySnapshot, reason: String) throws -> ProjectLockRecoveryResult? {
        let manager = ProjectLockManager()
        let lockURL = ProjectLockManager.lockURL(for: snapshot.projectURL)
        guard try validate(snapshot, at: lockURL, manager: manager) else { return nil }

        let gateURL = ProjectLockManager.replacementLockURL(forLockAt: lockURL)
        let operatorRecord = ProjectLockRecord.current(projectURL: snapshot.projectURL, mode: "lock-replacement",
            toolName: "Lungfish Project Lock Recovery",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
        guard try manager.acquireLock(operatorRecord, to: gateURL) else {
            throw ProjectLockRecoveryError.occupiedGate
        }
        defer {
            if (try? manager.readLock(at: gateURL)) == operatorRecord {
                try? manager.removeLockIfPresent(at: gateURL)
            }
        }
        guard try validate(snapshot, at: lockURL, manager: manager), let bytes = snapshot.bytes else { return nil }

        let directory = lockURL.deletingLastPathComponent()
            .appendingPathComponent("lock-recovery", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("project.lock")
        let recordURL = directory.appendingPathComponent("recovery.json")
        // Prepare the receipt before moving the lock, so a receipt write failure
        // cannot leave the primary removed without an explanation. On failure we
        // remove only our unused directory, never an archived lock.
        defer {
            if !FileManager.default.fileExists(atPath: archiveURL.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let record = RecoveryRecord(schemaVersion: 1, reason: reason,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            originalPath: lockURL.path, archivePath: archiveURL.path,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: bytes.count, operatorRecord: operatorRecord)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: [.atomic])
        guard try validate(snapshot, at: lockURL, manager: manager) else { return nil }
        try FileManager.default.moveItem(at: lockURL, to: archiveURL)
        return ProjectLockRecoveryResult(archiveURL: archiveURL, recoveryRecordURL: recordURL)
    }

    private static func validate(_ snapshot: ProjectLockRecoverySnapshot, at lockURL: URL, manager: ProjectLockManager) throws -> Bool {
        guard let currentBytes = try ProjectLockRecoverySnapshot.readBytes(at: lockURL) else { return false }
        guard currentBytes == snapshot.bytes else { throw ProjectLockRecoveryError.changedLock }
        if case .valid(let record) = snapshot.readResult, manager.status(of: record) == .active {
            throw ProjectLockRecoveryError.activeLock
        }
        return true
    }

    private struct RecoveryRecord: Encodable {
        let schemaVersion: Int
        let reason: String
        let timestamp: String
        let originalPath: String
        let archivePath: String
        let sha256: String
        let sizeBytes: Int
        let operatorRecord: ProjectLockRecord
    }
}
