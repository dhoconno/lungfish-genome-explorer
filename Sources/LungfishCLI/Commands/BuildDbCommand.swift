// BuildDbCommand.swift - CLI command to build SQLite databases from classifier results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import SQLite3

/// Build SQLite databases from classifier pipeline output.
///
/// Reads raw TSV/text output from classification pipelines (TaxTriage, EsViritu,
/// Kraken2) and creates a SQLite database for fast random-access queries in the
/// Lungfish taxonomy browser.
///
/// ## Examples
///
/// ```
/// # Build TaxTriage database
/// lungfish build-db taxtriage /path/to/taxtriage-results
///
/// # Force rebuild
/// lungfish build-db taxtriage /path/to/taxtriage-results --force
/// ```
struct BuildDbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-db",
        abstract: "Build SQLite databases from classifier results",
        subcommands: [
            TaxTriageSubcommand.self,
            EsVirituSubcommand.self,
            Kraken2Subcommand.self,
        ]
    )
}

// MARK: - Unique Reads Computation (samtools dedup)

/// Locates a samtools binary using the managed-first locator.
private func findSamtools() -> String? {
    BuildDbCommand.locateSamtools()
}

private enum BuildDbUniqueReadsError: LocalizedError {
    case managedSamtoolsUnavailable

    var errorDescription: String? {
        switch self {
        case .managedSamtoolsUnavailable:
            return "Managed samtools is required to compute build-db read counts. Install the managed samtools environment and rerun build-db."
        }
    }
}

