// LocusQueryParser.swift - One shared grammar for user-typed genomic locations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The result of parsing a locus query string.
public enum LocusQuery: Equatable, Sendable {
    /// A chromosome/contig name alone, with no position (`chr2`).
    case chromosome(name: String)

    /// A single 1-based position on a chromosome (`chr1:1000`), or a bare
    /// position with no chromosome (`1000`) to be resolved against whatever
    /// chromosome is currently in view.
    case position(chromosome: String?, position: Int)

    /// A 1-based closed range (`chr1:1,000-2,000`, `chr1:1000..2000`), or a
    /// bare range with no chromosome.
    case range(chromosome: String?, start: Int, end: Int)
}

/// Errors produced when a locus string cannot be parsed.
public enum LocusQueryError: Error, LocalizedError, Equatable {
    case empty
    case invalidFormat(String)
    case invalidRange(start: Int, end: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a chromosome name, position, or range."
        case .invalidFormat(let detail):
            return "Could not parse \"\(detail)\". Expected chr, chr:pos, or chr:start-end."
        case .invalidRange(let start, let end):
            return "Invalid range: start (\(start)) must be less than end (\(end))."
        }
    }
}

/// Parses the genomic-location grammar the app displays back to the user, so
/// pasting a coordinate string the ruler showed always works (SCI-13/FEA-09).
///
/// Accepts, case- and whitespace-tolerantly:
/// - `chr1` — a bare chromosome/contig name (rejected only if it also parses
///   as a bare number, to disambiguate `"100"` from a contig literally named
///   `"100"` — callers can special-case that with `knownChromosomes`).
/// - `1000` — a bare 1-based position, no chromosome.
/// - `1000-2000` / `1000..2000` — a bare 1-based closed range.
/// - `chr1:1000` — chromosome + 1-based position.
/// - `chr1:1,000-2,000` / `chr1:1000..2000` — chromosome + 1-based closed
///   range. Thousands separators (commas) are stripped before parsing, so the
///   ruler's own `GenomicRegion.displayString` output round-trips.
/// - A contig name containing colons (for example an HLA allele accession
///   `HLA-A*01:01:01:01`) is resolved by matching the LONGEST known contig
///   name that is a prefix of the input, when `knownChromosomes` is supplied.
///   Without `knownChromosomes`, the substring before the FIRST colon is
///   always treated as the chromosome, matching the historical behavior.
public enum LocusQueryParser {

    /// Parses `input` into a `LocusQuery`.
    ///
    /// - Parameters:
    ///   - input: The raw, user-typed or pasted string.
    ///   - knownChromosomes: Optional set of contig names in the current
    ///     bundle, used to correctly split a chromosome name that itself
    ///     contains colons from the following position/range.
    /// - Returns: The parsed query.
    /// - Throws: `LocusQueryError` if the string cannot be parsed.
    public static func parse(_ input: String, knownChromosomes: [String] = []) throws -> LocusQuery {
        let cleaned = input
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocusQueryError.empty }

        // Resolve a chromosome prefix that may itself contain colons (e.g. an
        // HLA allele contig) by preferring the longest known contig name that
        // is a prefix of the input, before falling back to splitting on the
        // first colon.
        let (chromosomePart, remainder) = splitChromosomePrefix(cleaned, knownChromosomes: knownChromosomes)

        guard let remainder else {
            // No colon found anywhere: either a bare chromosome name, a bare
            // position, or a bare range.
            if let range = try? parseRange(cleaned) {
                return .range(chromosome: nil, start: range.start, end: range.end)
            }
            if let position = Int(cleaned) {
                return .position(chromosome: nil, position: position)
            }
            // Not purely numeric: treat as a bare chromosome name.
            return .chromosome(name: cleaned)
        }

        guard !chromosomePart.isEmpty, !remainder.isEmpty else {
            throw LocusQueryError.invalidFormat(input)
        }

        if let range = try? parseRange(remainder) {
            guard range.end > range.start else {
                throw LocusQueryError.invalidRange(start: range.start, end: range.end)
            }
            return .range(chromosome: chromosomePart, start: range.start, end: range.end)
        }

        if let position = Int(remainder) {
            return .position(chromosome: chromosomePart, position: position)
        }

        throw LocusQueryError.invalidFormat(input)
    }

    /// Splits `input` into a chromosome-name prefix and the remaining
    /// position/range text, or returns `(input, nil)` if there is no colon.
    private static func splitChromosomePrefix(
        _ input: String,
        knownChromosomes: [String]
    ) -> (chromosome: String, remainder: String?) {
        guard input.contains(":") else { return (input, nil) }

        // Prefer the longest known chromosome name that is an exact prefix
        // (so a contig containing colons, like an HLA allele, is not split
        // mid-name).
        let candidates = knownChromosomes
            .filter { input.hasPrefix($0 + ":") }
            .sorted { $0.count > $1.count }
        if let best = candidates.first {
            let remainderStart = input.index(input.startIndex, offsetBy: best.count + 1)
            return (best, String(input[remainderStart...]))
        }

        // Fall back to the historical behavior: split on the first colon.
        let parts = input.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let chrom = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (chrom, rest)
    }

    /// Parses "start-end" or "start..end" (1-based, inclusive on both ends as
    /// typed). Returns `nil` if `text` is not a range (so callers can fall
    /// back to single-position parsing).
    private static func parseRange(_ text: String) throws -> (start: Int, end: Int)? {
        if text.contains("..") {
            let parts = text.components(separatedBy: "..")
            guard parts.count == 2,
                  let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return (start, end)
        }

        // A hyphen range, distinguished from a negative number: only treat a
        // hyphen as a range separator when it is preceded by at least one
        // digit (so "-5" alone stays a single negative position attempt,
        // which will fail Int parsing gracefully upstream in that rare case).
        guard text.contains("-"), text.first != "-" else { return nil }
        guard let hyphenIndex = text.lastIndex(of: "-") else { return nil }
        let before = String(text[text.startIndex..<hyphenIndex]).trimmingCharacters(in: .whitespaces)
        let after = String(text[text.index(after: hyphenIndex)...]).trimmingCharacters(in: .whitespaces)
        guard let start = Int(before), let end = Int(after) else { return nil }
        return (start, end)
    }
}
