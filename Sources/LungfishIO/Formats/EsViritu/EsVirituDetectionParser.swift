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

    /// The header line did not contain every column the parser needs.
    ///
    /// This is the signal that an upstream EsViritu release changed or dropped a
    /// column, rather than the parser quietly emitting wrong values.
    case missingColumns([String])

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Empty EsViritu detection file"
        case .fileReadError(let url, let detail):
            return "Cannot read EsViritu detection file at \(url.lastPathComponent): \(detail)"
        case .invalidColumnValue(let line, let column, let value):
            return "Invalid \(column) value '\(value)' on line \(line)"
        case .missingColumns(let names):
            return "EsViritu detection file is missing required column(s): \(names.joined(separator: ", "))"
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

    /// The column names EsViritu writes in the `detected_virus.info.tsv` header,
    /// in the order upstream emits them.
    ///
    /// Parsing is driven by these names rather than by fixed positions: when a
    /// header line is present, extra and reordered columns are tolerated and a
    /// missing name raises ``EsVirituDetectionParserError/missingColumns(_:)``.
    /// Headerless input falls back to this order positionally.
    public static let requiredColumns: [String] = [
        "sample_ID",
        "Name",
        "description",
        "Length",
        "Segment",
        "Accession",
        "Assembly",
        "Asm_length",
        "kingdom",
        "phylum",
        "tclass",
        "order",
        "family",
        "genus",
        "species",
        "subspecies",
        "RPKMF",
        "read_count",
        "covered_bases",
        "mean_coverage",
        "avg_read_identity",
        "Pi",
        "filtered_reads_in_sample",
    ]

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
        var columnIndex: [String: Int] = defaultColumnIndex

        for line in lines {
            lineNumber += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Header line: resolve column positions by name so that added,
            // removed, or reordered upstream columns are handled explicitly.
            if !sawDetectionHeader, isHeaderLine(trimmed) {
                sawDetectionHeader = true
                columnIndex = try makeColumnIndex(headerLine: line)
                continue
            }

            // Skip comment lines
            if trimmed.hasPrefix("#") { continue }

            guard let detection = parseLine(line, lineNumber: lineNumber, columnIndex: columnIndex) else {
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

    // MARK: - Header Handling

    /// Positional fallback used when the file has no header line.
    static let defaultColumnIndex: [String: Int] = {
        var index: [String: Int] = [:]
        for (position, name) in requiredColumns.enumerated() {
            index[name] = position
        }
        return index
    }()

    /// Returns `true` when a line looks like the EsViritu detection header.
    ///
    /// Detection is by cell content rather than by position, so a reordered
    /// upstream header is still recognised as a header (and then resolved by
    /// name) instead of being misread as a data row.
    static func isHeaderLine(_ trimmed: String) -> Bool {
        let cells = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return cells.contains("sample_id")
    }

    /// Resolves each required column name to its position in the header line.
    ///
    /// - Parameter headerLine: The raw header line.
    /// - Returns: A name-to-index map covering every required column.
    /// - Throws: ``EsVirituDetectionParserError/missingColumns(_:)`` when the
    ///   header omits any required column.
    static func makeColumnIndex(headerLine: String) throws -> [String: Int] {
        let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var index: [String: Int] = [:]
        for (position, name) in headers.enumerated() where index[name] == nil {
            index[name] = position
        }

        let missing = requiredColumns.filter { index[$0] == nil }
        guard missing.isEmpty else {
            logger.error(
                "EsViritu detection header is missing required column(s): \(missing.joined(separator: ", "), privacy: .public)"
            )
            throw EsVirituDetectionParserError.missingColumns(missing)
        }
        return index
    }

    // MARK: - Line Parsing

    /// Parses a single line from the detection file.
    ///
    /// - Parameters:
    ///   - line: The raw tab-separated line.
    ///   - lineNumber: The 1-based line number for error reporting.
    ///   - columnIndex: Name-to-position map resolved from the header line, or
    ///     the positional default when the file had no header.
    /// - Returns: A ``ViralDetection`` if the line is valid, or `nil` if it
    ///   should be skipped.
    static func parseLine(
        _ line: String,
        lineNumber: Int,
        columnIndex: [String: Int] = defaultColumnIndex
    ) -> ViralDetection? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0) }

        guard columns.count >= expectedColumnCount else {
            logger.warning(
                "Skipping malformed EsViritu detection line \(lineNumber): expected \(expectedColumnCount) columns, got \(columns.count)"
            )
            return nil
        }

        /// Returns the cell for a column name, or an empty string when the row is
        /// shorter than the header promised.
        func cell(_ name: String) -> String {
            guard let position = columnIndex[name], position < columns.count else { return "" }
            return columns[position]
        }

        let sampleId = cell("sample_ID").trimmingCharacters(in: .whitespaces)
        let name = cell("Name").trimmingCharacters(in: .whitespaces)
        let description = cell("description").trimmingCharacters(in: .whitespaces)

        let rawLength = cell("Length")
        guard let length = Int(rawLength.trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping EsViritu line \(lineNumber): invalid Length '\(rawLength)'"
            )
            return nil
        }

        let segment = optionalString(cell("Segment"))
        let accession = cell("Accession").trimmingCharacters(in: .whitespaces)
        let assembly = cell("Assembly").trimmingCharacters(in: .whitespaces)

        let rawAsmLength = cell("Asm_length")
        guard let assemblyLength = Int(rawAsmLength.trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping EsViritu line \(lineNumber): invalid Asm_length '\(rawAsmLength)'"
            )
            return nil
        }

        // Taxonomy fields -- all optional
        let kingdom = optionalString(cell("kingdom"))
        let phylum = optionalString(cell("phylum"))
        let tclass = optionalString(cell("tclass"))
        let order = optionalString(cell("order"))
        let family = optionalString(cell("family"))
        let genus = optionalString(cell("genus"))
        let species = optionalString(cell("species"))
        let subspecies = optionalString(cell("subspecies"))

        // Metric fields -- numeric, default to 0 if "NA"
        let rpkmf = parseDouble(cell("RPKMF"), default: 0.0)
        let readCount = parseInt(cell("read_count"), default: 0)
        let coveredBases = parseInt(cell("covered_bases"), default: 0)
        let meanCoverage = parseDouble(cell("mean_coverage"), default: 0.0)
        let avgReadIdentity = parseDouble(cell("avg_read_identity"), default: 0.0)
        let pi = parseDouble(cell("Pi"), default: 0.0)
        let filteredReadsInSample = parseInt(cell("filtered_reads_in_sample"), default: 0)

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
