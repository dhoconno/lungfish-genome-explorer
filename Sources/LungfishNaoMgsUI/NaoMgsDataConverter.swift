// NaoMgsDataConverter.swift - Data conversion utilities for NAO-MGS result viewer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - NaoMgsAccessionSummary

/// Per-accession read statistics for the detail pane.
///
/// Groups hits by GenBank accession within a taxon, providing read counts
/// and coverage information for each reference genome.
public struct NaoMgsAccessionSummary: Sendable {
    /// GenBank accession (e.g., "KU162869.1").
    public let accession: String

    /// Number of reads aligned to this accession.
    public let readCount: Int

    /// Estimated PCR duplicate reads for this accession.
    public let pcrDuplicateCount: Int

    /// Estimated unique reads (`readCount - pcrDuplicateCount`).
    public var uniqueReadCount: Int {
        max(0, readCount - pcrDuplicateCount)
    }

    /// Estimated reference genome length (max refEnd across all hits, or max refStart + readLength).
    public let referenceLength: Int

    /// Per-window coverage depth for sparkline rendering.
    public let coverageWindows: [Int]

    /// Number of covered positions (non-zero coverage).
    public let coveredBases: Int

    /// Fraction of reference covered (0.0 to 1.0).
    public var coverageFraction: Double {
        guard referenceLength > 0 else { return 0 }
        return Double(coveredBases) / Double(referenceLength)
    }
}

// MARK: - NaoMgsDataConverter

/// Converts NAO-MGS virus hits into structures suitable for the result viewer.
///
/// All methods are pure functions operating on immutable data. They are designed
/// to be called from the main actor when configuring view components.
///
/// ## Design Rationale
///
/// NAO-MGS data comes as flat per-read records. The viewer needs hierarchical
/// views (taxon -> accession -> reads), coverage plots, and histograms. This
/// converter bridges the gap between the parser output and the display layer.
public enum NaoMgsDataConverter {

    // MARK: - Taxonomy Grouping

    /// Groups hits by taxonomy ID and returns them as a dictionary.
    ///
    /// - Parameter hits: All virus hits from the result.
    /// - Returns: Dictionary keyed by taxonomy ID with arrays of hits.
    public static func groupByTaxon(_ hits: [NaoMgsVirusHit]) -> [Int: [NaoMgsVirusHit]] {
        var groups: [Int: [NaoMgsVirusHit]] = [:]
        for hit in hits {
            groups[hit.taxId, default: []].append(hit)
        }
        return groups
    }

    // MARK: - Accession Grouping

    /// Groups hits by GenBank accession for coverage analysis.
    ///
    /// Only includes hits with non-empty accession identifiers.
    ///
    /// - Parameter hits: Virus hits to group (typically for a single taxon).
    /// - Returns: Dictionary keyed by accession with arrays of hits.
    public static func groupByAccession(_ hits: [NaoMgsVirusHit]) -> [String: [NaoMgsVirusHit]] {
        var groups: [String: [NaoMgsVirusHit]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            groups[hit.subjectSeqId, default: []].append(hit)
        }
        return groups
    }

    // MARK: - Accession Summaries

