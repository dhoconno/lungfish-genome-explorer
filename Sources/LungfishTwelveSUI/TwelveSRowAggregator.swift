// TwelveSRowAggregator.swift — sample-subset aggregation for the 12S viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

/// Pure helpers that restrict per-sample 12S row metrics to a selected subset
/// of samples, mirroring the NAO-MGS / NVD multi-sample idiom.
///
/// The 12S bundle is already per-sample (each row carries `sampleCounts` keyed
/// by sample ID), so multi-sample comparison is a UI-layer concern: aggregate
/// over the selected sample set and drop rows with no reads in that set.
enum TwelveSRowAggregator {

    /// Sum of a target row's exact reads across the selected samples.
    static func totalExactReads(
        _ row: TwelveSScientificNameCountRow,
        selected: Set<String>
    ) -> Int {
        row.sampleCounts.reduce(0) { acc, entry in
            selected.contains(entry.key) ? acc + entry.value : acc
        }
    }

    /// Largest per-sample percentage among the selected samples.
    static func maxSamplePercent(
        _ row: TwelveSScientificNameCountRow,
        selected: Set<String>
    ) -> Double {
        row.sampleCounts.reduce(0) { best, entry in
            guard selected.contains(entry.key),
                  let denominator = row.sampleExactReadTotals[entry.key], denominator > 0
            else { return best }
            return max(best, Double(entry.value) / Double(denominator) * 100)
        }
    }

    /// Whether a target row has any reads in the selected samples.
    static func includesTarget(
        _ row: TwelveSScientificNameCountRow,
        selected: Set<String>
    ) -> Bool {
        row.sampleCounts.contains { selected.contains($0.key) && $0.value > 0 }
    }

    /// Sum of an unresolved cluster's reads across the selected samples.
    static func selectedReadCount(
        _ row: TwelveSUnresolvedSequence,
        selected: Set<String>
    ) -> Int {
        row.sampleCounts.reduce(0) { acc, entry in
            selected.contains(entry.key) ? acc + entry.value : acc
        }
    }

    /// Whether an unresolved cluster has any reads in the selected samples.
    static func includesUnresolved(
        _ row: TwelveSUnresolvedSequence,
        selected: Set<String>
    ) -> Bool {
        row.sampleCounts.contains { selected.contains($0.key) && $0.value > 0 }
    }
}

/// A 12S sample entry for the shared `ClassifierSamplePickerView`, surfacing the
/// per-sample exact-read count as the picker metric.
struct TwelveSSampleEntry: ClassifierSampleEntry {
    let id: String
    let displayName: String
    let exactReads: Int

    var metricLabel: String { "reads" }
    var metricValue: String { formatReadCount(exactReads) }
}
