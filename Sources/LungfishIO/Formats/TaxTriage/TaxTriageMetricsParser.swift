// TaxTriageMetricsParser.swift - Parser for TaxTriage TASS confidence metrics
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxTriageMetricsParser

/// Parses TaxTriage TASS (Taxonomic Assignment Scoring System) confidence metrics.
///
/// TaxTriage outputs tab-separated value (TSV) files containing detailed per-taxon
/// confidence metrics. These metrics include the TASS score, read counts,
/// coverage breadth, and other QC indicators used for confidence assessment.
///
/// ## TSV Format
///
/// The first row is a header. Subsequent rows contain one record per taxon:
///
/// ```tsv
/// sample\ttaxid\torganism\trank\treads\tabundance\tcoverage_breadth\tcoverage_depth\ttass_score\tconfidence
/// MySample\t562\tEscherichia coli\tS\t12345\t0.45\t85.3\t12.7\t0.95\thigh
/// ```
///
/// ## Example
///
/// ```swift
/// let metrics = try TaxTriageMetricsParser.parse(url: metricsURL)
/// for metric in metrics {
///     print("\(metric.organism): TASS=\(metric.tassScore), reads=\(metric.reads)")
/// }
/// ```
public enum TaxTriageMetricsParser {

    // MARK: - Known Column Names

    /// Canonical field identifiers used for parsing alternate header spellings.
    private enum Field {
        case sample
        case taxId
        case organism
        case rank
        case readsAligned
        case reads
        case k2Reads
        case abundance
        case coverageBreadth
        case coverage
        case coverageDepth
        case tassScore
        case confidence
        case status
    }

    /// Header aliases normalized through `normalizeHeader(_:)`.
    private static let aliases: [Field: [String]] = [
        .sample: ["sample", "specimen id"],
        .taxId: ["taxid", "tax id", "taxonomy id", "taxonomic id"],
        .organism: ["organism", "detected organism", "name", "species"],
        .rank: ["rank", "taxonomic rank"],
        .readsAligned: ["reads aligned"],
        .reads: ["reads", "read count", "number fragments assigned", "clade fragments covered"],
        .k2Reads: ["k2 reads"],
        .abundance: ["abundance", "percent reads"],
        .coverageBreadth: ["coverage breadth", "coverage_breadth"],
        .coverage: ["coverage"],
        .coverageDepth: ["coverage depth", "coverage_depth", "mean depth", "mean coverage"],
        .tassScore: ["tass score", "tass_score"],
        .confidence: ["confidence"],
        .status: ["status", "group"],
    ]

    // MARK: - Parsing