    /// Builds per-accession summaries for the selected taxon's detail pane.
    ///
    /// Each summary includes read count, estimated reference length, and
    /// windowed coverage depth for sparkline rendering.
    ///
    /// - Parameters:
    ///   - hits: All hits for a single taxon.
    ///   - windowCount: Number of coverage windows for sparkline (default 100).
    /// - Returns: Accession summaries sorted by unique read count descending.
    public static func buildAccessionSummaries(
        hits: [NaoMgsVirusHit],
        windowCount: Int = 100
    ) -> [NaoMgsAccessionSummary] {
        let byAccession = groupByAccession(hits)

        return byAccession.map { accession, accHits in
            // Estimate reference length from the maximum observed position
            let maxRefEnd = accHits.reduce(0) { current, hit in
                let end = hit.refEnd > 0
                    ? hit.refEnd
                    : hit.refStart + max(hit.readSequence.count, hit.queryLength)
                return max(current, end)
            }
            let refLength = max(maxRefEnd, 1)

            // Compute windowed coverage
            let windows = computeCoverage(hits: accHits, referenceLength: refLength, windowCount: windowCount)

            // Count covered bases (non-zero windows scaled to reference)
            let windowSize = max(refLength / windowCount, 1)
            let coveredBases = windows.enumerated().reduce(0) { total, pair in
                total + (pair.element > 0 ? windowSize : 0)
            }

            // PCR duplicate estimate: same start/end/strand on the same accession.
            var duplicateGroups: [String: Int] = [:]
            for hit in accHits {
                let strand = hit.isReverseComplement ? "R" : "F"
                let readLength = hit.queryLength > 0 ? hit.queryLength : max(0, hit.readSequence.count)
                let inferredRefEnd = max(hit.refEnd, hit.refStart + max(1, readLength))
                let key = "\(hit.refStart)|\(inferredRefEnd)|\(strand)"
                duplicateGroups[key, default: 0] += 1
            }
            let duplicateCount = duplicateGroups.values.reduce(0) { sum, count in
                sum + max(0, count - 1)
            }

            return NaoMgsAccessionSummary(
                accession: accession,
                readCount: accHits.count,
                pcrDuplicateCount: duplicateCount,
                referenceLength: refLength,
                coverageWindows: windows,
                coveredBases: min(coveredBases, refLength)
            )
        }.sorted {
            if $0.uniqueReadCount == $1.uniqueReadCount {
                return $0.readCount > $1.readCount
            }
            return $0.uniqueReadCount > $1.uniqueReadCount
        }
    }

    // MARK: - Coverage Computation

    /// Computes per-window coverage depth for a set of hits against a reference.
    ///
    /// Divides the reference into `windowCount` equal-sized windows and counts
    /// the number of reads overlapping each window.
    ///
    /// - Parameters:
    ///   - hits: Virus hits for a single accession.
    ///   - referenceLength: Estimated reference genome length in bases.
    ///   - windowCount: Number of windows to divide the reference into.
    /// - Returns: Array of coverage depths, one per window.
    public static func computeCoverage(
        hits: [NaoMgsVirusHit],
        referenceLength: Int,
        windowCount: Int = 100
    ) -> [Int] {
        guard referenceLength > 0, windowCount > 0 else { return [] }

        let windowSize = max(referenceLength / windowCount, 1)
        var windows = [Int](repeating: 0, count: windowCount)

        for hit in hits {
            let readLen = hit.readSequence.isEmpty ? hit.queryLength : hit.readSequence.count
            let effectiveReadLen = readLen > 0 ? readLen : 150 // default read length estimate
            let start = hit.refStart
            let end = hit.refEnd > 0 ? hit.refEnd : (start + effectiveReadLen)

            let startWindow = min(start / windowSize, windowCount - 1)
            let endWindow = min(end / windowSize, windowCount - 1)

            for w in startWindow...endWindow {
                windows[w] += 1
            }
        }

        return windows
    }

    // MARK: - Edit Distance Distribution

