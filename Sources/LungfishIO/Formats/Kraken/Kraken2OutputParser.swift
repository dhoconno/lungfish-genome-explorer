// Kraken2OutputParser.swift - Kraken2 per-read classification output parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://github.com/DerrickWood/kraken2/blob/master/docs/MANUAL.markdown

import Foundation
import LungfishCore
import os

/// Logger for Kraken2 output parsing operations.
private let logger = Logger(subsystem: LogSubsystem.io, category: "Kraken2OutputParser")

/// A single read classification record from Kraken2 output.
///
/// Kraken2 produces a 5-column tab-separated output for each read:
///
/// ```
/// C   read1   9606    150     0:1 9606:120 0:29
/// U   read2   0       150     0:150
/// ```
///
/// **Columns:**
///
/// | Column | Description |
/// |--------|-------------|
/// | 1 | Classification status: `C` (classified) or `U` (unclassified) |
/// | 2 | Read ID (sequence header) |
/// | 3 | Taxonomy ID assigned (0 if unclassified) |
/// | 4 | Read length in base pairs |
/// | 5 | Space-separated list of `taxId:kmerCount` pairs showing k-mer mappings |
public struct Kraken2ReadClassification: Sendable {

    /// Whether this read was classified.
    public let isClassified: Bool

    /// The read identifier (sequence header).
    public let readId: String

    /// The assigned taxonomy ID (0 if unclassified).
    public let taxId: Int

    /// The read length in base pairs.
    public let readLength: Int

    /// K-mer hit distribution as an array of (taxId, count) pairs.
    ///
    /// Each pair indicates how many consecutive k-mers mapped to a given
    /// taxonomy ID. A taxonomy ID of 0 means that k-mer was ambiguous or
    /// unmapped.
    public let kmerHits: [(taxId: Int, count: Int)]
}

// MARK: - Sendable conformance for kmerHits

// kmerHits contains only Int tuples, which are Sendable. The struct is fully
// value-typed and safe to send across isolation domains.

/// Errors that can occur during Kraken2 output parsing.
public enum Kraken2OutputParserError: Error, LocalizedError, Sendable {

    /// The output file is empty or contains no parseable lines.
    case emptyFile

    /// The output file could not be read.
    case fileReadError(URL, String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Empty Kraken2 output file"
        case .fileReadError(let url, let detail):
            return "Cannot read Kraken2 output at \(url.lastPathComponent): \(detail)"
        }
    }
}

/// A pure-function parser for Kraken2 per-read classification output.
///
/// This parser reads the standard Kraken2 output format (not the kreport) and
/// produces an array of ``Kraken2ReadClassification`` records. This output is
/// needed for downstream tasks such as:
///
/// - Extracting reads classified to a specific taxon
/// - Analyzing k-mer hit distributions
/// - Identifying ambiguously classified reads
///
/// ## Usage
///
/// ```swift
/// let reads = try Kraken2OutputParser.parse(url: outputURL)
/// let humanReads = reads.filter { $0.taxId == 9606 }
/// let unclassified = reads.filter { !$0.isClassified }
/// ```
///
/// ## Thread Safety
///
/// All methods are static and pure.
public enum Kraken2OutputParser {

    // MARK: - Public API

