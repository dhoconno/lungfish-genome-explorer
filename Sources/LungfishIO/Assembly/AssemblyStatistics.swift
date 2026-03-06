// AssemblyStatistics.swift - Pure Swift assembly quality metrics
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - AssemblyStatistics

/// Assembly quality metrics computed from a FASTA file.
///
/// Computes standard assembly statistics including N50, L50, GC content,
/// and contig size distribution. All computation is done in pure Swift
/// without external dependencies.
public struct AssemblyStatistics: Codable, Sendable, Equatable {
    /// Total number of contigs/scaffolds.
    public let contigCount: Int
    /// Total assembly length in base pairs.
    public let totalLengthBP: Int64
    /// Length of the largest contig.
    public let largestContigBP: Int64
    /// Length of the smallest contig.
    public let smallestContigBP: Int64
    /// N50 value: length such that contigs of this length or longer cover >= 50% of total.
    public let n50: Int64
    /// L50 value: minimum number of contigs whose lengths sum to >= 50% of total.
    public let l50: Int
    /// N90 value.
    public let n90: Int64
    /// GC content as a fraction (0.0 to 1.0).
    public let gcFraction: Double
    /// Mean contig length.
    public let meanLengthBP: Double

    /// GC content as a percentage (0.0 to 100.0).
    public var gcPercent: Double { gcFraction * 100.0 }

    /// Human-readable summary.
    public var summary: String {
        """
        Contigs: \(contigCount)
        Total length: \(totalLengthBP.formatted()) bp
        Largest: \(largestContigBP.formatted()) bp
        Smallest: \(smallestContigBP.formatted()) bp
        N50: \(n50.formatted()) bp
        L50: \(l50)
        N90: \(n90.formatted()) bp
        GC: \(String(format: "%.1f", gcPercent))%
        Mean length: \(String(format: "%.0f", meanLengthBP)) bp
        """
    }
}

// MARK: - AssemblyStatisticsCalculator

/// Computes assembly statistics from FASTA data.
public enum AssemblyStatisticsCalculator {

    /// Computes statistics from a FASTA file at the given URL.
    ///
    /// Supports plain FASTA (.fa, .fasta, .fna) files. For gzipped files,
    /// decompress first.
    ///
    /// - Parameter url: Path to the FASTA file
    /// - Returns: Computed assembly statistics
    /// - Throws: If the file cannot be read
    public static func compute(from url: URL) throws -> AssemblyStatistics {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw AssemblyStatisticsError.invalidEncoding
        }
        return compute(fromFASTAString: content)
    }

    /// Computes statistics from FASTA content as a string.
    ///
    /// Handles both Unix (`\n`) and Windows (`\r\n`) line endings.
    ///
    /// - Parameter fasta: FASTA-formatted string
    /// - Returns: Computed assembly statistics
    public static func compute(fromFASTAString fasta: String) -> AssemblyStatistics {
        var contigLengths: [Int64] = []
        var gcCount: Int64 = 0
        var totalBases: Int64 = 0
        var currentLength: Int64 = 0
        var currentGC: Int64 = 0

        // Normalize CR-LF to LF to handle Windows line endings
        let normalized = fasta.replacingOccurrences(of: "\r\n", with: "\n")

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                // New contig — flush previous
                if currentLength > 0 {
                    contigLengths.append(currentLength)
                    gcCount += currentGC
                    totalBases += currentLength
                }
                currentLength = 0
                currentGC = 0
            } else {
                // Sequence line
                for char in line {
                    switch char {
                    case "G", "g", "C", "c":
                        currentGC += 1
                        currentLength += 1
                    case "A", "a", "T", "t", "U", "u":
                        currentLength += 1
                    case "N", "n":
                        currentLength += 1
                    default:
                        // Skip whitespace/other
                        break
                    }
                }
            }
        }
        // Flush last contig
        if currentLength > 0 {
            contigLengths.append(currentLength)
            gcCount += currentGC
            totalBases += currentLength
        }

        return computeFromLengths(contigLengths, gcCount: gcCount, totalBases: totalBases)
    }

    /// Computes statistics from an array of contig lengths.
    ///
    /// - Parameters:
    ///   - lengths: Array of contig lengths in base pairs
    ///   - gcCount: Total G+C bases (for GC content)
    ///   - totalBases: Total bases (for GC content denominator)
    /// - Returns: Computed assembly statistics
    public static func computeFromLengths(
        _ lengths: [Int64],
        gcCount: Int64 = 0,
        totalBases: Int64 = 0
    ) -> AssemblyStatistics {
        guard !lengths.isEmpty else {
            return AssemblyStatistics(
                contigCount: 0, totalLengthBP: 0, largestContigBP: 0,
                smallestContigBP: 0, n50: 0, l50: 0, n90: 0,
                gcFraction: 0, meanLengthBP: 0
            )
        }

        let sorted = lengths.sorted(by: >)  // Descending
        let total = sorted.reduce(0, +)
        let count = sorted.count

        // N50 and L50
        let (n50, l50) = computeNx(sorted: sorted, total: total, x: 50)
        let (n90, _) = computeNx(sorted: sorted, total: total, x: 90)

        let gcFraction: Double
        if totalBases > 0 {
            gcFraction = Double(gcCount) / Double(totalBases)
        } else if total > 0 {
            gcFraction = 0
        } else {
            gcFraction = 0
        }

        return AssemblyStatistics(
            contigCount: count,
            totalLengthBP: total,
            largestContigBP: sorted.first!,
            smallestContigBP: sorted.last!,
            n50: n50,
            l50: l50,
            n90: n90,
            gcFraction: gcFraction,
            meanLengthBP: Double(total) / Double(count)
        )
    }

    /// Computes Nx and Lx from sorted (descending) contig lengths.
    private static func computeNx(sorted: [Int64], total: Int64, x: Int) -> (Int64, Int) {
        let threshold = Int64(Double(total) * Double(x) / 100.0)
        var cumulative: Int64 = 0
        for (index, length) in sorted.enumerated() {
            cumulative += length
            if cumulative >= threshold {
                return (length, index + 1)
            }
        }
        return (sorted.last ?? 0, sorted.count)
    }
}

// MARK: - AssemblyStatisticsError

/// Errors from assembly statistics computation.
public enum AssemblyStatisticsError: Error, LocalizedError {
    case invalidEncoding
    case emptyFile
    case noContigs

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "File is not valid UTF-8 text"
        case .emptyFile: return "FASTA file is empty"
        case .noContigs: return "No contigs found in FASTA file"
        }
    }
}