    /// Computes the distribution of edit distances for histogram rendering.
    ///
    /// Returns an array of (editDistance, count) tuples sorted by edit distance.
    ///
    /// - Parameter hits: Virus hits to analyze.
    /// - Returns: Array of (editDistance, count) pairs sorted ascending by distance.
    public static func editDistanceDistribution(_ hits: [NaoMgsVirusHit]) -> [(distance: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for hit in hits {
            counts[hit.editDistance, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (distance: $0.key, count: $0.value) }
    }

    // MARK: - Fragment Length Distribution

    /// Computes the distribution of fragment lengths for histogram rendering.
    ///
    /// Filters out zero-length fragments (unpaired or missing data).
    /// Returns an array of (length, count) tuples sorted by fragment length.
    ///
    /// - Parameter hits: Virus hits to analyze.
    /// - Returns: Array of (fragmentLength, count) pairs sorted ascending.
    public static func fragmentLengthDistribution(_ hits: [NaoMgsVirusHit]) -> [(length: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for hit in hits where hit.fragmentLength > 0 {
            counts[hit.fragmentLength, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (length: $0.key, count: $0.value) }
    }

    // MARK: - Pair Status Distribution

    /// Computes the distribution of pair status codes.
    ///
    /// - Parameter hits: Virus hits to analyze.
    /// - Returns: Array of (status, count) pairs sorted by count descending.
    public static func pairStatusDistribution(_ hits: [NaoMgsVirusHit]) -> [(status: String, count: Int)] {
        var counts: [String: Int] = [:]
        for hit in hits where !hit.pairStatus.isEmpty {
            counts[hit.pairStatus, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (status: $0.key, count: $0.value) }
    }

    // MARK: - BLAST Read Selection

    /// Selects reads for BLAST verification using a coverage-stratified strategy.
    ///
    /// The strategy ensures reads are drawn from across the reference genome,
    /// not just from high-coverage regions. This provides better verification
    /// coverage and catches edge cases at genome boundaries.
    ///
    /// ## Selection Algorithm
    ///
    /// 1. Group reads by genome quartile (0-25%, 25-50%, 50-75%, 75-100%).
    /// 2. From each quartile, pick reads with lowest edit distance first
    ///    (highest confidence alignments).
    /// 3. Fill remaining slots with highest edit distance reads (to test edge cases).
    /// 4. If a quartile has fewer reads than its quota, redistribute to others.
    ///
    /// - Parameters:
    ///   - hits: All virus hits for the target taxon.
    ///   - count: Desired number of reads to select.
    ///   - referenceLength: Estimated reference length for quartile computation.
    ///     If zero, uses the maximum observed refStart across all hits.
    /// - Returns: Selected reads, up to `count` in number.
    public static func selectBlastReads(
        hits: [NaoMgsVirusHit],
        count: Int,
        referenceLength: Int = 0
    ) -> [NaoMgsVirusHit] {
        guard !hits.isEmpty else { return [] }

        let targetCount = min(count, hits.count)
        guard targetCount > 0 else { return [] }

        // If we want all hits or nearly all, just return them
        if targetCount >= hits.count {
            return hits
        }

        // Determine reference length for quartile boundaries
        let effectiveRefLength: Int
        if referenceLength > 0 {
            effectiveRefLength = referenceLength
        } else {
            let maxPos = hits.reduce(0) { max($0, $1.refStart + $1.readSequence.count) }
            effectiveRefLength = max(maxPos, 1)
        }

        // Divide into 4 quartiles by genome position
        let quartileSize = effectiveRefLength / 4
        var quartiles: [[NaoMgsVirusHit]] = [[], [], [], []]

        for hit in hits {
            let quartileIndex = quartileSize > 0
                ? min(hit.refStart / quartileSize, 3)
                : 0
            quartiles[quartileIndex].append(hit)
        }

        // Sort each quartile by edit distance (lowest first for best alignments)
        for i in 0..<4 {
            quartiles[i].sort { $0.editDistance < $1.editDistance }
        }

        // Allocate quota per quartile
        let baseQuota = targetCount / 4
        let remainder = targetCount % 4
        var quotas = [Int](repeating: baseQuota, count: 4)
        for i in 0..<remainder {
            quotas[i] += 1
        }

        var selected: [NaoMgsVirusHit] = []
        var overflow = 0

        // First pass: take from each quartile up to its quota
        for i in 0..<4 {
            let available = quartiles[i]
            let take = min(quotas[i], available.count)
            if take > 0 {
                // Take half from lowest edit distance (best), half from highest (edge cases)
                let bestCount = (take + 1) / 2
                let edgeCount = take - bestCount

                // Best reads (lowest edit distance, already sorted ascending)
                selected.append(contentsOf: available.prefix(bestCount))

                // Edge case reads (highest edit distance)
                if edgeCount > 0 {
                    let edgeStart = max(available.count - edgeCount, bestCount)
                    selected.append(contentsOf: available[edgeStart...])
                }
            }
            overflow += max(0, quotas[i] - available.count)
        }

        // Second pass: fill overflow from quartiles with remaining reads
        if overflow > 0 {
            let selectedIds = Set(selected.map(\.seqId))
            let remaining = hits.filter { !selectedIds.contains($0.seqId) }
                .sorted { $0.editDistance < $1.editDistance }
            selected.append(contentsOf: remaining.prefix(overflow))
        }

        return Array(selected.prefix(targetCount))
    }
}
