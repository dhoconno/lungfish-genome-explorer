// AlignmentFetchError.swift - Errors from alignment data fetching
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

// MARK: - AlignmentFetchError

/// Errors from alignment data fetching.
public enum AlignmentFetchError: Error, LocalizedError, Sendable {
    case samtoolsNotFound
    case samtoolsFailed(String)
    case invalidRegion(String)
    case consensusCoordinateMismatch
    case consensusCoordinateMismatchWithRecords([AlignmentConsensusExecutionRecord])
    case consensusExecutionFailed([AlignmentConsensusExecutionRecord])
    case timeout

    public var errorDescription: String? {
        switch self {
        case .samtoolsNotFound:
            return "samtools not found in the managed Lungfish tool environment."
        case .samtoolsFailed(let msg):
            return "samtools failed: \(msg)"
        case .invalidRegion(let region):
            return "Invalid region: \(region)"
        case .consensusCoordinateMismatch:
            return "Consensus output does not project exactly onto the requested reference interval."
        case .consensusCoordinateMismatchWithRecords:
            return "Consensus output does not project exactly onto the requested reference interval; execution records are attached."
        case .consensusExecutionFailed(let records):
            let stage = records.last?.stage.rawValue ?? "unknown"
            let stderr = records.last?.stderr ?? ""
            return "Consensus \(stage) stage failed\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .timeout:
            return "samtools timed out"
        }
    }
}
