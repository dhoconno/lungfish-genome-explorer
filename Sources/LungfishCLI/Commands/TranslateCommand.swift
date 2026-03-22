// TranslateCommand.swift - DNA/RNA to protein translation command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Translate DNA/RNA sequences to protein
struct TranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate DNA/RNA sequences to protein",
        discussion: """
            Translate nucleotide sequences from a FASTA file into protein sequences
            using the standard or alternative genetic codes.

            Reading frames 1-3 are forward strand, 4-6 are reverse complement
            (frames -1, -2, -3). By default, all 6 frames are translated.

            Examples:
              lungfish translate input.fasta
              lungfish translate input.fasta --frame 1
              lungfish translate input.fasta --frame 1 --table 2 -o proteins.fasta
              lungfish translate input.fasta --all-frames --stop-as-asterisk
            """
    )

    @Argument(help: "Input file (FASTA format)")
    var input: String

    @Option(
        name: .shortAndLong,
        help: "Reading frame: 1-3 (forward), 4-6 (reverse). Default: all 6 frames"
    )
    var frame: Int?

    @Option(
        name: .customLong("table"),
        help: "Genetic code table ID (1=standard, 2=vertebrate mito, 3=yeast mito, 11=bacterial)"
    )
    var table: Int = 1

    @Option(
        name: .shortAndLong,
        help: "Output file path (default: stdout)"
    )
    var output: String?

    @Flag(
        name: .customLong("trim-to-stop"),
        help: "Stop translation at the first stop codon"
    )
    var trimToStop: Bool = false

    @Flag(
        name: .customLong("no-stop-asterisk"),
        help: "Omit stop codon asterisks from output"
    )
    var noStopAsterisk: Bool = false

    @Flag(
        name: .customLong("longest-orf"),
        help: "Output only the longest open reading frame per sequence per frame"
    )
    var longestORF: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        // Resolve codon table
        guard let codonTable = CodonTable.table(id: table) else {
            throw CLIError.conversionFailed(
                reason: "Unknown genetic code table ID \(table). Valid IDs: 1 (standard), 2 (vertebrate mito), 3 (yeast mito), 11 (bacterial)"
            )
        }

        // Validate frame number
        let framesToTranslate: [ReadingFrame]
        if let frame = frame {
            guard (1...6).contains(frame) else {
                throw CLIError.conversionFailed(
                    reason: "Frame must be 1-6. Frames 1-3 are forward, 4-6 are reverse complement."
                )
            }
            framesToTranslate = [frameNumberToReadingFrame(frame)]
        } else {
            framesToTranslate = ReadingFrame.allCases
        }

        let inputURL = URL(fileURLWithPath: input)

        // Read input sequences - strip .gz for format detection
        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()

        guard ["fa", "fasta", "fna", "faa"].contains(ext) else {
            throw CLIError.unsupportedFormat(
                format: "\(ext) (translate requires FASTA input)"
            )
        }

        if !globalOptions.quiet {
            print(formatter.info(
                "Translating \(inputURL.lastPathComponent) using \(codonTable.name) code (table \(codonTable.id))..."
            ))
        }

        let reader = try FASTAReader(url: inputURL)
        let sequences = try await reader.readAll(alphabet: .dna)

        // Translate each sequence in the requested frames
        var outputLines: [String] = []
        var translationCount = 0

        for seq in sequences {
            let seqStr = seq.asString()

            let results = TranslationEngine.translateFrames(
                framesToTranslate,
                sequence: seqStr,
                table: codonTable
            )

            for (readingFrame, protein) in results {
                let finalProtein: String
                if longestORF {
                    finalProtein = extractLongestORF(protein)
                } else if trimToStop {
                    finalProtein = trimToFirstStop(protein)
                } else if noStopAsterisk {
                    finalProtein = protein.replacingOccurrences(of: "*", with: "")
                } else {
                    finalProtein = protein
                }

                guard !finalProtein.isEmpty else { continue }

                let header = ">\(seq.name)_frame\(readingFrame.rawValue) " +
                    "[\(codonTable.name)] [\(finalProtein.count) aa]"
                outputLines.append(header)
                outputLines.append(contentsOf: wrapSequence(finalProtein, lineWidth: 70))
                translationCount += 1
            }
        }

        // Write output
        let outputText = outputLines.joined(separator: "\n") + "\n"

        if let outputPath = output {
            try outputText.write(
                to: URL(fileURLWithPath: outputPath),
                atomically: true,
                encoding: .utf8
            )
            if !globalOptions.quiet {
                print(formatter.success(
                    "Wrote \(translationCount) translation(s) from \(sequences.count) sequence(s) to \(outputPath)"
                ))
            }
        } else {
            print(outputText, terminator: "")
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let result = TranslateResult(
                inputFile: input,
                outputFile: output,
                sequenceCount: sequences.count,
                translationCount: translationCount,
                codonTable: codonTable.name,
                codonTableId: codonTable.id,
                frames: framesToTranslate.map { $0.rawValue }
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }

    // MARK: - Private Helpers

    private func frameNumberToReadingFrame(_ number: Int) -> ReadingFrame {
        switch number {
        case 1: return .plus1
        case 2: return .plus2
        case 3: return .plus3
        case 4: return .minus1
        case 5: return .minus2
        case 6: return .minus3
        default: return .plus1
        }
    }

    private func extractLongestORF(_ protein: String) -> String {
        let orfs = protein.split(separator: "*", omittingEmptySubsequences: true)
        guard let longest = orfs.max(by: { $0.count < $1.count }) else {
            return ""
        }
        return String(longest)
    }

    private func trimToFirstStop(_ protein: String) -> String {
        if let stopIndex = protein.firstIndex(of: "*") {
            return String(protein[protein.startIndex..<stopIndex])
        }
        return protein
    }

    private func wrapSequence(_ sequence: String, lineWidth: Int) -> [String] {
        guard lineWidth > 0 else { return [sequence] }
        var lines: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            lines.append(String(sequence[index..<end]))
            index = end
        }
        return lines
    }
}

/// Result data for translate command
struct TranslateResult: Codable {
    let inputFile: String
    let outputFile: String?
    let sequenceCount: Int
    let translationCount: Int
    let codonTable: String
    let codonTableId: Int
    let frames: [String]
}
