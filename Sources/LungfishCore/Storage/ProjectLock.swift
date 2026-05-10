// ProjectLock.swift - Shared Lungfish project lock metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum ProjectLockStatus: String, Codable, Sendable, Equatable {
    case active
    case stale
    case unknown
}

public struct ProjectLockRecord: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let toolName: String
    public let appVersion: String
    public let projectPath: String
    public let mode: String
    public let user: String
    public let host: String
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
        createdAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.toolName = toolName
        self.appVersion = appVersion
        self.projectPath = projectPath
        self.mode = mode
        self.user = user
        self.host = host
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
            createdAt: ProjectLockMetadata.nowString()
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

    public func readLock(at lockURL: URL) throws -> ProjectLockRecord? {
        guard fileManager.fileExists(atPath: lockURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: lockURL)
        return try JSONDecoder().decode(ProjectLockRecord.self, from: data)
    }

    public func readLock(forProjectAt projectURL: URL) throws -> ProjectLockRecord? {
        try readLock(at: Self.lockURL(for: projectURL))
    }

    public func writeLock(_ record: ProjectLockRecord, to lockURL: URL) throws {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: lockURL, options: [.atomic])
    }

    public func status(of record: ProjectLockRecord) -> ProjectLockStatus {
        guard record.pid > 0 else {
            return .unknown
        }

        guard ProjectLockMetadata.isLocalHost(record.host) else {
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
        record.user == ProjectLockMetadata.currentUser
            && ProjectLockMetadata.isLocalHost(record.host)
            && record.pid == Int(ProcessInfo.processInfo.processIdentifier)
    }

    public func canRemoveWithoutForce(_ record: ProjectLockRecord) -> Bool {
        if isOwnedByCurrentProcess(record) {
            return true
        }
        guard record.user == ProjectLockMetadata.currentUser,
              ProjectLockMetadata.isLocalHost(record.host) else {
            return false
        }
        return status(of: record) == .stale
    }
}

enum ProjectProcessInspector {
    static func processStartTime(for pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "lstart="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}

enum ProjectLockMetadata {
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
