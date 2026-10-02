// AlignmentConsensusResult.swift - An evidence-derived consensus projected onto the requested reference
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// An evidence-derived consensus projected onto the requested reference range.
public struct AlignmentConsensusResult: Sendable, Equatable {
    public let sequence: String
    public let referenceLength: Int
    public let allLowDepth: Bool
    /// Staging-only subprocess evidence for a consensus request. Durable output
    /// provenance must copy these records while replacing staging paths.
    public let executionRecords: [AlignmentConsensusExecutionRecord]

    public init(
        sequence: String,
        referenceLength: Int,
        allLowDepth: Bool,
        executionRecords: [AlignmentConsensusExecutionRecord] = []
    ) {
        self.sequence = sequence
        self.referenceLength = referenceLength
        self.allLowDepth = allLowDepth
        self.executionRecords = executionRecords
    }
}
