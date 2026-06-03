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

/// View-only target row projected from a scientific-name aggregate into one
/// row per sample with non-zero evidence.
struct TwelveSTargetSampleRow: Equatable, Sendable {
    let source: TwelveSScientificNameCountRow
    let sampleID: String
    let sampleDisplayName: String
    let exactReads: Int
    let sampleExactReadTotal: Int

    var scientificName: String { source.scientificName }
    var commonNamesText: String { source.commonNamesText }
    var displayTaxonGroups: [String] { source.displayTaxonGroups }
    var taxids: [String] { source.taxids }
    var targetIDs: [String] { source.targetIDs }
    var referenceTargetCount: Int { source.referenceTargetCount }
    var alternateMatches: [TwelveSAlternateMatch] { source.alternateMatches }
    var potentialMatches: [String] { source.potentialMatches }
    var potentialMatchesText: String { source.potentialMatchesText }
    var samplePercent: Double {
        guard sampleExactReadTotal > 0 else { return 0 }
        return Double(exactReads) / Double(sampleExactReadTotal) * 100
    }

    static func rows(
        from rows: [TwelveSScientificNameCountRow],
        samples: [TwelveSAmpliconSampleResult],
        selected: Set<String>,
        includeZeroReadScientificNames: Set<String> = []
    ) -> [TwelveSTargetSampleRow] {
        let sampleOrder = orderedSampleIDs(samples: samples, rows: rows, selected: selected)
        let sampleOrderIndex = Dictionary(uniqueKeysWithValues: sampleOrder.enumerated().map { ($0.element, $0.offset) })
        let selectedSamples = selected.isEmpty ? Set(sampleOrder) : selected
        let displayNames = Dictionary(uniqueKeysWithValues: samples.map { ($0.sampleID, $0.displayName) })
        var projected: [TwelveSTargetSampleRow] = []

        for row in rows {
            let startCount = projected.count
            let nonZeroCounts = row.sampleCounts
                .filter { selectedSamples.contains($0.key) && $0.value > 0 }
                .sorted { lhs, rhs in
                    let lhsIndex = sampleOrderIndex[lhs.key] ?? Int.max
                    let rhsIndex = sampleOrderIndex[rhs.key] ?? Int.max
                    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
            for (sampleID, count) in nonZeroCounts {
                projected.append(TwelveSTargetSampleRow(
                    source: row,
                    sampleID: sampleID,
                    sampleDisplayName: displayNames[sampleID] ?? sampleID,
                    exactReads: count,
                    sampleExactReadTotal: row.sampleExactReadTotals[sampleID, default: 0]
                ))
            }
            if projected.count == startCount,
               includeZeroReadScientificNames.contains(row.scientificName) {
                let sampleID = sampleOrder.first ?? ""
                projected.append(TwelveSTargetSampleRow(
                    source: row,
                    sampleID: sampleID,
                    sampleDisplayName: displayNames[sampleID] ?? sampleID,
                    exactReads: 0,
                    sampleExactReadTotal: sampleID.isEmpty ? 0 : row.sampleExactReadTotals[sampleID, default: 0]
                ))
            }
        }

        return projected
    }

    private static func orderedSampleIDs(
        samples: [TwelveSAmpliconSampleResult],
        rows: [TwelveSScientificNameCountRow],
        selected: Set<String>
    ) -> [String] {
        let allFromSamples = samples.map(\.sampleID)
        let allFromRows = allFromSamples.isEmpty ? rows.flatMap { Array($0.sampleCounts.keys) } : []
        let ordered = (allFromSamples + allFromRows).reduce(into: [String]()) { result, sampleID in
            guard !sampleID.isEmpty, !result.contains(sampleID) else { return }
            result.append(sampleID)
        }
        let active = selected.isEmpty ? Set(ordered) : selected
        return ordered.filter { active.contains($0) }
    }
}

/// A 12S sample entry for the shared `ClassifierSamplePickerView`, surfacing the
/// per-sample exact-read count as the picker metric.
public struct TwelveSSampleEntry: ClassifierSampleEntry {
    public let id: String
    public let displayName: String
    public let exactReads: Int

    public init(id: String, displayName: String, exactReads: Int) {
        self.id = id
        self.displayName = displayName
        self.exactReads = exactReads
    }

    public var metricLabel: String { "reads" }
    public var metricValue: String { formatReadCount(exactReads) }
}
