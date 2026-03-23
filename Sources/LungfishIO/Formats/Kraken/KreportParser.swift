// KreportParser.swift - Kraken2 report (kreport) file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://github.com/DerrickWood/kraken2/blob/master/docs/MANUAL.markdown

import Foundation
import LungfishCore
import os

/// Logger for kreport parsing operations.
private let logger = Logger(subsystem: LogSubsystem.io, category: "KreportParser")

/// Errors that can occur during Kraken2 report parsing.
public enum KreportParserError: Error, LocalizedError, Sendable {

    /// The report file is empty or contains no parseable lines.
    case emptyReport

    /// The report file could not be read.
    case fileReadError(URL, String)

    /// A required column value could not be parsed.
    case invalidColumnValue(line: Int, column: String, value: String)

    /// The report contains no root node.
    case missingRootNode

    public var errorDescription: String? {
        switch self {
        case .emptyReport:
            return "Empty Kraken2 report"
        case .fileReadError(let url, let detail):
            return "Cannot read Kraken2 report at \(url.lastPathComponent): \(detail)"
        case .invalidColumnValue(let line, let column, let value):
            return "Invalid \(column) value '\(value)' on line \(line)"
        case .missingRootNode:
            return "Kraken2 report contains no root node"
        }
    }
}

/// A pure-function parser for Kraken2 kreport (report) files.
///
/// Kraken2 produces a 6-column tab-separated report file with the following
/// format:
///
/// ```
///   0.01  1       1       U       0       unclassified
///  99.99  9999    100     R       1       root
///  98.50  9850    50      R1      131567    cellular organisms
///  95.00  9500    200     D       2           Bacteria
/// ```
///
/// **Columns:**
///
/// | Column | Description |
/// |--------|-------------|
/// | 1 | Percentage of reads rooted at this taxon |
/// | 2 | Number of reads rooted at this taxon (clade count) |
/// | 3 | Number of reads assigned directly to this taxon |
/// | 4 | Rank code (`U`, `R`, `D`, `K`, `P`, `C`, `O`, `F`, `G`, `S`, or with suffix) |
/// | 5 | NCBI taxonomy ID |
/// | 6 | Scientific name (indented with 2 spaces per depth level) |
///
/// The parser reconstructs the tree hierarchy from the indentation of scientific
/// names. Each level of indentation corresponds to one depth level in the tree.
///
/// ## Usage
///
/// ```swift
/// let tree = try KreportParser.parse(url: kreportURL)
/// print("Species count: \(tree.speciesCount)")
/// ```
///
/// ## Thread Safety
///
/// All methods are static and pure -- they take input and return output without
/// side effects. They are safe to call from any isolation domain.
public enum KreportParser {

    // MARK: - Public API

