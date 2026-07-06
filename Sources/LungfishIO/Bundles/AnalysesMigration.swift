// AnalysesMigration.swift - Migrate analysis results from derivatives/ to Analyses/
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: LogSubsystem.io, category: "AnalysesMigration")

public enum AnalysesMigration {

    /// Analysis directory prefixes that should be migrated from derivatives/.
    private static let analysisPrefixes = [
        "classification-", "esviritu-", "taxtriage-", "naomgs-", "nvd-",
    ]

    /// Maps a directory prefix to the tool name used in Analyses/.
    private static func toolForPrefix(_ prefix: String) -> String {
        switch prefix {
        case "classification-": return "kraken2"
        case "esviritu-": return "esviritu"
        case "taxtriage-": return "taxtriage"
        case "naomgs-": return "naomgs"
        case "nvd-": return "nvd"
        default: return prefix.replacingOccurrences(of: "-", with: "")
        }
    }

    /// Scans all .lungfishfastq bundles for analysis results in derivatives/
    /// and moves them to Analyses/. Returns count of directories migrated.
    @discardableResult
    public static func migrateProject(at projectURL: URL) throws -> Int {
        let fm = FileManager.default
        var totalMigrated = 0

        // 1. Find all .lungfishfastq bundles in project folders without
        // descending into any Lungfish bundle payload.
        let bundles = try fastqBundleURLs(in: projectURL, fileManager: fm)

        for bundleURL in bundles {
            let derivativesURL = bundleURL.appendingPathComponent("derivatives", isDirectory: true)

            // Skip bundles with no derivatives directory
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: derivativesURL.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            // 2. Scan derivatives/ for directories matching analysisPrefixes
            let derivContents = try fm.contentsOfDirectory(
                at: derivativesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for candidateURL in derivContents {
                let name = candidateURL.lastPathComponent

                // 3. Skip .lungfishfastq directories — those are FASTQ-to-FASTQ transforms, not analyses
                if candidateURL.pathExtension.lowercased() == "lungfishfastq" {
                    continue
                }

                // Only consider subdirectories
                guard (try? candidateURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                // Find matching prefix
                guard let matchedPrefix = analysisPrefixes.first(where: { name.hasPrefix($0) }) else {
                    continue
                }

                let tool = toolForPrefix(matchedPrefix)
                let migrationStartedAt = Date()
                let sourceFiles = try migrationFileDescriptors(
                    in: candidateURL,
                    role: "input",
                    originRoot: candidateURL
                )
                let sourceDirectory = try migrationDirectoryDescriptor(
                    url: candidateURL,
                    role: "input",
                    originPath: candidateURL.path
                )

                // 4. Prefer the legacy sidecar timestamp when present.
                let date = extractTimestamp(from: candidateURL) ?? Date()
                let timestamp = AnalysesFolder.formatTimestamp(date)

                // 5. Determine destination: Analyses/{tool}-{timestamp}/
                let analysesDir = try AnalysesFolder.url(for: projectURL)

                // 6. Move directory to Analyses/{tool}-{timestamp}/
                // Move failures are skipped; metadata or manifest failures below
                // roll back the move and abort so history cannot diverge.
                let moved: MigrationDestination
                do {
                    moved = try moveAnalysisDirectory(
                        at: candidateURL,
                        toUniqueDestinationNamed: "\(tool)-\(timestamp)",
                        in: analysesDir,
                        fileManager: fm
                    )
                    logger.info("Migration: moved \(name) -> Analyses/\(moved.name)")
                } catch {
                    logger.error("Migration: failed to move \(name) into Analyses/: \(error.localizedDescription, privacy: .public)")
                    continue
                }

                // 7. Record in analyses-manifest.json of the source bundle.
                // If this fails, roll the move back so discovery state and bundle-owned
                // history cannot diverge.
                do {
                    try AnalysesFolder.writeAnalysisMetadata(
                        AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: false, created: date),
                        to: moved.url
                    )
                    let entry = AnalysisManifestEntry(
                        tool: tool,
                        timestamp: date,
                        analysisDirectoryName: moved.name,
                        displayName: AnalysesFolder.displayName(for: tool),
                        summary: "Migrated from derivatives/\(name)"
                    )
                    try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
                    try writeMigrationProvenance(
                        projectURL: projectURL,
                        bundleURL: bundleURL,
                        sourceURL: candidateURL,
                        destinationURL: moved.url,
                        tool: tool,
                        sourceDirectory: sourceDirectory,
                        sourceFiles: sourceFiles,
                        startedAt: migrationStartedAt
                    )
                } catch {
                    do {
                        if !fm.fileExists(atPath: candidateURL.path) {
                            try fm.moveItem(at: moved.url, to: candidateURL)
                        }
                    } catch {
                        logger.error("Migration: failed to roll back \(moved.name) after manifest-record failure: \(error.localizedDescription, privacy: .public)")
                    }
                    logger.error("Migration: refused \(name) because manifest recording failed: \(error.localizedDescription, privacy: .public)")
                    throw error
                }

                totalMigrated += 1
            }
        }

        if totalMigrated > 0 {
            logger.info("Migration: migrated \(totalMigrated) analysis director\(totalMigrated == 1 ? "y" : "ies") in \(projectURL.lastPathComponent)")
        }

        return totalMigrated
    }

    /// Best-effort timestamp extraction from known legacy analysis sidecars.
    private static func extractTimestamp(from analysisDir: URL) -> Date? {
        let sidecarNames = [
            "esviritu-result.json",
            "classification-result.json",
            "taxtriage-result.json",
            "manifest.json",
        ]
        let iso8601Formatter = ISO8601DateFormatter()
        for name in sidecarNames {
            let sidecarURL = analysisDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecarURL) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let timestamp = (json["savedAt"] ?? json["importDate"]) as? String,
               let date = iso8601Formatter.date(from: timestamp) {
                return date
            }
        }
        return nil
    }