    /// Parses a Kraken2 output file from a URL.
    ///
    /// - Parameter url: The file URL to the Kraken2 output file.
    /// - Returns: An array of ``Kraken2ReadClassification`` records.
    /// - Throws: ``Kraken2OutputParserError`` if the file cannot be read or parsed.
    public static func parse(url: URL) throws -> [Kraken2ReadClassification] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Kraken2OutputParserError.fileReadError(url, error.localizedDescription)
        }
        return try parse(data: data)
    }

    /// Parses Kraken2 output from in-memory data.
    ///
    /// - Parameter data: The raw bytes of the Kraken2 output file.
    /// - Returns: An array of ``Kraken2ReadClassification`` records.
    /// - Throws: ``Kraken2OutputParserError`` if the data cannot be parsed.
    public static func parse(data: Data) throws -> [Kraken2ReadClassification] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Kraken2OutputParserError.emptyFile
        }
        return try parse(text: text)
    }

    /// Parses Kraken2 output from a string.
    ///
    /// - Parameter text: The Kraken2 output content as a string.
    /// - Returns: An array of ``Kraken2ReadClassification`` records.
    /// - Throws: ``Kraken2OutputParserError`` if the text cannot be parsed.
    public static func parse(text: String) throws -> [Kraken2ReadClassification] {
        let lines = text.components(separatedBy: .newlines)
        var results: [Kraken2ReadClassification] = []
        var lineNumber = 0

        for line in lines {
            lineNumber += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let record = parseLine(line, lineNumber: lineNumber) else {
                continue
            }

            results.append(record)
        }

        if results.isEmpty {
            throw Kraken2OutputParserError.emptyFile
        }

        logger.info(
            "Parsed Kraken2 output: \(results.count, privacy: .public) reads"
        )
        return results
    }

    // MARK: - Line Parsing

    /// Parses a single line of Kraken2 output.
    ///
    /// - Parameters:
    ///   - line: The raw line string.
    ///   - lineNumber: The 1-based line number for error reporting.
    /// - Returns: A ``Kraken2ReadClassification`` if the line is valid, or `nil`
    ///   if it should be skipped.
    static func parseLine(_ line: String, lineNumber: Int) -> Kraken2ReadClassification? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)

        guard columns.count >= 5 else {
            logger.warning(
                "Skipping malformed Kraken2 output line \(lineNumber, privacy: .public): expected 5 columns, got \(columns.count, privacy: .public)"
            )
            return nil
        }

        // Column 1: C/U classification status
        let status = columns[0].trimmingCharacters(in: .whitespaces)
        let isClassified: Bool
        switch status {
        case "C":
            isClassified = true
        case "U":
            isClassified = false
        default:
            logger.warning(
                "Skipping Kraken2 output line \(lineNumber, privacy: .public): unknown status '\(status, privacy: .public)'"
            )
            return nil
        }

        // Column 2: read ID
        let readId = String(columns[1]).trimmingCharacters(in: .whitespaces)

        // Column 3: taxonomy ID
        guard let taxId = Int(columns[2].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping Kraken2 output line \(lineNumber, privacy: .public): invalid taxonomy ID"
            )
            return nil
        }

        // Column 4: read length
        // Kraken2 may output "readLen|readLen" for paired-end reads
        let lengthStr = columns[3].trimmingCharacters(in: .whitespaces)
        let readLength: Int
        if lengthStr.contains("|") {
            // Paired-end: sum both lengths
            let parts = lengthStr.split(separator: "|")
            let lengths = parts.compactMap { Int($0) }
            readLength = lengths.reduce(0, +)
        } else {
            readLength = Int(lengthStr) ?? 0
        }

        // Column 5: k-mer hit list
        let kmerString = String(columns[4]).trimmingCharacters(in: .whitespaces)
        let kmerHits = parseKmerHits(kmerString)

        return Kraken2ReadClassification(
            isClassified: isClassified,
            readId: readId,
            taxId: taxId,
            readLength: readLength,
            kmerHits: kmerHits
        )
    }

    /// Parses the k-mer hit distribution string.
    ///
    /// The format is space-separated `taxId:count` pairs:
    /// `0:1 9606:120 0:29`
    ///
    /// Special tokens:
    /// - `A:count` - ambiguous k-mers (mapped to taxId 0)
    ///
    /// - Parameter kmerString: The raw k-mer hit string from column 5.
    /// - Returns: An array of (taxId, count) pairs.
    static func parseKmerHits(_ kmerString: String) -> [(taxId: Int, count: Int)] {
        let tokens = kmerString.split(separator: " ")
        var hits: [(taxId: Int, count: Int)] = []

        for token in tokens {
            let parts = token.split(separator: ":")
            guard parts.count == 2 else { continue }

            let taxIdStr = String(parts[0])
            let countStr = String(parts[1])

            // Handle special tokens: "A" for ambiguous
            let taxId: Int
            if taxIdStr == "A" {
                taxId = 0
            } else {
                guard let parsed = Int(taxIdStr) else { continue }
                taxId = parsed
            }

            guard let count = Int(countStr) else { continue }
            hits.append((taxId: taxId, count: count))
        }

        return hits
    }

    // MARK: - Filtering

    /// Extracts read IDs classified to a specific taxonomy ID.
    ///
    /// - Parameters:
    ///   - records: Parsed Kraken2 classification records.
    ///   - taxId: The taxonomy ID to filter for.
    /// - Returns: An array of read IDs assigned to the given taxon.
    public static func readIds(
        from records: [Kraken2ReadClassification],
        classifiedTo taxId: Int
    ) -> [String] {
        records.filter { $0.taxId == taxId }.map(\.readId)
    }

    /// Extracts read IDs classified to any taxonomy ID in a set.
    ///
    /// This is useful for extracting all reads in a clade (e.g., all descendants
    /// of a genus node).
    ///
    /// - Parameters:
    ///   - records: Parsed Kraken2 classification records.
    ///   - taxIds: The set of taxonomy IDs to include.
    /// - Returns: An array of read IDs assigned to any of the given taxa.
    public static func readIds(
        from records: [Kraken2ReadClassification],
        classifiedToAnyOf taxIds: Set<Int>
    ) -> [String] {
        records.filter { taxIds.contains($0.taxId) }.map(\.readId)
    }
}
