// CompositionCommand.swift - Detailed sequence composition analysis
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Calculate detailed sequence composition
struct CompositionSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "composition",
        abstract: "Calculate detailed nucleotide/amino acid composition",
        discussion: """
            Calculate detailed composition statistics including:
            - Per-base/residue counts and percentages
            - Purine/pyrimidine ratios (nucleotides)
            - GC/AT skew (nucleotides)
            - Codon usage table (nucleotides, --codons)
            - Dinucleotide frequencies (nucleotides, --dinucleotides)

            Positional counts reset at every record boundary. Codons use frame +1
            of each record; incomplete terminal codons and windows containing
            ambiguous symbols are excluded from frequency denominators.

            Examples:
              lungfish analyze composition genome.fasta
              lungfish analyze composition coding.fasta --codons
              lungfish analyze composition genome.fasta --dinucleotides
              lungfish analyze composition protein.faa --alphabet protein
            """
    )

    @Argument(help: "Input file path")
    var input: String

    @Flag(
        name: .customLong("codons"),
        help: "Show codon usage table (nucleotide sequences only)"
    )
    var showCodons: Bool = false

    @Flag(
        name: .customLong("dinucleotides"),
        help: "Show dinucleotide frequencies (nucleotide sequences only)"
    )
    var showDinucleotides: Bool = false

    @Option(
        name: .customLong("alphabet"),
        help: "Sequence alphabet: dna, rna, protein (default: auto-detect from file extension)"
    )
    var alphabetOverride: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate input
        guard FileManager.default.fileExists(atPath: input) else {
            throw CLIError.inputFileNotFound(path: input)
        }

        let inputURL = URL(fileURLWithPath: input)

        // Detect format
        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()

        // Determine alphabet
        let alphabet: SequenceAlphabet
        if let override = alphabetOverride {
            switch override.lowercased() {
            case "dna": alphabet = .dna
            case "rna": alphabet = .rna
            case "protein": alphabet = .protein
            default:
                throw CLIError.conversionFailed(
                    reason: "Unknown alphabet '\(override)'. Use: dna, rna, protein"
                )
            }
        } else {
            // Infer from extension
            switch ext {
            case "faa": alphabet = .protein
            default: alphabet = .dna
            }
        }

        let isNucleotide = alphabet == .dna || alphabet == .rna

        var summary = CompositionAccumulator(
            countCodons: showCodons && isNucleotide,
            countDinucleotides: showDinucleotides && isNucleotide
        )
        try await SequenceSummaryInput.forEachRecord(at: inputURL, alphabet: alphabet) { sequence in
            summary.add(sequence.asString())
        }
        guard summary.recordCount > 0 else {
            throw CLIError.conversionFailed(reason: "No sequences found in input file")
        }
        if !globalOptions.quiet && globalOptions.outputFormat == .text {
            print(formatter.info(
                "Analyzing composition of \(summary.recordCount) sequence(s) from \(inputURL.lastPathComponent)..."
            ))
        }
        let compositionData = buildComposition(
            summary,
            isNucleotide: isNucleotide,
            alphabetName: alphabet.rawValue,
            showCodons: showCodons,
            showDinucleotides: showDinucleotides
        )

        // Output
        switch globalOptions.outputFormat {
        case .json:
            let handler = JSONOutputHandler()
            handler.writeData(compositionData, label: nil)

        case .tsv:
            // Base composition as TSV
            print("residue\tcount\tpercentage")
            for entry in compositionData.baseComposition {
                print("\(entry.residue)\t\(entry.count)\t\(String(format: "%.4f", entry.percentage))")
            }

            if let codons = compositionData.codonUsage {
                print("\ncodon\tamino_acid\tcount\tfrequency")
                for entry in codons {
                    print("\(entry.codon)\t\(entry.aminoAcid)\t\(entry.count)\t\(String(format: "%.4f", entry.frequency))")
                }
            }

            if let dinucs = compositionData.dinucleotideFrequencies {
                print("\ndinucleotide\tcount\tfrequency")
                for entry in dinucs {
                    print("\(entry.dinucleotide)\t\(entry.count)\t\(String(format: "%.4f", entry.frequency))")
                }
            }

        case .text:
            print(formatter.header("Sequence Composition"))
            print(formatter.keyValueTable([
                ("File", inputURL.lastPathComponent),
                ("Sequences", "\(summary.recordCount)"),
                ("Total length", "\(summary.totalLength) \(isNucleotide ? "bp" : "aa")"),
                ("Alphabet", alphabet.rawValue),
            ]))

            // Base composition table
            print("\n" + formatter.header("Base Composition"))
            let compHeaders = ["Residue", "Count", "Percentage"]
            let compRows = compositionData.baseComposition.map { entry -> [String] in
                [entry.residue, "\(entry.count)", String(format: "%.2f%%", entry.percentage * 100)]
            }
            print(formatter.table(headers: compHeaders, rows: compRows))

            // Nucleotide-specific stats
            if isNucleotide {
                if let nucStats = compositionData.nucleotideStats {
                    print("\n" + formatter.header("Nucleotide Statistics"))
                    var pairs: [(String, String)] = [
                        ("Purines (A+G)", String(format: "%d (%.1f%%)", nucStats.purines, nucStats.purinePercent * 100)),
                        ("Pyrimidines (C+T)", String(format: "%d (%.1f%%)", nucStats.pyrimidines, nucStats.pyrimidinePercent * 100)),
                    ]
                    if let gcSkew = nucStats.gcSkew {
                        pairs.append(("GC Skew", String(format: "%.4f", gcSkew)))
                    }
                    if let atSkew = nucStats.atSkew {
                        pairs.append(("AT Skew", String(format: "%.4f", atSkew)))
                    }
                    print(formatter.keyValueTable(pairs))
                }
            }

            // Codon usage
            if let codons = compositionData.codonUsage {
                print("\n" + formatter.header("Codon Usage (Frame +1)"))
                let codonHeaders = ["Codon", "AA", "Count", "Frequency"]
                let codonRows = codons.map { entry -> [String] in
                    [entry.codon, entry.aminoAcid, "\(entry.count)", String(format: "%.2f%%", entry.frequency * 100)]
                }
                print(formatter.table(headers: codonHeaders, rows: codonRows))
            }

            // Dinucleotide frequencies
            if let dinucs = compositionData.dinucleotideFrequencies {
                print("\n" + formatter.header("Dinucleotide Frequencies"))
                let dinucHeaders = ["Dinucleotide", "Count", "Frequency"]
                let dinucRows = dinucs.map { entry -> [String] in
                    [entry.dinucleotide, "\(entry.count)", String(format: "%.2f%%", entry.frequency * 100)]
                }
                print(formatter.table(headers: dinucHeaders, rows: dinucRows))
            }
        }
    }

    // MARK: - Composition Analysis

    private func buildComposition(
        _ summary: CompositionAccumulator,
        isNucleotide: Bool,
        alphabetName: String,
        showCodons: Bool,
        showDinucleotides: Bool
    ) -> CompositionData {
        let total = Double(max(summary.totalLength, 1))
        let counts = summary.baseCounts
        let baseComposition = counts.keys.sorted().map { char -> BaseCompositionEntry in
            let count = counts[char]!
            return BaseCompositionEntry(
                residue: String(char),
                count: count,
                percentage: Double(count) / total
            )
        }

        // Nucleotide-specific statistics
        var nucStats: NucleotideStatsData?
        if isNucleotide {
            let purines = (counts["A"] ?? 0) + (counts["G"] ?? 0)
            let pyrimidines = (counts["C"] ?? 0) + (counts["T"] ?? 0) + (counts["U"] ?? 0)

            let g = Double(counts["G"] ?? 0)
            let c = Double(counts["C"] ?? 0)
            let a = Double(counts["A"] ?? 0)
            let t = Double((counts["T"] ?? 0) + (counts["U"] ?? 0))

            let gcSkew: Double? = (g + c > 0) ? (g - c) / (g + c) : nil
            let atSkew: Double? = (a + t > 0) ? (a - t) / (a + t) : nil

            nucStats = NucleotideStatsData(
                purines: purines,
                purinePercent: Double(purines) / total,
                pyrimidines: pyrimidines,
                pyrimidinePercent: Double(pyrimidines) / total,
                gcSkew: gcSkew,
                atSkew: atSkew
            )
        }

        // Codon usage
        var codonUsage: [CodonUsageEntry]?
        if showCodons && isNucleotide {
            let codonCounts = summary.codonCounts
            let totalCodons = Double(codonCounts.values.reduce(0, +))
            codonUsage = codonCounts.sorted { $0.key < $1.key }.map { codon, count in
                let aa = String(CodonTable.standard.translate(codon))
                return CodonUsageEntry(
                    codon: codon,
                    aminoAcid: aa,
                    count: count,
                    frequency: Double(count) / max(totalCodons, 1)
                )
            }
        }

        // Dinucleotide frequencies
        var dinucFreqs: [DinucleotideEntry]?
        if showDinucleotides && isNucleotide {
            let dinucCounts = summary.dinucleotideCounts
            let totalDinucs = Double(dinucCounts.values.reduce(0, +))
            dinucFreqs = dinucCounts.sorted { $0.key < $1.key }.map { dinuc, count in
                DinucleotideEntry(
                    dinucleotide: dinuc,
                    count: count,
                    frequency: Double(count) / max(totalDinucs, 1)
                )
            }
        }

        return CompositionData(
            totalLength: summary.totalLength,
            alphabet: alphabetName,
            baseComposition: baseComposition,
            nucleotideStats: nucStats,
            codonUsage: codonUsage,
            dinucleotideFrequencies: dinucFreqs
        )
    }
}

