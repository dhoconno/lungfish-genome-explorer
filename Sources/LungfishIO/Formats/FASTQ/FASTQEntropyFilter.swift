// FASTQEntropyFilter.swift - Low-complexity (bbduk entropy) filter defaults + stderr parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Benchmarked defaults for the low-complexity (entropy) filter.
///
/// Chosen from a benchmark readset containing ATC-microsatellite reads:
/// entropy 0.5 removed 1.8% of reads (79% of microsatellite reads), 0.6 removed
/// 4.1% (89%), and 0.7 removed 5.7% (94%). 0.6 is the default because it clears
/// the large majority of tandem-repeat reads without noticeable collateral loss.
public enum FASTQEntropyFilterDefaults: Sendable {
    /// Default Shannon entropy threshold.
    public static let entropy: Double = 0.6
    /// Default sliding window size in bases.
    public static let window: Int = 50
    /// Default k-mer length for entropy estimation.
    public static let kmer: Int = 5

    /// Lowest entropy threshold offered in the UI.
    public static let minimumEntropy: Double = 0.3
    /// Highest entropy threshold offered in the UI.
    public static let maximumEntropy: Double = 0.9
    /// Step size for the entropy control.
    public static let entropyStep: Double = 0.05

    /// Whether an entropy threshold is inside the supported range.
    public static func isValidEntropy(_ value: Double) -> Bool {
        value >= minimumEntropy - 1e-9 && value <= maximumEntropy + 1e-9
    }
}

/// Read and base counts parsed from a bbduk entropy-filter stderr summary.
///
/// bbduk prints a fixed three-line block, e.g.
/// ```
/// Input:                    49621316 reads          5725838608 bases.
/// Low entropy discards:       913960 reads (1.84%)    91699335 bases (1.60%)
/// Result:                   48707356 reads (98.16%) 5634139273 bases (98.40%)
/// ```
/// Older or differently configured runs emit `Total Removed:` in place of the
/// entropy-specific discard line, so both are accepted (the entropy line wins
/// when both appear).
public struct BBDukEntropySummary: Sendable, Equatable, Codable {
    public let inputReads: Int
    public let inputBases: Int
    public let discardedReads: Int
    public let discardedBases: Int
    public let outputReads: Int
    public let outputBases: Int

    public init(
        inputReads: Int,
        inputBases: Int,
        discardedReads: Int,
        discardedBases: Int,
        outputReads: Int,
        outputBases: Int
    ) {
        self.inputReads = inputReads
        self.inputBases = inputBases
        self.discardedReads = discardedReads
        self.discardedBases = discardedBases
        self.outputReads = outputReads
        self.outputBases = outputBases
    }

    /// Percentage of input reads discarded, computed from counts rather than
    /// from bbduk's own printed percentage.
    public var discardedReadPercentage: Double {
        guard inputReads > 0 else { return 0 }
        return Double(discardedReads) / Double(inputReads) * 100
    }

    /// Percentage of input bases discarded.
    public var discardedBasePercentage: Double {
        guard inputBases > 0 else { return 0 }
        return Double(discardedBases) / Double(inputBases) * 100
    }

    /// One-line human-readable summary for the Operations panel.
    public var displaySummary: String {
        let kept = Self.grouped(outputReads)
        let removed = Self.grouped(discardedReads)
        let total = Self.grouped(inputReads)
        let percent = String(format: "%.2f%%", discardedReadPercentage)
        return "Kept \(kept) of \(total) reads; removed \(removed) low-complexity reads (\(percent))."
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Parses a bbduk stderr block. Returns nil when the summary lines are absent.
    public init?(stderr: String) {
        guard let input = Self.counts(in: stderr, prefix: "Input:"),
              let result = Self.counts(in: stderr, prefix: "Result:")
        else {
            return nil
        }

        // The entropy-specific line is authoritative; fall back to the generic
        // total when bbduk did not print it.
        let discard = Self.counts(in: stderr, prefix: "Low entropy discards:")
            ?? Self.counts(in: stderr, prefix: "Total Removed:")
            ?? (reads: max(0, input.reads - result.reads), bases: max(0, input.bases - result.bases))

        self.init(
            inputReads: input.reads,
            inputBases: input.bases,
            discardedReads: discard.reads,
            discardedBases: discard.bases,
            outputReads: result.reads,
            outputBases: result.bases
        )
    }

    /// Extracts the `<n> reads ... <n> bases` pair from the first line starting
    /// with `prefix`. Percentages in parentheses are ignored.
    private static func counts(in stderr: String, prefix: String) -> (reads: Int, bases: Int)? {
        for rawLine in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let remainder = String(line.dropFirst(prefix.count))

            guard let reads = integer(before: "reads", in: remainder),
                  let bases = integer(before: "bases", in: remainder)
            else {
                continue
            }
            return (reads, bases)
        }
        return nil
    }

    /// Returns the integer immediately preceding `keyword` in `text`, skipping
    /// any parenthesized percentage tokens.
    private static func integer(before keyword: String, in text: String) -> Int? {
        let tokens = text
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        guard let keywordIndex = tokens.firstIndex(where: { $0 == keyword }), keywordIndex > 0 else {
            return nil
        }
        // Walk backwards past percentage tokens like "(1.84%)" to the count.
        var index = keywordIndex - 1
        while index >= 0 {
            if let value = Int(tokens[index]) {
                return value
            }
            index -= 1
        }
        return nil
    }
}
