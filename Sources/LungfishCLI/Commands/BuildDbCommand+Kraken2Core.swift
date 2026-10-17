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
        ///
        /// A cancel of the caller's task, or one the sink's `cancelRequested` reports (2.8 row 266), ends the
        /// build with `CancellationError` at its next check. The checks come before each sample folder is read
        /// or compacted and before the database and the record are written, so a folder whose compaction has
        /// started is finished first. The database of an earlier build is put back and no record of a failed
        /// build is written, so a cancelled build leaves no database and no record (plan decision E5 of Phase
        /// 2.7). The folders compacted before the cancel stay compacted, with their result sidecar updated, and
        /// no record of the core names that step, which the sink's `step` took as it ended (lane S33). The build
        /// step goes there once the database is kept. A cancel after the check before the record is not seen,
        /// and the build completes.
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
            var cleanup = Kraken2Cleanup()

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

                try events.checkCancellation()
                try Kraken2Database.create(at: dbURL, rows: rows, metadata: metadata, progress: events.progress)

                events.text(BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: nil).summary)

                if !options.noCleanup {
                    cleanup = try performCleanup(resultURL: resultURL, sampleDirectories: explicitSampleDirectories, events: events)
                }

                try events.checkCancellation()
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
                    additionalSteps: cleanup.steps,
                    writtenFiles: cleanup.written,
                    writesFolderRecord: options.writesFolderRecord,
                    events: events
                )
                try databaseSnapshot.discard()
                // The build step names the database, so it goes over only once no catch can put the earlier one
                // back. The steps before it went over as each ended (lane S33).
                if let buildStep = record.steps.last { events.step(buildStep) }
                return BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: record)
            } catch {
                do {
                    try databaseSnapshot.restore()
                } catch {
                    events.warning("Warning: could not restore previous Kraken2 database: \(error.localizedDescription)")
                }
                // A cancelled build is not a failed one, so it leaves no record of a failure. The cancel
                // request decides, never the error that the cancel caused (SWIFT X2).
                guard !events.isCancelled else { throw error }
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
                    additionalSteps: cleanup.steps,
                    includeOutputRecords: false,
                    writesFolderRecord: options.writesFolderRecord,
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
                    try Task.checkCancellation()
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
                try Task.checkCancellation()
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

        /// What the cleanup did. `steps` go in the run's record. `written` names each file the cleanup wrote or rewrote,
        /// the gzip copy and index that `KrakenOutputCompactor.compact` returns and each result sidecar it rewrote, as
        /// the steps name it, with the digest it has now. The run's own step names these and `kraken2.sqlite` as its
        /// outputs and every other file it read as an input, so no file it did not write gets it as a producer (2.11 B62).
        struct Kraken2Cleanup {
            var steps: [ProvenanceStep] = []
            var written: [ProvenanceFileDescriptor] = []
        }

        /// Compacts Kraken2 intermediate files while preserving kreport,
        /// database, and the per-read classification output in retained form.
        ///
        /// Removes per-sample: `classification.kraken` after compaction succeeds,
        /// `classification.kraken.idx.sqlite`.
        /// Keeps: `classification.kraken.gz`,
        /// `classification.kraken.gz.idx.sqlite`, `classification.kreport`,
        /// `classification-result.json`, `kraken2.sqlite`.
        ///
        /// A folder whose record names `classification.kraken`, `classification-result.json` or
        /// `classification.kraken.idx.sqlite` is left as it is, with one information line, when `build-db` may not
        /// replace that record, which is the classifier's. The compaction removes the first and rewrites the second
        /// in place, so the record would name a file that is gone and bytes the file no longer has, and no removal
        /// step can be added to a record that is not this run's (ARCH's ruling on A45 M3, section 4, and the
        /// A39 review). A folder with no such record compacts as before.
        ///
        /// Returns the files it wrote or rewrote and the steps of the run's record, the index and gzip of each compacted
        /// output and one removal step that names every removed file with the digest it had, because the
        /// classifier's record names the per-read output it wrote (P1 of Phase 2.8, row 423). The removal step also
        /// names the sidecar of each folder it compacted, with the digest it had before the rewrite, since that
        /// file is still there while this run's inputs and the classifier's record state the old digest (2.10 B34).
        ///
        /// Throws `CancellationError` before it starts on a folder when the caller's task is cancelled or the
        /// sink reports a cancel, so a folder is compacted whole or not at all. The folders it compacted before the
        /// cancel stay compacted. Each folder's two steps go to the sink's `step` as the folder ends, and the
        /// removal step once the last folder ends, so a caller that writes its own record keeps them (lane S33).
        private static func performCleanup(
            resultURL: URL, sampleDirectories: [URL] = [], events: BuildDbEventSink
        ) throws -> Kraken2Cleanup {
            let fm = FileManager.default
            var freedBytes: Int64 = 0
            var steps: [ProvenanceStep] = []
            var written: [ProvenanceFileDescriptor] = []
            var removed: [ProvenanceFileDescriptor] = []
            // The result sidecars a compaction rewrote in place, as they were before. Each is still there, so the
            // filter on `removed` below would drop it.
            var replaced: [ProvenanceFileDescriptor] = []
            let removalClock = ProvenanceRunClock()

            let cleanupDirs: [URL]
            if sampleDirectories.isEmpty {
                guard let contents = try? fm.contentsOfDirectory(
                    at: resultURL,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return Kraken2Cleanup() }

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

            // What the cleanup removed or rewrote so far, from descriptors it took before each removal, with no new hash.
            func removalStep() -> ProvenanceStep? {
                RecordedRemovalStep.step(
                    toolName: ClassificationPipeline.kraken2OutputRemovalToolName,
                    api: "BuildDbCommand.Kraken2Subcommand.performCleanup(resultURL:sampleDirectories:events:)",
                    removing: removed.filter { !fm.fileExists(atPath: $0.path) } + replaced,
                    clock: removalClock
                )
            }

            for dir in cleanupDirs {
                // Outside the `do` below, which turns a failed compaction into a warning. A cancel once a folder is
                // compacted hands over the removal step of what went so far before it ends the core, so the
                // caller's record names each file that is gone (lane S33 M4).
                do {
                    try events.checkCancellation()
                } catch {
                    if let removal = removalStep() { events.step(removal) }
                    throw error
                }
                let name = dir.lastPathComponent
                guard !name.hasPrefix(".") else { continue }

                let krakenOutput = dir.appendingPathComponent("classification.kraken")
                let krakenIndex = dir.appendingPathComponent("classification.kraken.idx.sqlite")

                // The classifier's record names the files below with their digests, and this run may not replace it
                // (2.10 FXA2). A folder whose record names any of them keeps all of them, with one information line,
                // and adds no step to this run's record. A folder with nothing to compact or remove reads no record.
                if fm.fileExists(atPath: krakenOutput.path) || fm.fileExists(atPath: krakenIndex.path) {
                    let namedByRecord = namedByClassifierRecord(
                        [krakenOutput, dir.appendingPathComponent(ClassificationResult.sidecarFilename), krakenIndex], in: dir
                    )
                    if !namedByRecord.isEmpty {
                        events.text(keptFolderLine(folder: name, recordNames: namedByRecord))
                        continue
                    }
                }

                // Retain the per-read output as gzip for audit/replay, plus a
                // classified-only SQLite index for fast taxon extraction.
                if fm.fileExists(atPath: krakenOutput.path) {
                    let originalSize = fileSize(krakenOutput) ?? 0
                    do {
                        // Hashed once, before the compaction removes it.
                        let raw = try ProvenanceFileDescriptor.file(url: krakenOutput, format: .text, role: .input)
                        let clock = ProvenanceRunClock()
                        let compaction = try KrakenOutputCompactor.compact(
                            rawURL: krakenOutput,
                            includeUnclassifiedInIndex: false,
                            removeRawOnSuccess: true
                        )
                        let compressedOutput = compaction.compressedURL
                        let folderSteps = compactionSteps(raw: raw, compressed: compressedOutput, clock: clock)
                        steps += folderSteps
                        // The folder's two steps ended whole, so they go over now and a cancel before a later
                        // folder keeps them (2.9 R6, lane S33).
                        folderSteps.forEach(events.step)
                        written += writtenFiles(compaction.writtenFiles, namedBy: folderSteps)
                        removed.append(raw)
                        if let before = updateClassificationResultSidecar(in: dir, outputURL: compressedOutput, events: events) {
                            replaced.append(before)
                            // The rewrite's new bytes, hashed once, which the run's step names as its output.
                            if let rewritten = try? ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: before.path), format: .json, role: .output) {
                                written.append(rewritten)
                            }
                        }
                        let compressedSize = fileSize(compressedOutput) ?? 0
                        freedBytes += max(0, originalSize - compressedSize)
                    } catch {
                        events.warning("Warning: could not compact \(krakenOutput.path): \(error.localizedDescription)")
                    }
                }

                // Remove old raw-output index SQLite files. New retained indexes
                // are named after the compressed output and must be kept.
                if let size = fileSize(krakenIndex) {
                    let oldIndex = try? ProvenanceFileDescriptor.file(url: krakenIndex, role: .index)
                    KrakenOutputCompactor.removeSQLiteDatabase(at: krakenIndex)
                    if let oldIndex { removed.append(oldIndex) }
                    freedBytes += size
                }
            }

            if let line = BuildDbCommand.cleanupLine(freedBytes: freedBytes) { events.text(line) }
            let removal = removalStep()
            if let removal { events.step(removal) }
            return Kraken2Cleanup(steps: steps + (removal.map { [$0] } ?? []), written: written)
        }

        /// Each of `files`, which one compaction wrote, as `steps` name it with its digest, so that it is hashed once
        /// (SWIFT 5). A file that no step names, because hashing it for its step failed, is hashed here once more.
        private static func writtenFiles(_ files: [URL], namedBy steps: [ProvenanceStep]) -> [ProvenanceFileDescriptor] {
            let named = steps.flatMap(\.outputs)
            return files.compactMap { url in
                named.first { URL(fileURLWithPath: $0.path).standardizedFileURL == url.standardizedFileURL }
                    ?? (try? ProvenanceFileDescriptor.file(url: url, role: url.lastPathComponent.hasSuffix(".idx.sqlite") ? .index : .output))
            }
        }

        /// The index and gzip steps of one compaction, as the classifier records its own
        /// (`ClassificationPipeline.compactKrakenOutputIfPossible`). `raw` is the per-read output
        /// as it was before the compaction removed it.
        static func compactionSteps(raw: ProvenanceFileDescriptor, compressed: URL, clock: ProvenanceRunClock) -> [ProvenanceStep] {
            let index = KrakenIndexDatabase.indexURL(for: compressed)
            guard let indexOutput = try? ProvenanceFileDescriptor.file(url: index, role: .index),
                  let gzipOutput = try? ProvenanceFileDescriptor.file(url: compressed, format: .text, role: .output) else { return [] }
            func step(_ toolName: String, _ version: String, _ argv: [String], _ output: ProvenanceFileDescriptor) -> ProvenanceStep {
                ProvenanceStep(
                    toolName: toolName, toolVersion: version, argv: argv, inputs: [raw], outputs: [output], exitStatus: 0,
                    wallTimeSeconds: clock.elapsed, startedAt: clock.startedAt, completedAt: clock.now
                )
            }
            return [
                step("lungfish-kraken2-index", WorkflowRun.currentAppVersion, [
                    CLICommandIdentity.executableName, "internal", "kraken2-index", "--classified-only", raw.path, index.path,
                ], indexOutput),
                step("gzip", "system", [
                    "/bin/sh", "-c", "/usr/bin/gzip -c \(shellEscape(raw.path)) > \(shellEscape(compressed.path))",
                ], gzipOutput),
            ]
        }

        /// The files among `candidates` that a record in `folder` names, in the order of `candidates`, when `build-db` may
        /// not replace that record. That record is another workflow's, the classifier's (`mayReplaceProvenance`), and it
        /// names each file with the digest it had. A record names a file at its run level or in a step, as an input or an
        /// output. A folder with no record, or with one an earlier `build-db` wrote, names nothing here, because this
        /// run records its own changes in its record.
        private static func namedByClassifierRecord(_ candidates: [URL], in folder: URL) -> [String] {
            guard let record = ProvenanceRecorder.loadEnvelope(from: folder),
                  !BuildDbCommand.mayReplaceProvenance(record, tool: .kraken2) else { return [] }
            let named = record.files + record.outputs + [record.output].compactMap { $0 }
                + record.steps.flatMap { $0.inputs + $0.outputs }
            let paths = Set(named.map { resolvedPath($0.path, in: folder) })
            return candidates.filter { paths.contains(resolvedPath($0.path, in: folder)) }.map(\.lastPathComponent)
        }

        /// `path` as an absolute path with its folder resolved, so that /var/folders and /private/var/folders are one
        /// place. A path with no root is the folder's.
        private static func resolvedPath(_ path: String, in folder: URL) -> String {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            return url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
        }

        /// The line a folder gets when the cleanup leaves it as it is, which says why. It is information and not a
        /// warning, because a run that keeps a folder did nothing wrong (UX 2 of the expert panel).
        private static func keptFolderLine(folder: String, recordNames names: [String]) -> String {
            let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
            return "Kept \(folder) as it is because its provenance record names \(list)."
        }

        private static func fileSize(_ url: URL) -> Int64? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }

        /// Rewrites `classification-result.json` in `directory` to name `outputURL` as the per-read output and keeps every
        /// other fact of the result. Returns the sidecar as it was, hashed before the save replaced it, so that the
        /// removal step can name the bytes that are gone (`RecordedRemovalStep`). Nil when nothing was rewritten.
        private static func updateClassificationResultSidecar(
            in directory: URL, outputURL: URL, events: BuildDbEventSink
        ) -> ProvenanceFileDescriptor? {
            guard ClassificationResult.exists(in: directory) else { return nil }

            do {
                let current = try ClassificationResult.load(from: directory)
                let replaced = try ProvenanceFileDescriptor.file(
                    url: directory.appendingPathComponent(ClassificationResult.sidecarFilename), format: .json, role: .input
                )
                let updated = ClassificationResult(
                    config: current.config,
                    tree: current.tree,
                    reportURL: current.reportURL,
                    outputURL: outputURL,
                    brackenURL: current.brackenURL,
                    profileOutcome: current.profileOutcome,
                    runtime: current.runtime,
                    toolVersion: current.toolVersion,
                    provenanceId: current.provenanceId,
                    fragmentComposition: current.fragmentComposition,
                    readPairingContract: current.readPairingContract
                )
                try updated.save(to: directory)
                return replaced
            } catch {
                events.warning(
                    "Warning: could not update \(directory.appendingPathComponent("classification-result.json").path): \(error.localizedDescription)"
                )
                return nil
            }
        }
    }
}
