// EsVirituDetectionParser.swift - Parser for EsViritu detected_virus.info.tsv
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://github.com/hurwitzlab/EsViritu

import Foundation
import os.log

/// Logger for EsViritu detection parsing operations.
private let logger = Logger(subsystem: "com.lungfish.io", category: "EsVirituDetectionParser")

/// Errors that can occur during EsViritu detection file parsing.
public enum EsVirituDetectionParserError: Error, LocalizedError, Sendable {

    /// The detection file is empty or contains no parseable data lines.
    case emptyFile

    /// The detection file could not be read from disk.
    case fileReadError(URL, String)

    /// A required column value could not be parsed on a specific line.
    case invalidColumnValue(line: Int, column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Empty EsViritu detection file"
        case .fileReadError(let url, let detail):
            return "Cannot read EsViritu detection file at \(url.lastPathComponent): \(detail)"
        case .invalidColumnValue(let line, let column, let value):
            return "Invalid \(column) value '\(value)' on line \(line)"
        }
    }
}

/// A pure-function parser for EsViritu `detected_virus.info.tsv` files.
///
/// The `detected_virus.info.tsv` file is a 23-column tab-separated file
/// produced by the EsViritu viral metagenomics pipeline. Each row represents
/// a single viral contig detection with alignment metrics, coverage statistics,
/// diversity measures, and full NCBI taxonomy.
///
/// **Columns:**
///
/// | Index | Header | Description |
/// |-------|--------|-------------|
/// | 0 | sample_ID | Sample identifier |
/// | 1 | Name | Virus name |
/// | 2 | description | Extended description |
/// | 3 | Length | Contig length (bp) |
/// | 4 | Segment | Genome segment (L/M/S) or empty |
/// | 5 | Accession | GenBank accession |
/// | 6 | Assembly | Assembly accession |
/// | 7 | Asm_length | Assembly length (bp) |
/// | 8 | kingdom | Taxonomic kingdom |
/// | 9 | phylum | Taxonomic phylum |
/// | 10 | tclass | Taxonomic class |
/// | 11 | order | Taxonomic order |
/// | 12 | family | Taxonomic family |
/// | 13 | genus | Taxonomic genus |
/// | 14 | species | Taxonomic species |
/// | 15 | subspecies | Taxonomic subspecies |
/// | 16 | RPKMF | Reads per kilobase per million filtered |
/// | 17 | read_count | Mapped read count |
/// | 18 | covered_bases | Bases with coverage |
/// | 19 | mean_coverage | Mean read depth |
/// | 20 | avg_read_identity | Average read identity % |
/// | 21 | Pi | Nucleotide diversity |
/// | 22 | filtered_reads_in_sample | Total filtered reads |
///
/// ## Usage
///
/// ```swift
/// let detections = try EsVirituDetectionParser.parse(url: detectionURL)
/// for detection in detections {
///     print("\(detection.name): \(detection.readCount) reads")
/// }
/// ```
///
/// ## Thread Safety
///
/// All methods are static and pure -- they take input and return output without
/// side effects. They are safe to call from any isolation domain.
public enum EsVirituDetectionParser {

    /// Expected minimum number of columns in each data row.
    private static let expectedColumnCount = 23

    // MARK: - Public API