    private static func fastqBundleURLs(in projectURL: URL, fileManager: FileManager) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var bundles: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: resourceKeys).isDirectory) == true else {
                continue
            }

            if url.pathExtension.lowercased() == "lungfishfastq" {
                bundles.append(url)
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension.lowercased().hasPrefix("lungfish") {
                enumerator.skipDescendants()
            }
        }
        return bundles.sorted { $0.path < $1.path }
    }

    private struct MigrationDestination {
        let name: String
        let url: URL
    }

    private static func moveAnalysisDirectory(
        at sourceURL: URL,
        toUniqueDestinationNamed baseName: String,
        in analysesDir: URL,
        fileManager: FileManager
    ) throws -> MigrationDestination {
        for attempt in 0..<1_000 {
            let name = attempt == 0 ? baseName : "\(baseName)-\(attempt + 1)"
            let destinationURL = analysesDir.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return MigrationDestination(name: name, url: destinationURL)
            } catch {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    continue
                }
                throw error
            }
        }

        throw CocoaError(
            .fileWriteFileExists,
            userInfo: [
                NSFilePathErrorKey: analysesDir.appendingPathComponent(baseName, isDirectory: true).path,
                NSLocalizedDescriptionKey: "Could not create a unique migrated analysis directory for \(baseName)"
            ]
        )
    }
}

// MARK: - Migration Provenance

private extension AnalysesMigration {
    struct MigrationProvenanceEnvelope: Encodable {
        let schemaVersion = 1
        let id = UUID()
        let createdAt: Date
        let workflowName: String
        let workflowVersion: String
        let toolName: String
        let toolVersion: String
        let tool: MigrationProvenanceTool
        let argv: [String]
        let durableReplayArgv: [String]
        let reproducibleCommand: String
        let options: MigrationProvenanceOptions
        let runtimeIdentity: MigrationProvenanceRuntimeIdentity
        let files: [MigrationProvenanceFileDescriptor]
        let output: MigrationProvenanceFileDescriptor
        let outputs: [MigrationProvenanceFileDescriptor]
        let steps: [MigrationProvenanceStep]
        let wallTimeSeconds: TimeInterval
        let exitStatus: Int
        let stderr: String
        let signatures: [String] = []
    }

