// FASTQQualityFractions.swift - Exact Q20/Q30 fractions counted from the bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `seqkit stats -a` (2.13) prints Q20(%) and Q30(%) as whole percents, so
// a bundle imported through seqkit showed 95.0 and 91.0 on its QC cards
// while Refresh QC Summary, which counts every base in Swift, showed 94.6
// and 91.3 for the same reads. Every path that takes its summary from
// seqkit now replaces those two values with fractions counted here, from
// the same per-base test the statistics collector applies, so the cards
// read the same whichever path filled them.

import Foundation

extension FASTQQualityFractions {
    /// Counts every base of every record in `urls` at Phred+33, the only
    /// encoding LGE stores. The bytes are counted as they stream past rather
    /// than parsed into records, which ran at about 50 MB/s and kept a
    /// 100 GB import busy for half an hour.
    public static func scan(_ urls: [URL]) async throws -> FASTQQualityFractions {
        var baseCount: Int64 = 0
        var q20Count: Int64 = 0
        var q30Count: Int64 = 0
        for url in urls {
            var counter = FASTQQualityByteCounter()
            try url.forEachChunkAutoDecompressing { chunk in
                try chunk.withUnsafeBytes { try counter.consume($0) }
            }
            let file = try counter.finish()
            baseCount += file.baseCount
            q20Count += file.q20Count
            q30Count += file.q30Count
        }
        return FASTQQualityFractions(baseCount: baseCount, q20Count: q20Count, q30Count: q30Count)
    }

    public static func scan(_ url: URL) async throws -> FASTQQualityFractions {
        try await scan([url])
    }
}

extension SeqkitStatsMetadata {
    /// The same summary with seqkit's whole-percent Q20/Q30 replaced by
    /// fractions counted from the bases.
    public func replacingQualityPercentages(with fractions: FASTQQualityFractions) -> SeqkitStatsMetadata {
        SeqkitStatsMetadata(
            numSeqs: numSeqs,
            sumLen: sumLen,
            minLen: minLen,
            avgLen: avgLen,
            maxLen: maxLen,
            q20Percentage: fractions.q20Percentage,
            q30Percentage: fractions.q30Percentage,
            averageQuality: averageQuality,
            gcPercentage: gcPercentage
        )
    }
}
