// TaxTriageOrganismReport.swift - Per-sample TaxTriage organism report discovery and parsing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Locates and parses TaxTriage's per-organism confidence tables.
///
/// TaxTriage has written the same tab-separated organism table under several names:
///
/// - `report/<sample>.odr.txt` ("organism discovery report", TaxTriage 3.3.x). TASS is
///   on a 0-100 scale, `% Reads` is a percentage, `Coverage` is a string such as `32%`,
///   breadth is in `Breadth %`, and the run's calling threshold is in `TASS Threshold`
///   and `Passes Threshold`. `Group` is a numeric grouping key, not a label.
/// - `<sample>.organisms.report.txt` (older revisions) and
///   `report/multiqc_data/multiqc_confidences.txt` (legacy MultiQC table). TASS is on a
///   0-1 scale and `Group` carries a confidence label.
///
/// `report/all.odr.txt` is the combined report. It carries a `Specimen ID` per row, so it
/// is only used when no per-sample report exists, and rows are keyed by that column.
///
/// Parsed rows are returned in the ``TaxTriageTaxonomyRow`` shape stored in
/// `taxtriage.sqlite`, with the viewport's conventions applied: `tassScore` is 0-1,
/// `pctReads` is a 0-1 fraction (the viewport shows it multiplied by 100), and
/// `coverageBreadth` is a 0-100 percentage for ODR input. BAM, index, accession and
/// unique-read fields are left empty for the database builder to resolve.
public enum TaxTriageOrganismReport {

    /// The file layout a report came from.
    public enum Format: String, Sendable, Equatable {
        /// TaxTriage 3.3.x organism discovery report (`*.odr.txt`).
        case organismDiscoveryReport = "odr"
        /// Older confidence table (`*.organisms.report.txt` or `multiqc_confidences.txt`).
        case legacyConfidenceTable = "legacy_confidence"
    }

    public static let perSampleODRSuffix = ".odr.txt"
    public static let legacyOrganismReportSuffix = ".organisms.report.txt"
    public static let combinedODRFileName = "all.odr.txt"

    // MARK: - File Classification

    /// True for a per-sample organism report: `<sample>.odr.txt` or
    /// `<sample>.organisms.report.txt`. The combined `all.odr.txt` is excluded.
    public static func isPerSampleReportFile(_ url: URL) -> Bool {
        sampleID(fromReportFile: url) != nil
    }

