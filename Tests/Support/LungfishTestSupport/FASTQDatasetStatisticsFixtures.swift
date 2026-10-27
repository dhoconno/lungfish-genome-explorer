// FASTQDatasetStatisticsFixtures.swift - Derived-manifest statistics for tests that need only the counts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension FASTQDatasetStatistics {
    /// Statistics for a test's derived manifest that needs only its read and base counts, with 0 for every length
    /// and score. It is the shape the app's placeholder wrote before Phase 3.0 lane ONT deleted it (walk WF-8). No
    /// app route writes this shape now, so a test of a sidecar's statistics measures its reads instead.
    public static func countsOnlyFixture(readCount: Int, baseCount: Int64) -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: readCount, baseCount: baseCount,
            meanReadLength: readCount > 0 ? Double(baseCount) / Double(readCount) : 0,
            minReadLength: 0, maxReadLength: 0,
            medianReadLength: 0, n50ReadLength: 0,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }
}