/// Counts positional windows within each record, with frame reset at its boundary.
/// Ambiguous windows and incomplete terminal codons are excluded from frequency denominators.
private struct CompositionAccumulator {
    let countCodons: Bool
    let countDinucleotides: Bool
    private(set) var recordCount = 0
    private(set) var totalLength = 0
    private(set) var baseCounts: [Character: Int] = [:]
    private(set) var codonCounts: [String: Int] = [:]
    private(set) var dinucleotideCounts: [String: Int] = [:]

    mutating func add(_ sequence: String) {
        recordCount += 1
        var previous: Character?
        var codon = ""
        for base in sequence.uppercased() {
            totalLength += 1
            baseCounts[base, default: 0] += 1
            if countDinucleotides, let previous, Self.isNucleotide(previous), Self.isNucleotide(base) {
                dinucleotideCounts[String(previous) + String(base), default: 0] += 1
            }
            previous = base
            if countCodons {
                codon.append(base)
                if codon.count == 3 {
                    if codon.allSatisfy(Self.isNucleotide) { codonCounts[codon, default: 0] += 1 }
                    codon.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private static func isNucleotide(_ base: Character) -> Bool {
        base == "A" || base == "C" || base == "G" || base == "T" || base == "U"
    }
}

// MARK: - Composition Result Types

/// Composition analysis result
struct CompositionData: Codable {
    let totalLength: Int
    let alphabet: String
    let baseComposition: [BaseCompositionEntry]
    let nucleotideStats: NucleotideStatsData?
    let codonUsage: [CodonUsageEntry]?
    let dinucleotideFrequencies: [DinucleotideEntry]?
}

/// Single base/residue composition entry
struct BaseCompositionEntry: Codable {
    let residue: String
    let count: Int
    let percentage: Double
}

/// Nucleotide-specific statistics
struct NucleotideStatsData: Codable {
    let purines: Int
    let purinePercent: Double
    let pyrimidines: Int
    let pyrimidinePercent: Double
    let gcSkew: Double?
    let atSkew: Double?
}

/// Codon usage entry
struct CodonUsageEntry: Codable {
    let codon: String
    let aminoAcid: String
    let count: Int
    let frequency: Double
}

/// Dinucleotide frequency entry
struct DinucleotideEntry: Codable {
    let dinucleotide: String
    let count: Int
    let frequency: Double
}
