// FASTQStatistics.swift - Statistics for a collection of FASTQ records
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - Statistics

/// Statistics for a collection of FASTQ records.
public struct FASTQStatistics: Sendable {

    /// Total number of reads
    public let readCount: Int

    /// Total number of bases
    public let baseCount: Int

    /// Mean read length
    public let meanReadLength: Double

    /// Minimum read length
    public let minReadLength: Int

    /// Maximum read length
    public let maxReadLength: Int

    /// Mean quality score
    public let meanQuality: Double

    /// Percentage of bases with Q >= 20
    public let q20Percentage: Double

    /// Percentage of bases with Q >= 30
    public let q30Percentage: Double

    /// GC content percentage
    public let gcContent: Double

    /// Computes statistics from FASTQ records.
    ///
    /// - Parameter records: Array of FASTQ records
    public init(records: [FASTQRecord]) {
        self.readCount = records.count

        if records.isEmpty {
            self.baseCount = 0
            self.meanReadLength = 0
            self.minReadLength = 0
            self.maxReadLength = 0
            self.meanQuality = 0
            self.q20Percentage = 0
            self.q30Percentage = 0
            self.gcContent = 0
            return
        }

        let lengths = records.map { $0.length }
        self.baseCount = lengths.reduce(0, +)
        self.meanReadLength = Double(baseCount) / Double(readCount)
        self.minReadLength = lengths.min() ?? 0
        self.maxReadLength = lengths.max() ?? 0

        // Quality statistics
        let qualitySum = records.reduce(0.0) { $0 + $1.quality.meanQuality }
        self.meanQuality = qualitySum / Double(readCount)

        var totalBases = 0
        var q20Bases = 0
        var q30Bases = 0
        var gcBases = 0

        for record in records {
            totalBases += record.length
            for (i, char) in record.sequence.uppercased().enumerated() {
                let qual = record.quality.qualityAt(i)
                if qual >= 20 { q20Bases += 1 }
                if qual >= 30 { q30Bases += 1 }
                if char == "G" || char == "C" { gcBases += 1 }
            }
        }

        self.q20Percentage = totalBases > 0 ? Double(q20Bases) / Double(totalBases) * 100 : 0
        self.q30Percentage = totalBases > 0 ? Double(q30Bases) / Double(totalBases) * 100 : 0
        self.gcContent = totalBases > 0 ? Double(gcBases) / Double(totalBases) * 100 : 0
    }
}
