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
            let options = BuildDbRunOptions(force: force, noCleanup: noCleanup, globalOptions: globalOptions)
            try await BuildDbCLIEvents(globalOptions: globalOptions).report(
                database: resultURL.appendingPathComponent("esviritu.sqlite")
            ) { events in
                try await Self.buildDatabase(in: resultURL, options: options, events: events)
            }
        }

        /// The `build-db esviritu` core. Builds `esviritu.sqlite` in `resultURL` from the detection and coverage
        /// tables of each sample folder, moves each sample's BAMs from `<sample>_temp` to `bams`, counts their
        /// reads with samtools, runs the cleanup unless `options.noCleanup`, records the run beside the database
        /// and returns what it built. A database that exists is kept unless `options.force`.
        static func buildDatabase(
            in resultURL: URL,
            options: BuildDbRunOptions,
            events: BuildDbEventSink
        ) async throws -> BuildDbRunResult {
            let runClock = ProvenanceRunClock()
            let dbURL = resultURL.appendingPathComponent("esviritu.sqlite")

            // Skip if exists (unless --force)
            if !options.force && FileManager.default.fileExists(atPath: dbURL.path) {
                let existing = BuildDbRunResult(databaseURL: dbURL, rowCount: nil, record: nil)
                events.text(existing.summary)
                return existing
            }

            let provenanceInputs = BuildDbCommand.buildDbInputRecords(tool: .esViritu, resultURL: resultURL)
            let samtoolsProvenance = BuildDbSamtoolsProvenanceCollector()
            let databaseSnapshot = try BuildDbDatabaseSnapshot.capture(dbURL: dbURL)
            var relocationSteps: [ProvenanceStep] = []
            var cleanupSteps: [ProvenanceStep] = []

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
                for sampleName in rootLayoutSamples(in: resultURL) {
                    let cwURL = resultURL.appendingPathComponent("\(sampleName).virus_coverage_windows.tsv")
                    guard fm.fileExists(atPath: cwURL.path), let parsed = try? EsVirituCoverageParser.parse(url: cwURL) else { continue }
                    allWindows.append(contentsOf: parsed.map { w in
                        EsVirituCoverageWindow(
                            sample: sampleName, accession: w.accession,
                            windowIndex: w.windowIndex, windowStart: w.windowStart,
                            windowEnd: w.windowEnd, averageCoverage: w.averageCoverage
                        )
                    })
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

                events.text(BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: nil).summary)

                // 4. Relocate BAMs from <sample>/<sample>_temp/ to <sample>/bams/ so the
                // resolver in updateUniqueReadsInDB and post-cleanup VC can both find them.
                // The move is a step of the run's record (plan decision E7).
                let relocationClock = ProvenanceRunClock()
                let moved = relocateEsVirituBAMs(resultURL: resultURL)
                relocationSteps = bamRelocationStep(
                    moved, resultURL: resultURL, recordedInputs: provenanceInputs, clock: relocationClock
                ).map { [$0] } ?? []

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

                let cleanupClock = ProvenanceRunClock()
                if !options.noCleanup {
                    performCleanup(resultURL: resultURL, events: events)
                }
                // The move left nothing at the BAMs' old paths in `_temp/`, which the records name, so a
                // step names each with the digest the move recorded (P1 of Phase 2.8, row 422).
                cleanupSteps = RecordedRemovalStep.step(
                    toolName: "Lungfish EsViritu Cleanup",
                    api: "BuildDbCommand.EsVirituSubcommand.relocateEsVirituBAMs(resultURL:)",
                    removing: relocationSteps.flatMap(\.inputs).filter { !FileManager.default.fileExists(atPath: $0.path) },
                    clock: cleanupClock
                ).map { [$0] } ?? []

                let record = try await BuildDbCommand.recordBuildDbProvenance(
                    tool: .esViritu,
                    resultURL: resultURL,
                    dbURL: dbURL,
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    additionalSteps: relocationSteps + samtoolsProvenance.steps + cleanupSteps,
                    writesFolderRecord: options.writesFolderRecord,
                    events: events
                )
                try databaseSnapshot.discard()
                return BuildDbRunResult(databaseURL: dbURL, rowCount: rows.count, record: record)
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
                    force: options.force,
                    noCleanup: options.noCleanup,
                    globalOptions: options.globalOptions,
                    runClock: runClock,
                    inputRecords: provenanceInputs,
                    error: error,
                    additionalSteps: relocationSteps + samtoolsProvenance.steps + cleanupSteps,
                    includeOutputRecords: false,
                    writesFolderRecord: options.writesFolderRecord,
                    events: events
                )
                throw error
            }
        }

        // MARK: - Sample Directory Enumeration & Parsing

        /// Enumerates sample subdirectories under `resultURL` and parses detection TSVs.
        static func parseSampleDirectories(resultURL: URL) throws -> [EsVirituDetectionRow] {
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

            for sampleName in rootLayoutSamples(in: resultURL) {
                let tsvURL = resultURL.appendingPathComponent("\(sampleName).detected_virus.info.tsv")
                allRows.append(contentsOf: try parseDetectionTSV(
                    at: tsvURL, sampleName: sampleName, sampleDir: resultURL, atResultRoot: true
                ))
            }

            return allRows
        }

        /// The samples of a one-folder result, whose tables sit at the folder root named by the sample, as
        /// `esviritu detect --output` and an EsViritu import leave them. Empty when a sample folder holds its
        /// detection table, because the folder is then a batch whose root is not read, in the way that
        /// `build-db kraken2` reads a root only when no sample folder holds a report.
        static func rootLayoutSamples(in resultURL: URL) -> [String] {
            let suffix = ".detected_virus.info.tsv"
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(at: resultURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let isBatch = contents.contains { dir in
                let name = dir.lastPathComponent
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !name.hasPrefix("."), !name.hasSuffix("_temp") else { return false }
                return fm.fileExists(atPath: dir.appendingPathComponent(name + suffix).path)
            }
            guard !isBatch else { return [] }
            return contents.compactMap { url -> String? in
                let name = url.lastPathComponent
                guard !name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
                return String(name.dropLast(suffix.count))
            }
            .sorted()
        }

        /// Parses a single EsViritu `detected_virus.info.tsv` file into detection rows. A table at the
        /// result root (`atResultRoot`) names its BAM under the root's `bams`, and a sample folder's table
        /// under that folder's `bams`.
        static func parseDetectionTSV(
            at url: URL,
            sampleName: String,
            sampleDir: URL,
            atResultRoot: Bool = false
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
                let bamRelative = atResultRoot ? "bams/\(bamBasename)" : "\(sampleName)/bams/\(bamBasename)"

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
        /// remove `_temp/` without breaking DB-referenced BAM paths. A one-folder
        /// result moves `<root>/<sample>_temp/` into `<root>/bams/`. Returns each
        /// file it moved.
        @discardableResult
        private static func relocateEsVirituBAMs(resultURL: URL) -> [(source: URL, destination: URL)] {
            let fm = FileManager.default
            guard let sampleDirs = try? fm.contentsOfDirectory(
                at: resultURL, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return [] }

            var moved: [(source: URL, destination: URL)] = []
            for sampleDir in sampleDirs {
                let isDir = (try? sampleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let sampleName = sampleDir.lastPathComponent
                guard !sampleName.hasPrefix(".") else { continue }
                moved += moveBAMs(of: sampleName, in: sampleDir)
            }
            for sampleName in rootLayoutSamples(in: resultURL) {
                moved += moveBAMs(of: sampleName, in: resultURL)
            }
            return moved
        }

        /// Moves `<sample>.third.filt.sorted.bam` and its index from `folder/<sample>_temp/` into
        /// `folder/bams/`, keeping a file that a run before this one already moved.
        private static func moveBAMs(of sampleName: String, in folder: URL) -> [(source: URL, destination: URL)] {
            let fm = FileManager.default
            let tempDir = folder.appendingPathComponent("\(sampleName)_temp")
            let bamsDir = folder.appendingPathComponent("bams")
            guard fm.fileExists(atPath: tempDir.path) else { return [] }

            let bamBasename = "\(sampleName).third.filt.sorted.bam"
            let sourceURLs = [
                tempDir.appendingPathComponent(bamBasename),
                tempDir.appendingPathComponent(bamBasename + ".bai"),
                tempDir.appendingPathComponent(bamBasename + ".csi"),
            ]

            // Only create bams/ if we have something to move
            let movable = sourceURLs.filter { fm.fileExists(atPath: $0.path) }
            guard !movable.isEmpty else { return [] }
            try? fm.createDirectory(at: bamsDir, withIntermediateDirectories: true)

            var moved: [(source: URL, destination: URL)] = []
            for source in movable {
                let dest = bamsDir.appendingPathComponent(source.lastPathComponent)
                // If destination already exists (re-run), skip
                guard !fm.fileExists(atPath: dest.path) else { continue }
                if (try? fm.moveItem(at: source, to: dest)) != nil {
                    moved.append((source: source, destination: dest))
                }
            }
            return moved
        }

        // MARK: - Post-Build Cleanup

        /// Removes the `_temp/` folders, whose BAMs the run moved to `bams/` first.
        ///
        /// Keeps every table EsViritu wrote, among them `*.virus_coverage_windows.tsv` and
        /// `*.detected_virus.assembly_summary.tsv`, which the sample record names as outputs and which
        /// hold the coverage breadth behind each detection (plan decision E7 of Phase 2.7, risk R6). Keeps
        /// `esviritu.sqlite` and `bams/`.
        private static func performCleanup(resultURL: URL, events: BuildDbEventSink) {
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

                // Remove _temp directory inside sample directory
                let tempDir = dir.appendingPathComponent("\(name)_temp")
                if let size = directorySize(tempDir) {
                    try? fm.removeItem(at: tempDir)
                    freedBytes += size
                }
            }

            events.text("Cleanup complete. Freed \(LungfishFormatters.formatBytes(freedBytes))")
        }

        private static func directorySize(_ url: URL) -> Int64? {
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

        /// The BAM move from `_temp/` to `bams/` as a step of the run's record (plan decision E7). Each moved
        /// file is an input under its old path and an output under its new one that names the old path as its
        /// origin. A move changes no byte, so both carry the digest and size the run recorded for the file when
        /// it began, or the digest of the moved file when the run recorded none. Nil when nothing moved.
        static func bamRelocationStep(
            _ moved: [(source: URL, destination: URL)],
            resultURL: URL,
            recordedInputs: [FileRecord],
            clock: ProvenanceRunClock
        ) -> ProvenanceStep? {
            var recorded: [String: ProvenanceFileDescriptor] = [:]
            for record in recordedInputs {
                recorded[URL(fileURLWithPath: record.path).standardizedFileURL.path] = ProvenanceFileDescriptor(fileRecord: record)
            }
            var inputs: [ProvenanceFileDescriptor] = []
            var outputs: [ProvenanceFileDescriptor] = []
            for move in moved {
                let name = move.destination.lastPathComponent
                let role: FileRole = name.hasSuffix(".bai") || name.hasSuffix(".csi") ? .index : .output
                guard let before = recorded[move.source.standardizedFileURL.path]
                    ?? (try? ProvenanceFileDescriptor.file(url: move.destination, role: role == .index ? .index : .input)),
                    before.checksumSHA256 != nil, before.fileSize != nil else { continue }
                inputs.append(ProvenanceFileDescriptor(
                    path: move.source.path, checksumSHA256: before.checksumSHA256, fileSize: before.fileSize,
                    format: before.format, role: before.role
                ))
                outputs.append(ProvenanceFileDescriptor(
                    path: move.destination.path, checksumSHA256: before.checksumSHA256, fileSize: before.fileSize,
                    format: before.format, role: role, originPath: move.source.path
                ))
            }
            guard !outputs.isEmpty else { return nil }
            return ProvenanceStep(
                toolName: "Lungfish EsViritu BAM Relocation",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: ["BuildDbCommand.EsVirituSubcommand.relocateEsVirituBAMs(resultURL:)", resultURL.path],
                resolvedOptions: ["invocationKind": .string("swift-api"), "operation": .string("move")],
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: inputs,
                outputs: outputs,
                exitStatus: 0,
                wallTimeSeconds: clock.elapsed,
                startedAt: clock.startedAt,
                completedAt: clock.now
            )
        }

        // MARK: - Column Index Builder

        private static func buildColumnIndex(from header: [String]) -> [String: Int] {
            var index: [String: Int] = [:]
            for (i, name) in header.enumerated() {
                index[name.lowercased().trimmingCharacters(in: .whitespaces)] = i
            }
            return index
        }

        // MARK: - Field Accessors

        private static func field(_ fields: [String], _ index: Int?) -> String {
            guard let i = index, i < fields.count else { return "" }
            return fields[i]
        }

        private static func optionalField(_ fields: [String], _ index: Int?) -> String? {
            guard let i = index, i < fields.count else { return nil }
            let val = fields[i]
            return val.isEmpty ? nil : val
        }

        /// Returns nil for empty strings and "NA" values.
        private static func naAwareOptionalField(_ fields: [String], _ index: Int?) -> String? {
            guard let i = index, i < fields.count else { return nil }
            let val = fields[i].trimmingCharacters(in: .whitespaces)
            if val.isEmpty || val == "NA" || val == "na" { return nil }
            return val
        }

        private static func parseDouble(_ fields: [String], _ index: Int?) -> Double? {
            guard let i = index, i < fields.count else { return nil }
            return Double(fields[i])
        }

        private static func parseInt(_ fields: [String], _ index: Int?) -> Int? {
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
