// SequenceStatisticsPlugin.swift - Sequence composition analysis
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import LungfishCore

// MARK: - Sequence Statistics Plugin

/// Plugin that calculates sequence composition statistics.
///
/// Provides comprehensive analysis of sequence composition including
/// base/residue counts, GC content, molecular weight, and more.
///
/// ## Features
/// - Base/residue composition
/// - GC content for nucleotides
/// - Molecular weight estimation
/// - Codon usage for nucleotides
/// - Amino acid composition for proteins
public struct SequenceStatisticsPlugin: SequenceAnalysisPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.sequence-statistics"
    public let name = "Sequence Statistics"
    public let version = "1.0.0"
    public let description = "Calculate sequence composition statistics"
    public let category = PluginCategory.sequenceAnalysis
    public let capabilities: PluginCapabilities = [
        .worksOnSelection,
        .worksOnWholeSequence,
        .producesReport
    ]
    public let iconName = "chart.bar"

    // MARK: - Default Options

    public var defaultOptions: AnalysisOptions {
        var options = AnalysisOptions()
        options["showCodonUsage"] = .bool(true)
        options["showDinucleotides"] = .bool(false)
        options["slidingWindowSize"] = .integer(100)
        return options
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Analysis

    public func analyze(_ input: AnalysisInput) async throws -> AnalysisResult {
        let sequence = input.regionToAnalyze.uppercased()

        guard !sequence.isEmpty else {
            return .failure("Sequence is empty")
        }

        var sections: [ResultSection] = []

        // Basic statistics
        sections.append(basicStatistics(sequence: sequence, alphabet: input.alphabet))

        // Composition
        sections.append(composition(sequence: sequence, alphabet: input.alphabet))

        // Alphabet-specific statistics
        if input.alphabet.isNucleotide {
            sections.append(nucleotideStatistics(sequence: sequence))

            if input.options.bool(for: "showCodonUsage", default: true) && sequence.count >= 3 {
                sections.append(codonUsage(sequence: sequence))
            }

            if input.options.bool(for: "showDinucleotides", default: false) {
                sections.append(dinucleotideFrequencies(sequence: sequence))
            }
        } else if input.alphabet == .protein {
            sections.append(proteinStatistics(sequence: sequence))
        }

        let summary = generateSummary(sequence: sequence, alphabet: input.alphabet)

        return AnalysisResult(
            summary: summary,
            sections: sections,
            exportData: generateExportData(sequence: sequence, alphabet: input.alphabet)
        )
    }

    // MARK: - Statistics Calculations

    private func basicStatistics(sequence: String, alphabet: SequenceAlphabet) -> ResultSection {
        let length = sequence.count
        let mw = estimateMolecularWeight(sequence: sequence, alphabet: alphabet)

        var pairs: [(String, String)] = [
            ("Length", "\(length) \(alphabet.isNucleotide ? "bp" : "aa")"),
            ("Molecular Weight", String(format: "%.2f Da", mw))
        ]

        if alphabet.isNucleotide {
            let gcContent = calculateGCContent(sequence)
            pairs.append(("GC Content", String(format: "%.1f%%", gcContent * 100)))

            let atContent = 1.0 - gcContent
            pairs.append(("AT Content", String(format: "%.1f%%", atContent * 100)))

            let tm = estimateMeltingTemperature(sequence: sequence)
            if let tm = tm {
                pairs.append(("Estimated Tm", String(format: "%.1f°C", tm)))
            }
        }

        return .keyValue("Basic Statistics", pairs)
    }

    private func composition(sequence: String, alphabet: SequenceAlphabet) -> ResultSection {
        var counts: [Character: Int] = [:]
        for char in sequence {
            counts[char, default: 0] += 1
        }

        let total = Double(sequence.count)
        var rows: [[String]] = []

        let sortedChars = counts.keys.sorted()
        for char in sortedChars {
            let count = counts[char]!
            let percent = Double(count) / total * 100
            rows.append([String(char), String(count), String(format: "%.2f%%", percent)])
        }

        return .table("Composition", headers: ["Residue", "Count", "Percentage"], rows: rows)
    }

    private func nucleotideStatistics(sequence: String) -> ResultSection {
        var pairs: [(String, String)] = []

        // Count purines and pyrimidines
        let purines = sequence.filter { $0 == "A" || $0 == "G" }.count
        let pyrimidines = sequence.filter { $0 == "C" || $0 == "T" || $0 == "U" }.count
        let total = Double(sequence.count)

        pairs.append(("Purines (A+G)", String(format: "%d (%.1f%%)", purines, Double(purines)/total*100)))
        pairs.append(("Pyrimidines (C+T)", String(format: "%d (%.1f%%)", pyrimidines, Double(pyrimidines)/total*100)))

        // Calculate GC skew if sequence is long enough
        if sequence.count >= 100 {
            let g = Double(sequence.filter { $0 == "G" }.count)
            let c = Double(sequence.filter { $0 == "C" }.count)
            if g + c > 0 {
                let gcSkew = (g - c) / (g + c)
                pairs.append(("GC Skew", String(format: "%.4f", gcSkew)))
            }

            let a = Double(sequence.filter { $0 == "A" }.count)
            let t = Double(sequence.filter { $0 == "T" || $0 == "U" }.count)
            if a + t > 0 {
                let atSkew = (a - t) / (a + t)
                pairs.append(("AT Skew", String(format: "%.4f", atSkew)))
            }
        }

        return .keyValue("Nucleotide Statistics", pairs)
    }

    private func codonUsage(sequence: String) -> ResultSection {
        var codonCounts: [String: Int] = [:]
        let chars = Array(sequence)

        for i in stride(from: 0, to: chars.count - 2, by: 3) {
            let codon = String(chars[i..<(i+3)])
            if codon.allSatisfy({ "ATCGU".contains($0) }) {
                codonCounts[codon, default: 0] += 1
            }
        }

        let totalCodons = Double(codonCounts.values.reduce(0, +))
        var rows: [[String]] = []

        for (codon, count) in codonCounts.sorted(by: { $0.key < $1.key }) {
            let percent = Double(count) / totalCodons * 100
            let aa = CodonTable.standard.translate(codon)
            rows.append([codon, String(aa), String(count), String(format: "%.2f%%", percent)])
        }

        return .table("Codon Usage (Frame +1)", headers: ["Codon", "AA", "Count", "Frequency"], rows: rows)
    }

    private func dinucleotideFrequencies(sequence: String) -> ResultSection {
        var counts: [String: Int] = [:]
        let chars = Array(sequence)

        for i in 0..<(chars.count - 1) {
            let dinuc = String(chars[i..<(i+2)])
            if dinuc.allSatisfy({ "ATCGU".contains($0) }) {
                counts[dinuc, default: 0] += 1
            }
        }

        let total = Double(counts.values.reduce(0, +))
        var rows: [[String]] = []

        for (dinuc, count) in counts.sorted(by: { $0.key < $1.key }) {
            let percent = Double(count) / total * 100
            rows.append([dinuc, String(count), String(format: "%.2f%%", percent)])
        }

        return .table("Dinucleotide Frequencies", headers: ["Dinucleotide", "Count", "Frequency"], rows: rows)
    }

    private func proteinStatistics(sequence: String) -> ResultSection {
        var pairs: [(String, String)] = []

        // Count amino acid types
        let hydrophobic = Set("AILMFWV")
        let polar = Set("STNQ")
        let charged = Set("DEKRH")
        let special = Set("CGP")

        let hydrophobicCount = sequence.filter { hydrophobic.contains($0) }.count
        let polarCount = sequence.filter { polar.contains($0) }.count
        let chargedCount = sequence.filter { charged.contains($0) }.count
        let specialCount = sequence.filter { special.contains($0) }.count

        let total = Double(sequence.count)

        pairs.append(("Hydrophobic (AILMFWV)", String(format: "%d (%.1f%%)", hydrophobicCount, Double(hydrophobicCount)/total*100)))
        pairs.append(("Polar (STNQ)", String(format: "%d (%.1f%%)", polarCount, Double(polarCount)/total*100)))
        pairs.append(("Charged (DEKRH)", String(format: "%d (%.1f%%)", chargedCount, Double(chargedCount)/total*100)))
        pairs.append(("Special (CGP)", String(format: "%d (%.1f%%)", specialCount, Double(specialCount)/total*100)))

        // Estimate pI (very rough approximation)
        let acidic = sequence.filter { "DE".contains($0) }.count
        let basic = sequence.filter { "KRH".contains($0) }.count
        let netCharge = basic - acidic
        pairs.append(("Net Charge (approx.)", String(format: "%+d", netCharge)))

        return .keyValue("Protein Statistics", pairs)
    }

    // MARK: - Helper Methods

    private func calculateGCContent(_ sequence: String) -> Double {
        let gc = sequence.filter { $0 == "G" || $0 == "C" }.count
        return Double(gc) / Double(sequence.count)
    }

    private func estimateMolecularWeight(sequence: String, alphabet: SequenceAlphabet) -> Double {
        if alphabet.isNucleotide {
            // Average nucleotide MW ~330 Da (includes backbone)
            return Double(sequence.count) * 330.0
        } else {
            // Average amino acid MW ~110 Da
            return Double(sequence.count) * 110.0
        }
    }

    private func estimateMeltingTemperature(sequence: String) -> Double? {
        guard sequence.count >= 10 && sequence.count <= 30 else {
            return nil  // Only accurate for oligonucleotides
        }

        let gc = sequence.filter { $0 == "G" || $0 == "C" }.count
        let at = sequence.filter { $0 == "A" || $0 == "T" || $0 == "U" }.count

        // Basic Tm formula (Wallace rule)
        return Double(4 * gc + 2 * at)
    }

    private func generateSummary(sequence: String, alphabet: SequenceAlphabet) -> String {
        let length = sequence.count
        if alphabet.isNucleotide {
            let gc = calculateGCContent(sequence) * 100
            return String(format: "%d bp, %.1f%% GC", length, gc)
        } else {
            return "\(length) amino acids"
        }
    }

    private func generateExportData(sequence: String, alphabet: SequenceAlphabet) -> ExportData {
        var lines: [String] = ["Residue\tCount\tPercentage"]

        var counts: [Character: Int] = [:]
        for char in sequence {
            counts[char, default: 0] += 1
        }

        let total = Double(sequence.count)
        for char in counts.keys.sorted() {
            let count = counts[char]!
            let percent = Double(count) / total * 100
            lines.append("\(char)\t\(count)\t\(String(format: "%.4f", percent))")
        }

        return ExportData(format: .tsv, content: lines.joined(separator: "\n"))
    }
}
