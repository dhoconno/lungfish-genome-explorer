// AlignmentReadSketch.swift - A bounded, representative read set for fast first-pass alignment
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// A bounded, representative read set for fast first-pass alignment rendering.
public struct AlignmentReadSketch: Sendable {
    public let reads: [AlignedRead]
    public let estimatedTotalReads: Int
    public let targetReads: Int
    public let isSubsampled: Bool
    public let transportTruncated: Bool

    public init(reads: [AlignedRead], estimatedTotalReads: Int, targetReads: Int, isSubsampled: Bool, transportTruncated: Bool = false) {
        self.reads = reads
        self.estimatedTotalReads = estimatedTotalReads
        self.targetReads = targetReads
        self.isSubsampled = isSubsampled
        self.transportTruncated = transportTruncated
    }
}
