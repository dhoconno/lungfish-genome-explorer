// BuildDbCommand+EsVirituCore.swift - The build-db esviritu leaf and its core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - EsViritu Subcommand

extension BuildDbCommand {

    /// Build a SQLite database from EsViritu pipeline output.
    ///
    /// Enumerates sample subdirectories, parses each `detected_virus.info.tsv`,
    /// resolves BAM paths, and writes an `esviritu.sqlite` database in the result
    /// directory.
    struct EsVirituSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "esviritu",
            abstract: "Build SQLite database from EsViritu results"
        )

        @Argument(help: "Path to the EsViritu result directory")
        var resultDir: String

        @Flag(name: .long, help: "Force rebuild even if database exists")
        var force: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Skip post-build cleanup of intermediate files")
        var noCleanup: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let resultURL = URL(fileURLWithPath: resultDir)
            try await BuildDbCLIEvents(globalOptions: globalOptions).report(
                database: resultURL.appendingPathComponent("esviritu.sqlite")
            ) { events in
                try await build(resultURL: resultURL, events: events)
            }
        }

        /// Builds `esviritu.sqlite` in the result folder and returns the sentence that ends the run.
        private func build(resultURL: URL, events: BuildDbEventSink) async throws -> String {
            let runClock = ProvenanceRunClock()
            let dbURL = resultURL.appendingPathComponent("esviritu.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                let existing = "Database already exists at \(dbURL.path). Use --force to rebuild."
                events.text(existing)
                return existing
            }

            let provenanceInputs = BuildDbCommand.buildDbInputRecords(tool: .esViritu, resultURL: resultURL)
            let samtoolsProvenance = BuildDbSamtoolsProvenanceCollector()
            let databaseSnapshot = try BuildDbDatabaseSnapshot.capture(dbURL: dbURL)

            do {
                // 1. Enumerate sample subdirectories containing detection TSVs
                let rows = try parseSampleDirectories(resultURL: resultURL)

                events.text("Parsed \(rows.count) detection rows from EsViritu results")

                // 2. Parse coverage windows from virus_coverage_windows.tsv files
                var allWindows: [EsVirituCoverageWindow] = []
                let fm = FileManager.default
                if let sampleDirs = try? fm.contentsOfDirectory(at: resultURL, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for dir in sampleDirs {
                        let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        guard isDir else { continue }
                        let sampleName = dir.lastPathComponent
                        guard !sampleName.hasPrefix(".") else { continue }

                        let cwURL = dir.appendingPathComponent("\(sampleName).virus_coverage_windows.tsv")
                        if fm.fileExists(atPath: cwURL.path) {
                            if let parsed = try? EsVirituCoverageParser.parse(url: cwURL) {
                                let dbWindows = parsed.map { w in
                                    EsVirituCoverageWindow(
                                        sample: sampleName, accession: w.accession,
                                        windowIndex: w.windowIndex, windowStart: w.windowStart,
                                        windowEnd: w.windowEnd, averageCoverage: w.averageCoverage
                                    )
                                }
                                allWindows.append(contentsOf: dbWindows)
                            }
                        }
                    }
                }

                events.text("Parsed \(allWindows.count) coverage windows from EsViritu results")

                // 3. Build database
                let metadata: [String: String] = [
                    "tool": "esviritu",
                    "created_at": ISO8601DateFormatter().string(from: Date()),
                    "source_dir": resultURL.path,
                ]

                _ = try EsVirituDatabase.create(
                    at: dbURL, rows: rows, coverageWindows: allWindows, metadata: metadata, progress: events.progress
                )

                let built = "Built database at \(dbURL.path) with \(rows.count) rows"
                events.text(built)

                // 4. Relocate BAMs from <sample>/<sample>_temp/ to <sample>/bams/ so the
                // resolver in updateUniqueReadsInDB and post-cleanup VC can both find them.
                relocateEsVirituBAMs(resultURL: resultURL)

                // 5. Compute unique reads from BAMs and update DB
                try await updateUniqueReadsInDB(
                    dbPath: dbURL.path,
                    table: "detection_rows",
                    sampleCol: "sample",
                    accessionCol: "accession",
                    bamPathCol: "bam_path",
                    totalReadsCol: "read_count",
                    resultURL: resultURL,
                    bamPathResolver: { resultURL, _, bamRelPath in
                        // EsViritu BAM paths are now full relative paths from the result root.
                        resultURL.appendingPathComponent(bamRelPath).path
                    },
                    updateAccessionLength: false,
                    events: events,
                    provenance: samtoolsProvenance
                )

                if !noCleanup {
                    performCleanup(resultURL: resultURL, events: events)
                }

                try await BuildDbCommand.recordBuildDbProvenance(
                    tool: .esViritu,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: force,
                    noCleanup: noCleanup,
                    globalOptions: globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    additionalSteps: samtoolsProvenance.steps
                )
                try databaseSnapshot.discard()
                return built
            } catch {
                do {
                    try databaseSnapshot.restore()
                } catch {
                    events.warning("Warning: could not restore previous EsViritu database: \(error.localizedDescription)")
                }
                await BuildDbCommand.recordBuildDbFailureProvenanceIfNeeded(
                    tool: .esViritu,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: force,
                    noCleanup: noCleanup,
                    globalOptions: globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    error: error,
                    additionalSteps: samtoolsProvenance.steps,
                    includeOutputRecords: false
                )
                throw error
            }
        }

        // MARK: - Sample Directory Enumeration & Parsing

        /// Enumerates sample subdirectories under `resultURL` and parses detection TSVs.
        func parseSampleDirectories(resultURL: URL) throws -> [EsVirituDetectionRow] {
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(
                at: resultURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

            var allRows: [EsVirituDetectionRow] = []

            for dir in contents {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let sampleName = dir.lastPathComponent
                // Skip _temp directories and hidden directories
                guard !sampleName.hasPrefix("."), !sampleName.hasSuffix("_temp") else { continue }

                // Look for detected_virus.info.tsv
                let tsvURL = dir.appendingPathComponent("\(sampleName).detected_virus.info.tsv")
                guard fm.fileExists(atPath: tsvURL.path) else { continue }

                let rows = try parseDetectionTSV(at: tsvURL, sampleName: sampleName, sampleDir: dir)
                allRows.append(contentsOf: rows)
            }

            return allRows
        }

        /// Parses a single EsViritu `detected_virus.info.tsv` file into detection rows.
        func parseDetectionTSV(
            at url: URL,
            sampleName: String,
            sampleDir: URL
        ) throws -> [EsVirituDetectionRow] {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else {
                return [] // Header only or empty
            }

            // Parse header to find column indices
            let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0) }
            let colIndex = buildColumnIndex(from: header)

            var rows: [EsVirituDetectionRow] = []

            for lineIndex in 1..<lines.count {
                let fields = lines[lineIndex]
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .map { String($0) }

                // Allow rows with fewer fields than header (filtered_reads_in_sample may be missing)
                guard fields.count >= 2 else { continue }

                let virusName = field(fields, colIndex["name"])
                let accession = field(fields, colIndex["accession"])
                guard !virusName.isEmpty, !accession.isEmpty else { continue }

                let description = optionalField(fields, colIndex["description"])
                let contigLength = parseInt(fields, colIndex["length"])
                let segment = naAwareOptionalField(fields, colIndex["segment"])
                let assembly = field(fields, colIndex["assembly"])
                let assemblyLength = parseInt(fields, colIndex["asm_length"])
                let kingdom = naAwareOptionalField(fields, colIndex["kingdom"])
                let phylum = naAwareOptionalField(fields, colIndex["phylum"])
                let tclass = naAwareOptionalField(fields, colIndex["tclass"])
                let torder = naAwareOptionalField(fields, colIndex["order"])
                let family = naAwareOptionalField(fields, colIndex["family"])
                let genus = naAwareOptionalField(fields, colIndex["genus"])
                let species = naAwareOptionalField(fields, colIndex["species"])
                let subspecies = naAwareOptionalField(fields, colIndex["subspecies"])
                let rpkmf = parseDouble(fields, colIndex["rpkmf"])
                let readCount = parseInt(fields, colIndex["read_count"]) ?? 0
                let coveredBases = parseInt(fields, colIndex["covered_bases"])
                let meanCoverage = parseDouble(fields, colIndex["mean_coverage"])
                let avgReadIdentity = parseDouble(fields, colIndex["avg_read_identity"])
                let pi = parseDouble(fields, colIndex["pi"])
                let filteredReadsInSample = parseInt(fields, colIndex["filtered_reads_in_sample"])

                // Resolve BAM path in persistent `bams/` location (relative to result root).
                let bamBasename = "\(sampleName).third.filt.sorted.bam"
                let bamRelative = "\(sampleName)/bams/\(bamBasename)"

                // BAM may be in _temp/ at parse time — relocation happens later in run().
                let tempBamURL = sampleDir.appendingPathComponent("\(sampleName)_temp")
                    .appendingPathComponent(bamBasename)
                let persistentBamURL = sampleDir.appendingPathComponent("bams")
                    .appendingPathComponent(bamBasename)

                var bamPath: String?
                var bamIndexPath: String?
                if FileManager.default.fileExists(atPath: tempBamURL.path)
                    || FileManager.default.fileExists(atPath: persistentBamURL.path) {
                    bamPath = bamRelative
                    // Index: prefer .bai then .csi, check either temp or persistent location
                    for ext in [".bai", ".csi"] {
                        let tempIdxURL = URL(fileURLWithPath: tempBamURL.path + ext)
                        let persistentIdxURL = URL(fileURLWithPath: persistentBamURL.path + ext)
                        if FileManager.default.fileExists(atPath: tempIdxURL.path)
                            || FileManager.default.fileExists(atPath: persistentIdxURL.path) {
                            bamIndexPath = bamRelative + ext
                            break
                        }
                    }
                }

                rows.append(EsVirituDetectionRow(
                    sample: sampleName,
                    virusName: virusName,
                    description: description,
                    contigLength: contigLength,
                    segment: segment,
                    accession: accession,
                    assembly: assembly,
                    assemblyLength: assemblyLength,
                    kingdom: kingdom,
                    phylum: phylum,
                    tclass: tclass,
                    torder: torder,
                    family: family,
                    genus: genus,
                    species: species,
                    subspecies: subspecies,
                    rpkmf: rpkmf,
                    readCount: readCount,
                    // Filled by the post-parse unique-read update pass once
                    // sample-level dedup counts are available.
                    uniqueReads: nil,
                    coveredBases: coveredBases,
                    meanCoverage: meanCoverage,
                    avgReadIdentity: avgReadIdentity,
                    pi: pi,
                    filteredReadsInSample: filteredReadsInSample,
                    bamPath: bamPath,
                    bamIndexPath: bamIndexPath
                ))
            }

            return rows
        }

        // MARK: - BAM Relocation (pre-cleanup)

        /// Moves `*.third.filt.sorted.bam{,.bai,.csi}` from each sample's `_temp/`
        /// directory into a sibling `bams/` directory so post-build cleanup can
        /// remove `_temp/` without breaking DB-referenced BAM paths.
        private func relocateEsVirituBAMs(resultURL: URL) {
            let fm = FileManager.default
            guard let sampleDirs = try? fm.contentsOfDirectory(
                at: resultURL, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return }

            for sampleDir in sampleDirs {
                let isDir = (try? sampleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let sampleName = sampleDir.lastPathComponent
                guard !sampleName.hasPrefix(".") else { continue }

                let tempDir = sampleDir.appendingPathComponent("\(sampleName)_temp")
                let bamsDir = sampleDir.appendingPathComponent("bams")
                guard fm.fileExists(atPath: tempDir.path) else { continue }

                let bamBasename = "\(sampleName).third.filt.sorted.bam"
                let sourceURLs = [
                    tempDir.appendingPathComponent(bamBasename),
                    tempDir.appendingPathComponent(bamBasename + ".bai"),
                    tempDir.appendingPathComponent(bamBasename + ".csi"),
                ]

                // Only create bams/ if we have something to move
                let movable = sourceURLs.filter { fm.fileExists(atPath: $0.path) }
                guard !movable.isEmpty else { continue }
                try? fm.createDirectory(at: bamsDir, withIntermediateDirectories: true)

                for source in movable {
                    let dest = bamsDir.appendingPathComponent(source.lastPathComponent)
                    // If destination already exists (re-run), skip
                    guard !fm.fileExists(atPath: dest.path) else { continue }
                    try? fm.moveItem(at: source, to: dest)
                }
            }
        }

        // MARK: - Post-Build Cleanup

        /// Removes intermediate files while preserving detection TSVs and the database.
        ///
        /// Removes: `*_temp/` directories, `*.virus_coverage_windows.tsv`,
        /// `*.detected_virus.assembly_summary.tsv`.
        /// Keeps: `*.detected_virus.info.tsv`, `esviritu.sqlite`.
        private func performCleanup(resultURL: URL, events: BuildDbEventSink) {
            let fm = FileManager.default
            var freedBytes: Int64 = 0

            guard let sampleDirs = try? fm.contentsOfDirectory(
                at: resultURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return }

            for dir in sampleDirs {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let name = dir.lastPathComponent
                guard !name.hasPrefix(".") else { continue }

                // Remove _temp directories (contain BAM files — no longer needed after DB build)
                if name.hasSuffix("_temp") {
                    if let size = directorySize(dir) {
                        try? fm.removeItem(at: dir)
                        freedBytes += size
                    }
                    continue
                }

                // Inside sample directories, remove intermediate TSVs
                let coverageWindows = dir.appendingPathComponent("\(name).virus_coverage_windows.tsv")
                if let size = fileSize(coverageWindows) {
                    try? fm.removeItem(at: coverageWindows)
                    freedBytes += size
                }

                let assemblySummary = dir.appendingPathComponent("\(name).detected_virus.assembly_summary.tsv")
                if let size = fileSize(assemblySummary) {
                    try? fm.removeItem(at: assemblySummary)
                    freedBytes += size
                }

                // Remove _temp directory inside sample directory
                let tempDir = dir.appendingPathComponent("\(name)_temp")
                if let size = directorySize(tempDir) {
                    try? fm.removeItem(at: tempDir)
                    freedBytes += size
                }
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
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

        private func fileSize(_ url: URL) -> Int64? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }

        // MARK: - Column Index Builder

        private func buildColumnIndex(from header: [String]) -> [String: Int] {
            var index: [String: Int] = [:]
            for (i, name) in header.enumerated() {
                index[name.lowercased().trimmingCharacters(in: .whitespaces)] = i
            }
            return index
        }

        // MARK: - Field Accessors

        private func field(_ fields: [String], _ index: Int?) -> String {
            guard let i = index, i < fields.count else { return "" }
            return fields[i]
        }

        private func optionalField(_ fields: [String], _ index: Int?) -> String? {
            guard let i = index, i < fields.count else { return nil }
            let val = fields[i]
            return val.isEmpty ? nil : val
        }

        /// Returns nil for empty strings and "NA" values.
        private func naAwareOptionalField(_ fields: [String], _ index: Int?) -> String? {
            guard let i = index, i < fields.count else { return nil }
            let val = fields[i].trimmingCharacters(in: .whitespaces)
            if val.isEmpty || val == "NA" || val == "na" { return nil }
            return val
        }

        private func parseDouble(_ fields: [String], _ index: Int?) -> Double? {
            guard let i = index, i < fields.count else { return nil }
            return Double(fields[i])
        }

        private func parseInt(_ fields: [String], _ index: Int?) -> Int? {
            guard let i = index, i < fields.count else { return nil }
            if let intVal = Int(fields[i]) {
                return intVal
            }
            if let dblVal = Double(fields[i]) {
                return Int(dblVal)
            }
            return nil
        }
    }
}
