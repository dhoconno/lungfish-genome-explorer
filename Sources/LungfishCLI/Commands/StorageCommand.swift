// StorageCommand.swift - Managed storage inspection and cross-channel deduplication
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Inspect managed storage and reclaim duplicate space across channels.
struct StorageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Inspect managed storage roots and reclaim duplicate space",
        discussion: """
        Each channel (Preview, stable, Debug) keeps its own managed storage root.
        Identical databases and conda packages are stored once with APFS clones.
        'storage dedupe' finds duplicate files across the roots and replaces each
        duplicate with a clone of one kept copy, and 'storage info' prints the roots
        this command line resolves.
        """,
        subcommands: [
            InfoSubcommand.self,
            DedupeSubcommand.self,
        ]
    )
}

extension StorageCommand {
    /// Default roots: every channel root that exists plus the shared root.
    static func defaultRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ManagedStorageChannelRoots.existingRoots(homeDirectory: homeDirectory)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Info

extension StorageCommand {
    struct InfoSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Print the storage roots this command line resolves"
        )

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        struct Report: Codable {
            let channel: String
            let appName: String
            let storageRoot: String
            let condaRoot: String
            let databaseRoot: String
            let sharedCondaPackageCache: String
            let knownChannelRoots: [String]
        }

        func run() async throws {
            let identity = LungfishAppIdentity.current
            let store = ManagedStorageConfigStore()
            let location = store.currentLocation()
            let report = Report(
                channel: identity.releaseChannel.rawValue,
                appName: identity.fullName,
                storageRoot: location.rootURL.path,
                condaRoot: store.currentCondaRootURL().path,
                databaseRoot: location.databaseRootURL.path,
                sharedCondaPackageCache: CondaSharedPackageCache().sharedCacheURL?.path ?? "disabled",
                knownChannelRoots: ManagedStorageChannelRoots.knownChannelRoots().map(\.path)
            )
            switch globalOptions.outputFormat {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                Swift.print(String(decoding: try encoder.encode(report), as: UTF8.self))
            default:
                Swift.print("Channel:               \(report.channel) (\(report.appName))")
                Swift.print("Storage root:          \(report.storageRoot)")
                Swift.print("Conda root:            \(report.condaRoot)")
                Swift.print("Database root:         \(report.databaseRoot)")
                Swift.print("Shared package cache:  \(report.sharedCondaPackageCache)")
                Swift.print("Known channel roots:")
                for root in report.knownChannelRoots { Swift.print("  \(root)") }
            }
        }
    }
}

// MARK: - Dedupe

extension StorageCommand {
    struct DedupeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dedupe",
            abstract: "Replace duplicate files across storage roots with APFS clones",
            discussion: """
            Scans databases/, conda/pkgs/ and conda/envs/ under each root, groups regular
            files by size and SHA-256, and replaces every duplicate with a clone of one kept
            copy. Each clone is verified (size and SHA-256), keeps the original's mode,
            extended attributes and times, and is renamed over the duplicate so open readers
            keep their old file. Files already sharing blocks, files another process holds
            open, and files with hard links outside the scanned roots are left alone.

            The default is a dry run. Pass --apply to reclaim space. --apply refuses to run
            while a managed install or download holds a root busy.
            """
        )

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        @Option(name: .customLong("roots"), parsing: .upToNextOption,
                help: "Storage roots to scan. The default is every channel root that exists plus ~/.lungfish-shared.")
        var roots: [String] = []

        @Flag(name: .customLong("dry-run"), help: "Report duplicates without changing anything (default).")
        var dryRun: Bool = false

        @Flag(name: .customLong("apply"), help: "Replace duplicates with verified clones and reclaim space.")
        var apply: Bool = false

        @Flag(name: .customLong("skip-envs"), help: "Do not scan conda/envs/ (hardlinked package files then stay unshared).")
        var skipEnvironments: Bool = false

        func validate() throws {
            if dryRun && apply {
                throw ValidationError("Pass either --dry-run or --apply, not both.")
            }
            for root in roots where !root.hasPrefix("/") {
                throw ValidationError("Storage roots must be absolute paths: \(root)")
            }
        }

        func run() async throws {
            let resolvedRoots = roots.isEmpty
                ? StorageCommand.defaultRoots()
                : roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            guard !resolvedRoots.isEmpty else {
                throw ValidationError("No managed storage roots exist to scan.")
            }
            let options = ManagedStorageDedupeOptions(roots: resolvedRoots, includeCondaEnvironments: !skipEnvironments)
            let deduplicator = ManagedStorageDeduplicator()
            let quiet = globalOptions.quiet || globalOptions.outputFormat == .json
            let progress: ManagedStorageDeduplicator.ProgressHandler? = quiet ? nil : { @Sendable message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            let report = try apply
                ? deduplicator.apply(options, progress: progress)
                : deduplicator.dryRun(options, progress: progress)
            Self.print(report, format: globalOptions.outputFormat)
        }

        static func print(_ report: ManagedStorageDedupeReport, format: OutputFormat) {
            if format == .json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(report) {
                    Swift.print(String(decoding: data, as: UTF8.self))
                }
                return
            }
            let applied = report.mode == .apply
            Swift.print(applied ? "Storage dedupe (applied)" : "Storage dedupe (dry run, nothing changed)")
            Swift.print("Files examined:        \(report.filesExamined) (\(formatBytes(report.bytesExamined)))")
            Swift.print("Files hashed:          \(report.filesHashed)")
            Swift.print("Duplicate sets:        \(report.duplicateSets)")
            Swift.print("Duplicate files:       \(report.duplicateFiles)")
            Swift.print("Already shared:        \(formatBytes(report.bytesAlreadyShared))")
            Swift.print("Reclaimable:           \(formatBytes(report.bytesReclaimable))")
            if applied {
                Swift.print("Reclaimed:             \(formatBytes(report.bytesReclaimed))")
                Swift.print("Files replaced:        \(report.replacements.count)")
            }
            if report.filesOpenElsewhere > 0 {
                Swift.print("Skipped (open):        \(report.filesOpenElsewhere)")
            }
            if report.filesWithExternalLinks > 0 {
                Swift.print("Skipped (ext. links):  \(report.filesWithExternalLinks)")
            }
            Swift.print("")
            Swift.print("Per root:")
            for root in report.roots {
                let reclaimed = applied ? ", reclaimed \(formatBytes(root.bytesReclaimed))" : ""
                Swift.print("  \(root.path): \(root.filesExamined) files, \(root.duplicateFiles) duplicates, reclaimable \(formatBytes(root.bytesReclaimable))\(reclaimed)")
            }
            if !report.blockers.isEmpty {
                Swift.print("")
                Swift.print("Installs in progress (apply would refuse):")
                for blocker in report.blockers { Swift.print("  \(blocker)") }
            }
            if !report.failures.isEmpty {
                Swift.print("")
                Swift.print("Failures:")
                for failure in report.failures { Swift.print("  \(failure)") }
            }
            if applied {
                Swift.print("")
                Swift.print("A record was appended to \(ManagedStorageDeduplicator.logFilename) under each root.")
            } else if report.bytesReclaimable > 0 {
                Swift.print("")
                Swift.print("Run again with --apply to reclaim the space.")
            }
        }
    }
}
