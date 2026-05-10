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
            let lockURL = ProjectLockManager.lockURL(for: projectURL)
            let manager = ProjectLockManager(fileManager: .default)

            if let existing = try manager.readLock(at: lockURL) {
                let status = manager.status(of: existing)
                if (status == .active || status == .unknown) && !force {
                    throw ProjectCommandError.alreadyLocked(lockURL: lockURL, record: existing)
                }
            }

            let record = ProjectLockRecord.current(
                projectURL: projectURL,
                mode: mode,
                toolName: "lungfish project lock",
                appVersion: ProjectCommandMetadata.appVersion
            )
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
            let lockURL = ProjectLockManager.lockURL(for: projectURL)
            let manager = ProjectLockManager(fileManager: .default)

            guard let record = try manager.readLock(at: lockURL) else {
                if !globalOptions.quiet {
                    print("No project lock found: \(lockURL.path)")
                }
                return
            }

            if !force && !manager.canRemoveWithoutForce(record) {
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

}

private struct ProjectUnlockOutput: Codable {
    let lockFile: String
    let removed: Bool
}

private enum ProjectCommandMetadata {
    static var appVersion: String {
        "lungfish-cli \(LungfishCLI.configuration.version)"
    }

}

private struct ProjectBundleMigrator {
    static let currentReferenceFormatVersion = "1.0"

    let fileManager: FileManager

    func migrate(projectURL: URL, dryRun: Bool) throws -> ProjectMigrationReport {
        let bundleURLs = try findBundles(in: projectURL)
        var entries: [ProjectMigrationBundleReport] = []

        for bundleURL in bundleURLs {
            entries.append(try inspect(bundleURL: bundleURL, projectURL: projectURL, dryRun: dryRun))
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

    private func inspect(bundleURL: URL, projectURL: URL, dryRun: Bool) throws -> ProjectMigrationBundleReport {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let hasProvenance = fileManager.fileExists(atPath: provenanceURL.path)
        let relativePath = ProjectBundleMigrator.relativePath(from: projectURL, to: bundleURL)

        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            return ProjectMigrationBundleReport(
                path: relativePath,
                manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                formatVersion: nil,
                status: "unreadable",
                action: "report-only",
                provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                provenancePreserved: hasProvenance,
                migrationProvenanceSidecar: nil,
                backupPath: nil,
                message: "Manifest could not be decoded: \(error.localizedDescription)"
            )
        }

        if manifest.formatVersion == Self.currentReferenceFormatVersion,
           manifest.browserSummary == nil,
           manifest.withSynthesizedBrowserSummaryIfNeeded().browserSummary != nil {
            if dryRun {
                return ProjectMigrationBundleReport(
                    path: relativePath,
                    manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                    formatVersion: manifest.formatVersion,
                    status: "migration-available",
                    action: "dry-run-synthesize-browser-summary",
                    provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                    provenancePreserved: hasProvenance,
                    migrationProvenanceSidecar: nil,
                    backupPath: nil,
                    message: "Bundle manifest predates browser_summary; migration would synthesize the cache without changing payload files."
                )
            }

            return try migrateLegacyBrowserSummary(
                manifest: manifest,
                bundleURL: bundleURL,
                projectURL: projectURL,
                hasCreationProvenance: hasProvenance,
                creationProvenanceURL: provenanceURL
            )
        }

        if manifest.formatVersion == Self.currentReferenceFormatVersion {
            return ProjectMigrationBundleReport(
                path: relativePath,
                manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
                formatVersion: manifest.formatVersion,
                status: "current",
                action: "none",
                provenanceSidecar: hasProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL) : nil,
                provenancePreserved: hasProvenance,
                migrationProvenanceSidecar: nil,
                backupPath: nil,
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
            migrationProvenanceSidecar: nil,
            backupPath: nil,
            message: "No safe transformer is registered for this bundle schema; bundle was not modified."
        )
    }

    private func migrateLegacyBrowserSummary(
        manifest: BundleManifest,
        bundleURL: URL,
        projectURL: URL,
        hasCreationProvenance: Bool,
        creationProvenanceURL: URL
    ) throws -> ProjectMigrationBundleReport {
        let startedAt = Date()
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let inputRecords = migrationInputRecords(manifestURL: manifestURL, creationProvenanceURL: creationProvenanceURL)
        let timestamp = Self.provenanceTimestampString(from: startedAt)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        let migrationDirectory = bundleURL
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("migrations", isDirectory: true)
        try fileManager.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)

        let backupURL = migrationDirectory.appendingPathComponent("\(timestamp).manifest.json.backup")
        try fileManager.copyItem(at: manifestURL, to: backupURL)

        let migratedManifest = manifest.withSynthesizedBrowserSummaryIfNeeded()
        try migratedManifest.save(to: bundleURL)

        let outputRecords = [
            ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output),
            ProvenanceRecorder.fileRecord(url: backupURL, format: .json, role: .output),
        ]
        let provenanceURL = migrationDirectory.appendingPathComponent("\(timestamp).project-migrate-provenance.json")
        try writeMigrationProvenance(
            projectURL: projectURL,
            bundleURL: bundleURL,
            manifestURL: manifestURL,
            backupURL: backupURL,
            provenanceURL: provenanceURL,
            startedAt: startedAt,
            inputs: inputRecords,
            outputs: outputRecords
        )

