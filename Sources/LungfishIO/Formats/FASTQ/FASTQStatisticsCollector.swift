// FASTQStatisticsCollector.swift - Streaming FASTQ statistics without memory retention
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Per-Position Quality Summary

/// Quality statistics for a single base position across all reads.
///
/// Used to render FastQC-style per-position quality boxplots.
public struct PositionQualitySummary: Sendable, Codable, Equatable {
    /// 0-based position in the read.
    public let position: Int
    /// Mean quality at this position.
    public let mean: Double
    /// Median quality (50th percentile).
    public let median: Double
    /// Lower quartile (25th percentile).
    public let lowerQuartile: Double
    /// Upper quartile (75th percentile).
    public let upperQuartile: Double
    /// 10th percentile.
    public let percentile10: Double
    /// 90th percentile.
    public let percentile90: Double

    public init(
        position: Int, mean: Double, median: Double,
        lowerQuartile: Double, upperQuartile: Double,
        percentile10: Double, percentile90: Double
    ) {
        self.position = position
        self.mean = mean
        self.median = median
        self.lowerQuartile = lowerQuartile
        self.upperQuartile = upperQuartile
        self.percentile10 = percentile10
        self.percentile90 = percentile90
    }
}

// MARK: - Dataset Statistics

/// Comprehensive statistics for a FASTQ dataset, computed by streaming.
///
/// Includes summary metrics, quality metrics, and distribution data
/// for rendering histograms and boxplots.
public struct FASTQDatasetStatistics: Sendable, Codable, Equatable {

    // MARK: Summary

    /// Total number of reads.
    public let readCount: Int
    /// Total number of bases across all reads.
    public let baseCount: Int64
    /// Mean read length.
    public let meanReadLength: Double
    /// Minimum read length.
    public let minReadLength: Int
    /// Maximum read length.
    public let maxReadLength: Int
    /// Median read length (from histogram).
    public let medianReadLength: Int
    /// N50 read length.
    public let n50ReadLength: Int

    // MARK: Quality

    /// Mean quality score across all bases.
    public let meanQuality: Double
    /// Percentage of bases with quality >= 20.
    public let q20Percentage: Double
    /// Percentage of bases with quality >= 30.
    public let q30Percentage: Double
    /// GC content as a fraction (0.0–1.0).
    public let gcContent: Double

    // MARK: Distributions

    /// Read length histogram: length → count.
    public let readLengthHistogram: [Int: Int]
    /// Quality score histogram: quality value → count across all bases.
    public let qualityScoreHistogram: [UInt8: Int]
    /// Per-position quality summaries for boxplot rendering.
    public let perPositionQuality: [PositionQualitySummary]

    public init(
        readCount: Int, baseCount: Int64,
        meanReadLength: Double, minReadLength: Int, maxReadLength: Int,
        medianReadLength: Int, n50ReadLength: Int,
        meanQuality: Double, q20Percentage: Double, q30Percentage: Double,
        gcContent: Double,
        readLengthHistogram: [Int: Int],
        qualityScoreHistogram: [UInt8: Int],
        perPositionQuality: [PositionQualitySummary]
    ) {
        self.readCount = readCount
        self.baseCount = baseCount
        self.meanReadLength = meanReadLength
        self.minReadLength = minReadLength
        self.maxReadLength = maxReadLength
        self.medianReadLength = medianReadLength
        self.n50ReadLength = n50ReadLength
        self.meanQuality = meanQuality
        self.q20Percentage = q20Percentage
        self.q30Percentage = q30Percentage
        self.gcContent = gcContent
        self.readLengthHistogram = readLengthHistogram
        self.qualityScoreHistogram = qualityScoreHistogram
        self.perPositionQuality = perPositionQuality
    }

