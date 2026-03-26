// AlignedReadDedup.swift - Shared read deduplication by position-strand fingerprint
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - AlignedRead Deduplication

extension AlignedRead {

    /// Counts unique reads by deduplicating on a position-strand fingerprint.
    ///
    /// Two reads are considered duplicates when they share the same start position,
    /// end position, and strand orientation. This is a common post-alignment
    /// deduplication heuristic used for metagenomic read counting.
    ///
    /// - Parameter reads: The aligned reads to deduplicate.
    /// - Returns: The number of unique reads (always >= 0).
    public static func deduplicatedReadCount(from reads: [AlignedRead]) -> Int {
        guard !reads.isEmpty else { return 0 }
        var positionGroups: [String: Int] = [:]
        for read in reads {
            let strand = read.isReverse ? "R" : "F"
            let key = "\(read.position)-\(read.alignmentEnd)-\(strand)"
            positionGroups[key, default: 0] += 1
        }
        let duplicateCount = positionGroups.values.reduce(into: 0) { total, count in
            if count > 1 { total += count - 1 }
        }
        return max(0, reads.count - duplicateCount)
    }
}
