// TaxTriageReportParser.swift - Parser for TaxTriage organism identification reports
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - TaxTriageReportParser

/// Parses TaxTriage organism identification reports.
///
/// TaxTriage produces text-format reports listing identified organisms along with
/// confidence scores, read counts, and coverage statistics. This parser extracts
/// structured data from these reports.
///
/// ## Report Format
///
/// Each organism entry in the report contains key-value pairs:
///
/// ```
/// Organism: Escherichia coli
/// Score: 0.95
/// Reads: 12345
/// Coverage: 85.3%
/// ```
///
/// ## Example
///
/// ```swift
/// let organisms = try TaxTriageReportParser.parse(url: reportURL)
/// for organism in organisms {
///     print("\(organism.name): score=\(organism.score), reads=\(organism.reads)")
/// }
/// ```
public enum TaxTriageReportParser {

    // MARK: - Parsing

    /// Parses a TaxTriage organism identification report file.
    ///
    /// - Parameter url: The report file URL.
    /// - Returns: An array of identified organisms.
    /// - Throws: If the file cannot be read or the format is invalid.
    public static func parse(url: URL) throws -> [TaxTriageOrganism] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(text: content)
    }

    /// Parses TaxTriage report text content.
    ///
    /// The parser is tolerant of missing fields and extra whitespace. Each organism
    /// block is delimited by blank lines or new `Organism:` lines.
    ///
    /// - Parameter text: The report text content.
    /// - Returns: An array of identified organisms.
    public static func parse(text: String) -> [TaxTriageOrganism] {
        var organisms: [TaxTriageOrganism] = []
        var currentName: String?
        var currentScore: Double?
        var currentReads: Int?
        var currentCoverage: Double?
        var currentTaxId: Int?
        var currentRank: String?

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Blank line: finalize any in-progress organism
                if let name = currentName {
                    organisms.append(TaxTriageOrganism(
                        name: name,
                        score: currentScore ?? 0.0,
                        reads: currentReads ?? 0,
                        coverage: currentCoverage,
                        taxId: currentTaxId,
                        rank: currentRank
                    ))
                    currentName = nil
                    currentScore = nil
                    currentReads = nil
                    currentCoverage = nil
                    currentTaxId = nil
                    currentRank = nil
                }
                continue
            }

            // Parse key-value pairs (case-insensitive key matching)
            if let (key, value) = parseKeyValue(trimmed) {
                let lowerKey = key.lowercased()

                switch lowerKey {
                case "organism", "name", "species":
                    // If we already have an organism in progress, save it first
                    if let name = currentName {
                        organisms.append(TaxTriageOrganism(
                            name: name,
                            score: currentScore ?? 0.0,
                            reads: currentReads ?? 0,
                            coverage: currentCoverage,
                            taxId: currentTaxId,
                            rank: currentRank
                        ))
                        currentScore = nil
                        currentReads = nil
                        currentCoverage = nil
                        currentTaxId = nil
                        currentRank = nil
                    }
                    currentName = value

                case "score", "confidence":
                    currentScore = Double(value)

                case "reads", "read_count", "read count":
                    currentReads = Int(value)

                case "coverage":
                    // Handle both "85.3" and "85.3%" formats
                    let cleanValue = value.replacingOccurrences(of: "%", with: "")
                    currentCoverage = Double(cleanValue)

                case "taxid", "tax_id", "taxonomy_id":
                    currentTaxId = Int(value)

                case "rank":
                    currentRank = value

                default:
                    break
                }
            }
        }

        // Finalize any trailing organism
        if let name = currentName {
            organisms.append(TaxTriageOrganism(
                name: name,
                score: currentScore ?? 0.0,
                reads: currentReads ?? 0,
                coverage: currentCoverage,
                taxId: currentTaxId,
                rank: currentRank
            ))
        }

        return organisms
    }

    // MARK: - Helpers

    /// Parses a "Key: Value" or "Key\tValue" line.
    ///
    /// - Parameter line: The input line.
    /// - Returns: A tuple of (key, value), or nil if the line is not a key-value pair.
    private static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        // Try colon-separated first
        if let colonIndex = line.firstIndex(of: ":") {
            let key = String(line[line.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                return (key, value)
            }
        }

        // Try tab-separated
        let tabParts = line.components(separatedBy: "\t")
        if tabParts.count >= 2 {
            let key = tabParts[0].trimmingCharacters(in: .whitespaces)
            let value = tabParts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                return (key, value)
            }
        }

        return nil
    }
}

// MARK: - TaxTriageOrganism

/// An organism identified by TaxTriage classification.
///
/// Contains the organism name, confidence score, read count, and optional
/// coverage and taxonomy information.
public struct TaxTriageOrganism: Sendable, Codable, Equatable, Identifiable {

    /// Unique identifier derived from the organism name.
    public var id: String { name }

    /// Scientific name of the identified organism.
    public let name: String

    /// Classification confidence score (0.0 to 1.0).
    ///
    /// Higher scores indicate more confident identification.
    public let score: Double

    /// Number of reads assigned to this organism.
    public let reads: Int

    /// Genome coverage percentage (0.0 to 100.0), if available.
    public let coverage: Double?

    /// NCBI taxonomy ID, if available.
    public let taxId: Int?

    /// Taxonomic rank (e.g., "species", "genus"), if available.
    public let rank: String?

    /// The sample whose reads a BLAST request for this organism searches, when the request names one (2.12 lane
    /// 12.09b). The result view sets it on the requests it forwards to its host and the report parsers leave it nil.
    /// A nil sample is not encoded, so an organism without one encodes as it always did.
    public let sample: String?

    /// Creates a new organism identification result.
    ///
    /// - Parameters:
    ///   - name: Scientific name.
    ///   - score: Confidence score.
    ///   - reads: Read count.
    ///   - coverage: Genome coverage percentage.
    ///   - taxId: NCBI taxonomy ID.
    ///   - rank: Taxonomic rank.
    ///   - sample: The sample whose reads a BLAST request searches.
    public init(
        name: String,
        score: Double,
        reads: Int,
        coverage: Double? = nil,
        taxId: Int? = nil,
        rank: String? = nil,
        sample: String? = nil
    ) {
        self.name = name
        self.score = score
        self.reads = reads
        self.coverage = coverage
        self.taxId = taxId
        self.rank = rank
        self.sample = sample
    }
}