    /// Placeholder statistics with known read/base counts but no quality data.
    /// Used for virtual demux bundles where full statistics aren't yet computed.
    public static func placeholder(readCount: Int, baseCount: Int64) -> FASTQDatasetStatistics {
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

    /// Empty statistics for an empty dataset.
    public static let empty = FASTQDatasetStatistics(
        readCount: 0, baseCount: 0,
        meanReadLength: 0, minReadLength: 0, maxReadLength: 0,
        medianReadLength: 0, n50ReadLength: 0,
        meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
        readLengthHistogram: [:], qualityScoreHistogram: [:],
        perPositionQuality: []
    )
}

// MARK: - Statistics Collector

/// Streaming FASTQ statistics collector that processes records one at a time.
///
/// Accumulates statistics across an entire FASTQ file in a single pass
/// without retaining individual records in memory. Suitable for files
/// with millions of reads.
///
/// ```swift
/// let collector = FASTQStatisticsCollector()
/// for try await record in reader.records(from: url) {
///     collector.process(record)
/// }
/// let stats = collector.finalize()
/// ```
public final class FASTQStatisticsCollector {

    // MARK: Accumulators

    private var readCount: Int = 0
    private var baseCount: Int64 = 0
    private var gcCount: Int64 = 0
    private var q20Count: Int64 = 0
    private var q30Count: Int64 = 0
    private var qualitySum: Int64 = 0
    private var minReadLength: Int = Int.max
    private var maxReadLength: Int = 0

    /// Read length → count.
    private var lengthHistogram: [Int: Int] = [:]

    /// Quality score (0-93) → count across all bases.
    private var qualityHistogram: [UInt8: Int] = [:]

    /// Per-position quality histograms. Each element is a 94-element array
    /// (indices 0-93) counting how many bases at that position had each quality score.
    /// Grows dynamically as longer reads are encountered.
    private var positionQualityHistograms: [[Int]] = []

    /// Maximum number of positions to track for per-position quality.
    /// Beyond this, per-position data is not recorded (saves memory for
    /// long-read datasets where per-position plots are less meaningful).
    private static let maxPositionsTracked = 1000

    public init() {}

    // MARK: - Processing

    /// Process a single FASTQ record, accumulating its statistics.
    ///
    /// - Parameter record: The FASTQ record to process.
    public func process(_ record: FASTQRecord) {
        let length = record.length
        readCount += 1
        baseCount += Int64(length)

        // Length tracking
        if length < minReadLength { minReadLength = length }
        if length > maxReadLength { maxReadLength = length }
        lengthHistogram[length, default: 0] += 1

        // Sequence content: GC count
        for byte in record.sequence.utf8 {
            let upper = byte & 0xDF  // uppercase
            if upper == 0x47 || upper == 0x43 { // G or C
                gcCount += 1
            }
        }

        // Quality analysis
        for i in 0..<record.quality.count {
            let q = record.quality.qualityAt(i)
            qualitySum += Int64(q)
            if q >= 20 { q20Count += 1 }
            if q >= 30 { q30Count += 1 }

            // Global quality histogram
            qualityHistogram[q, default: 0] += 1

            // Per-position histogram (capped)
            if i < Self.maxPositionsTracked {
                // Grow position histograms as needed
                while positionQualityHistograms.count <= i {
                    positionQualityHistograms.append([Int](repeating: 0, count: 94))
                }
                let clampedQ = Int(min(q, 93))
                positionQualityHistograms[i][clampedQ] += 1
            }
        }
    }

    // MARK: - Finalization

