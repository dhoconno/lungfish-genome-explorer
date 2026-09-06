// ProjectLock.swift - Shared Lungfish project lock metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum ProjectLockStatus: String, Codable, Sendable, Equatable {
    case active
    case stale
    case unknown
    case corrupted
}

public struct ProjectLockCorruption: Error, LocalizedError, Sendable, Equatable {
    public let lockURL: URL
    public let reason: String

    public init(lockURL: URL, reason: String) {
        self.lockURL = lockURL
        self.reason = reason
    }

    public var errorDescription: String? {
        "Project lock file is corrupted at \(lockURL.path): \(reason)"
    }
}

public enum ProjectLockReadResult: Sendable, Equatable {
    case missing
    case valid(ProjectLockRecord)
    case corrupted(ProjectLockCorruption)
}

public struct ProjectLockRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let toolName: String
    public let appVersion: String
    public let projectPath: String
    public let mode: String
    public let user: String
    public let host: String
    public let machineIdentifier: String?
    public let pid: Int
    public let processStartTime: String
    public let cwd: String
    public let createdAt: String

    public init(
        schemaVersion: Int,
        toolName: String,
        appVersion: String,
        projectPath: String,
        mode: String,
        user: String,
        host: String,
        pid: Int,
        processStartTime: String,
        cwd: String,
        createdAt: String,
        machineIdentifier: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.toolName = toolName
        self.appVersion = appVersion
        self.projectPath = projectPath
        self.mode = mode
        self.user = user
        self.host = host
        self.machineIdentifier = machineIdentifier
        self.pid = pid
        self.processStartTime = processStartTime
        self.cwd = cwd
        self.createdAt = createdAt
    }

    public static func current(
        projectURL: URL,
        mode: String,
        toolName: String,
        appVersion: String
    ) -> ProjectLockRecord {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return ProjectLockRecord(
            schemaVersion: 1,
            toolName: toolName,
            appVersion: appVersion,
            projectPath: projectURL.standardizedFileURL.path,
            mode: mode,
            user: ProjectLockMetadata.currentUser,
            host: ProcessInfo.processInfo.hostName,
            pid: pid,
            processStartTime: ProjectProcessInspector.processStartTime(for: pid) ?? ProjectLockMetadata.nowString(),
            cwd: FileManager.default.currentDirectoryPath,
            createdAt: ProjectLockMetadata.nowString(),
            machineIdentifier: ProjectLockMetadata.machineIdentifier
        )
    }
}

public struct ProjectLockManager {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func lockURL(for projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("project.lock", isDirectory: false)
    }

    public static func replacementLockURL(forLockAt lockURL: URL) -> URL {
        lockURL.appendingPathExtension("replace")
    }

    public func readLock(at lockURL: URL) throws -> ProjectLockRecord? {
        switch try readLockResult(at: lockURL) {
        case .missing:
            return nil
        case .valid(let record):
            return record
        case .corrupted(let corruption):
            throw corruption
        }
    }

    public func readLockResult(at lockURL: URL) throws -> ProjectLockReadResult {
        guard fileManager.fileExists(atPath: lockURL.path) else {
            return .missing
        }

        let data = try Data(contentsOf: lockURL)
        do {
            return .valid(try JSONDecoder().decode(ProjectLockRecord.self, from: data))
        } catch {
            return .corrupted(
                ProjectLockCorruption(
                    lockURL: lockURL,
                    reason: error.localizedDescription
                )
            )
        }
    }

    public func readLock(forProjectAt projectURL: URL) throws -> ProjectLockRecord? {
        try readLock(at: Self.lockURL(for: projectURL))
    }

    public func readLockResult(forProjectAt projectURL: URL) throws -> ProjectLockReadResult {
        try readLockResult(at: Self.lockURL(for: projectURL))
    }

