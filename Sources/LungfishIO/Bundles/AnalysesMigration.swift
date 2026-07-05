// AnalysesMigration.swift - Migrate analysis results from derivatives/ to Analyses/
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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

        // 1. Find all .lungfishfastq bundles as direct children of projectURL
        let projectContents = try fm.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let bundles = projectContents.filter {
            $0.pathExtension.lowercased() == "lungfishfastq" &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

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

                // 4. Extract timestamp from the sidecar's savedAt field
                let date = extractTimestamp(from: candidateURL) ?? Date()
                let timestamp = AnalysesFolder.formatTimestamp(date)

                // 5. Determine destination: Analyses/{tool}-{timestamp}/
                let analysesDir = try AnalysesFolder.url(for: projectURL)
                let destName = "\(tool)-\(timestamp)"
                let destURL = analysesDir.appendingPathComponent(destName, isDirectory: true)

                // Skip if destination already exists (idempotent)
                if fm.fileExists(atPath: destURL.path) {
                    logger.info("Migration: skipping \(name), destination \(destName) already exists")
                    continue
                }

                // 6. Move directory to Analyses/{tool}-{timestamp}/
                // Wrapped in do/catch so one failed migration does not abort the rest.
                do {
                    try fm.moveItem(at: candidateURL, to: destURL)
                    logger.info("Migration: moved \(name) -> Analyses/\(destName)")
                } catch {
                    logger.error("Migration: failed to move \(name) -> Analyses/\(destName): \(error.localizedDescription, privacy: .public)")
                    continue
                }

                // 7. Record in analyses-manifest.json of the source bundle.
                // If this fails, roll the move back so discovery state and bundle-owned
                // history cannot diverge.
                do {
                    let entry = AnalysisManifestEntry(
                        tool: tool,
                        timestamp: date,
                        analysisDirectoryName: destName,
                        displayName: AnalysesFolder.displayName(for: tool),
                        summary: "Migrated from derivatives/\(name)"
                    )
                    try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
                } catch {
                    do {
                        if !fm.fileExists(atPath: candidateURL.path) {
                            try fm.moveItem(at: destURL, to: candidateURL)
                        }
                    } catch {
                        logger.error("Migration: failed to roll back \(destName) after manifest-record failure: \(error.localizedDescription, privacy: .public)")
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

    /// Extract timestamp from sidecar JSON's savedAt field.
    // ISO8601DateFormatter is internally synchronized; shared access is safe.
    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    private static func extractTimestamp(from analysisDir: URL) -> Date? {
        let sidecarNames = [
            "esviritu-result.json",
            "classification-result.json",
            "taxtriage-result.json",
        ]
        for name in sidecarNames {
            let sidecarURL = analysisDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecarURL) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let savedAtString = json["savedAt"] as? String,
               let date = iso8601Formatter.date(from: savedAtString) {
                return date
            }
        }
        return nil
    }
}