    struct MigrationProvenanceTool: Encodable {
        let name: String
        let version: String
        let kind: String
    }

    struct MigrationProvenanceRuntimeIdentity: Encodable {
        let appVersion: String
        let executablePath: String
        let processIdentifier: Int
        let operatingSystemVersion: String
        let architecture: String
        let user: String?
    }

    struct MigrationProvenanceOptions: Encodable {
        let explicit: [String: String]
        let defaults: [String: String]
        let resolvedDefaults: [String: String]
    }

    struct MigrationProvenanceFileDescriptor: Encodable {
        let path: String
        let checksumSHA256: String
        let sha256: String
        let fileSize: UInt64
        let sizeBytes: UInt64
        let format: String?
        let role: String
        let originPath: String?

        init(
            path: String,
            checksumSHA256: String,
            fileSize: UInt64,
            format: String? = nil,
            role: String,
            originPath: String? = nil
        ) {
            self.path = path
            self.checksumSHA256 = checksumSHA256
            self.sha256 = checksumSHA256
            self.fileSize = fileSize
            self.sizeBytes = fileSize
            self.format = format
            self.role = role
            self.originPath = originPath
        }
    }

    struct MigrationProvenanceStep: Encodable {
        let id = UUID()
        let toolName: String
        let toolVersion: String
        let argv: [String]
        let command: [String]
        let durableReplayArgv: [String]
        let reproducibleCommand: String
        let inputs: [MigrationProvenanceFileDescriptor]
        let outputs: [MigrationProvenanceFileDescriptor]
        let exitStatus: Int
        let exitCode: Int
        let wallTimeSeconds: TimeInterval
        let wallTime: TimeInterval
        let stderr: String
        let dependsOn: [UUID] = []
        let startedAt: Date
        let completedAt: Date
    }