        let relativePath = ProjectBundleMigrator.relativePath(from: projectURL, to: bundleURL)
        return ProjectMigrationBundleReport(
            path: relativePath,
            manifestPath: ProjectBundleMigrator.relativePath(from: projectURL, to: manifestURL),
            formatVersion: manifest.formatVersion,
            status: "migrated",
            action: "synthesized-browser-summary",
            provenanceSidecar: hasCreationProvenance ? ProjectBundleMigrator.relativePath(from: projectURL, to: creationProvenanceURL) : nil,
            provenancePreserved: hasCreationProvenance,
            migrationProvenanceSidecar: ProjectBundleMigrator.relativePath(from: projectURL, to: provenanceURL),
            backupPath: ProjectBundleMigrator.relativePath(from: projectURL, to: backupURL),
            message: "Synthesized browser_summary from genome chromosomes; original manifest was backed up before writing."
        )
    }

    private func migrationInputRecords(manifestURL: URL, creationProvenanceURL: URL) -> [FileRecord] {
        var records = [
            ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .input)
        ]
        if fileManager.fileExists(atPath: creationProvenanceURL.path) {
            records.append(ProvenanceRecorder.fileRecord(url: creationProvenanceURL, format: .json, role: .input))
        }
        return records
    }

    private func writeMigrationProvenance(
        projectURL: URL,
        bundleURL: URL,
        manifestURL: URL,
        backupURL: URL,
        provenanceURL: URL,
        startedAt: Date,
        inputs: [FileRecord],
        outputs: [FileRecord]
    ) throws {
        let endedAt = Date()
        let wallTime = max(endedAt.timeIntervalSince(startedAt), 0.000001)
        let command = Self.reproducibleCommand(projectURL: projectURL, dryRun: false)
        let step = StepExecution(
            toolName: "lungfish project migrate",
            toolVersion: ProjectCommandMetadata.appVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: wallTime,
            stderr: nil,
            startTime: startedAt,
            endTime: endedAt
        )
        let run = WorkflowRun(
            name: "lungfish project migrate browser-summary",
            startTime: startedAt,
            endTime: endedAt,
            status: .completed,
            appVersion: ProjectCommandMetadata.appVersion,
            hostOS: WorkflowRun.currentHostOS,
            runtime: WorkflowRuntime(
                appVersion: ProjectCommandMetadata.appVersion,
                hostOS: WorkflowRun.currentHostOS,
                user: WorkflowRun.currentUser
            ),
            steps: [step],
            parameters: [
                "workflowName": .string("lungfish project migrate"),
                "transformer": .string("reference-manifest-browser-summary-v1"),
                "sourceSchema": .string("format_version=1.0 missing browser_summary"),
                "targetSchema": .string("format_version=1.0 with browser_summary"),
                "projectPath": .file(projectURL),
                "bundlePath": .file(bundleURL),
                "sourceManifest": .file(manifestURL),
                "targetManifest": .file(manifestURL),
                "backupManifest": .file(backupURL),
                "dryRun": .boolean(false),
                "currentReferenceFormatVersion": .string(Self.currentReferenceFormatVersion),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
    }

    private static func provenanceTimestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func reproducibleCommand(projectURL: URL, dryRun: Bool) -> [String] {
        var command = ["lungfish", "project", "migrate", projectURL.path]
        if dryRun {
            command.append("--dry-run")
        }
        return command
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
    let migrationProvenanceSidecar: String?
    let backupPath: String?
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