    /// Parses a TASS metrics TSV file.
    ///
    /// - Parameter url: The metrics TSV file URL.
    /// - Returns: An array of parsed metric records.
    /// - Throws: If the file cannot be read or the header is invalid.
    public static func parse(url: URL) throws -> [TaxTriageMetric] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(tsv: content)
    }

    /// Parses TASS metrics from TSV content.
    ///
    /// The parser is column-order-independent: it reads the header row to determine
    /// column positions, then extracts fields by name. Unrecognized columns are
    /// stored in the ``TaxTriageMetric/additionalFields`` dictionary.
    ///
    /// - Parameter tsv: The TSV content string.
    /// - Returns: An array of parsed metric records.
    /// - Throws: ``TaxTriageMetricsParserError`` if the format is invalid.
    public static func parse(tsv: String) throws -> [TaxTriageMetric] {
        let lines = tsv.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let headerLine = lines.first else {
            throw TaxTriageMetricsParserError.emptyFile
        }

        let rawColumns = headerLine.components(separatedBy: "\t")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let columns = rawColumns.map(normalizeHeader)
        guard !rawColumns.isEmpty else {
            throw TaxTriageMetricsParserError.emptyHeader
        }

        var columnMap: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            columnMap[name] = index
        }

        let sampleIndex = firstIndex(columnMap, for: .sample)
        let taxIdIndex = firstIndex(columnMap, for: .taxId)
        let organismIndex = firstIndex(columnMap, for: .organism)
        let rankIndex = firstIndex(columnMap, for: .rank)
        let readsAlignedIndex = firstIndex(columnMap, for: .readsAligned)
        let readsIndex = firstIndex(columnMap, for: .reads)
        let k2ReadsIndex = firstIndex(columnMap, for: .k2Reads)
        let abundanceIndex = firstIndex(columnMap, for: .abundance)
        let coverageBreadthIndex = firstIndex(columnMap, for: .coverageBreadth)
        let coverageIndex = firstIndex(columnMap, for: .coverage)
        let coverageDepthIndex = firstIndex(columnMap, for: .coverageDepth)
        let tassScoreIndex = firstIndex(columnMap, for: .tassScore)
        let confidenceIndex = firstIndex(columnMap, for: .confidence)
        let statusIndex = firstIndex(columnMap, for: .status)
        let knownIndices = Set([
            sampleIndex,
            taxIdIndex,
            organismIndex,
            rankIndex,
            readsAlignedIndex,
            readsIndex,
            k2ReadsIndex,
            abundanceIndex,
            coverageBreadthIndex,
            coverageIndex,
            coverageDepthIndex,
            tassScoreIndex,
            confidenceIndex,
            statusIndex,
        ].compactMap { $0 })

        // Parse data rows
        var metrics: [TaxTriageMetric] = []

        for (lineIndex, line) in lines.dropFirst().enumerated() {
            let fields = line.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            let sample = fieldValue(fields, index: sampleIndex)
            let taxId = fieldInt(fieldValue(fields, index: taxIdIndex))
            let organism = cleanOrganismName(fieldValue(fields, index: organismIndex) ?? "unknown")
            let rank = fieldValue(fields, index: rankIndex)
            let reads = fieldInt(
                fieldValue(fields, index: readsAlignedIndex)
                ?? fieldValue(fields, index: readsIndex)
                ?? fieldValue(fields, index: k2ReadsIndex)
            ) ?? 0
            let abundance = fieldDouble(fieldValue(fields, index: abundanceIndex))
            let coverageRaw = fieldDouble(
                fieldValue(fields, index: coverageBreadthIndex)
                ?? fieldValue(fields, index: coverageIndex)
            )
            let coverageBreadth = normalizeCoverage(coverageRaw)
            let coverageDepth = fieldDouble(fieldValue(fields, index: coverageDepthIndex))
            let tassScore = fieldDouble(fieldValue(fields, index: tassScoreIndex)) ?? 0.0
            let confidence = fieldValue(fields, index: confidenceIndex)
                ?? fieldValue(fields, index: statusIndex)

            let metric = TaxTriageMetric(
                sample: sample,
                taxId: taxId,
                organism: organism,
                rank: rank,
                reads: reads,
                abundance: abundance,
                coverageBreadth: coverageBreadth,
                coverageDepth: coverageDepth,
                tassScore: tassScore,
                confidence: confidence,
                additionalFields: collectAdditionalFields(
                    fields: fields,
                    rawColumns: rawColumns,
                    knownIndices: knownIndices
                ),
                sourceLineNumber: lineIndex + 2
            )

            metrics.append(metric)
        }

        return metrics
    }

    // MARK: - Field Extraction

    private static func normalizeHeader(_ value: String) -> String {
        let scalarTokens = value.lowercased().unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }
        return scalarTokens
            .joined()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private static func firstIndex(_ columnMap: [String: Int], for field: Field) -> Int? {
        for alias in aliases[field] ?? [] {
            let normalized = normalizeHeader(alias)
            if let index = columnMap[normalized] {
                return index
            }
        }
        return nil
    }

    /// Extracts a string field by column index.
    private static func fieldValue(
        _ fields: [String],
        index: Int?
    ) -> String? {
        guard let index, index < fields.count else { return nil }
        let value = fields[index]
        return value.isEmpty ? nil : value
    }

    /// Extracts an integer field from a raw value.
    private static func fieldInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        if let integer = Int(cleaned) {
            return integer
        }
        if let double = Double(cleaned) {
            return Int(double.rounded())
        }
        return nil
    }

    /// Extracts a double field from a raw value.
    private static func fieldDouble(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    private static func normalizeCoverage(_ coverage: Double?) -> Double? {
        guard let coverage else { return nil }
        if coverage > 0, coverage <= 1 {
            return coverage * 100
        }
        return coverage
    }

    private static func cleanOrganismName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "★", with: "")
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "\u{25CF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // TaxTriage reports occasionally emit a leading-character truncation
        // for Influenza names (e.g. "nfluenza B virus ..."). Repair it here.
        if cleaned.lowercased().hasPrefix("nfluenza") {
            return "I" + cleaned
        }
        return cleaned
    }

    /// Collects fields not in the known column set.
    private static func collectAdditionalFields(
        fields: [String],
        rawColumns: [String],
        knownIndices: Set<Int>
    ) -> [String: String] {
        var additional: [String: String] = [:]
        for (index, column) in rawColumns.enumerated() where !knownIndices.contains(index) {
            if index < fields.count && !fields[index].isEmpty {
                additional[column.trimmingCharacters(in: .whitespaces)] = fields[index]
            }
        }
        return additional
    }
}

