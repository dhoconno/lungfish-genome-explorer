// FASTQDatasetStatistics+Sequences.swift - Statistics of sequences that carry no measured quality scores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQDatasetStatistics {

    /// Whether these statistics were measured from the reads.
    ///
    /// Before Phase 3.0 an ONT import, a demultiplex manifest and a merge stored statistics that knew only the read
    /// and base counts, with 0 for every length and score. A record that counts reads and gives the longest of them 0
    /// bases is one of those, and a viewer measures the reads instead of showing it (walk WF-8).
    public var isMeasured: Bool {
        readCount == 0 || maxReadLength > 0
    }

    /// These statistics with the score fields cleared, for reads whose scores were made up, such as the synthetic
    /// scores a FASTA bridge writes. The empty score histogram says no score was measured.
    public var withoutQualities: FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: readCount, baseCount: baseCount,
            meanReadLength: meanReadLength, minReadLength: minReadLength, maxReadLength: maxReadLength,
            medianReadLength: medianReadLength, n50ReadLength: n50ReadLength,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: gcContent,
            readLengthHistogram: readLengthHistogram, qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }

    /// Measures the records of a FASTA file, plain or gzip. Counts, lengths and GC are measured. A FASTA record
    /// holds no scores, so the score fields are 0 and the score histogram is empty.
    public static func measuringFASTA(at url: URL) throws -> FASTQDatasetStatistics {
        var accumulator = SequenceLengthAccumulator()
        try url.forEachLineAutoDecompressing { accumulator.consume($0) }
        return accumulator.finish()
    }

    /// Measures the records of FASTA text held in memory, as `measuringFASTA(at:)` does for a file.
    public static func measuringFASTA(text: String) -> FASTQDatasetStatistics {
        var accumulator = SequenceLengthAccumulator()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            accumulator.consume(line)
        }
        return accumulator.finish()
    }
}

/// Adds up FASTA records line by line: a `>` line starts a record and every other line adds to its sequence.
private struct SequenceLengthAccumulator {
    private var lengthHistogram: [Int: Int] = [:]
    private var readCount = 0
    private var baseCount: Int64 = 0
    private var gcCount: Int64 = 0
    private var currentLength = 0
    private var inRecord = false

    mutating func consume<Line: StringProtocol>(_ rawLine: Line) {
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
        if line.hasPrefix(">") {
            closeRecord()
            inRecord = true
            return
        }
        guard inRecord else { return }
        for byte in line.utf8 where byte != 0x20 && byte != 0x09 {
            currentLength += 1
            let upper = byte & 0xDF
            if upper == 0x47 || upper == 0x43 { gcCount += 1 }
        }
    }

    private mutating func closeRecord() {
        guard inRecord else { return }
        readCount += 1
        baseCount += Int64(currentLength)
        lengthHistogram[currentLength, default: 0] += 1
        currentLength = 0
    }

    mutating func finish() -> FASTQDatasetStatistics {
        closeRecord()
        inRecord = false
        guard readCount > 0 else { return .empty }
        let lengths = lengthHistogram.keys
        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: Double(baseCount) / Double(readCount),
            minReadLength: lengths.min() ?? 0,
            maxReadLength: lengths.max() ?? 0,
            medianReadLength: FASTQStatisticsCollector.computeMedianFromHistogram(lengthHistogram, totalCount: readCount),
            n50ReadLength: FASTQStatisticsCollector.computeN50FromHistogram(lengthHistogram, totalBases: baseCount),
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0,
            gcContent: baseCount > 0 ? Double(gcCount) / Double(baseCount) : 0,
            readLengthHistogram: lengthHistogram,
            qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }
}
