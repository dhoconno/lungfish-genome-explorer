// BrackenParser.swift - Bracken abundance estimation output parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://github.com/jenniferlu717/Bracken

import Foundation
import LungfishCore
import os

/// Logger for Bracken parsing operations.
private let logger = Logger(subsystem: LogSubsystem.io, category: "BrackenParser")

/// Errors that can occur during Bracken output parsing.
public enum BrackenParserError: Error, LocalizedError, Sendable {

    /// The Bracken output file is empty or contains no data lines.
    case emptyFile

    /// The Bracken output file could not be read.
    case fileReadError(URL, String)

    /// A required column value could not be parsed.
    case invalidColumnValue(line: Int, column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Empty Bracken output file"
        case .fileReadError(let url, let detail):
            return "Cannot read Bracken output at \(url.lastPathComponent): \(detail)"
        case .invalidColumnValue(let line, let column, let value):
            return "Invalid \(column) value '\(value)' on line \(line)"
        }
    }
}

/// A single row from a Bracken abundance output file.
///
/// Bracken produces a 7-column TSV file:
///
/// ```
/// name                    taxonomy_id     taxonomy_lvl    kraken_assigned_reads    added_reads     new_est_reads   fraction_total_reads
/// Escherichia coli        562             S               200                     1800            2000            0.40000
/// Staphylococcus aureus   1280            S               150                     350             500             0.10000
/// ```
public struct BrackenRow: Sendable {

    /// Scientific name of the taxon.
    public let name: String

    /// NCBI taxonomy ID.
    public let taxId: Int

    /// Taxonomy level code (e.g., "S" for species, "G" for genus).
    public let taxonomyLevel: String

    /// Number of reads assigned by Kraken2 directly to this taxon.
    public let krakenAssignedReads: Int

    /// Number of reads redistributed to this taxon by Bracken.
    public let addedReads: Int

    /// New estimated total reads (kraken_assigned + added).
    public let newEstReads: Int

    /// Fraction of total reads (0.0 to 1.0).
    public let fractionTotalReads: Double
}

/// A pure-function parser for Bracken abundance estimation output.
///
/// Bracken re-estimates abundance at a specific taxonomic rank by redistributing
/// reads from higher taxonomic levels down to species (or another target rank).
/// This parser reads the Bracken output TSV and can merge its estimates into an
/// existing ``TaxonTree``.
///
/// ## Usage
///
/// ```swift
/// var tree = try KreportParser.parse(url: kreportURL)
/// try BrackenParser.mergeBracken(url: brackenURL, into: &tree)
/// ```
///
/// ## Thread Safety
///
/// All methods are static and pure.
public enum BrackenParser {

    // MARK: - Public API

