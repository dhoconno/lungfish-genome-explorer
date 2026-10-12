// BuildDbCommand+TaxTriageCore.swift - The build-db taxtriage leaf and its core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The `build-db taxtriage` leaf moved here from BuildDbCommand.swift (Phase 2.9, lane A1), and TaxTriage on the
// analysis run executor builds its viewer index through it (lane A2, `TaxTriageResultIndexer`). The core is the
// static `buildDatabase(in:options:cleanup:events:)`, as the Kraken2 and EsViritu leaves have theirs. It keeps an
// existing database unless `--force`, captures the record's input list, resolves the taxonomy rows of the result
// folder and of each serial sample folder, writes `taxtriage.sqlite`, recomputes unique reads
// from the BAMs and writes the records. A failure puts the database of an earlier build back and writes a failure
// record, and a cancel writes none. Its cleanup takes one of two forms (decision T5 of Phase 2.8).
//
// - `.legacy`, the command's, which the app's in-process TaxTriage route runs after each run. `performCleanup`
//   removes `count/`, the fastp FASTQ files and eight intermediate folders, `top/` among them, between the
//   unique-read pass and the record, so the record names sources that are gone. It records no step.
//   `BuildDbTaxTriageCleanupFreezeTests` pins the rows, the record and the removed paths of that order.
// - `.recordedRemoval`, the executor's. `performRecordedCleanup` runs after the record, keeps `top/`, removes the
//   other seven folders, `count/` and the fastp FASTQ files of each result folder that is no symbolic link, and
//   returns one removal step naming each removed file that a record names, with that record's digest and size,
//   so the run's record names it after the build step. It hashes no file it removes (2.8 T5 as amended in 2.9).
//
// The parsers in BuildDbCommand.swift are instance methods that read no parsed option, so the core runs them on
// an instance of its own.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - TaxTriage Subcommand

extension BuildDbCommand {