/// Updates the `unique_reads` column in a SQLite database for rows with BAM paths.
///
/// Opens the database read-write, queries rows that have a BAM path and accession,
/// computes unique reads via samtools, and updates each row.
///
/// - Parameters:
///   - dbPath: Absolute path to the SQLite database file.
///   - table: Table name (e.g., "taxonomy_rows" or "detection_rows").
///   - sampleCol: Column name for the sample identifier.
///   - accessionCol: Column name for the accession to query in the BAM.
///   - bamPathCol: Column name for the relative BAM path.
///   - resultURL: Base URL for resolving relative BAM paths.
///   - bamPathResolver: Closure that resolves (resultURL, sample, bamRelPath) to an absolute path.
///   - quiet: Whether to suppress progress output.
private func updateUniqueReadsInDB(
    dbPath: String,
    table: String,
    sampleCol: String,
    accessionCol: String,
    bamPathCol: String,
    totalReadsCol: String,
    resultURL: URL,
    bamPathResolver: (URL, String, String) -> String,
    updateAccessionLength: Bool,
    quiet: Bool
) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        if !quiet { print("Warning: could not open database for unique reads update") }
        return
    }
    defer { sqlite3_close(db) }

    // Query rows that have BAM + accession
    let selectSQL = "SELECT rowid, \(sampleCol), \(accessionCol), \(bamPathCol) FROM \(table) WHERE \(bamPathCol) IS NOT NULL AND \(accessionCol) IS NOT NULL AND \(accessionCol) != ''"
    var selectStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
        if !quiet { print("Warning: failed to prepare SELECT for unique reads") }
        return
    }
    defer { sqlite3_finalize(selectStmt) }

    struct RowToProcess {
        let rowid: Int64
        let sample: String
        let accession: String
        let bamRelPath: String
    }
    var rowsToProcess: [RowToProcess] = []
    while sqlite3_step(selectStmt) == SQLITE_ROW {
        let rowid = sqlite3_column_int64(selectStmt, 0)
        guard let sPtr = sqlite3_column_text(selectStmt, 1),
              let aPtr = sqlite3_column_text(selectStmt, 2),
              let bPtr = sqlite3_column_text(selectStmt, 3) else { continue }
        rowsToProcess.append(RowToProcess(
            rowid: rowid,
            sample: String(cString: sPtr),
            accession: String(cString: aPtr),
            bamRelPath: String(cString: bPtr)
        ))
    }

    guard !rowsToProcess.isEmpty else {
        if !quiet { print("  No rows with BAM paths found, skipping unique reads") }
        return
    }

    guard let samtoolsPath = findSamtools() else {
        throw BuildDbUniqueReadsError.managedSamtoolsUnavailable
    }

    // Step 1: Run markdup on each unique BAM file
    let uniqueBAMPaths = Set(rowsToProcess.map { bamPathResolver(resultURL, $0.sample, $0.bamRelPath) })
    if !quiet { print("Running markdup on \(uniqueBAMPaths.count) BAM file(s)...") }
    var marked = 0
    for bamFullPath in uniqueBAMPaths {
        let bamURL = URL(fileURLWithPath: bamFullPath)
        guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
        do {
            let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
            if !result.wasAlreadyMarkduped { marked += 1 }
        } catch {
            if !quiet { print("  Warning: markdup failed on \(bamURL.lastPathComponent): \(error.localizedDescription)") }
        }
    }
    if !quiet && marked > 0 { print("  Marked duplicates in \(marked) BAM file(s)") }

    // Step 2: Count reads_aligned and unique_reads per (sample, accession)
    if !quiet { print("Counting reads per organism...") }

    // Build accession_length map from samtools idxstats if needed
    var refLengths: [String: Int] = [:]
    if updateAccessionLength {
        for bamFullPath in uniqueBAMPaths {
            guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
            let idxProcess = Process()
            idxProcess.executableURL = URL(fileURLWithPath: samtoolsPath)
            idxProcess.arguments = ["idxstats", bamFullPath]
            let pipe = Pipe()
            idxProcess.standardOutput = pipe
            idxProcess.standardError = FileHandle.nullDevice
            do { try idxProcess.run() } catch { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            idxProcess.waitUntilExit()
            guard idxProcess.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { continue }
            for line in output.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 2 else { continue }
                let refName = String(cols[0])
                guard refName != "*" else { continue }
                if let len = Int(cols[1]), len > 0 {
                    refLengths[refName] = len
                }
            }
        }
    }

    // Update accession_length column (TaxTriage only)
    if updateAccessionLength && !refLengths.isEmpty {
        let lenSQL = "UPDATE \(table) SET accession_length = ? WHERE rowid = ?"
        var lenStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, lenSQL, -1, &lenStmt, nil) == SQLITE_OK {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            var lenUpdated = 0
            for row in rowsToProcess {
                if let len = refLengths[row.accession] {
                    sqlite3_reset(lenStmt)
                    sqlite3_bind_int64(lenStmt, 1, Int64(len))
                    sqlite3_bind_int64(lenStmt, 2, row.rowid)
                    sqlite3_step(lenStmt)
                    lenUpdated += 1
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            sqlite3_finalize(lenStmt)
            if !quiet && lenUpdated > 0 { print("  Updated accession lengths for \(lenUpdated) organisms") }
        }
    }

    // Update reads_aligned (total mapped) and unique_reads (non-duplicate mapped)
    // from the BAM. reads_aligned is overwritten with the authoritative BAM count
    // (samtools view -c -F 0x4) replacing the pipeline TSV value.
    let updateSQL = "UPDATE \(table) SET \(totalReadsCol) = ?, unique_reads = ? WHERE rowid = ?"
    var updateStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
        if !quiet { print("Warning: failed to prepare UPDATE for read counts") }
        return
    }
    defer { sqlite3_finalize(updateStmt) }

    sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
    var updated = 0
    var uniqueCache: [String: Int] = [:]
    var totalCache: [String: Int] = [:]
    for (i, row) in rowsToProcess.enumerated() {
        let bamFullPath = bamPathResolver(resultURL, row.sample, row.bamRelPath)
        guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }

        let cacheKey = "\(bamFullPath)\t\(row.accession)"
        let bamURL = URL(fileURLWithPath: bamFullPath)

        let unique: Int
        if let cached = uniqueCache[cacheKey] {
            unique = cached
        } else {
            do {
                unique = try MarkdupService.countReads(
                    bamURL: bamURL,
                    accession: row.accession,
                    flagFilter: 0x404,  // unmapped + duplicate
                    samtoolsPath: samtoolsPath
                )
                uniqueCache[cacheKey] = unique
            } catch {
                continue
            }
        }

        let total: Int
        if let cached = totalCache[cacheKey] {
            total = cached
        } else {
            do {
                total = try MarkdupService.countReads(
                    bamURL: bamURL,
                    accession: row.accession,
                    flagFilter: 0x4,  // unmapped only (includes duplicates)
                    samtoolsPath: samtoolsPath
                )
                totalCache[cacheKey] = total
            } catch {
                total = 0
            }
        }

        sqlite3_reset(updateStmt)
        sqlite3_bind_int64(updateStmt, 1, Int64(total))
        sqlite3_bind_int64(updateStmt, 2, Int64(unique))
        sqlite3_bind_int64(updateStmt, 3, row.rowid)
        sqlite3_step(updateStmt)
        updated += 1

        if (i + 1) % 50 == 0 && !quiet {
            print("  Processed \(i + 1)/\(rowsToProcess.count) organisms...")
        }
    }
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
    if !quiet { print("  Updated read counts for \(updated)/\(rowsToProcess.count) organisms") }
}