    /// Parses a Bracken output file and returns the parsed rows.
    ///
    /// - Parameter url: The file URL to the Bracken output file.
    /// - Returns: An array of ``BrackenRow`` values.
    /// - Throws: ``BrackenParserError`` if the file cannot be read or parsed.
    public static func parse(url: URL) throws -> [BrackenRow] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BrackenParserError.fileReadError(url, error.localizedDescription)
        }
        return try parse(data: data)
    }

    /// Parses Bracken output from in-memory data.
    ///
    /// - Parameter data: The raw bytes of the Bracken output.
    /// - Returns: An array of ``BrackenRow`` values.
    /// - Throws: ``BrackenParserError`` if the data cannot be parsed.
    public static func parse(data: Data) throws -> [BrackenRow] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrackenParserError.emptyFile
        }
        return try parse(text: text)
    }

    /// Parses Bracken output from a string.
    ///
    /// - Parameter text: The Bracken output content as a string.
    /// - Returns: An array of ``BrackenRow`` values.
    /// - Throws: ``BrackenParserError`` if the text cannot be parsed.
    public static func parse(text: String) throws -> [BrackenRow] {
        let lines = text.components(separatedBy: .newlines)
        var rows: [BrackenRow] = []
        var lineNumber = 0

        for line in lines {
            lineNumber += 1

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Skip header line
            if trimmed.hasPrefix("name") && trimmed.contains("taxonomy_id") {
                continue
            }

            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 7 else {
                logger.warning(
                    "Skipping malformed Bracken line \(lineNumber, privacy: .public): expected 7 columns, got \(columns.count, privacy: .public)"
                )
                continue
            }

            let name = columns[0].trimmingCharacters(in: .whitespaces)

            guard let taxId = Int(columns[1].trimmingCharacters(in: .whitespaces)) else {
                logger.warning(
                    "Skipping Bracken line \(lineNumber, privacy: .public): invalid taxonomy ID"
                )
                continue
            }

            let taxonomyLevel = columns[2].trimmingCharacters(in: .whitespaces)

            guard let krakenReads = Int(columns[3].trimmingCharacters(in: .whitespaces)) else {
                logger.warning(
                    "Skipping Bracken line \(lineNumber, privacy: .public): invalid kraken_assigned_reads"
                )
                continue
            }

            guard let addedReads = Int(columns[4].trimmingCharacters(in: .whitespaces)) else {
                logger.warning(
                    "Skipping Bracken line \(lineNumber, privacy: .public): invalid added_reads"
                )
                continue
            }

            guard let newEstReads = Int(columns[5].trimmingCharacters(in: .whitespaces)) else {
                logger.warning(
                    "Skipping Bracken line \(lineNumber, privacy: .public): invalid new_est_reads"
                )
                continue
            }

            guard let fraction = Double(columns[6].trimmingCharacters(in: .whitespaces)) else {
                logger.warning(
                    "Skipping Bracken line \(lineNumber, privacy: .public): invalid fraction_total_reads"
                )
                continue
            }

            rows.append(BrackenRow(
                name: name,
                taxId: taxId,
                taxonomyLevel: taxonomyLevel,
                krakenAssignedReads: krakenReads,
                addedReads: addedReads,
                newEstReads: newEstReads,
                fractionTotalReads: fraction
            ))
        }

        if rows.isEmpty {
            throw BrackenParserError.emptyFile
        }

        logger.info("Parsed Bracken output: \(rows.count, privacy: .public) taxa")
        return rows
    }

    /// Merges Bracken abundance estimates into an existing ``TaxonTree``.
    ///
    /// For each row in the Bracken output, this method finds the matching node
    /// in the tree by taxonomy ID and sets its ``TaxonNode/brackenReads`` and
    /// ``TaxonNode/brackenFraction`` properties. Rows with taxonomy IDs not
    /// found in the tree are silently skipped (with a log warning).
    ///
    /// - Parameters:
    ///   - url: The file URL to the Bracken output file.
    ///   - tree: The ``TaxonTree`` to patch. Passed by reference because we
    ///     mutate the nodes within it.
    /// - Throws: ``BrackenParserError`` if the file cannot be read or parsed.
    public static func mergeBracken(url: URL, into tree: inout TaxonTree) throws {
        let rows = try parse(url: url)
        mergeBracken(rows: rows, into: &tree)
    }

    /// Merges parsed Bracken rows into an existing ``TaxonTree``.
    ///
    /// - Parameters:
    ///   - rows: Parsed Bracken rows.
    ///   - tree: The ``TaxonTree`` to patch.
    public static func mergeBracken(rows: [BrackenRow], into tree: inout TaxonTree) {
        var matchCount = 0
        var missCount = 0

        for row in rows {
            if let node = tree.node(taxId: row.taxId) {
                node.brackenReads = row.newEstReads
                node.brackenFraction = row.fractionTotalReads
                matchCount += 1
            } else {
                logger.debug(
                    "Bracken taxId \(row.taxId, privacy: .public) (\(row.name, privacy: .public)) not found in tree, skipping"
                )
                missCount += 1
            }
        }

        logger.info(
            "Merged Bracken: \(matchCount, privacy: .public) matched, \(missCount, privacy: .public) skipped"
        )
    }
}
