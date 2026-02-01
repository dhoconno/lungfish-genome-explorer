// PatternSearchPlugin.swift - Sequence pattern/motif search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation

// MARK: - Pattern Search Plugin

/// Plugin that searches for patterns/motifs in sequences.
///
/// Supports exact matches, IUPAC ambiguity codes, and regular expressions.
///
/// ## Features
/// - Exact string matching
/// - IUPAC nucleotide ambiguity codes
/// - Regular expression patterns
/// - Mismatch tolerance
/// - Both strand search for nucleotides
public struct PatternSearchPlugin: AnnotationGeneratorPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.pattern-search"
    public let name = "Pattern Search"
    public let version = "1.0.0"
    public let description = "Search for patterns and motifs in sequences"
    public let category = PluginCategory.sequenceAnalysis
    public let capabilities: PluginCapabilities = [
        .worksOnWholeSequence,
        .generatesAnnotations,
        .producesReport
    ]
    public let iconName = "magnifyingglass"
    public let keyboardShortcut = KeyboardShortcut(key: "F", modifiers: [.command])

    // MARK: - Default Options

    public var defaultOptions: AnnotationOptions {
        var options = AnnotationOptions()
        options["pattern"] = .string("")
        options["patternType"] = .string("exact")  // exact, iupac, regex
        options["caseSensitive"] = .bool(false)
        options["searchBothStrands"] = .bool(true)
        options["maxMismatches"] = .integer(0)
        options["annotationType"] = .string("misc_feature")
        return options
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Annotation Generation

    public func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult] {
        let pattern = input.options.string(for: "pattern", default: "")
        guard !pattern.isEmpty else {
            throw PluginError.invalidOptions(reason: "Pattern cannot be empty")
        }

        let patternType = input.options.string(for: "patternType", default: "exact")
        let caseSensitive = input.options.bool(for: "caseSensitive", default: false)
        let searchBothStrands = input.options.bool(for: "searchBothStrands", default: true)
        let maxMismatches = input.options.integer(for: "maxMismatches", default: 0)
        let annotationType = input.options.string(for: "annotationType", default: "misc_feature")

        let sequence = caseSensitive ? input.sequence : input.sequence.uppercased()
        let searchPattern = caseSensitive ? pattern : pattern.uppercased()

        var matches: [PatternMatch] = []

        // Search forward strand
        let forwardMatches = try findMatches(
            pattern: searchPattern,
            patternType: patternType,
            in: sequence,
            maxMismatches: maxMismatches
        )
        matches.append(contentsOf: forwardMatches.map { PatternMatch(position: $0.position, length: $0.length, strand: .forward, mismatches: $0.mismatches) })

        // Search reverse strand for nucleotides
        if searchBothStrands && input.alphabet.isNucleotide {
            let rcPattern = reverseComplement(searchPattern)
            let reverseMatches = try findMatches(
                pattern: rcPattern,
                patternType: patternType,
                in: sequence,
                maxMismatches: maxMismatches
            )
            matches.append(contentsOf: reverseMatches.map { PatternMatch(position: $0.position, length: $0.length, strand: .reverse, mismatches: $0.mismatches) })
        }

        // Convert to annotations
        return matches.enumerated().map { index, match in
            AnnotationResult(
                name: "Match \(index + 1)",
                type: annotationType,
                start: match.position,
                end: match.position + match.length,
                strand: match.strand,
                qualifiers: [
                    "pattern": pattern,
                    "mismatches": String(match.mismatches)
                ]
            )
        }
    }

    // MARK: - Pattern Matching

    private struct MatchResult {
        let position: Int
        let length: Int
        let mismatches: Int
    }

    private struct PatternMatch {
        let position: Int
        let length: Int
        let strand: Strand
        let mismatches: Int
    }

    private func findMatches(
        pattern: String,
        patternType: String,
        in sequence: String,
        maxMismatches: Int
    ) throws -> [MatchResult] {
        switch patternType {
        case "exact":
            if maxMismatches > 0 {
                return findWithMismatches(pattern: pattern, in: sequence, maxMismatches: maxMismatches)
            } else {
                return findExact(pattern: pattern, in: sequence)
            }
        case "iupac":
            return try findIUPAC(pattern: pattern, in: sequence)
        case "regex":
            return try findRegex(pattern: pattern, in: sequence)
        default:
            throw PluginError.invalidOptions(reason: "Unknown pattern type: \(patternType)")
        }
    }

    private func findExact(pattern: String, in sequence: String) -> [MatchResult] {
        var matches: [MatchResult] = []
        var searchStart = sequence.startIndex

        while let range = sequence.range(of: pattern, range: searchStart..<sequence.endIndex) {
            let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
            matches.append(MatchResult(position: position, length: pattern.count, mismatches: 0))
            searchStart = sequence.index(after: range.lowerBound)
        }

        return matches
    }

    private func findWithMismatches(pattern: String, in sequence: String, maxMismatches: Int) -> [MatchResult] {
        var matches: [MatchResult] = []
        let patternChars = Array(pattern)
        let seqChars = Array(sequence)
        let patternLen = patternChars.count

        for i in 0...(seqChars.count - patternLen) {
            var mismatches = 0
            for j in 0..<patternLen {
                if patternChars[j] != seqChars[i + j] {
                    mismatches += 1
                    if mismatches > maxMismatches {
                        break
                    }
                }
            }
            if mismatches <= maxMismatches {
                matches.append(MatchResult(position: i, length: patternLen, mismatches: mismatches))
            }
        }

        return matches
    }

    private func findIUPAC(pattern: String, in sequence: String) throws -> [MatchResult] {
        var regexPattern = ""
        for char in pattern {
            regexPattern += iupacToRegex(char)
        }

        let regex = try NSRegularExpression(pattern: regexPattern, options: [])
        let range = NSRange(sequence.startIndex..., in: sequence)
        let nsMatches = regex.matches(in: sequence, range: range)

        return nsMatches.compactMap { match -> MatchResult? in
            guard let range = Range(match.range, in: sequence) else { return nil }
            let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
            let length = sequence.distance(from: range.lowerBound, to: range.upperBound)
            return MatchResult(position: position, length: length, mismatches: 0)
        }
    }

    private func findRegex(pattern: String, in sequence: String) throws -> [MatchResult] {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(sequence.startIndex..., in: sequence)
        let nsMatches = regex.matches(in: sequence, range: range)

        return nsMatches.compactMap { match -> MatchResult? in
            guard let range = Range(match.range, in: sequence) else { return nil }
            let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
            let length = sequence.distance(from: range.lowerBound, to: range.upperBound)
            return MatchResult(position: position, length: length, mismatches: 0)
        }
    }

    private func iupacToRegex(_ char: Character) -> String {
        switch char.uppercased().first! {
        case "A": return "A"
        case "T", "U": return "[TU]"
        case "C": return "C"
        case "G": return "G"
        case "R": return "[AG]"
        case "Y": return "[CTU]"
        case "S": return "[GC]"
        case "W": return "[ATU]"
        case "K": return "[GTU]"
        case "M": return "[AC]"
        case "B": return "[CGTU]"
        case "D": return "[AGTU]"
        case "H": return "[ACTU]"
        case "V": return "[ACG]"
        case "N": return "[ACGTU]"
        default: return NSRegularExpression.escapedPattern(for: String(char))
        }
    }

    private func reverseComplement(_ sequence: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "U": "A", "C": "G", "G": "C",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N"
        ]
        return String(sequence.reversed().map { complementMap[$0] ?? $0 })
    }
}