extension BuildDbCommand {
    static func locateSamtools(homeDirectory: URL = currentHomeDirectory()) -> String? {
        SamtoolsLocator.locate(homeDirectory: homeDirectory, searchPath: nil)
    }

    private static func currentHomeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

// MARK: - TaxTriage Subcommand

extension BuildDbCommand {

    /// Build a SQLite database from TaxTriage pipeline output.
    ///
    /// Parses the confidence TSV (`report/multiqc_data/multiqc_confidences.txt`),
    /// resolves BAM paths and accession data from gcfmap files, and writes a
    /// `taxtriage.sqlite` database in the result directory.
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
            let dbURL = resultURL.appendingPathComponent("taxtriage.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                if !globalOptions.quiet {
                    print("Database already exists at \(dbURL.path). Use --force to rebuild.")
                }
                return
            }

            // 1. Locate a supported taxonomy report
            let resolvedInput = try resolveTaxonomyRows(resultURL: resultURL)
            let rows = resolvedInput.rows
            let accessionMap = resolvedInput.accessionMap

            if !globalOptions.quiet {
                print("Parsed \(rows.count) taxonomy rows, \(accessionMap.count) accession entries from \(resolvedInput.sourceDescription)")
            }

            // 3. Build database
            let metadata: [String: String] = [
                "tool": "taxtriage",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "source_dir": resultURL.path,
            ]

            try TaxTriageDatabase.create(at: dbURL, rows: rows, accessionMap: accessionMap, metadata: metadata) { fraction, msg in
                if self.globalOptions.outputFormat == .json {
                    let obj: [String: Any] = ["progress": fraction, "message": msg]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let json = String(data: data, encoding: .utf8) {
                        FileHandle.standardError.write(Data((json + "\n").utf8))
                    }
                }
            }

            if !globalOptions.quiet {
                print("Built database at \(dbURL.path) with \(rows.count) rows")
            }

            // 4. Compute unique reads from BAMs and update DB
            try updateUniqueReadsInDB(
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
                quiet: globalOptions.quiet
            )

            if !noCleanup {
                performCleanup(resultURL: resultURL)
            }
        }

        // MARK: - Post-Build Cleanup

        private func performCleanup(resultURL: URL) {
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

            if !globalOptions.quiet {
                print("Cleanup complete. Freed \(formatBytes(freedBytes))")
            }
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

        private func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }
}

// MARK: - TSV Parsing

extension BuildDbCommand.TaxTriageSubcommand {

    private func resolveTaxonomyRows(
        resultURL: URL
    ) throws -> (
        rows: [TaxTriageTaxonomyRow],
        accessionMap: [TaxTriageAccessionEntry],
        sourceDescription: String
    ) {
        if let parsed = try parseSingleTaxTriageResult(resultURL: resultURL) {
            return parsed
        }

        let serialResults = serialTaxTriageResultDirectories(in: resultURL)
        if !serialResults.isEmpty {
            var rows: [TaxTriageTaxonomyRow] = []
            var accessionMap: [TaxTriageAccessionEntry] = []

            for sampleResultURL in serialResults {
                guard let parsed = try parseSingleTaxTriageResult(resultURL: sampleResultURL) else { continue }
                let directoryName = sampleResultURL.lastPathComponent
                rows.append(contentsOf: parsed.rows.map { prefixBAMPaths(in: $0, with: directoryName) })
                accessionMap.append(contentsOf: parsed.accessionMap)
            }

            if !rows.isEmpty {
                return (rows, accessionMap, "serial sample result directories")
            }
        }

        throw ValidationError(
            "No supported TaxTriage taxonomy report found in \(resultURL.path). Expected report/multiqc_data/multiqc_confidences.txt, top/*.top_report.tsv, or serial sample subdirectories containing those reports"
        )
    }

