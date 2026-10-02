// DepthCappedReadSketch.swift - Depth-capped read set returned for a window
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// Result of ``AlignmentDataProvider/fetchDepthCappedReads(chromosome:start:end:excludeFlags:minMapQ:readGroups:maxDisplayedDepth:maxReads:maxDisplayedBases:subsampleSeed:)``.
public struct DepthCappedReadSketch: Sendable {
    /// Reads to display, each exactly once.
    public let reads: [AlignedRead]
    /// Reads believed to be in the window: exact when `isEstimated` is false.
    public let estimatedTotalReads: Int
    /// True when `estimatedTotalReads` is an estimate (sampling or truncation).
    public let isEstimated: Bool
    /// The bin plan that produced the fetch.
    public let plan: ReadDepthCapPlan
    /// True when the read ceiling or byte budget stopped the fetch early.
    public let transportTruncated: Bool
    /// Number of `samtools` invocations, including the depth query.
    public let samtoolsCalls: Int

    /// The cap actually applied (may be below the requested cap when the
    /// transport budget forced it down).
    public var maxDisplayedDepth: Int { plan.maxDisplayedDepth }
    /// True when at least one region of the window was thinned.
    public var isDepthCapped: Bool { plan.isSampled }
}
