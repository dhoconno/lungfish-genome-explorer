// BuildDbCommand.swift - CLI command to build SQLite databases from classifier results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
///   - events: Where the lines that report the pass go, with its warnings on `textWarning`.
func updateUniqueReadsInDB(
    dbPath: String,
    table: String,
    sampleCol: String,
    accessionCol: String,
    bamPathCol: String,
    totalReadsCol: String,
    resultURL: URL,
    bamPathResolver: (URL, String, String) -> String,
    updateAccessionLength: Bool,
    events: BuildDbEventSink,
    provenance: BuildDbSamtoolsProvenanceCollector
) async throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        events.textWarning("Warning: could not open database for unique reads update")
        return
    }
    defer { sqlite3_close(db) }

    // Query rows that have BAM + accession
    let selectSQL = "SELECT rowid, \(sampleCol), \(accessionCol), \(bamPathCol) FROM \(table) WHERE \(bamPathCol) IS NOT NULL AND \(accessionCol) IS NOT NULL AND \(accessionCol) != ''"
    var selectStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
        events.textWarning("Warning: failed to prepare SELECT for unique reads")
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
        events.text("  No rows with BAM paths found, skipping unique reads")
        return
    }

    guard let samtoolsPath = findSamtools() else {
        throw BuildDbUniqueReadsError.managedSamtoolsUnavailable
    }
    let samtoolsProvenance = BuildDbSamtoolsProvenanceTracker(
        samtoolsPath: samtoolsPath,
        collector: provenance
    )

    // Step 1: Run markdup on each unique BAM file in path order, so the recorded steps repeat
    let uniqueBAMPaths = Set(rowsToProcess.map { bamPathResolver(resultURL, $0.sample, $0.bamRelPath) }).sorted()
    events.text("Running markdup on \(uniqueBAMPaths.count) BAM file(s)...")
    var marked = 0
    var unmarked: Set<String> = []
    for bamFullPath in uniqueBAMPaths {
        let bamURL = URL(fileURLWithPath: bamFullPath)
        guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
        do {
            let result = try await samtoolsProvenance.markdup(bamURL: bamURL)
            if !result.wasAlreadyMarkduped { marked += 1 }
        } catch let provenanceError as BuildDbSamtoolsProvenanceError {
            throw provenanceError
        } catch let cancelled as CancellationError {
            // A cancel is not a failed markdup. It ends the pass at this BAM, with no warning for it or for the
            // BAMs left (lane S33 M2).
            throw cancelled
        } catch {
            events.textWarning("  Warning: markdup failed on \(bamURL.lastPathComponent): \(error.localizedDescription)")
            unmarked.insert(bamFullPath)
        }
    }
    if marked > 0 { events.text("  Marked duplicates in \(marked) BAM file(s)") }

    // Step 2: Count reads_aligned and unique_reads per (sample, accession)
    events.text("Counting reads per organism...")

    // Build accession_length map from samtools idxstats if needed
    var refLengths: [String: Int] = [:]
    if updateAccessionLength {
        for bamFullPath in uniqueBAMPaths {
            guard FileManager.default.fileExists(atPath: bamFullPath) else { continue }
            let bamURL = URL(fileURLWithPath: bamFullPath)
            guard let output = try await samtoolsProvenance.idxstats(bamURL: bamURL) else { continue }
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
            if lenUpdated > 0 { events.text("  Updated accession lengths for \(lenUpdated) organisms") }
        }
    }

    // Update reads_aligned (total mapped) and unique_reads (non-duplicate mapped)
    // from the BAM. reads_aligned is overwritten with the authoritative BAM count
    // (samtools view -c -F 0x4) replacing the pipeline TSV value. A reported
    // accession with mapped reads must have at least one unique read.
    let updateSQL = "UPDATE \(table) SET \(totalReadsCol) = ?, unique_reads = ? WHERE rowid = ?"
    var updateStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
        events.textWarning("Warning: failed to prepare UPDATE for read counts")
        return
    }
    defer { sqlite3_finalize(updateStmt) }

    sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
    var updated = 0
    var uniqueCache: [String: Int] = [:]
    var totalCache: [String: Int] = [:]
    for (i, row) in rowsToProcess.enumerated() {
        let bamFullPath = bamPathResolver(resultURL, row.sample, row.bamRelPath)
        // A row keeps the counts it was parsed with when a count fails, and so does each row of a BAM whose
        // markdup failed, whose 0x404 count would call every mapped read unique (BIO's Q-A3 item 6).
        guard FileManager.default.fileExists(atPath: bamFullPath), !unmarked.contains(bamFullPath) else { continue }

        let cacheKey = "\(bamFullPath)\t\(row.accession)"
        let bamURL = URL(fileURLWithPath: bamFullPath)

        let unique: Int
        if let cached = uniqueCache[cacheKey] {
            unique = cached
        } else {
            do {
                unique = try await samtoolsProvenance.countReads(
                    bamURL: bamURL,
                    accession: row.accession,
                    flagFilter: 0x404  // unmapped + duplicate
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
                total = try await samtoolsProvenance.countReads(
                    bamURL: bamURL,
                    accession: row.accession,
                    flagFilter: 0x4  // unmapped only (includes duplicates)
                )
                totalCache[cacheKey] = total
            } catch {
                continue
            }
        }

        sqlite3_reset(updateStmt)
        let normalizedUnique = total > 0 ? max(unique, 1) : 0

        sqlite3_bind_int64(updateStmt, 1, Int64(total))
        sqlite3_bind_int64(updateStmt, 2, Int64(normalizedUnique))
        sqlite3_bind_int64(updateStmt, 3, row.rowid)
        sqlite3_step(updateStmt)
        updated += 1

        if (i + 1) % 50 == 0 {
            events.text("  Processed \(i + 1)/\(rowsToProcess.count) organisms...")
        }
    }
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
    let uncounted = rowsToProcess.count - updated
    events.text("  Updated read counts for \(updated)/\(rowsToProcess.count) organisms" + (uncounted > 0 ? ", \(uncounted) left uncounted" : ""))
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

// MARK: - TSV Parsing

extension BuildDbCommand.TaxTriageSubcommand {

    /// Parses the TaxTriage multiqc_confidences.txt TSV into taxonomy rows.
    ///
    /// Also resolves BAM paths and primary accession from gcfmap files.
    func parseConfidenceTSV(
        at url: URL,
        resultURL: URL
    ) throws -> (rows: [TaxTriageTaxonomyRow], accessionMap: [TaxTriageAccessionEntry]) {
        try parseOrganismReports(at: [url], resultURL: resultURL)
    }

    /// Parses TaxTriage organism confidence tables into taxonomy rows.
    ///
    /// Accepts the 3.3.x per-sample organism discovery report (`report/<sample>.odr.txt`),
    /// the combined `report/all.odr.txt` (rows keyed by `Specimen ID`), the older
    /// `<sample>.organisms.report.txt`, and the legacy `multiqc_confidences.txt`.
    /// Column mapping and scale normalization live in ``TaxTriageOrganismReport``.
    /// BAM paths and primary accessions are resolved here from `minimap2/` and the
    /// `combine/<sample>.combined.gcfmap.tsv` files.
    func parseOrganismReports(
        at urls: [URL],
        resultURL: URL
    ) throws -> (rows: [TaxTriageTaxonomyRow], accessionMap: [TaxTriageAccessionEntry]) {
        let gcfmapDir = resultURL.appendingPathComponent("combine")
        var gcfmapCache: [String: [(accession: String, organism: String)]] = [:]
        var bamCache: [String: (bamPath: String?, bamIndexPath: String?)] = [:]
        var seenKeys: Set<String> = []
        var rows: [TaxTriageTaxonomyRow] = []

        for url in urls.sorted(by: { $0.path < $1.path }) {
            for parsed in try TaxTriageOrganismReport.parse(url: url) {
                let sample = parsed.sample
                // taxonomy_rows is UNIQUE(sample, organism). Keep the first occurrence.
                guard seenKeys.insert("\(sample)\t\(parsed.organism)").inserted else { continue }

                if gcfmapCache[sample] == nil {
                    gcfmapCache[sample] = loadGCFMap(
                        at: gcfmapDir.appendingPathComponent("\(sample).combined.gcfmap.tsv")
                    )
                }
                if bamCache[sample] == nil {
                    bamCache[sample] = resolveTaxTriageBAMPaths(sample: sample, resultURL: resultURL)
                }
                let bam = bamCache[sample] ?? (nil, nil)
                let primaryAccession = gcfmapCache[sample].flatMap {
                    findAccession(for: parsed.organism, in: $0)
                }

                rows.append(TaxTriageTaxonomyRow(
                    sample: parsed.sample,
                    organism: parsed.organism,
                    taxId: parsed.taxId,
                    status: parsed.status,
                    tassScore: parsed.tassScore,
                    readsAligned: parsed.readsAligned,
                    // Filled by the post-parse unique-read update pass once samtools
                    // dedup counts are available for all rows.
                    uniqueReads: nil,
                    pctReads: parsed.pctReads,
                    pctAlignedReads: parsed.pctAlignedReads,
                    coverageBreadth: parsed.coverageBreadth,
                    meanCoverage: parsed.meanCoverage,
                    meanDepth: parsed.meanDepth,
                    confidence: parsed.confidence,
                    k2Reads: parsed.k2Reads,
                    parentK2Reads: parsed.parentK2Reads,
                    giniCoefficient: parsed.giniCoefficient,
                    meanBaseQ: parsed.meanBaseQ,
                    meanMapQ: parsed.meanMapQ,
                    mapqScore: parsed.mapqScore,
                    disparityScore: parsed.disparityScore,
                    minhashScore: parsed.minhashScore,
                    diamondIdentity: parsed.diamondIdentity,
                    k2DisparityScore: parsed.k2DisparityScore,
                    siblingsScore: parsed.siblingsScore,
                    breadthWeightScore: parsed.breadthWeightScore,
                    hhsPercentile: parsed.hhsPercentile,
                    isAnnotated: parsed.isAnnotated,
                    annClass: parsed.annClass,
                    microbialCategory: parsed.microbialCategory,
                    highConsequence: parsed.highConsequence,
                    isSpecies: parsed.isSpecies,
                    pathogenicSubstrains: parsed.pathogenicSubstrains,
                    sampleType: parsed.sampleType,
                    bamPath: bam.bamPath,
                    bamIndexPath: bam.bamIndexPath,
                    primaryAccession: primaryAccession,
                    accessionLength: nil
                ))
            }
        }

        // Build accession map entries from gcfmap cache (raw organism names)
        var accessionEntries: [TaxTriageAccessionEntry] = []
        for (sampleId, gcfEntries) in gcfmapCache.sorted(by: { $0.key < $1.key }) {
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
        if FileManager.default.fileExists(atPath: bamURL.path) {
            return relativeBAMPaths(for: bamURL, resultURL: resultURL)
        }

        let minimap2URL = resultURL.appendingPathComponent("minimap2", isDirectory: true)
        guard let candidate = bestTaxTriageBAMCandidate(
            sample: sample,
            minimap2URL: minimap2URL
        ) else {
            return (nil, nil)
        }
        return relativeBAMPaths(for: candidate, resultURL: resultURL)
    }

    private func bestTaxTriageBAMCandidate(
        sample: String,
        minimap2URL: URL
    ) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: minimap2URL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "bam",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.compactMap { candidate -> (url: URL, score: Int)? in
            guard let score = taxTriageBAMCandidateScore(
                filename: candidate.lastPathComponent,
                sample: sample
            ) else {
                return nil
            }
            return (candidate, score)
        }
        let sorted = scored.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.url.path < $1.url.path
        }
        guard let best = sorted.first else { return nil }
        if sorted.dropFirst().contains(where: { $0.score == best.score }) {
            return nil
        }
        return best.url
    }

    private func taxTriageBAMCandidateScore(filename: String, sample: String) -> Int? {
        let name = filename.lowercased()
        let sample = sample.lowercased()
        guard filenameContainsSampleToken(name, sample: sample) else { return nil }

        if name == "\(sample).bam" { return 10 }
        if name.contains("downsample") || name.contains("minibam") { return 20 }
        if name.contains("dwnld.references") { return 30 }
        if name.contains("references") { return 40 }
        return 50
    }

    private func filenameContainsSampleToken(_ filename: String, sample: String) -> Bool {
        guard !sample.isEmpty else { return false }
        let delimiters = CharacterSet(charactersIn: "._-")
        if filename.hasPrefix(sample) {
            let remainder = filename.dropFirst(sample.count)
            if remainder.isEmpty { return true }
            if let first = remainder.unicodeScalars.first, delimiters.contains(first) {
                return true
            }
        }

        for left in [".", "_", "-"] {
            for right in [".", "_", "-"] {
                if filename.contains("\(left)\(sample)\(right)") {
                    return true
                }
            }
        }
        return false
    }

    private func relativeBAMPaths(
        for bamURL: URL,
        resultURL: URL
    ) -> (bamPath: String?, bamIndexPath: String?) {
        guard let bamRelative = relativePath(for: bamURL, root: resultURL) else {
            return (nil, nil)
        }

        let indexCandidates = [
            URL(fileURLWithPath: bamURL.path + ".bai"),
            URL(fileURLWithPath: bamURL.path + ".csi"),
            bamURL.deletingPathExtension().appendingPathExtension("bai"),
            bamURL.deletingPathExtension().appendingPathExtension("csi"),
        ]

        let indexRelative = indexCandidates
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { relativePath(for: $0, root: resultURL) }

        return (bamRelative, indexRelative)
    }

    private func relativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }
}
