// GFF3Statistics.swift - Statistics about a GFF3 file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - GFF3 Statistics

/// Statistics about a GFF3 file.
public struct GFF3Statistics: Sendable {

    /// Total number of features
    public let featureCount: Int

    /// Features by type
    public let featuresByType: [String: Int]

    /// Features by sequence
    public let featuresBySequence: [String: Int]

    /// Unique sequence IDs
    public var sequenceCount: Int { featuresBySequence.count }

    /// Computes statistics from features.
    public init(features: [GFF3Feature]) {
        self.featureCount = features.count

        var byType: [String: Int] = [:]
        var bySeq: [String: Int] = [:]

        for feature in features {
            byType[feature.type, default: 0] += 1
            bySeq[feature.seqid, default: 0] += 1
        }

        self.featuresByType = byType
        self.featuresBySequence = bySeq
    }
}
