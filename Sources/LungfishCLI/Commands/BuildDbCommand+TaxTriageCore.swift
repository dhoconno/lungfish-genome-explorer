// BuildDbCommand+TaxTriageCore.swift - The build-db taxtriage leaf and its core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The `build-db taxtriage` leaf moved here from BuildDbCommand.swift with no logic edit (Phase 2.9, lane A1), so
// that TaxTriage on the analysis run executor can take it over in one file. Two functions do its work.
//
// - The index is `build(resultURL:events:)`. It keeps an existing database unless `--force`, captures the record's
//   input list, resolves the taxonomy rows of the result folder, writes `taxtriage.sqlite`, recomputes unique
//   reads from the BAMs, runs the cleanup unless `--no-cleanup`, and then writes the records. A failure puts the
//   database of an earlier build back and writes a failure record.
// - The cleanup is `performCleanup(resultURL:events:)`. It removes `count/`, the fastp FASTQ files and eight
//   intermediate folders, `top/` among them, from the result folder and from each serial sample folder under it.
//
// `run` calls the index, the index calls the cleanup between the unique-read pass and the record, as it always
// has, so the record names sources that the cleanup has already removed. The folder helpers move with them
// because they are private. The report parsers stay in BuildDbCommand.swift as instance methods.
// `BuildDbTaxTriageCleanupFreezeTests` pins the rows, the record and the removed paths of that order.

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
            try await BuildDbCLIEvents(globalOptions: globalOptions).report(
                database: resultURL.appendingPathComponent("taxtriage.sqlite")
            ) { events in
                try await build(resultURL: resultURL, events: events)
            }
        }

        /// Builds `taxtriage.sqlite` in the result folder and returns what it built.
        private func build(resultURL: URL, events: BuildDbEventSink) async throws -> BuildDbRunResult {
            let runClock = ProvenanceRunClock()
            let dbURL = resultURL.appendingPathComponent("taxtriage.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                let existing = BuildDbRunResult(databaseURL: dbURL, rowCount: nil, record: nil)
                events.text(existing.summary)
                return existing
            }

            let provenanceInputs = BuildDbCommand.buildDbInputRecords(tool: .taxTriage, resultURL: resultURL)
            let samtoolsProvenance = BuildDbSamtoolsProvenanceCollector()
            let databaseSnapshot = try BuildDbDatabaseSnapshot.capture(dbURL: dbURL)

            do {
                // 1. Locate a supported taxonomy report
                let resolvedInput = try resolveTaxonomyRows(resultURL: resultURL)
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

                if !noCleanup {
                    performCleanup(resultURL: resultURL, events: events)
                }

                let record = try await BuildDbCommand.recordBuildDbProvenance(
                    tool: .taxTriage,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: force,
                    noCleanup: noCleanup,
                    globalOptions: globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    additionalSteps: samtoolsProvenance.steps, events: events
                )
                try databaseSnapshot.discard()
                return BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: record)
            } catch {
                do {
                    try databaseSnapshot.restore()
                } catch {
                    events.warning("Warning: could not restore previous TaxTriage database: \(error.localizedDescription)")
                }
                await BuildDbCommand.recordBuildDbFailureProvenanceIfNeeded(
                    tool: .taxTriage,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: force,
                    noCleanup: noCleanup,
                    globalOptions: globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    error: error,
                    additionalSteps: samtoolsProvenance.steps,
                    includeOutputRecords: false, events: events
                )
                throw error
            }
        }

        // MARK: - Post-Build Cleanup

        private func performCleanup(resultURL: URL, events: BuildDbEventSink) {
            var freedBytes: Int64 = 0

            let cleanupRoots = [resultURL] + serialTaxTriageResultDirectories(in: resultURL)
            for cleanupRoot in cleanupRoots {
                freedBytes += performCleanupForSingleResult(resultURL: cleanupRoot)
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
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