    /// True for the combined multi-sample `all.odr.txt`.
    public static func isCombinedReportFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == combinedODRFileName
    }

    /// True for any organism report file, per-sample or combined.
    public static func isOrganismReportFile(_ url: URL) -> Bool {
        isPerSampleReportFile(url) || isCombinedReportFile(url)
    }

    /// The sample ID encoded in a per-sample report file name, or nil when the file is
    /// not a per-sample organism report.
    public static func sampleID(fromReportFile url: URL) -> String? {
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        guard lowered != combinedODRFileName else { return nil }
        for suffix in [perSampleODRSuffix, legacyOrganismReportSuffix] where lowered.hasSuffix(suffix) {
            let sample = String(name.dropLast(suffix.count))
            return sample.isEmpty ? nil : sample
        }
        return nil
    }

    /// Organism report files for one TaxTriage result directory (not a serial batch root).
    ///
    /// Looks in `report/` and in the directory itself. Per-sample reports win. The
    /// combined `all.odr.txt` is returned only when no per-sample report exists.
    public static func reportFiles(inResultDirectory resultURL: URL) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []
        for directory in [resultURL.appendingPathComponent("report", isDirectory: true), resultURL] {
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: children.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
        }

        let perSample = candidates.filter(isPerSampleReportFile)
        if !perSample.isEmpty {
            // Prefer the current `.odr.txt` over an older report for the same sample.
            var bySample: [String: URL] = [:]
            for url in perSample.sorted(by: { $0.path < $1.path }) {
                guard let sample = sampleID(fromReportFile: url) else { continue }
                if let existing = bySample[sample],
                   existing.lastPathComponent.lowercased().hasSuffix(perSampleODRSuffix) {
                    continue
                }
                bySample[sample] = url
            }
            return bySample.values.sorted { $0.path < $1.path }
        }
        return candidates.filter(isCombinedReportFile).sorted { $0.path < $1.path }
    }

    /// True when a single result directory, or any direct sample subdirectory of a
    /// serial batch root, holds an organism report.
    public static func containsReportFiles(inResultOrBatchDirectory url: URL) -> Bool {
        if !reportFiles(inResultDirectory: url).isEmpty { return true }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !reportFiles(inResultDirectory: child).isEmpty
        }
    }

    // MARK: - Parsing

    /// Parses an organism report file.
    ///
    /// - Parameters:
    ///   - url: The report file.
    ///   - fallbackSample: Sample ID used when a row has no `Specimen ID`. Defaults to
    ///     the sample encoded in the file name.
    public static func parse(url: URL, fallbackSample: String? = nil) throws -> [TaxTriageTaxonomyRow] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(tsv: content, fallbackSample: fallbackSample ?? sampleID(fromReportFile: url))
    }

    /// Detects the report layout from its header columns.
    public static func format(ofHeader header: [String]) -> Format {
        let columns = Set(header.map(normalizedColumn))
        if columns.contains("tass threshold")
            || columns.contains("passes threshold")
            || columns.contains("breadth %") {
            return .organismDiscoveryReport
        }
        return .legacyConfidenceTable
    }

    /// Parses organism report TSV content.
    public static func parse(tsv: String, fallbackSample: String? = nil) -> [TaxTriageTaxonomyRow] {
        let lines = tsv.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        let header = splitTSV(lines[0])
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() where column[normalizedColumn(name)] == nil {
            column[normalizedColumn(name)] = index
        }
        let format = format(ofHeader: header)
        let records = lines.dropFirst().map(splitTSV)

        func value(_ fields: [String], _ key: String) -> String? {
            guard let index = column[key], index < fields.count else { return nil }
            let raw = fields[index].trimmingCharacters(in: .whitespaces)
            return raw.isEmpty ? nil : raw
        }
        func double(_ fields: [String], _ key: String) -> Double? { parseNumber(value(fields, key)) }
        func int(_ fields: [String], _ key: String) -> Int? {
            guard let raw = value(fields, key)?.replacingOccurrences(of: ",", with: "") else { return nil }
            if let integer = Int(raw) { return integer }
            return Double(raw).map { Int($0.rounded()) }
        }

        // ODR TASS is 0-100. Older tables are 0-1. Decide once per file so a file whose
        // best hit happens to be <= 1 on the 0-100 scale is still scaled.
        let tassDivisor: Double
        switch format {
        case .organismDiscoveryReport:
            let threshold = records.compactMap { double($0, "tass threshold") }.max() ?? 0
            let maxScore = records.compactMap { double($0, "tass score") }.max() ?? 0
            tassDivisor = (threshold > 1 || maxScore > 1 || column["tass threshold"] != nil) ? 100 : 1
        case .legacyConfidenceTable:
            tassDivisor = 1
        }

        var rows: [TaxTriageTaxonomyRow] = []
        rows.reserveCapacity(records.count)

        for fields in records {
            guard let rawOrganism = value(fields, "detected organism") else { continue }
            let organism = OrganismNameNormalizer.clean(rawOrganism)
            guard !organism.isEmpty,
                  let sample = value(fields, "specimen id") ?? fallbackSample else { continue }

            let rawTASS = double(fields, "tass score")
            let tassScore = (rawTASS ?? 0) / tassDivisor

            let pctReads: Double?
            let coverageBreadth: Double?
            let confidence: String?
            switch format {
            case .organismDiscoveryReport:
                pctReads = double(fields, "% reads").map { $0 / 100 }
                coverageBreadth = double(fields, "breadth %") ?? double(fields, "coverage")
                confidence = odrConfidenceLabel(
                    tassScore: rawTASS.map { $0 / tassDivisor },
                    passesThreshold: parseBool(value(fields, "passes threshold")),
                    threshold: double(fields, "tass threshold").map { $0 / tassDivisor }
                )
            case .legacyConfidenceTable:
                pctReads = double(fields, "% reads")
                coverageBreadth = double(fields, "coverage")
                confidence = value(fields, "group")
            }

            rows.append(TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: int(fields, "taxonomic id #"),
                status: value(fields, "status"),
                tassScore: tassScore,
                readsAligned: int(fields, "# reads aligned") ?? int(fields, "reads aligned") ?? 0,
                uniqueReads: nil,
                pctReads: pctReads,
                pctAlignedReads: double(fields, "% aligned reads"),
                coverageBreadth: coverageBreadth,
                meanCoverage: double(fields, "mean coverage"),
                meanDepth: double(fields, "mean depth"),
                confidence: confidence,
                k2Reads: int(fields, "k2 reads"),
                parentK2Reads: int(fields, "parent k2 reads"),
                giniCoefficient: double(fields, "gini coefficient"),
                meanBaseQ: double(fields, "mean baseq"),
                meanMapQ: double(fields, "mean mapq"),
                mapqScore: double(fields, "mapq score"),
                disparityScore: double(fields, "disparity score"),
                minhashScore: double(fields, "minhash score"),
                diamondIdentity: double(fields, "diamond identity"),
                k2DisparityScore: double(fields, "k2 disparity score"),
                siblingsScore: double(fields, "siblings score"),
                breadthWeightScore: double(fields, "breadth weight score"),
                hhsPercentile: double(fields, "hhs percentile"),
                isAnnotated: parseBool(value(fields, "isannotated")),
                annClass: value(fields, "annclass"),
                microbialCategory: value(fields, "microbial category"),
                highConsequence: parseBool(value(fields, "high consequence")),
                isSpecies: parseBool(value(fields, "isspecies")),
                pathogenicSubstrains: value(fields, "pathogenic subsp/strains"),
                sampleType: value(fields, "sample type"),
                bamPath: nil,
                bamIndexPath: nil,
                primaryAccession: nil,
                accessionLength: nil
            ))
        }
        return rows
    }

    /// Confidence label for an ODR row, in the viewport's High/Medium/Low vocabulary.
    ///
    /// TaxTriage's own call wins: a row that passes the run's TASS threshold is "High".
    /// Below the threshold the viewport's score bands apply (Medium from 0.4, else Low).
    /// Without threshold columns the viewport's bands apply throughout (High from 0.8).
    public static func odrConfidenceLabel(
        tassScore: Double?,
        passesThreshold: Bool?,
        threshold: Double?
    ) -> String? {
        guard let tassScore else { return nil }
        let passes = passesThreshold ?? threshold.map { tassScore >= $0 }
        if let passes {
            if passes { return "High" }
            return tassScore >= 0.4 ? "Medium" : "Low"
        }
        if tassScore >= 0.8 { return "High" }
        return tassScore >= 0.4 ? "Medium" : "Low"
    }

    // MARK: - Helpers

    private static func splitTSV(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
    }

    private static func normalizedColumn(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parseNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }
}