    static func writeMigrationProvenance(
        projectURL: URL,
        bundleURL: URL,
        sourceURL: URL,
        destinationURL: URL,
        tool: String,
        sourceDirectory: MigrationProvenanceFileDescriptor,
        sourceFiles: [MigrationProvenanceFileDescriptor],
        startedAt: Date
    ) throws {
        let completedAt = Date()
        let outputFiles = try migrationFileDescriptors(
            in: destinationURL,
            role: "output",
            originRoot: sourceURL
        )
        let outputDirectory = try migrationDirectoryDescriptor(
            url: destinationURL,
            role: "output",
            originPath: sourceURL.path
        )
        let argv = ["lungfish-internal", "analyses", "migrate", "--project", projectURL.path]
        let version = migrationAppVersion
        let wallTime = completedAt.timeIntervalSince(startedAt)
        let allFiles = uniqueMigrationDescriptors(
            [sourceDirectory] + sourceFiles + [outputDirectory] + outputFiles
        )
        let replayCommand = argv.map(shellEscapeForMigrationProvenance).joined(separator: " ")
        let step = MigrationProvenanceStep(
            toolName: "lungfish analyses migrate",
            toolVersion: version,
            argv: argv,
            command: argv,
            durableReplayArgv: argv,
            reproducibleCommand: replayCommand,
            inputs: [sourceDirectory] + sourceFiles,
            outputs: [outputDirectory] + outputFiles,
            exitStatus: 0,
            exitCode: 0,
            wallTimeSeconds: wallTime,
            wallTime: wallTime,
            stderr: "",
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = MigrationProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish analyses migrate",
            workflowVersion: version,
            toolName: "lungfish analyses migrate",
            toolVersion: version,
            tool: MigrationProvenanceTool(name: "lungfish analyses migrate", version: version, kind: "app"),
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: replayCommand,
            options: MigrationProvenanceOptions(
                explicit: [
                    "tool": tool,
                    "sourceBundle": standardizedPathForMigrationProvenance(bundleURL),
                    "legacyAnalysisDirectory": standardizedPathForMigrationProvenance(sourceURL),
                ],
                defaults: [
                    "migrationMode": "move",
                    "rollbackOnMetadataFailure": "true",
                ],
                resolvedDefaults: [
                    "analysisDirectory": standardizedPathForMigrationProvenance(destinationURL),
                    "project": standardizedPathForMigrationProvenance(projectURL),
                    "sourceBundle": standardizedPathForMigrationProvenance(bundleURL),
                ]
            ),
            runtimeIdentity: MigrationProvenanceRuntimeIdentity(
                appVersion: version,
                executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown",
                processIdentifier: Int(ProcessInfo.processInfo.processIdentifier),
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: currentArchitecture,
                user: currentUser
            ),
            files: allFiles,
            output: outputDirectory,
            outputs: [outputDirectory] + outputFiles,
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0,
            stderr: ""
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(
            to: destinationURL.appendingPathComponent(".lungfish-provenance.json"),
            options: .atomic
        )
    }

    static func migrationFileDescriptors(
        in rootURL: URL,
        role: String,
        originRoot: URL
    ) throws -> [MigrationProvenanceFileDescriptor] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var descriptors: [MigrationProvenanceFileDescriptor] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = relativePathForMigrationProvenance(fileURL, root: rootURL)
            let originPath = originRoot.appendingPathComponent(relativePath).path
            descriptors.append(
                MigrationProvenanceFileDescriptor(
                    path: standardizedPathForMigrationProvenance(fileURL),
                    checksumSHA256: try sha256HexForMigrationProvenance(at: fileURL),
                    fileSize: UInt64(values.fileSize ?? 0),
                    format: formatForMigrationProvenance(fileURL),
                    role: role,
                    originPath: standardizedPathForMigrationProvenance(URL(fileURLWithPath: originPath))
                )
            )
        }
        return descriptors.sorted { $0.path < $1.path }
    }

    static func migrationDirectoryDescriptor(
        url: URL,
        role: String,
        originPath: String
    ) throws -> MigrationProvenanceFileDescriptor {
        let manifest = try directoryManifestForMigrationProvenance(at: url)
        return MigrationProvenanceFileDescriptor(
            path: standardizedPathForMigrationProvenance(url),
            checksumSHA256: manifest.checksum,
            fileSize: manifest.size,
            format: "unknown",
            role: role,
            originPath: standardizedPathForMigrationProvenance(URL(fileURLWithPath: originPath))
        )
    }

    static func directoryManifestForMigrationProvenance(at rootURL: URL) throws -> (checksum: String, size: UInt64) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (sha256HexForMigrationProvenance(Data()), 0)
        }

        var totalSize: UInt64 = 0
        var entries: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = UInt64(values.fileSize ?? 0)
            totalSize += size
            let relativePath = relativePathForMigrationProvenance(fileURL, root: rootURL)
            let checksum = try sha256HexForMigrationProvenance(at: fileURL)
            entries.append("\(relativePath)\t\(checksum)\t\(size)")
        }
        entries.sort()
        return (sha256HexForMigrationProvenance(Data(entries.joined(separator: "\n").utf8)), totalSize)
    }

    static func uniqueMigrationDescriptors(
        _ descriptors: [MigrationProvenanceFileDescriptor]
    ) -> [MigrationProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [MigrationProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    static func sha256HexForMigrationProvenance(at url: URL) throws -> String {
        try sha256HexForMigrationProvenance(Data(contentsOf: url))
    }

    static func sha256HexForMigrationProvenance(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func relativePathForMigrationProvenance(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    static func standardizedPathForMigrationProvenance(_ url: URL) -> String {
        normalizeMacOSTemporarySymlink(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    static func normalizeMacOSTemporarySymlink(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private\(path)" : path
    }

    static func formatForMigrationProvenance(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json":
            return "json"
        case "txt", "tsv", "csv":
            return "text"
        case "html", "htm":
            return "html"
        default:
            return "unknown"
        }
    }

    static var migrationAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static var currentUser: String? {
        let user = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
    }

    static func shellEscapeForMigrationProvenance(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/:=-.,+")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
