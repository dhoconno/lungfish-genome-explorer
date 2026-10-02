// SeqkitStatsMetadata.swift - Summary values from seqkit stats -a -T cached in metadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// Summary values from `seqkit stats -a -T` cached in metadata.
public struct SeqkitStatsMetadata: Codable, Sendable, Equatable {
    public let numSeqs: Int
    public let sumLen: Int64
    public let minLen: Int
    public let avgLen: Double
    public let maxLen: Int
    public let q20Percentage: Double
    public let q30Percentage: Double
    public let averageQuality: Double
    public let gcPercentage: Double

    public init(
        numSeqs: Int,
        sumLen: Int64,
        minLen: Int,
        avgLen: Double,
        maxLen: Int,
        q20Percentage: Double,
        q30Percentage: Double,
        averageQuality: Double,
        gcPercentage: Double
    ) {
        self.numSeqs = numSeqs
        self.sumLen = sumLen
        self.minLen = minLen
        self.avgLen = avgLen
        self.maxLen = maxLen
        self.q20Percentage = q20Percentage
        self.q30Percentage = q30Percentage
        self.averageQuality = averageQuality
        self.gcPercentage = gcPercentage
    }
}
