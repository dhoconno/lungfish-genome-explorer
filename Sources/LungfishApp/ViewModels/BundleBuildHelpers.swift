// BundleBuildHelpers.swift - Shared utilities for bundle building ViewModels
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// Shared helpers used by both ``GenomeDownloadViewModel`` and ``GenBankBundleDownloadViewModel``
/// during `.lungfishref` bundle creation.
enum BundleBuildHelpers {

    static func sanitizedFilename(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    static func makeUniqueBundleURL(baseName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).lungfishref", isDirectory: true)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(counter).lungfishref", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    static func parseFai(at url: URL) throws -> [ChromosomeInfo] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(whereSeparator: \.isNewline)

        var chromosomes: [ChromosomeInfo] = []
        for line in lines {
            let fields = line.split(separator: "\t")
            guard fields.count >= 5,
                  let length = Int64(fields[1]),
                  let offset = Int64(fields[2]),
                  let lineBases = Int(fields[3]),
                  let lineWidth = Int(fields[4]) else {
                continue
            }

            let name = String(fields[0])
            let isMito = name.lowercased() == "mt" || name.lowercased() == "chrm" || name.uppercased().contains("MITO")
            chromosomes.append(
                ChromosomeInfo(
                    name: name,
                    length: length,
                    offset: offset,
                    lineBases: lineBases,
                    lineWidth: lineWidth,
                    aliases: [],
                    isPrimary: true,
                    isMitochondrial: isMito,
                    fastaDescription: nil
                )
            )
        }

        if chromosomes.isEmpty {
            throw BundleBuildError.indexingFailed("FASTA index is empty or unreadable")
        }

        return chromosomes
    }

