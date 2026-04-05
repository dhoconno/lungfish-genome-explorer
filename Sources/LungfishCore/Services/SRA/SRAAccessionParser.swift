// SRAAccessionParser.swift - SRA accession pattern detection and parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Type of SRA-related accession.
public enum SRAAccessionType: Sendable {
    case run         // SRR, ERR, DRR
    case experiment  // SRX, ERX, DRX
    case sample      // SRS, ERS, DRS
    case study       // SRP, ERP, DRP
    case bioProject  // PRJNA, PRJEB, PRJDB
}

/// Utility for detecting and parsing SRA accession patterns.
public enum SRAAccessionParser {

    // Regex<Substring> is not Sendable in the stdlib, but these are compile-time
    // constants with no mutable state, so nonisolated(unsafe) is correct here.
    private nonisolated(unsafe) static let runPattern = /^[SED]RR\d+$/
    private nonisolated(unsafe) static let experimentPattern = /^[SED]RX\d+$/
    private nonisolated(unsafe) static let samplePattern = /^[SED]RS\d+$/
    private nonisolated(unsafe) static let studyPattern = /^[SED]RP\d+$/
    private nonisolated(unsafe) static let bioProjectPattern = /^PRJ[A-Z]{2}\d+$/

    /// Returns true if the string is a recognized SRA-related accession.
    public static func isSRAAccession(_ string: String) -> Bool {
        accessionType(string) != nil
    }

    /// Returns the accession type, or nil if not recognized.
    public static func accessionType(_ string: String) -> SRAAccessionType? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: runPattern) != nil { return .run }
        if trimmed.wholeMatch(of: experimentPattern) != nil { return .experiment }
        if trimmed.wholeMatch(of: samplePattern) != nil { return .sample }
        if trimmed.wholeMatch(of: studyPattern) != nil { return .study }
        if trimmed.wholeMatch(of: bioProjectPattern) != nil { return .bioProject }
        return nil
    }

    /// Parses a string containing multiple accessions separated by newlines, commas, or tabs.
    /// Returns deduplicated accessions in order of first appearance.
    public static func parseAccessionList(_ input: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let tokens = input.components(separatedBy: CharacterSet(charactersIn: "\n\r,\t "))
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isSRAAccession(trimmed), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Returns true if the input contains 2 or more SRA accessions.
    public static func isMultiAccessionInput(_ input: String) -> Bool {
        parseAccessionList(input).count >= 2
    }

    /// Parses CSV text in NCBI SraAccList.csv format.
    /// Handles files with or without an "acc" header line.
    public static func parseCSV(_ csvText: String) -> [String] {
        var lines = csvText.components(separatedBy: .newlines)
        if let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
           first == "acc" || first == "accession" || first == "run" {
            lines.removeFirst()
        }
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isSRAAccession(trimmed), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Reads and parses a CSV file at the given URL.
    public static func parseCSVFile(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parseCSV(text)
    }
}
