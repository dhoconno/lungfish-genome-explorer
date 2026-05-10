// ProjectCommand.swift - Shared project lock and migration commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Darwin
import Foundation
import LungfishCore
import LungfishWorkflow

/// Manage shared Lungfish project coordination metadata.
struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage shared project locks and bundle migrations",
        discussion: """
            Project commands provide explicit coordination primitives for shared
            Lungfish project directories. Lock records are stored inside the
            project so GUI and CLI tooling can detect active advanced workflows.
            """,
        subcommands: [
            LockSubcommand.self,
            UnlockSubcommand.self,
            MigrateSubcommand.self,
        ],
        defaultSubcommand: nil
    )

    /// Create or refresh a project-local lock record.
    struct LockSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lock",
            abstract: "Create a project-local lock record"
        )

        @Argument(help: "Path to the Lungfish project directory")
        var projectPath: String

        @Option(help: "Lock mode to record for tools and GUI clients")
        var mode: String = "exclusive"

        @Flag(help: "Replace an active lock without stale-owner checks")
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let projectURL = try ProjectPaths.validProjectURL(for: projectPath)
            let lockURL = ProjectPaths.lockURL(for: projectURL)
            let manager = ProjectLockManager(fileManager: .default)

            if let existing = try manager.readLock(at: lockURL) {
                let status = manager.status(of: existing)
                if (status == .active || status == .unknown) && !force {
                    throw ProjectCommandError.alreadyLocked(lockURL: lockURL, record: existing)
                }
            }

            let record = ProjectLockRecord.current(projectURL: projectURL, mode: mode)
            try manager.writeLock(record, to: lockURL)

            switch globalOptions.outputFormat {
            case .json:
                if !globalOptions.quiet {
                    JSONOutputHandler().writeData(record, label: nil)
                }
            case .text, .tsv:
                if !globalOptions.quiet {
                    print("Locked project: \(record.projectPath)")
                    print("Lock file: \(lockURL.path)")
                    print("Mode: \(record.mode)")
                }
            }
        }
    }

    /// Remove a project-local lock record.
    struct UnlockSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unlock",
            abstract: "Remove a project-local lock record"
        )

        @Argument(help: "Path to the Lungfish project directory")
        var projectPath: String

        @Flag(help: "Remove the lock even when it belongs to another user or process")
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let projectURL = try ProjectPaths.validProjectURL(for: projectPath)
            let lockURL = ProjectPaths.lockURL(for: projectURL)
            let manager = ProjectLockManager(fileManager: .default)

            guard let record = try manager.readLock(at: lockURL) else {
                if !globalOptions.quiet {
                    print("No project lock found: \(lockURL.path)")
                }
                return
            }

            if !force && !manager.isOwnedByCurrentProcess(record) {
                throw ProjectCommandError.foreignLock(lockURL: lockURL, record: record)
            }

            try FileManager.default.removeItem(at: lockURL)

            if globalOptions.outputFormat == .json {
                if !globalOptions.quiet {
                    JSONOutputHandler().writeData(ProjectUnlockOutput(lockFile: lockURL.path, removed: true), label: nil)
                }
            } else if !globalOptions.quiet {
                print("Unlocked project: \(projectURL.path)")
                print("Removed lock file: \(lockURL.path)")
            }
        }
    }

    /// Inspect project bundles and run safe schema migrations when available.
    struct MigrateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate",
            abstract: "Migrate project bundles when a safe transformer is available",
            discussion: """
                The migration command is intentionally conservative. It scans
                Lungfish bundles inside a project, leaves current-version bundles
                untouched, and reports unsupported legacy schemas without
                mutating data until a schema-specific transformer exists.
                """
        )

        @Argument(help: "Path to the Lungfish project directory")
        var projectPath: String

        @Flag(help: "Report planned actions without modifying files")
        var dryRun: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let projectURL = try ProjectPaths.validProjectURL(for: projectPath)
            let migrator = ProjectBundleMigrator(fileManager: .default)
            let report = try migrator.migrate(projectURL: projectURL, dryRun: dryRun)

            switch globalOptions.outputFormat {
            case .json:
                if !globalOptions.quiet {
                    JSONOutputHandler().writeData(report, label: nil)
                }
            case .text, .tsv:
                guard !globalOptions.quiet else { return }
                print("Project migration report")
                print("Project: \(report.projectPath)")
                print("Dry run: \(report.dryRun)")
                print("Bundles inspected: \(report.summary.inspected)")
                print("Current: \(report.summary.current)")
                print("Unsupported: \(report.summary.unsupported)")
                print("Migrated: \(report.summary.migrated)")
                for bundle in report.bundles {
                    print("- \(bundle.path): \(bundle.status) (\(bundle.action))")
                }
            }
        }
    }
}

private enum ProjectPaths {
    static func validProjectURL(for path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectCommandError.projectNotFound(path: path)
        }
        return url
    }

    static func lockURL(for projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("project.lock", isDirectory: false)
    }
}

private struct ProjectLockRecord: Codable, Equatable {
    let schemaVersion: Int
    let toolName: String
    let appVersion: String
    let projectPath: String
    let mode: String
    let user: String
    let host: String
    let pid: Int
    let processStartTime: String
    let cwd: String
    let createdAt: String

    static func current(projectURL: URL, mode: String) -> ProjectLockRecord {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return ProjectLockRecord(
            schemaVersion: 1,
            toolName: "lungfish project lock",
            appVersion: ProjectCommandMetadata.appVersion,
            projectPath: projectURL.standardizedFileURL.path,
            mode: mode,
            user: ProjectCommandMetadata.currentUser,
            host: ProcessInfo.processInfo.hostName,
            pid: pid,
            processStartTime: ProjectProcessInspector.processStartTime(for: pid) ?? ProjectCommandMetadata.nowString(),
            cwd: FileManager.default.currentDirectoryPath,
            createdAt: ProjectCommandMetadata.nowString()
        )
    }
}