    /// Parses a Kraken2 kreport file from a URL.
    ///
    /// - Parameter url: The file URL to the kreport file.
    /// - Returns: A fully constructed ``TaxonTree``.
    /// - Throws: ``KreportParserError`` if the file cannot be read or parsed.
    public static func parse(url: URL) throws -> TaxonTree {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KreportParserError.fileReadError(url, error.localizedDescription)
        }
        return try parse(data: data)
    }

    /// Parses a Kraken2 kreport from in-memory data.
    ///
    /// - Parameter data: The raw bytes of the kreport file.
    /// - Returns: A fully constructed ``TaxonTree``.
    /// - Throws: ``KreportParserError`` if the data cannot be parsed.
    public static func parse(data: Data) throws -> TaxonTree {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KreportParserError.emptyReport
        }
        return try parse(text: text)
    }

    /// Parses a Kraken2 kreport from a string.
    ///
    /// - Parameter text: The kreport content as a string.
    /// - Returns: A fully constructed ``TaxonTree``.
    /// - Throws: ``KreportParserError`` if the text cannot be parsed.
    public static func parse(text: String) throws -> TaxonTree {
        let lines = text.components(separatedBy: .newlines)

        var parsedNodes: [ParsedLine] = []
        var unclassifiedLine: ParsedLine?
        var totalReads = 0
        var lineNumber = 0

        for line in lines {
            lineNumber += 1

            // Skip empty lines
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Skip comment lines
            if trimmed.hasPrefix("#") { continue }

            guard let parsed = parseLine(line, lineNumber: lineNumber) else {
                continue
            }

            if parsed.rank == .unclassified {
                unclassifiedLine = parsed
                totalReads += parsed.readsClade
            } else {
                parsedNodes.append(parsed)
                if parsed.rank == .root {
                    totalReads += parsed.readsClade
                }
            }
        }

        guard !parsedNodes.isEmpty else {
            throw KreportParserError.emptyReport
        }

        // Ensure root node is first in the list
        if let first = parsedNodes.first, first.rank == .root || parsedNodes.count == 1 {
            // Root is already first — nothing to do
        } else if let rootIdx = parsedNodes.firstIndex(where: { $0.rank == .root }) {
            // Reorder so root is first
            let rootNode = parsedNodes.remove(at: rootIdx)
            parsedNodes.insert(rootNode, at: 0)
        } else {
            throw KreportParserError.missingRootNode
        }

        // If totalReads was not computed (unusual format), derive from root + unclassified
        if totalReads == 0 {
            totalReads = parsedNodes.first.map(\.readsClade) ?? 0
            if let unclassified = unclassifiedLine {
                totalReads += unclassified.readsClade
            }
        }

        let tree = buildTree(from: parsedNodes, unclassifiedLine: unclassifiedLine, totalReads: totalReads)
        return tree
    }

    // MARK: - Internal Types

    /// A parsed line from the kreport file, before tree construction.
    struct ParsedLine {
        let percentage: Double
        let readsClade: Int
        let readsDirect: Int
        let rank: TaxonomicRank
        let taxId: Int
        let name: String
        let depth: Int
        let lineNumber: Int
    }

    // MARK: - Line Parsing

    /// Parses a single line of the kreport file.
    ///
    /// - Parameters:
    ///   - line: The raw line string.
    ///   - lineNumber: The 1-based line number for error reporting.
    /// - Returns: A ``ParsedLine`` if the line is valid, or `nil` if it should
    ///   be skipped.
    static func parseLine(_ line: String, lineNumber: Int) -> ParsedLine? {
        // Split on tabs
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)

        guard columns.count >= 6 else {
            logger.warning(
                "Skipping malformed line \(lineNumber, privacy: .public): expected 6+ columns, got \(columns.count, privacy: .public)"
            )
            return nil
        }

        // Column 1: percentage
        guard let percentage = Double(columns[0].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping line \(lineNumber, privacy: .public): invalid percentage '\(String(columns[0]), privacy: .public)'"
            )
            return nil
        }

        // Column 2: clade count
        guard let readsClade = Int(columns[1].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping line \(lineNumber, privacy: .public): invalid clade count '\(String(columns[1]), privacy: .public)'"
            )
            return nil
        }

        // Column 3: direct count
        guard let readsDirect = Int(columns[2].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping line \(lineNumber, privacy: .public): invalid direct count '\(String(columns[2]), privacy: .public)'"
            )
            return nil
        }

        // Detect extended format with k-mer statistics (8 columns):
        //   pct  clade  direct  kmercount  kmerdistinct  rank  taxid  name
        // vs standard format (6 columns):
        //   pct  clade  direct  rank  taxid  name
        //
        // Heuristic: if column 3 parses as an integer, it's a k-mer count
        // (extended format) and the rank code is at column 5 instead of 3.
        let rankOffset: Int
        if columns.count >= 8,
           Int(columns[3].trimmingCharacters(in: .whitespaces)) != nil {
            // Extended format: skip 2 k-mer columns
            rankOffset = 5
        } else {
            // Standard 6-column format
            rankOffset = 3
        }

        guard columns.count > rankOffset + 2 else {
            logger.warning(
                "Skipping line \(lineNumber, privacy: .public): not enough columns for rank/taxid/name"
            )
            return nil
        }

        // Rank code
        let rankCode = columns[rankOffset].trimmingCharacters(in: .whitespaces)
        let rank = TaxonomicRank(code: rankCode)

        // Taxonomy ID
        guard let taxId = Int(columns[rankOffset + 1].trimmingCharacters(in: .whitespaces)) else {
            logger.warning(
                "Skipping line \(lineNumber, privacy: .public): invalid taxonomy ID '\(String(columns[rankOffset + 1]), privacy: .public)'"
            )
            return nil
        }

        // Scientific name (with indentation) — everything from rankOffset+2 onward
        let rawName = String(columns[(rankOffset + 2)...].joined(separator: "\t"))
        let depth = countIndentationDepth(rawName)
        let name = rawName.trimmingCharacters(in: .whitespaces)

        return ParsedLine(
            percentage: percentage,
            readsClade: readsClade,
            readsDirect: readsDirect,
            rank: rank,
            taxId: taxId,
            name: name,
            depth: depth,
            lineNumber: lineNumber
        )
    }

    /// Counts the indentation depth of a name string.
    ///
    /// Kraken2 uses 2 spaces per depth level. For example:
    /// - `"root"` -> depth 0
    /// - `"  cellular organisms"` -> depth 1
    /// - `"    Bacteria"` -> depth 2
    ///
    /// - Parameter name: The raw name string including leading whitespace.
    /// - Returns: The depth level (number of 2-space indentations).
    static func countIndentationDepth(_ name: String) -> Int {
        var spaces = 0
        for char in name {
            if char == " " {
                spaces += 1
            } else {
                break
            }
        }
        return spaces / 2
    }

    // MARK: - Tree Construction

    /// Builds a ``TaxonTree`` from parsed lines.
    ///
    /// The tree is constructed using a stack-based approach: each node's depth
    /// determines where it fits relative to the current stack of ancestors.
    ///
    /// - Parameters:
    ///   - lines: Parsed kreport lines (excluding unclassified).
    ///   - unclassifiedLine: The unclassified line, if present.
    ///   - totalReads: Total reads for fraction computation.
    /// - Returns: A fully constructed ``TaxonTree``.
    static func buildTree(
        from lines: [ParsedLine],
        unclassifiedLine: ParsedLine?,
        totalReads: Int
    ) -> TaxonTree {
        guard let firstLine = lines.first else {
            // Shouldn't happen -- caller checks for empty
            let emptyRoot = TaxonNode(
                taxId: 1, name: "root", rank: .root, depth: 0,
                readsDirect: 0, readsClade: 0,
                fractionClade: 0, fractionDirect: 0, parentTaxId: nil
            )
            return TaxonTree(root: emptyRoot, unclassifiedNode: nil, totalReads: 0)
        }

        let totalDouble = Double(max(totalReads, 1))

        // Create root node
        let rootNode = TaxonNode(
            taxId: firstLine.taxId,
            name: firstLine.name,
            rank: firstLine.rank,
            depth: 0,
            readsDirect: firstLine.readsDirect,
            readsClade: firstLine.readsClade,
            fractionClade: Double(firstLine.readsClade) / totalDouble,
            fractionDirect: Double(firstLine.readsDirect) / totalDouble,
            parentTaxId: nil
        )

        // Stack tracks the ancestor chain: stack[i] is the most recent node at depth i
        var stack: [TaxonNode] = [rootNode]

        for i in 1 ..< lines.count {
            let line = lines[i]
            let node = TaxonNode(
                taxId: line.taxId,
                name: line.name,
                rank: line.rank,
                depth: line.depth,
                readsDirect: line.readsDirect,
                readsClade: line.readsClade,
                fractionClade: Double(line.readsClade) / totalDouble,
                fractionDirect: Double(line.readsDirect) / totalDouble,
                parentTaxId: nil
            )

            // Find the correct parent by popping the stack until we find a node
            // at a depth less than this node's depth
            while stack.count > line.depth {
                stack.removeLast()
            }

            // The top of the stack is the parent
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            }

            // Push this node as the current node at its depth
            if stack.count == line.depth {
                stack.append(node)
            } else {
                // Extend the stack if there's a gap (shouldn't normally happen)
                while stack.count < line.depth {
                    stack.append(node)
                }
                stack.append(node)
            }
        }

        // Create unclassified node if present
        var unclassifiedNode: TaxonNode?
        if let unclassified = unclassifiedLine {
            unclassifiedNode = TaxonNode(
                taxId: unclassified.taxId,
                name: unclassified.name,
                rank: .unclassified,
                depth: 0,
                readsDirect: unclassified.readsDirect,
                readsClade: unclassified.readsClade,
                fractionClade: Double(unclassified.readsClade) / totalDouble,
                fractionDirect: Double(unclassified.readsDirect) / totalDouble,
                parentTaxId: nil
            )
        }

        logger.info(
            "Parsed kreport: \(lines.count, privacy: .public) nodes, \(totalReads, privacy: .public) total reads"
        )

        return TaxonTree(
            root: rootNode,
            unclassifiedNode: unclassifiedNode,
            totalReads: totalReads
        )
    }
}
