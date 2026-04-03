// ExtractCommand.swift - Sequence region extraction command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Extract data from genomic files — subsequences from FASTA or reads from FASTQ/BAM/database.
struct ExtractCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract subsequences or reads from genomic files",
        discussion: """
            Subcommands:
              sequence  Extract subsequences from FASTA files by region
              reads     Extract reads from FASTQ, BAM, or database sources
            """,
        subcommands: [
            ExtractSequenceSubcommand.self,
            ExtractReadsSubcommand.self,
        ],
        defaultSubcommand: ExtractSequenceSubcommand.self
    )
}

/// Extract subsequences from FASTA files by region.
///
/// This subcommand is also the default when running `lungfish extract` directly
/// to preserve backward compatibility.
struct ExtractSequenceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence",
        abstract: "Extract subsequences from FASTA files",
        discussion: """
            Extract a subsequence from a FASTA file by specifying a region in the
            format chr:start-end (1-based, inclusive coordinates, matching samtools
            faidx convention). Output is in FASTA format.

            When the input contains multiple sequences, specify the sequence name
            as the chromosome. If omitted and the file contains a single sequence,
            that sequence is used.

            Examples:
              lungfish extract sequence genome.fasta chr1:1000-2000
              lungfish extract sequence genome.fasta chr1:1000-2000 --reverse-complement
              lungfish extract sequence genome.fasta chr1:1-500 --flank 100
              lungfish extract sequence genome.fasta seq1:1-100 -o region.fasta
            """
    )

    @Argument(help: "Input file (FASTA format)")
    var input: String

    @Argument(help: "Region to extract (format: name:start-end, 1-based inclusive)")
    var region: String

    @Flag(
        name: .customLong("reverse-complement"),
        help: "Reverse complement the extracted sequence"
    )
    var reverseComplement: Bool = false

    @Option(
        name: .customLong("flank"),
        help: "Add N bases of flanking sequence on each side"
    )
    var flank: Int = 0

    @Option(
        name: .customLong("flank-5"),
        help: "Add N bases of 5' (upstream) flanking sequence"
    )
    var flank5: Int?

    @Option(
        name: .customLong("flank-3"),
        help: "Add N bases of 3' (downstream) flanking sequence"
    )
    var flank3: Int?

    @Option(
        name: .shortAndLong,
        help: "Output file path (default: stdout)"
    )
    var output: String?

    @Option(
        name: .customLong("line-width"),
        help: "FASTA line width (default: 70)"
    )
    var lineWidth: Int = 70

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        // Parse region
        let parsed = try parseRegion(region)

        let inputURL = URL(fileURLWithPath: input)

        // Detect format - strip .gz for format detection
        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()

        guard ["fa", "fasta", "fna", "faa"].contains(ext) else {
            throw CLIError.unsupportedFormat(
                format: "\(ext) (extract requires FASTA input)"
            )
        }

        if !globalOptions.quiet {
            print(formatter.info(
                "Extracting \(region) from \(inputURL.lastPathComponent)..."
            ))
        }

        let reader = try FASTAReader(url: inputURL)
        let sequences = try await reader.readAll()

        // Find the target sequence
        let targetSequence: Sequence
        if let name = parsed.chromosome {
            // Try exact match first, then case-insensitive
            if let found = sequences.first(where: { $0.name == name }) {
                targetSequence = found
            } else if let found = sequences.first(where: { $0.name.lowercased() == name.lowercased() }) {
                targetSequence = found
            } else {
                let available = sequences.map { $0.name }.joined(separator: ", ")
                throw CLIError.conversionFailed(
                    reason: "Sequence '\(name)' not found. Available: \(available)"
                )
            }
        } else if sequences.count == 1 {
            targetSequence = sequences[0]
        } else {
            let available = sequences.map { $0.name }.joined(separator: ", ")
            throw CLIError.conversionFailed(
                reason: "Multiple sequences in file. Specify which one: \(available)"
            )
        }

        // Convert from 1-based inclusive to 0-based half-open
        let start0 = parsed.start - 1
        let end0 = parsed.end

        // Validate coordinates
        guard start0 >= 0 else {
            throw CLIError.conversionFailed(reason: "Start position must be >= 1")
        }
        guard end0 <= targetSequence.length else {
            throw CLIError.conversionFailed(
                reason: "End position \(parsed.end) exceeds sequence length \(targetSequence.length)"
            )
        }
        guard start0 < end0 else {
            throw CLIError.conversionFailed(reason: "Start must be less than end")
        }

        // Calculate flanking
        let effectiveFlank5 = flank5 ?? flank
        let effectiveFlank3 = flank3 ?? flank

        // Build extraction using SequenceExtractor
        let seqStr = targetSequence.asString()

        let request = ExtractionRequest(
            source: .region(
                chromosome: targetSequence.name,
                start: start0,
                end: end0
            ),
            flank5Prime: effectiveFlank5,
            flank3Prime: effectiveFlank3,
            reverseComplement: reverseComplement
        )

        let provider: SequenceExtractor.SequenceProvider = { _, reqStart, reqEnd in
            let clampedStart = max(0, reqStart)
            let clampedEnd = min(seqStr.count, reqEnd)
            guard clampedStart < clampedEnd else { return nil }
            let startIdx = seqStr.index(seqStr.startIndex, offsetBy: clampedStart)
            let endIdx = seqStr.index(seqStr.startIndex, offsetBy: clampedEnd)
            return String(seqStr[startIdx..<endIdx])
        }

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: targetSequence.length
        )

        let fastaOutput = SequenceExtractor.formatFASTA(result, lineWidth: lineWidth)

        // Write output
        if let outputPath = output {
            try fastaOutput.write(
                to: URL(fileURLWithPath: outputPath),
                atomically: true,
                encoding: .utf8
            )
            if !globalOptions.quiet {
                print(formatter.success(
                    "Extracted \(result.nucleotideSequence.count) bp to \(outputPath)"
                ))
            }
        } else {
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                print(formatter.info("Extracted \(result.nucleotideSequence.count) bp:"))
            }
            print(fastaOutput, terminator: "")
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let jsonResult = ExtractResult(
                inputFile: input,
                outputFile: output,
                region: region,
                chromosome: targetSequence.name,
                start: result.effectiveStart,
                end: result.effectiveEnd,
                length: result.nucleotideSequence.count,
                reverseComplement: reverseComplement
            )
            let handler = JSONOutputHandler()
            handler.writeData(jsonResult, label: nil)
        }
    }

    // MARK: - Region Parsing

    /// Parsed region components
    private struct ParsedRegion {
        let chromosome: String?
        let start: Int
        let end: Int
    }

    /// Parses a region string in the format `name:start-end` (1-based inclusive).
    /// The chromosome name is optional if the file has a single sequence.
    private func parseRegion(_ region: String) throws -> ParsedRegion {
        // Try format: chr:start-end
        if let colonIndex = region.lastIndex(of: ":") {
            let name = String(region[region.startIndex..<colonIndex])
            let coords = String(region[region.index(after: colonIndex)...])
            let (start, end) = try parseCoordinates(coords)
            return ParsedRegion(chromosome: name.isEmpty ? nil : name, start: start, end: end)
        }

        // Try format: start-end (no chromosome)
        let (start, end) = try parseCoordinates(region)
        return ParsedRegion(chromosome: nil, start: start, end: end)
    }

    /// Parses `start-end` coordinate pair.
    private func parseCoordinates(_ coords: String) throws -> (Int, Int) {
        let parts = coords.split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]) else {
            throw CLIError.conversionFailed(
                reason: "Invalid region format '\(coords)'. Expected: name:start-end (e.g., chr1:1000-2000)"
            )
        }
        return (start, end)
    }
}

/// Result data for extract command
struct ExtractResult: Codable {
    let inputFile: String
    let outputFile: String?
    let region: String
    let chromosome: String
    let start: Int
    let end: Int
    let length: Int
    let reverseComplement: Bool
}
