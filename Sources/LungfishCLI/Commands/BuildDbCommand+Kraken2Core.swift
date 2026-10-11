// BuildDbCommand+Kraken2Core.swift - The build-db kraken2 leaf and its core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Kraken2 Subcommand

extension BuildDbCommand {

    /// Build a SQLite database from Kraken2 pipeline output.
    ///
    /// Enumerates sample subdirectories, parses each `classification.kreport`
    /// via `KreportParser`, flattens the taxonomy tree into classification rows,
    /// and writes a `kraken2.sqlite` database in the result directory.
    ///
    /// Optionally compacts `classification.kraken` to `classification.kraken.gz`
    /// plus a classified-read SQLite index, and removes obsolete raw-output
    /// index sidecars after a successful build.
    struct Kraken2Subcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kraken2",
            abstract: "Build SQLite database from Kraken2 results"
        )

        @Argument(help: "Path to the Kraken2 result directory")
        var resultDir: String

        @Flag(name: .long, help: "Force rebuild even if database exists")
        var force: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Skip post-build cleanup of intermediate files")
        var noCleanup: Bool = false

        @Option(name: .customLong("sample-dir"), help: "Successful Kraken2 sample result directory to include. May be repeated.")
        var sampleDirs: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let resultURL = URL(fileURLWithPath: resultDir)
            let options = BuildDbRunOptions(
                force: force,
                noCleanup: noCleanup,
                sampleDirectories: sampleDirs.map { URL(fileURLWithPath: $0) },
                globalOptions: globalOptions
            )
            try await BuildDbCLIEvents(globalOptions: globalOptions).report(
                database: resultURL.appendingPathComponent("kraken2.sqlite")
            ) { events in
                try await Self.buildDatabase(in: resultURL, options: options, events: events)
            }
        }

        /// The `build-db kraken2` core. Builds `kraken2.sqlite` in `resultURL` from the Kraken 2 report of each
        /// sample folder, or of the folder itself when it holds one run, compacts the per-read output unless
        /// `options.noCleanup`, records the run beside the database and returns what it built. A database that
        /// exists is kept unless `options.force`.
        static func buildDatabase(
            in resultURL: URL,
            options: BuildDbRunOptions,
            events: BuildDbEventSink
        ) async throws -> BuildDbRunResult {
            let runClock = ProvenanceRunClock()
            let dbURL = resultURL.appendingPathComponent("kraken2.sqlite")
            let requestedSampleDirectories = options.sampleDirectories.map(\.standardizedFileURL)

            // Skip if exists (unless --force)
            if !options.force && FileManager.default.fileExists(atPath: dbURL.path) {
                let existing = BuildDbRunResult(databaseURL: dbURL, rowCount: nil, record: nil)
                events.text(existing.summary)
                return existing
            }

            let explicitSampleDirectories = try validatedExplicitSampleDirectories(requestedSampleDirectories)
            let provenanceInputs = BuildDbCommand.buildDbInputRecords(
                tool: .kraken2,
                resultURL: resultURL,
                sampleDirectories: explicitSampleDirectories
            )
            let databaseSnapshot = try BuildDbDatabaseSnapshot.capture(dbURL: dbURL)

            do {
                // 1. Enumerate sample subdirectories and parse kreport files
                let (rows, sampleMetadata) = try parseSampleDirectories(
                    resultURL: resultURL,
                    sampleDirectories: explicitSampleDirectories
                )

                events.text("Parsed \(rows.count) classification rows from Kraken2 results")

                // 2. Build database
                var metadata: [String: String] = [
                    "tool": "kraken2",
                    "created_at": ISO8601DateFormatter().string(from: Date()),
                    "source_dir": resultURL.path,
                ]
                // Merge per-sample tree statistics into metadata
                for (key, value) in sampleMetadata {
                    metadata[key] = value
                }

                try Kraken2Database.create(at: dbURL, rows: rows, metadata: metadata, progress: events.progress)

                events.text(BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: nil).summary)

                if !options.noCleanup {
                    performCleanup(resultURL: resultURL, sampleDirectories: explicitSampleDirectories, events: events)
                }

                let record = try await BuildDbCommand.recordBuildDbProvenance(
                    tool: .kraken2,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    sampleDirectories: explicitSampleDirectories,
                    events: events
                )
                try databaseSnapshot.discard()
                return BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: record)
            } catch {
                do {
                    try databaseSnapshot.restore()
                } catch {
                    events.warning("Warning: could not restore previous Kraken2 database: \(error.localizedDescription)")
                }
                await BuildDbCommand.recordBuildDbFailureProvenanceIfNeeded(
                    tool: .kraken2,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    error: error,
                    sampleDirectories: explicitSampleDirectories,
                    includeOutputRecords: false,
                    events: events
                )
                throw error
            }
        }

        // MARK: - Sample Directory Enumeration & Parsing

        /// Enumerates sample subdirectories under `resultURL` and parses kreport files.
        ///
        /// Returns classification rows and per-sample metadata for tree reconstruction.
        static func parseSampleDirectories(
            resultURL: URL,
            sampleDirectories: [URL] = []
        ) throws -> (rows: [Kraken2ClassificationRow], sampleMetadata: [String: String]) {
            let fm = FileManager.default
            let explicitSampleDirectories = try validatedExplicitSampleDirectories(sampleDirectories)
            if !explicitSampleDirectories.isEmpty {
                var allRows: [Kraken2ClassificationRow] = []
                var sampleMetadata: [String: String] = [:]

                for dir in explicitSampleDirectories {
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw ValidationError("--sample-dir must be an existing directory: \(dir.path)")
                    }

                    let sampleId = dir.lastPathComponent
                    guard !sampleId.hasPrefix(".") else {
                        throw ValidationError("--sample-dir must not point to a hidden directory: \(dir.path)")
                    }

                    let kreportURL = dir.appendingPathComponent("classification.kreport")
                    guard fm.fileExists(atPath: kreportURL.path) else {
                        throw ValidationError("Missing classification.kreport in --sample-dir \(dir.path)")
                    }

                    let source = try Self.loadKraken2Source(in: dir, kreportURL: kreportURL)
                    let (rows, tree) = flattenTree(source.tree, sampleId: sampleId)
                    allRows.append(contentsOf: rows)
                    sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
                    sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
                    sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"
                }

                return (allRows, sampleMetadata)
            }

            let contents = try fm.contentsOfDirectory(
                at: resultURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

            var allRows: [Kraken2ClassificationRow] = []
            var sampleMetadata: [String: String] = [:]

            // First pass: batch layout — sample subdirectories containing classification.kreport
            var foundSubdirKreports = false
            for dir in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let sampleId = dir.lastPathComponent
                // Skip hidden directories
                guard !sampleId.hasPrefix(".") else { continue }

                // Look for classification.kreport
                let kreportURL = dir.appendingPathComponent("classification.kreport")
                guard fm.fileExists(atPath: kreportURL.path) else { continue }

                foundSubdirKreports = true
                let source = try Self.loadKraken2Source(in: dir, kreportURL: kreportURL)
                let (rows, tree) = flattenTree(source.tree, sampleId: sampleId)
                allRows.append(contentsOf: rows)

                // Store per-sample tree statistics
                sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
                sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
                sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"
            }

            if foundSubdirKreports {
                return (allRows, sampleMetadata)
            }

            // Fallback: single-sample root layout. The folder can also hold
            // Bracken's re-estimated `classification.bracken.kreport`, which
            // sorts before Kraken 2's `classification.kreport`; picking by
            // sort order used to build the tree from Bracken's species-only
            // report. Resolve Kraken 2's own report explicitly instead.
            guard let kreportURL = Self.primaryKraken2Report(in: resultURL) else {
                return ([], [:])
            }

            let source = try Self.loadKraken2Source(in: resultURL, kreportURL: kreportURL)
            // Key the sample by its recorded name (the input bundle), not the
            // report's file stem ("classification" or "classification.bracken").
            let sampleId = source.recordedSampleName
                ?? kreportURL.deletingPathExtension().lastPathComponent
            let (rows, tree) = flattenTree(source.tree, sampleId: sampleId)
            allRows.append(contentsOf: rows)
            sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
            sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
            sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"

            return (allRows, sampleMetadata)
        }

        private static func validatedExplicitSampleDirectories(_ sampleDirectories: [URL]) throws -> [URL] {
            var seenPaths = Set<String>()
            var seenSampleIds = Set<String>()
            var validated: [URL] = []

            for url in sampleDirectories {
                let directory = url.standardizedFileURL
                guard seenPaths.insert(directory.path).inserted else {
                    throw ValidationError("Duplicate --sample-dir path: \(directory.path)")
                }

                let sampleId = directory.lastPathComponent
                guard !sampleId.hasPrefix(".") else {
                    throw ValidationError("--sample-dir must not point to a hidden directory: \(directory.path)")
                }
                guard seenSampleIds.insert(sampleId).inserted else {
                    throw ValidationError("Duplicate --sample-dir sample identifier '\(sampleId)'. Sample directory basenames must be unique.")
                }

                validated.append(directory)
            }

            return validated.sorted { $0.path < $1.path }
        }

        /// Parses a single kreport file into classification rows.
        ///
        /// Flattens the taxonomy tree produced by `KreportParser`, excluding
        /// only the unclassified pseudo-node. The root node (taxId 1) is included
        /// so that ``Kraken2Database/fetchTree(sample:)`` can reconstruct the tree.
        static func parseKreport(
            at kreportURL: URL,
            sampleId: String
        ) throws -> ([Kraken2ClassificationRow], TaxonTree) {
            flattenTree(try KreportParser.parse(url: kreportURL), sampleId: sampleId)
        }

        /// Flattens a parsed (and optionally Bracken-merged) tree into rows.
        static func flattenTree(
            _ tree: TaxonTree,
            sampleId: String
        ) -> ([Kraken2ClassificationRow], TaxonTree) {
            (Kraken2Database.rows(from: tree, sample: sampleId), tree)
        }

        // MARK: - Kraken 2 Source Resolution

        /// One result directory's taxonomy tree plus the sample name it records.
        struct Kraken2Source {
            /// Kraken 2's tree with Bracken's re-estimates merged in, when present.
            let tree: TaxonTree
            /// The sample name recorded in `classification-result.json`, if any.
            let recordedSampleName: String?
        }

        /// Whether `name` is a Bracken re-estimated report rather than Kraken 2's own.
        static func isBrackenReport(_ name: String) -> Bool {
            name.hasSuffix(".bracken.kreport") || name.contains("_bracken_")
        }

        /// Resolves Kraken 2's own report in a result directory.
        ///
        /// Order: the report named by `classification-result.json`, then
        /// `classification.kreport`, then the first other non-Bracken
        /// `*.kreport`. A Bracken report is used only when it is the sole
        /// report present (an imported Bracken-only result).
        static func primaryKraken2Report(in directory: URL) -> URL? {
            let fm = FileManager.default
            if let reportPath = persistedReportPath(in: directory) {
                let url = directory.appendingPathComponent(reportPath)
                if fm.fileExists(atPath: url.path), !isBrackenReport(url.lastPathComponent) {
                    return url
                }
            }
            let canonical = directory.appendingPathComponent("classification.kreport")
            if fm.fileExists(atPath: canonical.path) {
                return canonical
            }
            let reports = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "kreport" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return reports.first { !isBrackenReport($0.lastPathComponent) } ?? reports.first
        }

        /// Loads the tree for one result directory the same way the post-run
        /// viewer does: Kraken 2's report with Bracken's estimates merged into
        /// a separate field, never Bracken's report as the tree.
        static func loadKraken2Source(in directory: URL, kreportURL: URL) throws -> Kraken2Source {
            if let result = try? ClassificationResult.load(from: directory),
               result.reportURL.standardizedFileURL == kreportURL.standardizedFileURL {
                return Kraken2Source(
                    tree: result.tree,
                    recordedSampleName: recordedSampleName(for: result.config)
                )
            }
            var tree = try KreportParser.parse(url: kreportURL)
            let brackenURL = directory.appendingPathComponent("classification.bracken")
            if FileManager.default.fileExists(atPath: brackenURL.path) {
                try? BrackenParser.mergeBracken(url: brackenURL, into: &tree)
            }
            return Kraken2Source(tree: tree, recordedSampleName: nil)
        }

        /// The sample name a classification run recorded: the display name the
        /// GUI stored, else the name of the input `.lungfishfastq` bundle.
        static func recordedSampleName(for config: ClassificationConfig) -> String? {
            if let name = config.sampleDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            for url in (config.originalInputFiles ?? []) + config.inputFiles {
                if let bundle = enclosingFASTQBundle(of: url) {
                    return bundle.deletingPathExtension().lastPathComponent
                }
            }
            return nil
        }

        /// The `.lungfishfastq` bundle a recorded input path sits in. Matched by
        /// name only: the recorded name stays valid after a bundle is moved.
        private static func enclosingFASTQBundle(of url: URL) -> URL? {
            var current = url.standardizedFileURL
            for _ in 0..<3 {
                if current.pathExtension.lowercased() == FASTQBundle.directoryExtension { return current }
                let parent = current.deletingLastPathComponent()
                guard parent.path != current.path else { return nil }
                current = parent
            }
            return nil
        }

        private static func persistedReportPath(in directory: URL) -> String? {
            let sidecar = directory.appendingPathComponent("classification-result.json")
            guard let data = try? Data(contentsOf: sidecar),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object["reportPath"] as? String
        }

        // MARK: - Post-Build Cleanup

        /// Compacts Kraken2 intermediate files while preserving kreport,
        /// database, and the per-read classification output in retained form.
        ///
        /// Removes per-sample: `classification.kraken` after compaction succeeds,
        /// `classification.kraken.idx.sqlite`.
        /// Keeps: `classification.kraken.gz`,
        /// `classification.kraken.gz.idx.sqlite`, `classification.kreport`,
        /// `classification-result.json`, `kraken2.sqlite`.
        private static func performCleanup(resultURL: URL, sampleDirectories: [URL] = [], events: BuildDbEventSink) {
            let fm = FileManager.default
            var freedBytes: Int64 = 0

            let cleanupDirs: [URL]
            if sampleDirectories.isEmpty {
                guard let contents = try? fm.contentsOfDirectory(
                    at: resultURL,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return }

                cleanupDirs = [resultURL] + contents
                    .filter { url in
                        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                            && !url.lastPathComponent.hasPrefix(".")
                    }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                cleanupDirs = sampleDirectories
                    .map(\.standardizedFileURL)
                    .filter { url in
                        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                            && !url.lastPathComponent.hasPrefix(".")
                    }
                    .sorted { $0.path < $1.path }
            }

            for dir in cleanupDirs {
                let name = dir.lastPathComponent
                guard !name.hasPrefix(".") else { continue }

                // Retain the per-read output as gzip for audit/replay, plus a
                // classified-only SQLite index for fast taxon extraction.
                let krakenOutput = dir.appendingPathComponent("classification.kraken")
                if fm.fileExists(atPath: krakenOutput.path) {
                    let originalSize = fileSize(krakenOutput) ?? 0
                    do {
                        let compressedOutput = try KrakenOutputCompactor.compact(
                            rawURL: krakenOutput,
                            includeUnclassifiedInIndex: false,
                            removeRawOnSuccess: true
                        )
                        updateClassificationResultSidecar(in: dir, outputURL: compressedOutput, events: events)
                        let compressedSize = fileSize(compressedOutput) ?? 0
                        freedBytes += max(0, originalSize - compressedSize)
                    } catch {
                        events.warning("Warning: could not compact \(krakenOutput.path): \(error.localizedDescription)")
                    }
                }

                // Remove old raw-output index SQLite files. New retained indexes
                // are named after the compressed output and must be kept.
                let krakenIndex = dir.appendingPathComponent("classification.kraken.idx.sqlite")
                if let size = fileSize(krakenIndex) {
                    KrakenOutputCompactor.removeSQLiteDatabase(at: krakenIndex)
                    freedBytes += size
                }
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
        }

        private static func fileSize(_ url: URL) -> Int64? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }

        private static func updateClassificationResultSidecar(in directory: URL, outputURL: URL, events: BuildDbEventSink) {
            guard ClassificationResult.exists(in: directory) else { return }

            do {
                let current = try ClassificationResult.load(from: directory)
                let updated = ClassificationResult(
                    config: current.config,
                    tree: current.tree,
                    reportURL: current.reportURL,
                    outputURL: outputURL,
                    brackenURL: current.brackenURL,
                    profileOutcome: current.profileOutcome,
                    runtime: current.runtime,
                    toolVersion: current.toolVersion,
                    provenanceId: current.provenanceId
                )
                try updated.save(to: directory)
            } catch {
                events.warning(
                    "Warning: could not update \(directory.appendingPathComponent("classification-result.json").path): \(error.localizedDescription)"
                )
            }
        }
    }
}
