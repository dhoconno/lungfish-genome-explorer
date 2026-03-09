// BarcodeKitSuggestionEngine.swift - FASTQ barcode kit inference helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Suggested barcode kit detected from a FASTQ sample.
public struct BarcodeKitSuggestion: Sendable, Equatable {
    public let kitID: String
    public let displayName: String
    public let matchingReadCount: Int
    public let sampledReadCount: Int

    public var hitFraction: Double {
        guard sampledReadCount > 0 else { return 0 }
        return Double(matchingReadCount) / Double(sampledReadCount)
    }

    public init(
        kitID: String,
        displayName: String,
        matchingReadCount: Int,
        sampledReadCount: Int
    ) {
        self.kitID = kitID
        self.displayName = displayName
        self.matchingReadCount = matchingReadCount
        self.sampledReadCount = sampledReadCount
    }
}

/// Detects likely barcode kits and dominant barcode IDs from sampled FASTQ reads.
public enum BarcodeKitSuggestionEngine {

    /// Suggest built-in kits by scanning the first N reads.
    ///
    /// A kit is suggested when the fraction of reads containing at least one
    /// compatible barcode signal exceeds `minimumHitFraction`.
    public static func suggestKits(
        in fastqURL: URL,
        kits: [IlluminaBarcodeDefinition] = IlluminaBarcodeKitRegistry.builtinKits(),
        sampleReadLimit: Int = 1_000,
        minimumHitFraction: Double = 0.25
    ) async throws -> [BarcodeKitSuggestion] {
        let reads = try await sampleReadSequences(from: fastqURL, limit: sampleReadLimit)
        guard !reads.isEmpty else { return [] }

        var suggestions: [BarcodeKitSuggestion] = []
        for kit in kits {
            var hits = 0
            for read in reads where !read.isEmpty {
                if !matchedBarcodeIDs(in: read, for: kit).isEmpty {
                    hits += 1
                }
            }
            let suggestion = BarcodeKitSuggestion(
                kitID: kit.id,
                displayName: kit.displayName,
                matchingReadCount: hits,
                sampledReadCount: reads.count
            )
            if suggestion.hitFraction >= minimumHitFraction {
                suggestions.append(suggestion)
            }
        }

        return suggestions.sorted {
            if $0.hitFraction == $1.hitFraction {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.hitFraction > $1.hitFraction
        }
    }

    /// Finds dominant barcode IDs for a specific kit by sampling reads.
    ///
    /// Useful for narrowing combinatorial pair space before full demultiplexing.
    public static func dominantBarcodeIDs(
        in fastqURL: URL,
        kit: IlluminaBarcodeDefinition,
        sampleReadLimit: Int = 1_000,
        minimumHitFraction: Double = 0.01,
        maxCandidates: Int = 48
    ) async throws -> [String] {
        let reads = try await sampleReadSequences(from: fastqURL, limit: sampleReadLimit)
        guard !reads.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for read in reads where !read.isEmpty {
            for barcodeID in matchedBarcodeIDs(in: read, for: kit) {
                counts[barcodeID, default: 0] += 1
            }
        }

        if counts.isEmpty { return [] }

        let minHits = max(1, Int(Double(reads.count) * minimumHitFraction))
        var ranked = counts
            .filter { $0.value >= minHits }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        if ranked.isEmpty {
            ranked = counts
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    }
                    return lhs.value > rhs.value
                }
                .map(\.key)
        }

        return Array(ranked.prefix(max(1, maxCandidates)))
    }

    /// Reverse-complements a DNA sequence.
    public static func reverseComplement(_ sequence: String) -> String {
        let mapped = sequence.uppercased().reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "T": return "A"
            case "C": return "G"
            case "G": return "C"
            case "N": return "N"
            case "R": return "Y"
            case "Y": return "R"
            case "S": return "S"
            case "W": return "W"
            case "K": return "M"
            case "M": return "K"
            case "B": return "V"
            case "V": return "B"
            case "D": return "H"
            case "H": return "D"
            default: return "N"
            }
        }
        return String(mapped)
    }

    // MARK: - Internal Matching

    private static func matchedBarcodeIDs(
        in read: String,
        for kit: IlluminaBarcodeDefinition
    ) -> Set<String> {
        let normalizedRead = read.uppercased()
        var matched: Set<String> = []

        for barcode in kit.barcodes {
            let i7 = barcode.i7Sequence.uppercased()
            let i7rc = reverseComplement(i7)
            let i7Matched = normalizedRead.contains(i7) || normalizedRead.contains(i7rc)

            switch kit.pairingMode {
            case .singleEnd:
                if i7Matched {
                    matched.insert(barcode.id)
                }

            case .fixedDual:
                guard let i5 = barcode.i5Sequence?.uppercased() else {
                    if i7Matched {
                        matched.insert(barcode.id)
                    }
                    continue
                }
                let i5rc = reverseComplement(i5)
                let i5Matched = normalizedRead.contains(i5) || normalizedRead.contains(i5rc)
                if i7Matched && i5Matched {
                    matched.insert(barcode.id)
                }

            case .combinatorialDual:
                if i7Matched {
                    matched.insert(barcode.id)
                }
            }
        }

        return matched
    }

    private static func sampleReadSequences(
        from fastqURL: URL,
        limit: Int
    ) async throws -> [String] {
        let reader = FASTQReader(validateSequence: false)
        var sampled: [String] = []
        sampled.reserveCapacity(max(1, limit))

        for try await record in reader.records(from: fastqURL) {
            sampled.append(record.sequence)
            if sampled.count >= limit {
                break
            }
        }

        return sampled
    }
}