    /// Compute final statistics from accumulated data.
    ///
    /// - Returns: Complete dataset statistics.
    public func finalize() -> FASTQDatasetStatistics {
        guard readCount > 0 else { return .empty }

        let meanLength = Double(baseCount) / Double(readCount)
        let meanQ = baseCount > 0 ? Double(qualitySum) / Double(baseCount) : 0
        let q20Pct = baseCount > 0 ? Double(q20Count) / Double(baseCount) * 100 : 0
        let q30Pct = baseCount > 0 ? Double(q30Count) / Double(baseCount) * 100 : 0
        let gc = baseCount > 0 ? Double(gcCount) / Double(baseCount) : 0

        let medianLength = Self.computeMedianFromHistogram(lengthHistogram, totalCount: readCount)
        let n50Length = Self.computeN50FromHistogram(lengthHistogram, totalBases: baseCount)

        let perPositionSummaries = Self.computePerPositionSummaries(
            positionQualityHistograms
        )

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: meanLength,
            minReadLength: minReadLength == Int.max ? 0 : minReadLength,
            maxReadLength: maxReadLength,
            medianReadLength: medianLength,
            n50ReadLength: n50Length,
            meanQuality: meanQ,
            q20Percentage: q20Pct,
            q30Percentage: q30Pct,
            gcContent: gc,
            readLengthHistogram: lengthHistogram,
            qualityScoreHistogram: qualityHistogram,
            perPositionQuality: perPositionSummaries
        )
    }

    // MARK: - Histogram Computations

    /// Compute the median value from a histogram (value → count).
    static func computeMedianFromHistogram(_ histogram: [Int: Int], totalCount: Int) -> Int {
        guard totalCount > 0 else { return 0 }
        let target = (totalCount + 1) / 2
        var cumulative = 0
        for key in histogram.keys.sorted() {
            cumulative += histogram[key]!
            if cumulative >= target {
                return key
            }
        }
        return 0
    }

    /// Compute N50 from a read length histogram.
    ///
    /// N50 is the length such that reads of this length or longer cover
    /// at least 50% of total bases.
    static func computeN50FromHistogram(_ histogram: [Int: Int], totalBases: Int64) -> Int {
        guard totalBases > 0 else { return 0 }
        let halfBases = totalBases / 2
        var cumulative: Int64 = 0
        // Sort by length descending to accumulate from longest reads
        for key in histogram.keys.sorted(by: >) {
            let count = histogram[key]!
            cumulative += Int64(key) * Int64(count)
            if cumulative >= halfBases {
                return key
            }
        }
        return 0
    }

    /// Compute per-position quality summaries from accumulated histograms.
    static func computePerPositionSummaries(
        _ histograms: [[Int]]
    ) -> [PositionQualitySummary] {
        var summaries: [PositionQualitySummary] = []
        summaries.reserveCapacity(histograms.count)

        for (pos, histogram) in histograms.enumerated() {
            let total = histogram.reduce(0, +)
            guard total > 0 else { continue }

            // Mean
            var qualitySum: Int64 = 0
            for q in 0..<histogram.count {
                qualitySum += Int64(q) * Int64(histogram[q])
            }
            let mean = Double(qualitySum) / Double(total)

            // Percentiles from histogram
            let p10 = percentileFromHistogram(histogram, total: total, percentile: 0.10)
            let p25 = percentileFromHistogram(histogram, total: total, percentile: 0.25)
            let p50 = percentileFromHistogram(histogram, total: total, percentile: 0.50)
            let p75 = percentileFromHistogram(histogram, total: total, percentile: 0.75)
            let p90 = percentileFromHistogram(histogram, total: total, percentile: 0.90)

            summaries.append(PositionQualitySummary(
                position: pos,
                mean: mean,
                median: p50,
                lowerQuartile: p25,
                upperQuartile: p75,
                percentile10: p10,
                percentile90: p90
            ))
        }
        return summaries
    }

    /// Compute a percentile value from a quality histogram (0-93 bins).
    private static func percentileFromHistogram(
        _ histogram: [Int], total: Int, percentile: Double
    ) -> Double {
        guard total > 0 else { return 0 }
        let target = Double(total) * percentile
        var cumulative = 0
        for q in 0..<histogram.count {
            cumulative += histogram[q]
            if Double(cumulative) >= target {
                return Double(q)
            }
        }
        return 0
    }
}