    private func parseSingleTaxTriageResult(
        resultURL: URL
    ) throws -> (
        rows: [TaxTriageTaxonomyRow],
        accessionMap: [TaxTriageAccessionEntry],
        sourceDescription: String
    )? {
        let confidenceURL = resultURL
            .appendingPathComponent("report")
            .appendingPathComponent("multiqc_data")
            .appendingPathComponent("multiqc_confidences.txt")
        if FileManager.default.fileExists(atPath: confidenceURL.path) {
            let parsed = try parseConfidenceTSV(at: confidenceURL, resultURL: resultURL)
            return (parsed.rows, parsed.accessionMap, "confidence report")
        }

        let topDir = resultURL.appendingPathComponent("top")
        let topReportFiles = taxTriageTopReportFiles(in: topDir)
        guard !topReportFiles.isEmpty else { return nil }

        let parsed = try parseTopReportTSVs(at: topReportFiles, resultURL: resultURL)
        return (parsed.rows, parsed.accessionMap, "top report fallback")
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

    /// Parses the TaxTriage multiqc_confidences.txt TSV into taxonomy rows.
    ///
    /// Also resolves BAM paths and primary accession from gcfmap files.
    func parseConfidenceTSV(
        at url: URL,
        resultURL: URL
    ) throws -> (rows: [TaxTriageTaxonomyRow], accessionMap: [TaxTriageAccessionEntry]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            return (rows: [], accessionMap: []) // Header only or empty
        }

        // Parse header to find column indices
        let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0) }
        let colIndex = buildColumnIndex(from: header)

        // Load gcfmap data for accession lookup — keyed by sample ID
        let gcfmapDir = resultURL.appendingPathComponent("combine")
        var gcfmapCache: [String: [(accession: String, organism: String)]] = [:]

        var rows: [TaxTriageTaxonomyRow] = []

        for lineIndex in 1..<lines.count {
            let fields = lines[lineIndex]
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0) }

            guard fields.count >= header.count else { continue }

            let sample = field(fields, colIndex["specimen id"])
            let rawOrganism = field(fields, colIndex["detected organism"])
            guard !sample.isEmpty, !rawOrganism.isEmpty else { continue }

            // Strip leading star and trailing degree symbol from organism name
            let organism = cleanOrganismName(rawOrganism)

            let taxId = parseInt(fields, colIndex["taxonomic id #"])
            let status = optionalField(fields, colIndex["status"])
            let tassScore = parseDouble(fields, colIndex["tass score"]) ?? 0.0
            let readsAligned = parseInt(fields, colIndex["# reads aligned"]) ?? 0
            let pctReads = optionalField(fields, colIndex["% reads"])
            let pctAlignedReads = optionalField(fields, colIndex["% aligned reads"])
            let coverageBreadth = optionalField(fields, colIndex["coverage"])
            let meanCoverage = optionalField(fields, colIndex["mean coverage"])
            let meanDepth = optionalField(fields, colIndex["mean depth"])
            let confidence = optionalField(fields, colIndex["group"])
            let k2Reads = parseInt(fields, colIndex["k2 reads"])
            let parentK2Reads = parseInt(fields, colIndex["parent k2 reads"])
            let giniCoefficient = parseDouble(fields, colIndex["gini coefficient"])
            let meanBaseQ = parseDouble(fields, colIndex["mean baseq"])
            let meanMapQ = parseDouble(fields, colIndex["mean mapq"])
            let mapqScore = parseDouble(fields, colIndex["mapq score"])
            let disparityScore = parseDouble(fields, colIndex["disparity score"])
            let minhashScore = parseDouble(fields, colIndex["minhash score"])
            let diamondIdentity = parseDouble(fields, colIndex["diamond identity"])
            let k2DisparityScore = parseDouble(fields, colIndex["k2 disparity score"])
            let siblingsScore = parseDouble(fields, colIndex["siblings score"])
            let breadthWeightScore = parseDouble(fields, colIndex["breadth weight score"])
            let hhsPercentile = parseDouble(fields, colIndex["hhs percentile"])
            let isAnnotated = parseBoolYesNo(fields, colIndex["isannotated"])
            let annClass = optionalField(fields, colIndex["annclass"])
            let microbialCategory = optionalField(fields, colIndex["microbial category"])
            let highConsequence = parseBoolTrueFalse(fields, colIndex["high consequence"])
            let isSpecies = parseBoolTrueFalse(fields, colIndex["isspecies"])
            let pathogenicSubstrains = optionalField(fields, colIndex["pathogenic subsp/strains"])
            let sampleType = optionalField(fields, colIndex["sample type"])

            // Resolve BAM path
            let (bamPath, bamIndexPath) = resolveTaxTriageBAMPaths(sample: sample, resultURL: resultURL)

            // Resolve primary accession from gcfmap
            var primaryAccession: String?
            if gcfmapCache[sample] == nil {
                gcfmapCache[sample] = loadGCFMap(
                    at: gcfmapDir.appendingPathComponent("\(sample).combined.gcfmap.tsv")
                )
            }
            if let entries = gcfmapCache[sample] {
                primaryAccession = findAccession(for: organism, in: entries)
            }

            rows.append(TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: taxId,
                status: status,
                tassScore: tassScore,
                readsAligned: readsAligned,
                uniqueReads: nil, // Deferred: computed in a separate pass via samtools dedup (Task 4)
                pctReads: Double(pctReads ?? ""),
                pctAlignedReads: Double(pctAlignedReads ?? ""),
                coverageBreadth: Double(coverageBreadth ?? ""),
                meanCoverage: Double(meanCoverage ?? ""),
                meanDepth: Double(meanDepth ?? ""),
                confidence: confidence,
                k2Reads: k2Reads,
                parentK2Reads: parentK2Reads,
                giniCoefficient: giniCoefficient,
                meanBaseQ: meanBaseQ,
                meanMapQ: meanMapQ,
                mapqScore: mapqScore,
                disparityScore: disparityScore,
                minhashScore: minhashScore,
                diamondIdentity: diamondIdentity,
                k2DisparityScore: k2DisparityScore,
                siblingsScore: siblingsScore,
                breadthWeightScore: breadthWeightScore,
                hhsPercentile: hhsPercentile,
                isAnnotated: isAnnotated,
                annClass: annClass,
                microbialCategory: microbialCategory,
                highConsequence: highConsequence,
                isSpecies: isSpecies,
                pathogenicSubstrains: pathogenicSubstrains,
                sampleType: sampleType,
                bamPath: bamPath,
                bamIndexPath: bamIndexPath,
                primaryAccession: primaryAccession,
                accessionLength: nil
            ))
        }

        // Build accession map entries from gcfmap cache (raw organism names)
        var accessionEntries: [TaxTriageAccessionEntry] = []
        for (sampleId, gcfEntries) in gcfmapCache {
            for entry in gcfEntries {
                accessionEntries.append(TaxTriageAccessionEntry(
                    sample: sampleId,
                    organism: entry.organism,
                    accession: entry.accession,
                    description: nil
                ))
            }
        }

        return (rows: rows, accessionMap: accessionEntries)
    }

    /// Parses one or more TaxTriage `top/*.top_report.tsv` files into reduced taxonomy rows.
    ///
    /// This is a compatibility fallback for newer pipeline revisions that no longer emit
    /// `multiqc_confidences.txt`. The imported rows intentionally preserve only the fields
    /// that are present in the top-report schema.
    func parseTopReportTSVs(
        at urls: [URL],
        resultURL: URL
    ) throws -> (rows: [TaxTriageTaxonomyRow], accessionMap: [TaxTriageAccessionEntry]) {
        let sortedURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let gcfmapDir = resultURL.appendingPathComponent("combine")
        var gcfmapCache: [String: [(accession: String, organism: String)]] = [:]
        var rows: [TaxTriageTaxonomyRow] = []

        for url in sortedURLs {
            let sample = topReportSampleID(from: url)
            guard !sample.isEmpty else { continue }

            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }

            let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0) }
            let colIndex = buildColumnIndex(from: header)
            let nameIndex = colIndex["name"] ?? colIndex["detected organism"]
            let taxIDIndex = colIndex["taxid"] ?? colIndex["taxonomic id #"]
            let readsAlignedIndex = colIndex["clade_fragments_covered"] ?? colIndex["# reads aligned"]
            let abundanceIndex = colIndex["abundance"] ?? colIndex["% reads"]
            let k2ReadsIndex = colIndex["number_fragments_assigned"] ?? colIndex["k2 reads"]
            let rankIndex = colIndex["rank"]

            if gcfmapCache[sample] == nil {
                gcfmapCache[sample] = loadGCFMap(
                    at: gcfmapDir.appendingPathComponent("\(sample).combined.gcfmap.tsv")
                )
            }

            let (bamPath, bamIndexPath) = resolveTaxTriageBAMPaths(sample: sample, resultURL: resultURL)

            for line in lines.dropFirst() {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map { String($0) }
                let rawOrganism = field(fields, nameIndex)
                let organism = cleanOrganismName(rawOrganism)
                guard !organism.isEmpty else { continue }

                let taxID = parseInt(fields, taxIDIndex)
                let readsAligned = parseInt(fields, readsAlignedIndex) ?? 0
                let pctReads = parseNumericValue(optionalField(fields, abundanceIndex))
                let k2Reads = parseInt(fields, k2ReadsIndex)
                let rank = optionalField(fields, rankIndex)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                let primaryAccession = gcfmapCache[sample].flatMap { findAccession(for: organism, in: $0) }

                rows.append(TaxTriageTaxonomyRow(
                    sample: sample,
                    organism: organism,
                    taxId: taxID,
                    status: nil,
                    tassScore: 0.0,
                    readsAligned: readsAligned,
                    uniqueReads: nil,
                    pctReads: pctReads,
                    pctAlignedReads: nil,
                    coverageBreadth: nil,
                    meanCoverage: nil,
                    meanDepth: nil,
                    confidence: nil,
                    k2Reads: k2Reads,
                    parentK2Reads: nil,
                    giniCoefficient: nil,
                    meanBaseQ: nil,
                    meanMapQ: nil,
                    mapqScore: nil,
                    disparityScore: nil,
                    minhashScore: nil,
                    diamondIdentity: nil,
                    k2DisparityScore: nil,
                    siblingsScore: nil,
                    breadthWeightScore: nil,
                    hhsPercentile: nil,
                    isAnnotated: nil,
                    annClass: nil,
                    microbialCategory: nil,
                    highConsequence: nil,
                    isSpecies: rank == "S",
                    pathogenicSubstrains: nil,
                    sampleType: nil,
                    bamPath: bamPath,
                    bamIndexPath: bamIndexPath,
                    primaryAccession: primaryAccession,
                    accessionLength: nil
                ))
            }
        }

        var accessionEntries: [TaxTriageAccessionEntry] = []
        for (sampleID, gcfEntries) in gcfmapCache {
            for entry in gcfEntries {
                accessionEntries.append(TaxTriageAccessionEntry(
                    sample: sampleID,
                    organism: entry.organism,
                    accession: entry.accession,
                    description: nil
                ))
            }
        }

        return (rows: rows, accessionMap: accessionEntries)
    }

    // MARK: - Column Index Builder

    /// Builds a case-insensitive column name -> index mapping from the TSV header.
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

    private func parseDouble(_ fields: [String], _ index: Int?) -> Double? {
        guard let i = index, i < fields.count else { return nil }
        return Double(fields[i])
    }

    private func parseInt(_ fields: [String], _ index: Int?) -> Int? {
        guard let i = index, i < fields.count else { return nil }
        // Handle values like "3.0" by parsing as Double first
        if let intVal = Int(fields[i]) {
            return intVal
        }
        if let dblVal = Double(fields[i]) {
            return Int(dblVal)
        }
        return nil
    }

    private func parseBoolYesNo(_ fields: [String], _ index: Int?) -> Bool? {
        guard let s = optionalField(fields, index) else { return nil }
        switch s.lowercased() {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    private func parseBoolTrueFalse(_ fields: [String], _ index: Int?) -> Bool? {
        guard let s = optionalField(fields, index) else { return nil }
        switch s.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func parseNumericValue(_ value: String?) -> Double? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    // MARK: - Organism Name Cleanup

    /// Strips leading star marker and trailing degree symbol from organism names.
    ///
    /// TaxTriage uses `\u{2605}` (black star) prefix for high-priority organisms and
    /// `\u{00B0}` (degree sign) suffix as a separator in multi-strain entries.
    private func cleanOrganismName(_ raw: String) -> String {
        var name = raw
        // Strip leading star and whitespace
        while name.hasPrefix("\u{2605}") || name.hasPrefix(" ") {
            name = String(name.dropFirst())
        }
        // Strip trailing degree symbol
        while name.hasSuffix("\u{00B0}") {
            name = String(name.dropLast())
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - GCFMap Loading

    /// Loads a gcfmap TSV file returning (accession, organism) pairs.
    ///
    /// Format: 4-column TSV with no header.
    /// Column 0 = accession (e.g. NC_045512.2), Column 2 = organism name.
    private func loadGCFMap(at url: URL) -> [(accession: String, organism: String)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var entries: [(accession: String, organism: String)] = []
        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { String($0) }
            guard cols.count >= 3 else { continue }
            entries.append((accession: cols[0], organism: cols[2]))
        }
        return entries
    }

    /// Finds the best matching accession for a given organism in gcfmap entries.
    ///
    /// Tries exact match first, then falls back to prefix matching for organism
    /// names that may differ slightly between the confidence report and gcfmap.
    private func findAccession(
        for organism: String,
        in entries: [(accession: String, organism: String)]
    ) -> String? {
        // Exact match
        if let match = entries.first(where: { $0.organism == organism }) {
            return match.accession
        }
        // Prefix match (organism names in gcfmap may be truncated or different)
        let lowered = organism.lowercased()
        if let match = entries.first(where: { lowered.hasPrefix($0.organism.lowercased()) }) {
            return match.accession
        }
        if let match = entries.first(where: { $0.organism.lowercased().hasPrefix(lowered) }) {
            return match.accession
        }
        return nil
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

    private func topReportSampleID(from url: URL) -> String {
        let filename = url.lastPathComponent
        let suffix = ".top_report.tsv"
        guard filename.hasSuffix(suffix) else {
            return url.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        return String(filename.dropLast(suffix.count))
    }

    private func resolveTaxTriageBAMPaths(
        sample: String,
        resultURL: URL
    ) -> (bamPath: String?, bamIndexPath: String?) {
        let bamRelative = "minimap2/\(sample).\(sample).dwnld.references.bam"
        let bamURL = resultURL.appendingPathComponent(bamRelative)
        guard FileManager.default.fileExists(atPath: bamURL.path) else {
            return (nil, nil)
        }

        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
        if FileManager.default.fileExists(atPath: baiURL.path) {
            return (bamRelative, bamRelative + ".bai")
        }
        if FileManager.default.fileExists(atPath: csiURL.path) {
            return (bamRelative, bamRelative + ".csi")
        }
        return (bamRelative, nil)
    }
}

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
            let dbURL = resultURL.appendingPathComponent("esviritu.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                if !globalOptions.quiet {
                    print("Database already exists at \(dbURL.path). Use --force to rebuild.")
                }
                return
            }

            // 1. Enumerate sample subdirectories containing detection TSVs
            let rows = try parseSampleDirectories(resultURL: resultURL)

            if !globalOptions.quiet {
                print("Parsed \(rows.count) detection rows from EsViritu results")
            }

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

            if !globalOptions.quiet {
                print("Parsed \(allWindows.count) coverage windows from EsViritu results")
            }

            // 3. Build database
            let metadata: [String: String] = [
                "tool": "esviritu",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "source_dir": resultURL.path,
            ]

            _ = try EsVirituDatabase.create(at: dbURL, rows: rows, coverageWindows: allWindows, metadata: metadata) { fraction, msg in
                if self.globalOptions.outputFormat == .json {
                    let obj: [String: Any] = ["progress": fraction, "message": msg]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let json = String(data: data, encoding: .utf8) {
                        FileHandle.standardError.write(Data((json + "\n").utf8))
                    }
                }
            }

            if !globalOptions.quiet {
                print("Built database at \(dbURL.path) with \(rows.count) rows")
            }

            // 4. Relocate BAMs from <sample>/<sample>_temp/ to <sample>/bams/ so the
            // resolver in updateUniqueReadsInDB and post-cleanup VC can both find them.
            relocateEsVirituBAMs(resultURL: resultURL)

            // 5. Compute unique reads from BAMs and update DB
            try updateUniqueReadsInDB(
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
                quiet: globalOptions.quiet
            )

            if !noCleanup {
                performCleanup(resultURL: resultURL)
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
                    uniqueReads: nil, // Deferred: computed in a separate pass
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
        private func performCleanup(resultURL: URL) {
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

            if !globalOptions.quiet {
                print("Cleanup complete. Freed \(formatBytes(freedBytes))")
            }
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

        private func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
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

// MARK: - Kraken2 Subcommand

extension BuildDbCommand {

    /// Build a SQLite database from Kraken2 pipeline output.
    ///
    /// Enumerates sample subdirectories, parses each `classification.kreport`
    /// via `KreportParser`, flattens the taxonomy tree into classification rows,
    /// and writes a `kraken2.sqlite` database in the result directory.
    ///
    /// Optionally removes `classification.kraken` and
    /// `classification.kraken.idx.sqlite` intermediate files after a successful
    /// build.
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

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let resultURL = URL(fileURLWithPath: resultDir)
            let dbURL = resultURL.appendingPathComponent("kraken2.sqlite")

            // Skip if exists (unless --force)
            if !force && FileManager.default.fileExists(atPath: dbURL.path) {
                if !globalOptions.quiet {
                    print("Database already exists at \(dbURL.path). Use --force to rebuild.")
                }
                return
            }

            // 1. Enumerate sample subdirectories and parse kreport files
            let (rows, sampleMetadata) = try parseSampleDirectories(resultURL: resultURL)

            if !globalOptions.quiet {
                print("Parsed \(rows.count) classification rows from Kraken2 results")
            }

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

            try Kraken2Database.create(at: dbURL, rows: rows, metadata: metadata) { fraction, msg in
                if self.globalOptions.outputFormat == .json {
                    let obj: [String: Any] = ["progress": fraction, "message": msg]
                    if let data = try? JSONSerialization.data(withJSONObject: obj),
                       let json = String(data: data, encoding: .utf8) {
                        FileHandle.standardError.write(Data((json + "\n").utf8))
                    }
                }
            }

            if !globalOptions.quiet {
                print("Built database at \(dbURL.path) with \(rows.count) rows")
            }

            if !noCleanup {
                performCleanup(resultURL: resultURL)
            }
        }

        // MARK: - Sample Directory Enumeration & Parsing

        /// Enumerates sample subdirectories under `resultURL` and parses kreport files.
        ///
        /// Returns classification rows and per-sample metadata for tree reconstruction.
        func parseSampleDirectories(
            resultURL: URL
        ) throws -> (rows: [Kraken2ClassificationRow], sampleMetadata: [String: String]) {
            let fm = FileManager.default
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
                let (rows, tree) = try parseKreport(at: kreportURL, sampleId: sampleId)
                allRows.append(contentsOf: rows)

                // Store per-sample tree statistics
                sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
                sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
                sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"
            }

            if foundSubdirKreports {
                return (allRows, sampleMetadata)
            }

            // Fallback: single-sample root layout — look for any *.kreport at resultURL
            let rootKreports = contents
                .filter { $0.pathExtension == "kreport" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let kreportURL = rootKreports.first else {
                return ([], [:])
            }

            // Derive sample ID from kreport filename (drop .kreport extension)
            let sampleId = kreportURL.deletingPathExtension().lastPathComponent
            let (rows, tree) = try parseKreport(at: kreportURL, sampleId: sampleId)
            allRows.append(contentsOf: rows)
            sampleMetadata["total_reads_\(sampleId)"] = "\(tree.totalReads)"
            sampleMetadata["classified_reads_\(sampleId)"] = "\(tree.classifiedReads)"
            sampleMetadata["unclassified_reads_\(sampleId)"] = "\(tree.unclassifiedReads)"

            return (allRows, sampleMetadata)
        }

        /// Parses a single kreport file into classification rows.
        ///
        /// Flattens the taxonomy tree produced by `KreportParser`, excluding
        /// only the unclassified pseudo-node. The root node (taxId 1) is included
        /// so that ``Kraken2Database/fetchTree(sample:)`` can reconstruct the tree.
        func parseKreport(
            at kreportURL: URL,
            sampleId: String
        ) throws -> ([Kraken2ClassificationRow], TaxonTree) {
            let tree = try KreportParser.parse(url: kreportURL)

            let rows = tree.allNodes().compactMap { node -> Kraken2ClassificationRow? in
                // Exclude unclassified nodes only; keep root for tree reconstruction
                guard node.rank != .unclassified else { return nil }
                return Kraken2ClassificationRow(
                    sample: sampleId,
                    taxonName: node.name,
                    taxId: node.taxId,
                    rank: node.rank.code,
                    rankDisplayName: node.rank.displayName,
                    readsDirect: node.readsDirect,
                    readsClade: node.readsClade,
                    percentage: node.fractionClade * 100.0,
                    parentTaxId: node.parent?.taxId,
                    depth: node.depth,
                    fractionDirect: node.fractionDirect
                )
            }
            return (rows, tree)
        }

        // MARK: - Post-Build Cleanup

        /// Removes Kraken2 intermediate files while preserving kreport, database,
        /// and the per-read classification output.
        ///
        /// Removes per-sample: `classification.kraken.idx.sqlite`.
        /// Keeps: `classification.kraken` (needed by TaxonomyExtractionPipeline),
        ///        `classification.kreport`, `classification-result.json`, `kraken2.sqlite`.
        private func performCleanup(resultURL: URL) {
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

                // Keep classification.kraken — the per-read output is needed by
                // TaxonomyExtractionPipeline.extract for read extraction. Previously
                // this was deleted to save disk space, but that broke the unified
                // classifier extraction feature (the resolver wraps the pipeline,
                // which reads this file to build the read-ID-to-taxon mapping).

                // Remove Kraken2 index SQLite file (intermediate build artifact)
                let krakenIndex = dir.appendingPathComponent("classification.kraken.idx.sqlite")
                if let size = fileSize(krakenIndex) {
                    try? fm.removeItem(at: krakenIndex)
                    freedBytes += size
                }
            }

            if !globalOptions.quiet {
                print("Cleanup complete. Freed \(formatBytes(freedBytes))")
            }
        }

        private func fileSize(_ url: URL) -> Int64? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }

        private func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }
}
