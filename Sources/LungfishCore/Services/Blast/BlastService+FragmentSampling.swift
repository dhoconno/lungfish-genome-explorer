// BlastService+FragmentSampling.swift - Unbiased fragment sampling and mate selection for BLAST verification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Kraken hit-string evidence

/// Per-mate k-mer evidence parsed from a Kraken 2 hit string.
///
/// Kraken 2 classifies a read pair as one fragment. Its fifth output column
/// lists `taxid:count` k-mer runs for mate 1, then ` |:| `, then mate 2.
/// Single-end records have no separator.
public struct KrakenMateEvidence: Sendable, Equatable {
    /// K-mers in mate 1 that hit a taxon in the target set.
    public let mate1TargetKmers: Int
    /// K-mers in mate 2 that hit a taxon in the target set, or `nil` for single-end.
    public let mate2TargetKmers: Int?
    /// K-mers in mate 1 that hit any taxon at all (not `0` or `A`).
    public let mate1ClassifiedKmers: Int
    /// K-mers in mate 2 that hit any taxon at all, or `nil` for single-end.
    public let mate2ClassifiedKmers: Int?

    public var isPaired: Bool { mate2TargetKmers != nil }

    /// Parses a Kraken 2 hit string against a set of target taxonomy IDs.
    public init(hitString: Substring, targetTaxIds: Set<Int>) {
        let parts = hitString.components(separatedBy: "|:|")
        let first = Self.count(Substring(parts.first ?? ""), targetTaxIds: targetTaxIds)
        mate1TargetKmers = first.target
        mate1ClassifiedKmers = first.classified
        if parts.count >= 2 {
            let second = Self.count(Substring(parts[1]), targetTaxIds: targetTaxIds)
            mate2TargetKmers = second.target
            mate2ClassifiedKmers = second.classified
        } else {
            mate2TargetKmers = nil
            mate2ClassifiedKmers = nil
        }
    }

    public init(hitString: String, targetTaxIds: Set<Int>) {
        self.init(hitString: Substring(hitString), targetTaxIds: targetTaxIds)
    }

    /// The mate (1 or 2) that carries the most k-mer evidence for the target
    /// taxa. Falls back to classified k-mers of any taxon when neither mate
    /// hits the target set directly, and to mate 1 on a tie. Single-end
    /// fragments always return 1.
    public var preferredMate: Int {
        guard let mate2Target = mate2TargetKmers else { return 1 }
        if mate2Target != mate1TargetKmers {
            return mate2Target > mate1TargetKmers ? 2 : 1
        }
        if let mate2Classified = mate2ClassifiedKmers, mate2Classified > mate1ClassifiedKmers {
            return 2
        }
        return 1
    }

    private static func count(_ segment: Substring, targetTaxIds: Set<Int>) -> (target: Int, classified: Int) {
        var target = 0
        var classified = 0
        for token in segment.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.lastIndex(of: ":"),
                  let kmers = Int(token[token.index(after: colon)...]) else { continue }
            let taxToken = token[..<colon]
            guard let taxId = Int(taxToken), taxId != 0 else { continue }
            classified += kmers
            if targetTaxIds.contains(taxId) {
                target += kmers
            }
        }
        return (target, classified)
    }
}

// MARK: - Fragment sampling

extension BlastService {

    /// Draws an unbiased, seeded random sample of fragment IDs.
    ///
    /// IDs are sorted before shuffling so the result depends only on the ID
    /// set and the seed, not on `Set` iteration order or on the order of
    /// records in the FASTQ file. Every fragment has the same chance of being
    /// chosen regardless of read length or file position.
    public nonisolated func sampleFragmentIds(
        _ fragmentIds: Set<String>,
        count: Int,
        seed: UInt64 = 0
    ) -> [String] {
        guard count > 0, !fragmentIds.isEmpty else { return [] }
        let sorted = fragmentIds.sorted()
        guard sorted.count > count else { return sorted }
        var rng = SeededRandomNumberGenerator(seed: seed)
        // Partial Fisher-Yates: only the first `count` positions are needed.
        var pool = sorted
        for i in 0..<count {
            let j = Int.random(in: i..<pool.count, using: &rng)
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(count))
    }

    /// Normalizes a FASTQ or Kraken read identifier to its fragment ID and,
    /// when the identifier carries a `/1` or `/2` suffix, its mate number.
    nonisolated static func normalizeFragmentId<S: StringProtocol>(_ raw: S) -> (id: String, mate: Int?) {
        if raw.hasSuffix("/1") {
            return (String(raw.dropLast(2)), 1)
        }
        if raw.hasSuffix("/2") {
            return (String(raw.dropLast(2)), 2)
        }
        return (String(raw), nil)
    }

    /// Mate number declared in a FASTQ header's description, if any.
    ///
    /// Recognizes SRA-style `name/1` descriptions and Illumina CASAVA
    /// `1:N:0:...` comments.
    nonisolated static func mateFromDescription<S: StringProtocol>(_ description: S) -> Int? {
        guard let token = description.split(separator: " ").first else { return nil }
        if token.hasSuffix("/1") { return 1 }
        if token.hasSuffix("/2") { return 2 }
        if token.hasPrefix("1:") { return 1 }
        if token.hasPrefix("2:") { return 2 }
        return nil
    }
}