    /// Parses an EsViritu detection file from a URL.
    ///
    /// - Parameter url: The file URL to the `detected_virus.info.tsv` file.
    /// - Returns: An array of ``ViralDetection`` values.
    /// - Throws: ``EsVirituDetectionParserError`` if the file cannot be read or parsed.
    public static func parse(url: URL) throws -> [ViralDetection] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EsVirituDetectionParserError.fileReadError(url, error.localizedDescription)
        }
        return try parse(data: data)
    }

    /// Parses EsViritu detection data from in-memory bytes.
    ///
    /// - Parameter data: The raw bytes of the detection file.
    /// - Returns: An array of ``ViralDetection`` values.
    /// - Throws: ``EsVirituDetectionParserError`` if the data cannot be parsed.
    public static func parse(data: Data) throws -> [ViralDetection] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw EsVirituDetectionParserError.emptyFile
        }
        return try parse(text: text)
    }

    /// Parses EsViritu detection data from a string.
    ///
    /// - Parameter text: The detection file content as a string.
    /// - Returns: An array of ``ViralDetection`` values.
    /// - Throws: ``EsVirituDetectionParserError`` if the text cannot be parsed.
    public static func parse(text: String) throws -> [ViralDetection] {
        let lines = text.components(separatedBy: .newlines)
        var detections: [ViralDetection] = []
        var lineNumber = 0
        var sawDetectionHeader = false

        for line in lines {
            lineNumber += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Skip header line
            if trimmed.hasPrefix("sample_ID") || trimmed.hasPrefix("sample_id") {
                sawDetectionHeader = true
                continue
            }

            // Skip comment lines
            if trimmed.hasPrefix("#") { continue }

            guard let detection = parseLine(line, lineNumber: lineNumber) else {
                continue
            }

            detections.append(detection)
        }

        if detections.isEmpty {
            if sawDetectionHeader {
                logger.info("Parsed EsViritu detections: 0 viral contigs")
                return []
            }
            throw EsVirituDetectionParserError.emptyFile
        }

        logger.info("Parsed EsViritu detections: \(detections.count) viral contigs")
        return detections
    }

    /// Parses detections and groups them into assembly-level aggregates.
    ///
    /// Contigs sharing the same assembly accession are grouped together.
    /// Assembly-level metrics are computed as weighted averages or sums
    /// of the constituent contigs.
    ///
    /// - Parameter detections: Parsed contig-level detections.
    /// - Returns: An array of ``ViralAssembly`` values sorted by total reads descending.
    public static func groupByAssembly(_ detections: [ViralDetection]) -> [ViralAssembly] {
        let grouped = Dictionary(grouping: detections, by: \.assembly)

        var assemblies: [ViralAssembly] = []
        for (assemblyAccession, contigs) in grouped {
            guard let first = contigs.first else { continue }

            let totalReads = contigs.reduce(0) { $0 + $1.readCount }
            let totalRpkmf = contigs.reduce(0.0) { $0 + $1.rpkmf }

            // Weighted average coverage and identity by read count
            let weightedCoverage: Double
            let weightedIdentity: Double
            if totalReads > 0 {
                weightedCoverage = contigs.reduce(0.0) {
                    $0 + $1.meanCoverage * Double($1.readCount)
                } / Double(totalReads)
                weightedIdentity = contigs.reduce(0.0) {
                    $0 + $1.avgReadIdentity * Double($1.readCount)
                } / Double(totalReads)
            } else {
                weightedCoverage = contigs.reduce(0.0) { $0 + $1.meanCoverage }
                    / Double(max(contigs.count, 1))
                weightedIdentity = contigs.reduce(0.0) { $0 + $1.avgReadIdentity }
                    / Double(max(contigs.count, 1))
            }

            assemblies.append(ViralAssembly(
                assembly: assemblyAccession,
                assemblyLength: first.assemblyLength,
                name: first.name,
                family: first.family,
                genus: first.genus,
                species: first.species,
                totalReads: totalReads,
                rpkmf: totalRpkmf,
                meanCoverage: weightedCoverage,
                avgReadIdentity: weightedIdentity,
                contigs: contigs
            ))
        }

        return assemblies.sorted { $0.totalReads > $1.totalReads }
    }

    // MARK: - Line Parsing

    /// Parses a single line from the detection file.
    ///
    /// - Parameters:
    ///   - line: The raw tab-separated line.
    ///   - lineNumber: The 1-based line number for error reporting.
    /// - Returns: A ``ViralDetection`` if the line is valid, or `nil` if it
    ///   should be skipped.
    static func parseLine(_ line: String, lineNumber: Int) -> ViralDetection? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0) }

        guard columns.count >= expectedColumnCount else {
            logger.warning(
                "Skipping malformed EsViritu detection line \(lineNumber): expected \(expectedColumnCount) columns, got \(columns.count)"
            )
            return nil
        }

        let sampleId = columns[0].trimmingCharacters(in: .whitespaces)
        let name = columns[1].trimmingCharacters(in: .whitespaces)
        let description = columns[2].trimmingCharacters(in: .whitespaces)

        guard let length = Int(columns[3].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping EsViritu line \(lineNumber): invalid Length '\(columns[3])'"
            )
            return nil
        }

        let segment = optionalString(columns[4])
        let accession = columns[5].trimmingCharacters(in: .whitespaces)
        let assembly = columns[6].trimmingCharacters(in: .whitespaces)

        guard let assemblyLength = Int(columns[7].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping EsViritu line \(lineNumber): invalid Asm_length '\(columns[7])'"
            )
            return nil
        }

        // Taxonomy fields (columns 8-15) -- all optional
        let kingdom = optionalString(columns[8])
        let phylum = optionalString(columns[9])
        let tclass = optionalString(columns[10])
        let order = optionalString(columns[11])
        let family = optionalString(columns[12])
        let genus = optionalString(columns[13])
        let species = optionalString(columns[14])
        let subspecies = optionalString(columns[15])

        // Metric fields (columns 16-22) -- numeric, default to 0 if "NA"
        let rpkmf = parseDouble(columns[16], default: 0.0)
        let readCount = parseInt(columns[17], default: 0)
        let coveredBases = parseInt(columns[18], default: 0)
        let meanCoverage = parseDouble(columns[19], default: 0.0)
        let avgReadIdentity = parseDouble(columns[20], default: 0.0)
        let pi = parseDouble(columns[21], default: 0.0)
        let filteredReadsInSample = parseInt(columns[22], default: 0)

        return ViralDetection(
            sampleId: sampleId,
            name: name,
            description: description,
            length: length,
            segment: segment,
            accession: accession,
            assembly: assembly,
            assemblyLength: assemblyLength,
            kingdom: kingdom,
            phylum: phylum,
            tclass: tclass,
            order: order,
            family: family,
            genus: genus,
            species: species,
            subspecies: subspecies,
            rpkmf: rpkmf,
            readCount: readCount,
            coveredBases: coveredBases,
            meanCoverage: meanCoverage,
            avgReadIdentity: avgReadIdentity,
            pi: pi,
            filteredReadsInSample: filteredReadsInSample
        )
    }

    // MARK: - Field Helpers

    /// Converts a string field to an optional, mapping empty strings, "NA",
    /// and "none" to `nil`.
    ///
    /// - Parameter value: The raw field value.
    /// - Returns: The trimmed string, or `nil` if it represents a missing value.
    static func optionalString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "na" || trimmed.lowercased() == "none" {
            return nil
        }
        return trimmed
    }

    /// Parses a string as a `Double`, returning a default value for "NA" or
    /// unparseable strings.
    ///
    /// - Parameters:
    ///   - value: The raw field value.
    ///   - defaultValue: The value to return if parsing fails.
    /// - Returns: The parsed double or the default.
    static func parseDouble(_ value: String, default defaultValue: Double) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "na" || trimmed.lowercased() == "none" {
            return defaultValue
        }
        return Double(trimmed) ?? defaultValue
    }

    /// Parses a string as an `Int`, returning a default value for "NA" or
    /// unparseable strings.
    ///
    /// - Parameters:
    ///   - value: The raw field value.
    ///   - defaultValue: The value to return if parsing fails.
    /// - Returns: The parsed integer or the default.
    static func parseInt(_ value: String, default defaultValue: Int) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "na" || trimmed.lowercased() == "none" {
            return defaultValue
        }
        return Int(trimmed) ?? defaultValue
    }
}