// MARK: - TaxTriageMetric

/// A single TASS confidence metric record for one taxon in one sample.
///
/// Contains the organism identification along with confidence scoring metrics
/// produced by TaxTriage's taxonomic assignment confidence system.
public struct TaxTriageMetric: Sendable, Codable, Equatable {

    /// Sample identifier (nil if single-sample file).
    public let sample: String?

    /// NCBI taxonomy ID.
    public let taxId: Int?

    /// Scientific name of the organism.
    public let organism: String

    /// Taxonomic rank code (e.g., "S" for species, "G" for genus).
    public let rank: String?

    /// Number of reads assigned to this taxon.
    public let reads: Int

    /// Relative abundance within the sample (0.0 to 1.0).
    public let abundance: Double?

    /// Genome coverage breadth percentage (0.0 to 100.0).
    ///
    /// Fraction of the reference genome covered by at least one read.
    public let coverageBreadth: Double?

    /// Mean coverage depth.
    ///
    /// Average number of reads covering each base of the reference.
    public let coverageDepth: Double?

    /// TASS (Taxonomic Assignment Scoring System) confidence score (0.0 to 1.0).
    ///
    /// A composite score incorporating read count, coverage breadth, coverage
    /// depth, and other factors. Higher scores indicate more reliable identifications.
    public let tassScore: Double

    /// Qualitative confidence label (e.g., "high", "medium", "low").
    public let confidence: String?

    /// Additional columns not in the standard schema.
    public let additionalFields: [String: String]

    /// The line number in the source file (for diagnostics).
    public let sourceLineNumber: Int?

    /// Creates a new TASS metric record.
    ///
    /// - Parameters:
    ///   - sample: Sample identifier.
    ///   - taxId: NCBI taxonomy ID.
    ///   - organism: Scientific name.
    ///   - rank: Taxonomic rank code.
    ///   - reads: Read count.
    ///   - abundance: Relative abundance.
    ///   - coverageBreadth: Genome coverage breadth percentage.
    ///   - coverageDepth: Mean coverage depth.
    ///   - tassScore: TASS confidence score.
    ///   - confidence: Qualitative confidence label.
    ///   - additionalFields: Extra columns.
    ///   - sourceLineNumber: Source file line number.
    public init(
        sample: String? = nil,
        taxId: Int? = nil,
        organism: String,
        rank: String? = nil,
        reads: Int = 0,
        abundance: Double? = nil,
        coverageBreadth: Double? = nil,
        coverageDepth: Double? = nil,
        tassScore: Double = 0.0,
        confidence: String? = nil,
        additionalFields: [String: String] = [:],
        sourceLineNumber: Int? = nil
    ) {
        self.sample = sample
        self.taxId = taxId
        self.organism = organism
        self.rank = rank
        self.reads = reads
        self.abundance = abundance
        self.coverageBreadth = coverageBreadth
        self.coverageDepth = coverageDepth
        self.tassScore = tassScore
        self.confidence = confidence
        self.additionalFields = additionalFields
        self.sourceLineNumber = sourceLineNumber
    }
}

// MARK: - TaxTriageMetricsParserError

/// Errors produced when parsing TASS metrics files.
public enum TaxTriageMetricsParserError: Error, LocalizedError, Sendable {

    /// The metrics file is empty.
    case emptyFile

    /// The header row is empty or missing.
    case emptyHeader

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "TASS metrics file is empty"
        case .emptyHeader:
            return "TASS metrics file has an empty header row"
        }
    }
}
