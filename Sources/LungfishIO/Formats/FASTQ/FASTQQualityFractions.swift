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

/// Base counts at or above Q20 and Q30, and the percentages they give.
public struct FASTQQualityFractions: Sendable, Equatable {
    public let baseCount: Int64
    public let q20Count: Int64
    public let q30Count: Int64

    public init(baseCount: Int64, q20Count: Int64, q30Count: Int64) {
        self.baseCount = baseCount
        self.q20Count = q20Count
        self.q30Count = q30Count
    }

    public var q20Percentage: Double {
        baseCount > 0 ? Double(q20Count) / Double(baseCount) * 100 : 0
    }

    public var q30Percentage: Double {
        baseCount > 0 ? Double(q30Count) / Double(baseCount) * 100 : 0
    }

    /// Counts every base of every record in `urls`.
    public static func scan(_ urls: [URL]) async throws -> FASTQQualityFractions {
        var baseCount: Int64 = 0
        var q20Count: Int64 = 0
        var q30Count: Int64 = 0
        let reader = FASTQReader(validateSequence: false)
        for url in urls {
            for try await record in reader.records(from: url) {
                let quality = record.quality
                baseCount += Int64(quality.count)
                for index in 0..<quality.count {
                    let q = quality.qualityAt(index)
                    if q >= 20 {
                        q20Count += 1
                        if q >= 30 { q30Count += 1 }
                    }
                }
            }
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
