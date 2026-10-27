// FASTQStatisticsDisplayRules.swift - Which stored FASTQ statistics a view shows, and the words for missing scores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The rules a FASTQ view applies to stored statistics before it shows them (Phase 3.0 lane DEMUX-STATS).
enum FASTQStatisticsDisplayRules {

    /// The words shown in place of mean Q, Q20 and Q30 for reads that carry no quality scores.
    static let noQualityScores = "No quality scores"

    /// `statistics` when a view can show them as stored, or nil when it measures the reads instead.
    ///
    /// A record that counts reads and gives the longest of them 0 bases was never measured (`isMeasured`). Bundles
    /// demultiplexed before this lane stored real lengths beside GC 0, mean Q 0 and no score histogram (walk WF-8b).
    /// Counted reads give GC or a score, so that shape was not counted, and the view measures those reads. A FASTA
    /// record counts GC and has no scores, so it is shown as stored. Reads with no G, no C and no scores are measured
    /// again too, which costs one pass and shows the same numbers.
    static func storedStatisticsToShow(_ statistics: FASTQDatasetStatistics) -> FASTQDatasetStatistics? {
        guard statistics.isMeasured else { return nil }
        let notCounted = statistics.baseCount > 0
            && statistics.gcContent == 0
            && statistics.meanQuality == 0
            && statistics.qualityScoreHistogram.isEmpty
        return notCounted ? nil : statistics
    }

    /// Whether the reads carry no quality scores, as FASTA records and bridged reads do (ONT-BIO Backlog 3).
    static func hasNoQualityScores(_ statistics: FASTQDatasetStatistics) -> Bool {
        statistics.readCount > 0 && statistics.qualityScoreHistogram.isEmpty
    }

    static func meanQualityText(_ statistics: FASTQDatasetStatistics) -> String {
        hasNoQualityScores(statistics) ? noQualityScores : String(format: "%.1f", statistics.meanQuality)
    }

    static func q20Text(_ statistics: FASTQDatasetStatistics) -> String {
        hasNoQualityScores(statistics) ? noQualityScores : String(format: "%.1f%%", statistics.q20Percentage)
    }

    static func q30Text(_ statistics: FASTQDatasetStatistics) -> String {
        hasNoQualityScores(statistics) ? noQualityScores : String(format: "%.1f%%", statistics.q30Percentage)
    }
}