    static func writeChromSizes(_ chromosomes: [ChromosomeInfo], to url: URL) throws {
        let lines = chromosomes.map { "\($0.name)\t\($0.length)" }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Clips BED coordinates to chromosome boundaries.
    static func clipBEDCoordinates(bedURL: URL, chromosomeSizes: [(String, Int64)]) {
        let chromSizeMap = Dictionary(uniqueKeysWithValues: chromosomeSizes)
        guard let content = try? String(contentsOf: bedURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)

        var clipped: [String] = []
        for line in lines {
            if line.isEmpty || line.hasPrefix("#") {
                clipped.append(line)
                continue
            }
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else {
                clipped.append(line)
                continue
            }
            let chrom = fields[0]
            guard let chromSize = chromSizeMap[chrom] else {
                clipped.append(line)
                continue
            }
            if let start = Int64(fields[1]), start >= chromSize { continue }
            if let end = Int64(fields[2]), end > chromSize {
                fields[2] = "\(chromSize)"
            }
            // Also clip thickEnd (BED12 column 7) to chromosome boundary
            if fields.count >= 7 {
                if let thickEnd = Int64(fields[6]), thickEnd > chromSize {
                    fields[6] = "\(chromSize)"
                }
            }
            clipped.append(fields.joined(separator: "\t"))
        }

        try? clipped.joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
    }

    /// Strips columns beyond `keepColumns`.
    static func stripExtraBEDColumns(bedURL: URL, keepColumns: Int) {
        guard let content = try? String(contentsOf: bedURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)

        var stripped: [String] = []
        for line in lines {
            if line.isEmpty || line.hasPrefix("#") {
                stripped.append(line)
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count > keepColumns {
                stripped.append(fields.prefix(keepColumns).joined(separator: "\t"))
            } else {
                stripped.append(line)
            }
        }

        try? stripped.joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
    }

    /// Validates that required tools (bgzip, samtools) are available.
    ///
    /// - Throws: `BundleBuildError.missingTools` if essential tools are missing.
    static func validateTools(using toolRunner: NativeToolRunner) async throws {
        let (valid, missing) = await toolRunner.validateToolsInstallation()
        if !valid {
            let essential = missing.filter { $0 == .bgzip || $0 == .samtools }
            if !essential.isEmpty {
                throw BundleBuildError.missingTools(essential.map(\.rawValue))
            }
        }
    }

    /// Formats a byte count as a human-readable string.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Assembly Report Parsing

    /// A single row from an NCBI assembly report file.
    ///
    /// The assembly report maps between all chromosome naming conventions:
    /// RefSeq accession, GenBank accession, UCSC name, and assigned molecule number.
    struct AssemblyReportEntry {
        /// Sequence name from the assembly (col 0, e.g., "chr1", "random_chr1_000743F_qpd_obj")
        let sequenceName: String
        /// Role of this sequence (col 1, e.g., "assembled-molecule", "unlocalized-scaffold", "unplaced-scaffold")
        let sequenceRole: String
        /// Assigned molecule name (col 2, e.g., "1", "X", "MT", "na")
        let assignedMolecule: String
        /// Molecule location type (col 3, e.g., "Chromosome", "Mitochondrion", "na")
        let moleculeType: String
        /// GenBank accession (col 4, e.g., "CM018917.1")
        let genBankAccession: String
        /// RefSeq accession (col 6, e.g., "NC_048383.1")
        let refSeqAccession: String
        /// Sequence length in base pairs (col 8)
        let sequenceLength: Int64?
        /// UCSC-style name (col 9, nil if "na")
        let ucscName: String?
    }

    /// Parses an NCBI assembly report text file.
    ///
    /// The report is tab-delimited with 10 columns, preceded by `#` header lines.
    /// Columns: Sequence-Name, Sequence-Role, Assigned-Molecule, Assigned-Molecule-loc/type,
    /// GenBank-Accn, Relationship, RefSeq-Accn, Assembly-Unit, Sequence-Length, UCSC-style-name
    ///
    /// - Parameter url: Path to the assembly report file.
    /// - Returns: Array of parsed entries.
    static func parseAssemblyReport(at url: URL) throws -> [AssemblyReportEntry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var entries: [AssemblyReportEntry] = []
        for line in lines {
            // Skip comment/header lines and empty lines
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Need at least 9 columns (UCSC name in col 9 is optional in some reports)
            guard fields.count >= 9 else { continue }

            let ucsc: String? = fields.count > 9 && fields[9] != "na" ? fields[9] : nil
            let seqLength = Int64(fields[8])

            entries.append(AssemblyReportEntry(
                sequenceName: fields[0],
                sequenceRole: fields[1],
                assignedMolecule: fields[2],
                moleculeType: fields[3],
                genBankAccession: fields[4],
                refSeqAccession: fields[6],
                sequenceLength: seqLength,
                ucscName: ucsc
            ))
        }

        return entries
    }

    /// Parses metadata from the `#` header lines of an assembly report.
    ///
    /// Extracts key-value pairs like "Assembly method", "Genome coverage", "Sequencing technology"
    /// for display in the Inspector panel.
    ///
    /// - Parameter url: Path to the assembly report file.
    /// - Returns: Array of metadata items, or empty if parsing fails.
    static func parseAssemblyReportHeader(at url: URL) throws -> [MetadataItem] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var items: [MetadataItem] = []
        for line in lines {
            guard line.hasPrefix("# ") else {
                // Stop at first non-comment line (data starts)
                if !line.isEmpty && !line.hasPrefix("#") { break }
                continue
            }

            // Format: "# Key:  Value" or "# Key: Value"
            let stripped = String(line.dropFirst(2)) // Remove "# "
            guard let colonIndex = stripped.firstIndex(of: ":") else { continue }
            let label = stripped[stripped.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = stripped[stripped.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

            guard !label.isEmpty, !value.isEmpty else { continue }

            // Skip redundant header lines (e.g., section markers)
            let skipLabels: Set<String> = ["Assembly-Units"]
            if skipLabels.contains(label) { continue }

            items.append(MetadataItem(label: label, value: value))
        }

        return items
    }

    /// Enriches chromosome info from `.fai` parsing with aliases from the assembly report.
    ///
    /// For each chromosome, finds the matching assembly report entry (by RefSeq accession,
    /// GenBank accession, or sequence name) and populates `aliases`, `fastaDescription`,
    /// `isPrimary`, and `isMitochondrial` fields.
    ///
    /// - Parameters:
    ///   - chromosomes: Chromosomes from `parseFai()`.
    ///   - report: Parsed assembly report entries.
    /// - Returns: Enriched chromosome info array with populated aliases.
    static func augmentChromosomesWithAssemblyReport(
        _ chromosomes: [ChromosomeInfo],
        report: [AssemblyReportEntry]
    ) -> [ChromosomeInfo] {
        // Build lookup maps by the various name columns
        var byRefSeq: [String: AssemblyReportEntry] = [:]
        var byGenBank: [String: AssemblyReportEntry] = [:]
        var bySeqName: [String: AssemblyReportEntry] = [:]

        for entry in report {
            if entry.refSeqAccession != "na" {
                byRefSeq[entry.refSeqAccession] = entry
            }
            if entry.genBankAccession != "na" {
                byGenBank[entry.genBankAccession] = entry
            }
            bySeqName[entry.sequenceName] = entry
        }

        return chromosomes.map { chrom in
            // Match by RefSeq accession first (most common for NCBI downloads),
            // then GenBank accession, then sequence name
            let entry = byRefSeq[chrom.name]
                ?? byGenBank[chrom.name]
                ?? bySeqName[chrom.name]

            guard let entry else { return chrom }

            // Collect all alternative names, excluding the chromosome's own name
            var aliasSet = Set<String>()

            let isAssembledMolecule = entry.sequenceRole == "assembled-molecule"

            // Assigned molecule number (e.g., "1", "X", "MT") — only for assembled molecules.
            // Unlocalized/unplaced scaffolds report the chromosome they're assigned to,
            // which is NOT an alias for the scaffold itself.
            if isAssembledMolecule && entry.assignedMolecule != "na" {
                aliasSet.insert(entry.assignedMolecule)
                // UCSC convention: "chr" + molecule
                aliasSet.insert("chr\(entry.assignedMolecule)")
            }

            // Sequence name from the assembly (e.g., "chr1")
            aliasSet.insert(entry.sequenceName)

            // GenBank accession (e.g., "CM018917.1")
            if entry.genBankAccession != "na" {
                aliasSet.insert(entry.genBankAccession)
            }

            // RefSeq accession (e.g., "NC_048383.1")
            if entry.refSeqAccession != "na" {
                aliasSet.insert(entry.refSeqAccession)
            }

            // UCSC name if present
            if let ucsc = entry.ucscName {
                aliasSet.insert(ucsc)
            }

            // Remove the chromosome's own name — it's not an "alias"
            aliasSet.remove(chrom.name)
            // Also merge with any pre-existing aliases
            let finalAliases = Array(aliasSet.union(chrom.aliases)).sorted()

            // Build a useful fastaDescription
            let description: String?
            if entry.assignedMolecule != "na" && entry.moleculeType != "na" {
                description = "\(entry.moleculeType) \(entry.assignedMolecule)"
            } else {
                description = chrom.fastaDescription
            }

            let isPrimary = entry.sequenceRole == "assembled-molecule"
            let isMito = entry.moleculeType.lowercased() == "mitochondrion"
                || entry.assignedMolecule.uppercased() == "MT"

            return ChromosomeInfo(
                name: chrom.name,
                length: chrom.length,
                offset: chrom.offset,
                lineBases: chrom.lineBases,
                lineWidth: chrom.lineWidth,
                aliases: finalAliases,
                isPrimary: isPrimary,
                isMitochondrial: isMito,
                fastaDescription: description
            )
        }
    }
}

extension BundleBuildHelpers {

    /// Resolves a managed tool executable path using the Lungfish conda layout.
    ///
    /// This intentionally avoids PATH and bundled-location fallbacks so the app
    /// matches the managed-tool resolution introduced for workflow execution.
    static func managedToolExecutablePath(
        _ tool: NativeTool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard case .managed(let environment, let executableName) = tool.location else {
            return nil
        }

        let executableURL = CoreToolLocator.managedExecutableURL(
            environment: environment,
            executableName: executableName,
            homeDirectory: homeDirectory
        )
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return executableURL.path
    }
}