    /// Build a SQLite database from TaxTriage pipeline output.
    ///
    /// Parses the per-sample organism discovery report (`report/<sample>.odr.txt`,
    /// TaxTriage 3.3.x), falling back to `<sample>.organisms.report.txt`, the legacy
    /// `report/multiqc_data/multiqc_confidences.txt`, and finally the Kraken-only
    /// `top/*.top_report.tsv`. Resolves BAM paths and accession data from gcfmap
    /// files, and writes a `taxtriage.sqlite` database in the result directory.
    /// Rerun with `--force` to rebuild an existing database.
    struct TaxTriageSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "taxtriage",
            abstract: "Build SQLite database from TaxTriage results"
        )

        @Argument(help: "Path to the TaxTriage result directory")
        var resultDir: String

        @Flag(name: .long, help: "Force rebuild even if database exists")
        var force: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Skip post-build cleanup of intermediate files")
        var noCleanup: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let resultURL = URL(fileURLWithPath: resultDir)
            let options = BuildDbRunOptions(force: force, noCleanup: noCleanup, globalOptions: globalOptions)
            try await BuildDbCLIEvents(globalOptions: globalOptions).report(
                database: resultURL.appendingPathComponent("taxtriage.sqlite")
            ) { events in
                try await Self.buildDatabase(in: resultURL, options: options, events: events).result
            }
        }

        /// How a build's cleanup treats `top/` and what it records (decision T5 of Phase 2.8).
        enum Cleanup: Sendable {
            /// The command's cleanup, which the app's in-process route runs. It removes `top/` too, before
            /// the record, and records nothing. The legacy route keeps it until that route goes.
            case legacy
            /// The analysis run executor's. It runs after the record, keeps `top/`, so a `--force`
            /// rebuild still reads a sample whose only rows come from there, and names each file it
            /// removes in one removal step.
            case recordedRemoval
        }

        /// What one build left in its result folder, and the removal step of a `.recordedRemoval`
        /// cleanup that removed anything.
        struct Build: Sendable {
            let result: BuildDbRunResult
            let removal: ProvenanceStep?
        }

        /// The tool name of the removal step a `.recordedRemoval` cleanup records.
        static let cleanupRemovalToolName = "Lungfish TaxTriage Intermediate Removal"

        /// The `build-db taxtriage` core. Builds `taxtriage.sqlite` in `resultURL` from the result folder's
        /// reports, or from those of each serial sample folder under it, records the run beside the database
        /// and returns what it built. A database that exists is kept unless `options.force`. Unless
        /// `options.noCleanup`, `cleanup` says which cleanup runs. A `.recordedRemoval` cleanup names
        /// each file it removes with the descriptor that the record of the file's folder, `recordedFiles`
        /// or the build's own record holds for it, in that order.
        ///
        /// A cancel of the caller's task ends the build with `CancellationError` at its next check, before
        /// each sample folder is read or cleaned up, before the database is written, after the samtools pass
        /// and before the record. The database of an earlier build is put back and no record of a failed
        /// build is written (plan decision E5 of Phase 2.7). A folder the cleanup finished stays cleaned.
        static func buildDatabase(
            in resultURL: URL,
            options: BuildDbRunOptions,
            cleanup: Cleanup = .legacy,
            recordedFiles: [ProvenanceFileDescriptor] = [],
            events: BuildDbEventSink
        ) async throws -> Build {
            let core = Self()
            let runClock = ProvenanceRunClock()
            let dbURL = resultURL.appendingPathComponent("taxtriage.sqlite")

            // Skip if exists (unless --force)
            if !options.force && FileManager.default.fileExists(atPath: dbURL.path) {
                let existing = BuildDbRunResult(databaseURL: dbURL, rowCount: nil, record: nil)
                events.text(existing.summary)
                return Build(result: existing, removal: nil)
            }

            let provenanceInputs = BuildDbCommand.buildDbInputRecords(tool: .taxTriage, resultURL: resultURL)
            let samtoolsProvenance = BuildDbSamtoolsProvenanceCollector()
            let databaseSnapshot = try BuildDbDatabaseSnapshot.capture(dbURL: dbURL)

            let built: BuildDbRunResult
            do {
                // 1. Locate a supported taxonomy report
                let resolvedInput = try core.resolveTaxonomyRows(resultURL: resultURL)
                let rows = resolvedInput.rows
                let accessionMap = resolvedInput.accessionMap

                events.text("Parsed \(rows.count) taxonomy rows, \(accessionMap.count) accession entries from \(resolvedInput.sourceDescription)")

                // 3. Build database
                let metadata: [String: String] = [
                    "tool": "taxtriage",
                    "created_at": ISO8601DateFormatter().string(from: Date()),
                    "source_dir": resultURL.path,
                    TaxTriageDatabase.taxonomySourceMetadataKey: resolvedInput.sources
                        .map(\.rawValue)
                        .joined(separator: ","),
                    TaxTriageDatabase.tassScaleMetadataKey: TaxTriageDatabase.currentTASSScale,
                ]

                try Task.checkCancellation()
                try TaxTriageDatabase.create(
                    at: dbURL, rows: rows, accessionMap: accessionMap, metadata: metadata, progress: events.progress
                )

                events.text(BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: nil).summary)

                // 4. Compute unique reads from BAMs and update DB
                try await updateUniqueReadsInDB(
                    dbPath: dbURL.path,
                    table: "taxonomy_rows",
                    sampleCol: "sample",
                    accessionCol: "primary_accession",
                    bamPathCol: "bam_path",
                    totalReadsCol: "reads_aligned",
                    resultURL: resultURL,
                    bamPathResolver: { resultURL, _, bamRelPath in
                        // TaxTriage BAM paths are relative to resultURL directly
                        resultURL.appendingPathComponent(bamRelPath).path
                    },
                    updateAccessionLength: true,
                    events: events,
                    provenance: samtoolsProvenance
                )
                try Task.checkCancellation()

                if !options.noCleanup, cleanup == .legacy {
                    try core.performCleanup(resultURL: resultURL, events: events)
                }

                try Task.checkCancellation()
                let record = try await BuildDbCommand.recordBuildDbProvenance(
                    tool: .taxTriage,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    additionalSteps: samtoolsProvenance.steps,
                    writesFolderRecord: options.writesFolderRecord,
                    events: events
                )
                try databaseSnapshot.discard()
                built = BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: record)
            } catch {
                do {
                    try databaseSnapshot.restore()
                } catch {
                    events.warning("Warning: could not restore previous TaxTriage database: \(error.localizedDescription)")
                }
                // A cancelled build is not a failed one, so it leaves no record of a failure (SWIFT X2).
                guard !Task.isCancelled else { throw error }
                await BuildDbCommand.recordBuildDbFailureProvenanceIfNeeded(
                    tool: .taxTriage,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    error: error,
                    additionalSteps: samtoolsProvenance.steps,
                    includeOutputRecords: false,
                    writesFolderRecord: options.writesFolderRecord,
                    events: events
                )
                throw error
            }

            guard !options.noCleanup, cleanup == .recordedRemoval else {
                return Build(result: built, removal: nil)
            }
            // T5. After the record, so the run's record names the removal after the build step that read
            // what it removes (2.8 P1). The build's own steps name what it read with a digest too. The
            // removal depends on each build step, which read what it removed (BIO 6).
            let recorded = recordedFiles + (built.record?.steps ?? []).flatMap { $0.inputs + $0.outputs }
            var removal = try core.performRecordedCleanup(resultURL: resultURL, recorded: recorded, events: events)
            removal?.dependsOn = built.record?.steps.map(\.id) ?? []
            return Build(result: built, removal: removal)
        }

        // MARK: - Post-Build Cleanup

        /// The intermediate folders a cleanup removes whole. The `.legacy` cleanup also removes `top/`.
        static let removedFolderNames = ["filterkraken", "get", "map", "samtools", "bedtools", "mergedsubspecies", "mergedkrakenreport"]

        private func performCleanup(resultURL: URL, events: BuildDbEventSink) throws {
            var freedBytes: Int64 = 0

            let cleanupRoots = [resultURL] + serialTaxTriageResultDirectories(in: resultURL)
            for cleanupRoot in cleanupRoots {
                try Task.checkCancellation()
                freedBytes += performCleanupForSingleResult(resultURL: cleanupRoot)
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
        }

        /// T5's cleanup on the executor path, as amended in Phase 2.9. In the result folder and each serial
        /// sample folder that is no symbolic link, it removes `count/`, the fastp FASTQ files and the seven
        /// folders of ``removedFolderNames``, never `top/` and never a symbolic link among them, and reads no
        /// file it removes (SWIFT F1). It returns one removal step that names each removed file a record
        /// already names, with the digest and size that record holds for it, the record of the file's folder
        /// first and then `recorded`. A file that no record names, or whose size on disk is not the size its
        /// record holds, goes unnamed, because P1 excuses a missing file only by the digest of a record that
        /// names it. It returns nil when it names nothing.
        private func performRecordedCleanup(
            resultURL: URL,
            recorded: [ProvenanceFileDescriptor],
            events: BuildDbEventSink
        ) throws -> ProvenanceStep? {
            let fm = FileManager.default
            let removalClock = ProvenanceRunClock()
            let named = Self.byResolvedPath(recorded)
            var removed: [ProvenanceFileDescriptor] = []
            var freedBytes: Int64 = 0

            for cleanupRoot in [resultURL] + serialTaxTriageResultDirectories(in: resultURL) {
                try Task.checkCancellation()
                guard !Self.isSymbolicLink(cleanupRoot) else { continue }
                let folderNamed = Self.byResolvedPath(
                    ProvenanceRecorder.loadEnvelope(from: cleanupRoot).map(Self.fileDescriptors(of:)) ?? []
                )
                var files = Self.fastpFASTQFiles(in: cleanupRoot.appendingPathComponent("fastp"))
                var folders: [URL] = []
                for name in ["count"] + Self.removedFolderNames {
                    let folder = cleanupRoot.appendingPathComponent(name, isDirectory: true)
                    guard fm.fileExists(atPath: folder.path), !Self.isSymbolicLink(folder) else { continue }
                    folders.append(folder)
                    files += Self.regularFiles(under: folder)
                }
                for file in files {
                    let key = Self.resolvedPath(file)
                    let size = try? ProvenanceFileHasher.fileSize(of: file)
                    do {
                        try fm.removeItem(at: file)
                    } catch {
                        events.warning("Warning: could not remove \(file.path): \(error.localizedDescription)")
                        continue
                    }
                    freedBytes += Int64(size ?? 0)
                    let candidates = [folderNamed[key], named[key]].compactMap { $0 }
                    if let size, let descriptor = candidates.first(where: { $0.fileSize == size }) {
                        removed.append(descriptor.withRole(.input))
                    }
                }
                for folder in folders {
                    try? fm.removeItem(at: folder)
                }
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
            return RecordedRemovalStep.step(
                toolName: Self.cleanupRemovalToolName,
                api: "BuildDbCommand.TaxTriageSubcommand.performRecordedCleanup(resultURL:recorded:events:)",
                removing: removed.filter { !fm.fileExists(atPath: $0.path) },
                clock: removalClock
            )
        }

        /// The fastp FASTQ files a cleanup removes, the files directly in `fastpDir` named as FASTQ or gzip,
        /// never its reports or a file in a subfolder.
        private static func fastpFASTQFiles(in fastpDir: URL) -> [URL] {
            guard !isSymbolicLink(fastpDir),
                  let contents = try? FileManager.default.contentsOfDirectory(
                      at: fastpDir, includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { return [] }
            return contents
                .filter { file in
                    let ext = file.pathExtension.lowercased()
                    let named = ext == "fastq" || ext == "gz" || file.lastPathComponent.hasSuffix(".fastp.fastq.gz")
                    return named && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        }

        /// Every regular file under `folder`, in byte order of its path. A symbolic link is not followed
        /// and not listed, and goes with its folder.
        private static func regularFiles(under folder: URL) -> [URL] {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [] }
            return enumerator
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        }

        private static func isSymbolicLink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }

        /// Every file `record` names, at run level and in its steps.
        private static func fileDescriptors(of record: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
            var descriptors = record.files + record.outputs
            if let output = record.output {
                descriptors.append(output)
            }
            return descriptors + record.steps.flatMap { $0.inputs + $0.outputs }
        }

        /// The first of `descriptors` with a digest and a size for each path, keyed as
        /// ``resolvedPath(_:)`` keys a file, so a record's `/private/var` path meets a folder's `/var` one.
        private static func byResolvedPath(_ descriptors: [ProvenanceFileDescriptor]) -> [String: ProvenanceFileDescriptor] {
            var byPath: [String: ProvenanceFileDescriptor] = [:]
            for descriptor in descriptors where descriptor.checksumSHA256 != nil && descriptor.fileSize != nil {
                let key = resolvedPath(URL(fileURLWithPath: descriptor.path))
                if byPath[key] == nil {
                    byPath[key] = descriptor
                }
            }
            return byPath
        }

        private static func resolvedPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().path
        }

        private func performCleanupForSingleResult(resultURL: URL) -> Int64 {
            let fm = FileManager.default
            var freedBytes: Int64 = 0

            // Delete count/ directory (raw FASTQ copies)
            let countDir = resultURL.appendingPathComponent("count")
            if let size = directorySize(countDir) {
                try? fm.removeItem(at: countDir)
                freedBytes += size
            }

            // Delete fastp/ FASTQ files only (keep .html and .json QC reports)
            let fastpDir = resultURL.appendingPathComponent("fastp")
            if fm.fileExists(atPath: fastpDir.path) {
                let contents = try? fm.contentsOfDirectory(at: fastpDir, includingPropertiesForKeys: [.fileSizeKey])
                for file in contents ?? [] {
                    let ext = file.pathExtension.lowercased()
                    if ext == "fastq" || ext == "gz" || file.lastPathComponent.hasSuffix(".fastp.fastq.gz") {
                        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        try? fm.removeItem(at: file)
                        freedBytes += Int64(size)
                    }
                }
            }

            // Delete intermediate pipeline directories
            for dirname in ["filterkraken", "get", "map", "samtools", "bedtools", "top", "mergedsubspecies", "mergedkrakenreport"] {
                let dir = resultURL.appendingPathComponent(dirname)
                if let size = directorySize(dir) {
                    try? fm.removeItem(at: dir)
                    freedBytes += size
                }
            }

            return freedBytes
        }

        private func directorySize(_ url: URL) -> Int64? {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return nil }
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
            return total
        }

        // MARK: - Result Folders

        /// Where `build-db taxtriage` read its taxonomy rows from. Recorded in the database
        /// metadata as `taxonomy_source` so stale databases can be detected.
        enum TaxonomySource: String {
            /// `report/<sample>.odr.txt` (TaxTriage 3.3.x), or `all.odr.txt` when no
            /// per-sample report exists, or an older `<sample>.organisms.report.txt`.
            case organismReport = "organism_report"
            /// `report/multiqc_data/multiqc_confidences.txt`.
            case multiqcConfidences = "multiqc_confidences"
            /// `top/*.top_report.tsv`: Kraken-derived counts only, no TASS.
            case topReport = "top_report"
        }

        private func resolveTaxonomyRows(
            resultURL: URL
        ) throws -> (
            rows: [TaxTriageTaxonomyRow],
            accessionMap: [TaxTriageAccessionEntry],
            sourceDescription: String,
            sources: [TaxonomySource]
        ) {
            if let parsed = try parseSingleTaxTriageResult(resultURL: resultURL) {
                return (parsed.rows, parsed.accessionMap, parsed.sourceDescription, [parsed.source])
            }

            let serialResults = serialTaxTriageResultDirectories(in: resultURL)
            if !serialResults.isEmpty {
                var rows: [TaxTriageTaxonomyRow] = []
                var accessionMap: [TaxTriageAccessionEntry] = []
                var sources: [TaxonomySource] = []

                for sampleResultURL in serialResults {
                    try Task.checkCancellation()
                    guard let parsed = try parseSingleTaxTriageResult(resultURL: sampleResultURL) else { continue }
                    let directoryName = sampleResultURL.lastPathComponent
                    rows.append(contentsOf: parsed.rows.map { prefixBAMPaths(in: $0, with: directoryName) })
                    accessionMap.append(contentsOf: parsed.accessionMap)
                    if !sources.contains(parsed.source) { sources.append(parsed.source) }
                }

                if !rows.isEmpty {
                    return (rows, accessionMap, "serial sample result directories", sources)
                }
            }

            throw ValidationError(
                "No supported TaxTriage taxonomy report found in \(resultURL.path). Expected report/<sample>.odr.txt, <sample>.organisms.report.txt, report/multiqc_data/multiqc_confidences.txt, top/*.top_report.tsv, or serial sample subdirectories containing those reports"
            )
        }

        /// Parses one TaxTriage result directory (a single run, or one sample of a serial batch).
        ///
        /// Source priority: the organism discovery report (`report/<sample>.odr.txt`, 3.3.x,
        /// or the older `<sample>.organisms.report.txt`), then the legacy MultiQC confidence
        /// table, then the Kraken-only `top/*.top_report.tsv` fallback, which has no TASS.
        private func parseSingleTaxTriageResult(
            resultURL: URL
        ) throws -> (
            rows: [TaxTriageTaxonomyRow],
            accessionMap: [TaxTriageAccessionEntry],
            sourceDescription: String,
            source: TaxonomySource
        )? {
            let organismReports = TaxTriageOrganismReport.reportFiles(inResultDirectory: resultURL)
            if !organismReports.isEmpty {
                let parsed = try parseOrganismReports(at: organismReports, resultURL: resultURL)
                if !parsed.rows.isEmpty {
                    let names = organismReports.map(\.lastPathComponent).joined(separator: ", ")
                    return (parsed.rows, parsed.accessionMap, "organism report (\(names))", .organismReport)
                }
            }

            let confidenceURL = resultURL
                .appendingPathComponent("report")
                .appendingPathComponent("multiqc_data")
                .appendingPathComponent("multiqc_confidences.txt")
            if FileManager.default.fileExists(atPath: confidenceURL.path) {
                let parsed = try parseConfidenceTSV(at: confidenceURL, resultURL: resultURL)
                return (parsed.rows, parsed.accessionMap, "confidence report", .multiqcConfidences)
            }

            let topDir = resultURL.appendingPathComponent("top")
            let topReportFiles = taxTriageTopReportFiles(in: topDir)
            guard !topReportFiles.isEmpty else { return nil }

            let parsed = try parseTopReportTSVs(at: topReportFiles, resultURL: resultURL)
            return (parsed.rows, parsed.accessionMap, "top report fallback", .topReport)
        }

        private func serialTaxTriageResultDirectories(in resultURL: URL) -> [URL] {
            let fm = FileManager.default
            guard let children = try? fm.contentsOfDirectory(
                at: resultURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return children
                .filter { child in
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                    guard values?.isDirectory == true else { return false }

                    if !TaxTriageOrganismReport.reportFiles(inResultDirectory: child).isEmpty {
                        return true
                    }

                    let confidenceURL = child
                        .appendingPathComponent("report")
                        .appendingPathComponent("multiqc_data")
                        .appendingPathComponent("multiqc_confidences.txt")
                    if fm.fileExists(atPath: confidenceURL.path) {
                        return true
                    }

                    return !taxTriageTopReportFiles(in: child.appendingPathComponent("top")).isEmpty
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        private func prefixBAMPaths(in row: TaxTriageTaxonomyRow, with directoryName: String) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: row.sample,
                organism: row.organism,
                taxId: row.taxId,
                status: row.status,
                tassScore: row.tassScore,
                readsAligned: row.readsAligned,
                uniqueReads: row.uniqueReads,
                pctReads: row.pctReads,
                pctAlignedReads: row.pctAlignedReads,
                coverageBreadth: row.coverageBreadth,
                meanCoverage: row.meanCoverage,
                meanDepth: row.meanDepth,
                confidence: row.confidence,
                k2Reads: row.k2Reads,
                parentK2Reads: row.parentK2Reads,
                giniCoefficient: row.giniCoefficient,
                meanBaseQ: row.meanBaseQ,
                meanMapQ: row.meanMapQ,
                mapqScore: row.mapqScore,
                disparityScore: row.disparityScore,
                minhashScore: row.minhashScore,
                diamondIdentity: row.diamondIdentity,
                k2DisparityScore: row.k2DisparityScore,
                siblingsScore: row.siblingsScore,
                breadthWeightScore: row.breadthWeightScore,
                hhsPercentile: row.hhsPercentile,
                isAnnotated: row.isAnnotated,
                annClass: row.annClass,
                microbialCategory: row.microbialCategory,
                highConsequence: row.highConsequence,
                isSpecies: row.isSpecies,
                pathogenicSubstrains: row.pathogenicSubstrains,
                sampleType: row.sampleType,
                bamPath: prefixRelativePath(row.bamPath, with: directoryName),
                bamIndexPath: prefixRelativePath(row.bamIndexPath, with: directoryName),
                primaryAccession: row.primaryAccession,
                accessionLength: row.accessionLength
            )
        }

        private func prefixRelativePath(_ path: String?, with directoryName: String) -> String? {
            guard let path, !path.isEmpty, !path.hasPrefix("/") else { return path }
            return URL(fileURLWithPath: directoryName, isDirectory: true)
                .appendingPathComponent(path)
                .relativePath
        }

        private func taxTriageTopReportFiles(in topDir: URL) -> [URL] {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: topDir,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }
            return urls.filter { $0.lastPathComponent.hasSuffix(".top_report.tsv") }
        }
    }
}