private struct ProjectUnlockOutput: Codable {
    let lockFile: String
    let removed: Bool
}

private enum ProjectLockStatus {
    case active
    case stale
    case unknown
}

private struct ProjectLockManager {
    let fileManager: FileManager

    func readLock(at lockURL: URL) throws -> ProjectLockRecord? {
        guard fileManager.fileExists(atPath: lockURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: lockURL)
        return try JSONDecoder().decode(ProjectLockRecord.self, from: data)
    }

    func writeLock(_ record: ProjectLockRecord, to lockURL: URL) throws {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: lockURL, options: [.atomic])
    }

    func status(of record: ProjectLockRecord) -> ProjectLockStatus {
        guard record.pid > 0 else {
            return .unknown
        }

        guard ProjectCommandMetadata.isLocalHost(record.host) else {
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

    func isOwnedByCurrentProcess(_ record: ProjectLockRecord) -> Bool {
        record.user == ProjectCommandMetadata.currentUser
            && ProjectCommandMetadata.isLocalHost(record.host)
            && record.pid == Int(ProcessInfo.processInfo.processIdentifier)
    }
}

private enum ProjectProcessInspector {
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

private enum ProjectCommandMetadata {
    static var appVersion: String {
        "lungfish-cli \(LungfishCLI.configuration.version)"
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

private struct ProjectBundleMigrator {
    static let currentReferenceFormatVersion = "1.0"

    let fileManager: FileManager

    func migrate(projectURL: URL, dryRun: Bool) throws -> ProjectMigrationReport {
        let bundleURLs = try findBundles(in: projectURL)
        var entries: [ProjectMigrationBundleReport] = []

        for bundleURL in bundleURLs {
            entries.append(inspect(bundleURL: bundleURL, projectURL: projectURL, dryRun: dryRun))
        }

        return ProjectMigrationReport(
            toolName: "lungfish project migrate",
            appVersion: ProjectCommandMetadata.appVersion,
            projectPath: projectURL.path,
            dryRun: dryRun,
            bundles: entries,
            summary: ProjectMigrationSummary(
                inspected: entries.count,
                current: entries.filter { $0.status == "current" }.count,
                unsupported: entries.filter { $0.status == "unsupported" || $0.status == "unreadable" }.count,
                migrated: entries.filter { $0.status == "migrated" }.count
            )
        )
    }

    private func findBundles(in projectURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var bundles: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            if isBundleDirectory(url) {
                bundles.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return bundles.sorted { $0.path < $1.path }
    }

    private func isBundleDirectory(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard ext.hasPrefix("lungfish"), ext != "lungfish" else {
            return false
        }
        return fileManager.fileExists(atPath: url.appendingPathComponent(BundleManifest.filename).path)
    }

    private func inspect(bundleURL: URL, projectURL: URL, dryRun: Bool) -> ProjectMigrationBundleReport {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let hasProvenance = fileManager.fileExists(atPath: provenanceURL.path)
        let relativePath = ProjectBundleMigrator.relativePath(from: projectURL, to: bundleURL)

        do {
            let manifest = try BundleManifest.load(from: bundleURL)
            if manifest.formatVersion == Self.currentReferenceFormatVersion {
                return ProjectMigrationBundleReport(
                    path: relativePath,
                    manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                    formatVersion: manifest.formatVersion,
                    status: "current",
                    action: "none",
                    provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                    provenancePreserved: hasProvenance,
                    message: "Bundle is already at the current supported schema."
                )
            }

            return ProjectMigrationBundleReport(
                path: relativePath,
                manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                formatVersion: manifest.formatVersion,
                status: "unsupported",
                action: dryRun ? "dry-run-report" : "report-only",
                provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                provenancePreserved: hasProvenance,
                message: "No safe transformer is registered for this bundle schema; bundle was not modified."
            )
        } catch {
            return ProjectMigrationBundleReport(
                path: relativePath,
                manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                formatVersion: nil,
                status: "unreadable",
                action: "report-only",
                provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                provenancePreserved: hasProvenance,
                message: "Manifest could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    private static func relativePath(from baseURL: URL, to url: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents

        if targetComponents.starts(with: baseComponents) {
            return targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
        }
        return url.standardizedFileURL.path
    }
}

private struct ProjectMigrationReport: Codable {
    let toolName: String
    let appVersion: String
    let projectPath: String
    let dryRun: Bool
    let bundles: [ProjectMigrationBundleReport]
    let summary: ProjectMigrationSummary
}

private struct ProjectMigrationSummary: Codable {
    let inspected: Int
    let current: Int
    let unsupported: Int
    let migrated: Int
}

private struct ProjectMigrationBundleReport: Codable {
    let path: String
    let manifestPath: String
    let formatVersion: String?
    let status: String
    let action: String
    let provenanceSidecar: String?
    let provenancePreserved: Bool
    let message: String
}

private enum ProjectCommandError: Error, LocalizedError {
    case projectNotFound(path: String)
    case alreadyLocked(lockURL: URL, record: ProjectLockRecord)
    case foreignLock(lockURL: URL, record: ProjectLockRecord)

    var errorDescription: String? {
        switch self {
        case .projectNotFound(let path):
            return "Project directory not found: \(path)"
        case .alreadyLocked(let lockURL, let record):
            return "Project is already locked at \(lockURL.path) by \(record.user)@\(record.host) pid \(record.pid) mode \(record.mode)."
        case .foreignLock(let lockURL, let record):
            return "Refusing to remove lock at \(lockURL.path) owned by \(record.user)@\(record.host) pid \(record.pid); pass --force to override."
        }
    }
}
