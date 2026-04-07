// BuildDbCommand.swift - CLI command to build SQLite databases from classifier results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

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
        ]
    )
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

            // 1. Locate confidence TSV
            let confidenceURL = resultURL
                .appendingPathComponent("report")
                .appendingPathComponent("multiqc_data")
                .appendingPathComponent("multiqc_confidences.txt")
            guard FileManager.default.fileExists(atPath: confidenceURL.path) else {
                throw ValidationError("Confidence file not found: \(confidenceURL.path)")
            }

            // 2. Parse confidence TSV and resolve BAM/accession data
            let rows = try parseConfidenceTSV(at: confidenceURL, resultURL: resultURL)

            if !globalOptions.quiet {
                print("Parsed \(rows.count) taxonomy rows from confidence report")
            }

            // 3. Build database
            let metadata: [String: String] = [
                "tool": "taxtriage",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "source_dir": resultURL.path,
            ]

            try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: metadata) { fraction, msg in
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

    /// Parses the TaxTriage multiqc_confidences.txt TSV into taxonomy rows.
    ///
    /// Also resolves BAM paths and primary accession from gcfmap files.
    func parseConfidenceTSV(
        at url: URL,
        resultURL: URL
    ) throws -> [TaxTriageTaxonomyRow] {
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
            let bamRelative = "minimap2/\(sample).\(sample).dwnld.references.bam"
            let bamURL = resultURL.appendingPathComponent(bamRelative)
            var bamPath: String?
            var bamIndexPath: String?
            if FileManager.default.fileExists(atPath: bamURL.path) {
                bamPath = bamRelative
                // Check for .bai or .csi index
                let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
                let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
                if FileManager.default.fileExists(atPath: baiURL.path) {
                    bamIndexPath = bamRelative + ".bai"
                } else if FileManager.default.fileExists(atPath: csiURL.path) {
                    bamIndexPath = bamRelative + ".csi"
                }
            }

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

        return rows
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
}