    public func writeLock(_ record: ProjectLockRecord, to lockURL: URL) throws {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: lockURL, options: [.atomic])
    }

    public func acquireLock(_ record: ProjectLockRecord, to lockURL: URL) throws -> Bool {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)

        let descriptor = open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else {
            if errno == EEXIST {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        do {
            try Self.writeAll(data, to: descriptor)
        } catch {
            try? fileManager.removeItem(at: lockURL)
            throw error
        }

        return true
    }

    public func removeLockIfPresent(at lockURL: URL) throws {
        do {
            try fileManager.removeItem(at: lockURL)
        } catch {
            guard Self.isMissingFileError(error) else {
                throw error
            }
        }
    }

    public func status(of record: ProjectLockRecord) -> ProjectLockStatus {
        guard record.pid > 0, record.pid <= Int(Int32.max) else {
            return .unknown
        }

        guard ProjectLockMetadata.isLocalMachine(record) else {
            return .unknown
        }

        let pid = pid_t(record.pid)
        if kill(pid, 0) == 0 {
            if let currentStartTime = ProjectProcessInspector.processStartTime(for: record.pid),
               !record.processStartTime.isEmpty,
               currentStartTime != record.processStartTime {
                return .stale
            }
            return .active
        }

        if errno == ESRCH {
            return .stale
        }

        return .unknown
    }

    public func isOwnedByCurrentProcess(_ record: ProjectLockRecord) -> Bool {
        guard record.user == ProjectLockMetadata.currentUser,
              ProjectLockMetadata.isLocalMachine(record),
              record.pid == Int(ProcessInfo.processInfo.processIdentifier) else {
            return false
        }
        return record.processStartTime.isEmpty
            || ProjectProcessInspector.processStartTime(for: record.pid) == record.processStartTime
    }

    public func canRemoveWithoutForce(_ record: ProjectLockRecord) -> Bool {
        if isOwnedByCurrentProcess(record) {
            return true
        }
        guard record.user == ProjectLockMetadata.currentUser,
              ProjectLockMetadata.isLocalMachine(record) else {
            return false
        }
        return status(of: record) == .stale
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                offset += written
            }
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        return false
    }
}

enum ProjectProcessInspector {
    /// Returns the target process's start time, formatted identically to `ps -o lstart=`
    /// (e.g. "Tue Aug  8 23:50:57 2026", matching C's `ctime`/`asctime` layout) for
    /// on-disk lock-file compatibility with any records written by an earlier version of
    /// this function.
    ///
    /// Resolved via `proc_pidinfo(PROC_PIDTBSDINFO)`, a direct kernel query, rather than
    /// forking and waiting on `/bin/ps` -- this function is called synchronously from the
    /// main-actor project-open path (ProjectOpenWarningState.evaluate ->
    /// ProjectLockManager.status(of:) / ProjectLockRecord.current), so avoiding a
    /// subprocess spawn/wait here removes a fork+exec+wait round trip from that hot path
    /// (R3-R3ML-2).
    static func processStartTime(for pid: Int) -> String? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }

        var processInfo = proc_bsdinfo()
        errno = 0
        let result = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                Int32(pid),
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            return nil
        }

        var startSeconds = time_t(processInfo.pbi_start_tvsec)
        var timeStruct = tm()
        localtime_r(&startSeconds, &timeStruct)

        var buffer = [Int8](repeating: 0, count: 64)
        let formatted = buffer.withUnsafeMutableBufferPointer { pointer -> String? in
            // Matches ps(1)'s lstart format: "%a %b %e %H:%M:%S %Y" (e.g.
            // "Tue Aug  8 23:50:57 2026"), the same layout ctime_r/asctime_r produce.
            let written = strftime(pointer.baseAddress, pointer.count, "%a %b %e %H:%M:%S %Y", &timeStruct)
            guard written > 0, let baseAddress = pointer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }

        guard let formatted, !formatted.isEmpty else { return nil }
        return formatted
    }
}

enum ProjectLockMetadata {
    /// Native host UUID stays stable when VPN/DNS changes the displayed hostname.
    /// Failure leaves new records compatible with the legacy hostname check.
    static let machineIdentifier: String? = {
        var bytes = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        let result = bytes.withUnsafeMutableBufferPointer {
            gethostuuid($0.baseAddress!, &timeout)
        }
        guard result == 0, bytes.contains(where: { $0 != 0 }) else { return nil }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }()

    static func isLocalMachine(_ record: ProjectLockRecord) -> Bool {
        if let recordedIdentifier = record.machineIdentifier {
            guard let machineIdentifier else { return false }
            return recordedIdentifier == machineIdentifier
        }
        return isLocalHost(record.host)
    }

    static var currentUser: String {
        let nsUser = NSUserName()
        if !nsUser.isEmpty {
            return nsUser
        }
        return ProcessInfo.processInfo.environment["USER"] ?? "unknown"
    }

    static func nowString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func isLocalHost(_ host: String) -> Bool {
        let candidates = [
            ProcessInfo.processInfo.hostName,
            Host.current().name ?? "",
            Host.current().localizedName ?? "",
        ]
        return candidates.contains(host)
    }
}
