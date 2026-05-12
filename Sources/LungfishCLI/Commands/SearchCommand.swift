// SearchCommand.swift - Sequence pattern search command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Search for patterns in sequences
struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for patterns in sequences",
        discussion: """
            Search for exact strings, IUPAC motifs, or regex patterns in nucleotide
            or protein sequences. Outputs results in BED format (chrom, start, end,
            name, score, strand) suitable for downstream processing.

            For nucleotide sequences, both forward and reverse complement strands
            are searched by default.

            Examples:
              lungfish search genome.fasta ATGCGATCG
              lungfish search genome.fasta --iupac "TATAWAWN"
              lungfish search genome.fasta --regex "ATG(.{3}){10,50}T(AA|AG|GA)"
              lungfish search genome.fasta GAATTC --max-mismatches 1
              lungfish search genome.fasta GAATTC -o sites.bed
            """
    )

    @Argument(help: "Input file (FASTA format)")
    var input: String

    @Argument(help: "Search pattern (exact sequence, IUPAC motif, or regex)")
    var pattern: String

    @Flag(
        name: .customLong("regex"),
        help: "Interpret pattern as a regular expression"
    )
    var useRegex: Bool = false

    @Flag(
        name: .customLong("iupac"),
        help: "Interpret pattern as an IUPAC ambiguity code motif"
    )
    var useIUPAC: Bool = false

    @Option(
        name: .customLong("max-mismatches"),
        help: "Allow up to N mismatches for exact matching (default: 0)"
    )
    var maxMismatches: Int = 0

    @Flag(
        name: .customLong("forward-only"),
        help: "Search forward strand only (skip reverse complement)"
    )
    var forwardOnly: Bool = false

    @Flag(
        name: .customLong("case-sensitive"),
        help: "Enable case-sensitive matching"
    )
    var caseSensitive: Bool = false

    @Option(
        name: .shortAndLong,
        help: "Output file path (default: stdout)"
    )
    var output: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        guard !pattern.isEmpty else {
            throw CLIError.conversionFailed(reason: "Search pattern cannot be empty")
        }

        // Validate exclusive flags
        if useRegex && useIUPAC {
            throw CLIError.conversionFailed(
                reason: "Cannot use both --regex and --iupac simultaneously"
            )
        }

        if maxMismatches > 0 && (useRegex || useIUPAC) {
            throw CLIError.conversionFailed(
                reason: "--max-mismatches is only supported with exact matching"
            )
        }

        let inputURL = URL(fileURLWithPath: input)

        // Detect format - strip .gz for format detection
        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()

        guard ["fa", "fasta", "fna", "faa"].contains(ext) else {
            throw CLIError.unsupportedFormat(
                format: "\(ext) (search requires FASTA input)"
            )
        }

        if !globalOptions.quiet {
            let patternType = useRegex ? "regex" : (useIUPAC ? "IUPAC" : "exact")
            print(formatter.info(
                "Searching \(inputURL.lastPathComponent) for \(patternType) pattern '\(pattern)'..."
            ))
        }

        let reader = try FASTAReader(url: inputURL)
        let sequences = try await reader.readAll()

        var allMatches: [SearchMatch] = []

        for seq in sequences {
            let seqStr = caseSensitive ? seq.asString() : seq.asString().uppercased()
            let searchPattern = caseSensitive ? pattern : pattern.uppercased()

            // Forward strand
            let forwardMatches = try findMatches(
                pattern: searchPattern,
                in: seqStr,
                chromosome: seq.name,
                strand: "+"
            )
            allMatches.append(contentsOf: forwardMatches)

            // Reverse strand
            if !forwardOnly && seq.alphabet.canTranslate {
                let rcPattern = TranslationEngine.reverseComplement(searchPattern)
                let reverseMatches = try findMatches(
                    pattern: rcPattern,
                    in: seqStr,
                    chromosome: seq.name,
                    strand: "-"
                )
                allMatches.append(contentsOf: reverseMatches)
            }
        }

        // Format output as BED
        var bedLines: [String] = []
        for (index, match) in allMatches.enumerated() {
            let name = "match_\(index + 1)"
            let score = max(0, maxMismatches - match.mismatches) * 100
            // BED format: chrom start end name score strand
            bedLines.append(
                "\(match.chromosome)\t\(match.start)\t\(match.end)\t\(name)\t\(score)\t\(match.strand)"
            )
        }

        let outputText = bedLines.joined(separator: "\n") + (bedLines.isEmpty ? "" : "\n")

        // Write output
        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: outputPath)
            try outputText.write(
                to: outputURL,
                atomically: true,
                encoding: .utf8
            )
            let completedAt = Date()
            try await CLIProvenanceSupport.recordSingleStepRun(
                name: "lungfish search",
                parameters: [
                    "input": .file(inputURL),
                    "output": .file(outputURL),
                    "pattern": .string(pattern),
                    "patternType": .string(useRegex ? "regex" : (useIUPAC ? "iupac" : "exact")),
                    "useRegex": .boolean(useRegex),
                    "useIUPAC": .boolean(useIUPAC),
                    "maxMismatches": .integer(maxMismatches),
                    "forwardOnly": .boolean(forwardOnly),
                    "caseSensitive": .boolean(caseSensitive),
                    "sequenceCount": .integer(sequences.count),
                    "matchCount": .integer(allMatches.count),
                    "resolvedDefaults": .dictionary([
                        "useRegex": .boolean(false),
                        "useIUPAC": .boolean(false),
                        "maxMismatches": .integer(0),
                        "forwardOnly": .boolean(false),
                        "caseSensitive": .boolean(false)
                    ])
                ],
                toolName: "lungfish search",
                toolVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                command: provenanceCommand(inputURL: inputURL, outputURL: outputURL),
                inputs: [
                    ProvenanceRecorder.fileRecord(url: inputURL, format: .fasta, role: .input)
                ],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: outputURL, format: .bed, role: .output)
                ],
                exitCode: 0,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: nil,
                status: .completed,
                outputDirectory: outputURL.deletingLastPathComponent()
            )
            if !globalOptions.quiet {
                print(formatter.success(
                    "Found \(allMatches.count) match(es) across \(sequences.count) sequence(s), written to \(outputPath)"
                ))
            }
        } else {
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                print(formatter.info("Found \(allMatches.count) match(es):"))
            }
            if globalOptions.outputFormat == .text || globalOptions.outputFormat == .tsv {
                print(outputText, terminator: "")
            }
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let result = PatternSearchResult(
                inputFile: input,
                pattern: pattern,
                patternType: useRegex ? "regex" : (useIUPAC ? "iupac" : "exact"),
                matchCount: allMatches.count,
                sequenceCount: sequences.count,
                matches: allMatches
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }

    // MARK: - Pattern Matching

    private func findMatches(
        pattern: String,
        in sequence: String,
        chromosome: String,
        strand: String
    ) throws -> [SearchMatch] {
        if useRegex {
            return try findRegex(pattern: pattern, in: sequence, chromosome: chromosome, strand: strand)
        } else if useIUPAC {
            return try findIUPAC(pattern: pattern, in: sequence, chromosome: chromosome, strand: strand)
        } else if maxMismatches > 0 {
            return findWithMismatches(
                pattern: pattern,
                in: sequence,
                maxMismatches: maxMismatches,
                chromosome: chromosome,
                strand: strand
            )
        } else {
            return findExact(pattern: pattern, in: sequence, chromosome: chromosome, strand: strand)
        }
    }

    private func findExact(
        pattern: String,
        in sequence: String,
        chromosome: String,
        strand: String
    ) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        var searchStart = sequence.startIndex

        while let range = sequence.range(of: pattern, range: searchStart..<sequence.endIndex) {
            let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
            matches.append(SearchMatch(
                chromosome: chromosome,
                start: position,
                end: position + pattern.count,
                strand: strand,
                mismatches: 0
            ))
            searchStart = sequence.index(after: range.lowerBound)
        }

        return matches
    }

    private func findWithMismatches(
        pattern: String,
        in sequence: String,
        maxMismatches: Int,
        chromosome: String,
        strand: String
    ) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        let patternChars = Array(pattern)
        let seqChars = Array(sequence)
        let patternLen = patternChars.count

        guard seqChars.count >= patternLen else { return [] }

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
                matches.append(SearchMatch(
                    chromosome: chromosome,
                    start: i,
                    end: i + patternLen,
                    strand: strand,
                    mismatches: mismatches
                ))
            }
        }

        return matches
    }

    private func findIUPAC(
        pattern: String,
        in sequence: String,
        chromosome: String,
        strand: String
    ) throws -> [SearchMatch] {
        var regexPattern = ""
        for char in pattern {
            regexPattern += iupacToRegex(char)
        }
        return try findRegex(
            pattern: regexPattern,
            in: sequence,
            chromosome: chromosome,
            strand: strand
        )
    }

    private func findRegex(
        pattern: String,
        in sequence: String,
        chromosome: String,
        strand: String
    ) throws -> [SearchMatch] {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            throw CLIError.conversionFailed(
                reason: "Invalid regular expression '\(pattern)': \(error.localizedDescription)"
            )
        }

        let range = NSRange(sequence.startIndex..., in: sequence)
        let nsMatches = regex.matches(in: sequence, range: range)

        return nsMatches.compactMap { match -> SearchMatch? in
            guard let range = Range(match.range, in: sequence) else { return nil }
            let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
            let length = sequence.distance(from: range.lowerBound, to: range.upperBound)
            return SearchMatch(
                chromosome: chromosome,
                start: position,
                end: position + length,
                strand: strand,
                mismatches: 0
            )
        }
    }

    private func iupacToRegex(_ char: Character) -> String {
        switch char.uppercased().first ?? char {
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

    private func provenanceCommand(inputURL: URL, outputURL: URL) -> [String] {
        var command = ["lungfish", "search", inputURL.path, pattern]
        if useRegex {
            command.append("--regex")
        }
        if useIUPAC {
            command.append("--iupac")
        }
        if maxMismatches != 0 {
            command += ["--max-mismatches", String(maxMismatches)]
        }
        if forwardOnly {
            command.append("--forward-only")
        }
        if caseSensitive {
            command.append("--case-sensitive")
        }
        command += ["--output", outputURL.path]
        return command
    }
}

/// A single search match
struct SearchMatch: Codable {
    let chromosome: String
    let start: Int
    let end: Int
    let strand: String
    let mismatches: Int
}

/// Result data for search command
struct PatternSearchResult: Codable {
    let inputFile: String
    let pattern: String
    let patternType: String
    let matchCount: Int
    let sequenceCount: Int
    let matches: [SearchMatch]
}
