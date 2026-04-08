// MarkdupResult.swift - Result and error types for MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Outcome of a markdup operation on a single BAM file.
public struct MarkdupResult: Sendable {
    /// Absolute path to the BAM that was processed (unchanged after in-place replacement).
    public let bamURL: URL
    /// True if the BAM already had a `@PG ID:samtools.markdup` header and was skipped.
    public let wasAlreadyMarkduped: Bool
    /// Total mapped reads after markdup (samtools view -c -F 0x004).
    public let totalReads: Int
    /// Reads flagged as duplicates (totalReads - nonDuplicateReads).
    public let duplicateReads: Int
    /// Wall-clock time for the full pipeline including indexing.
    public let durationSeconds: Double

    public init(
        bamURL: URL,
        wasAlreadyMarkduped: Bool,
        totalReads: Int,
        duplicateReads: Int,
        durationSeconds: Double
    ) {
        self.bamURL = bamURL
        self.wasAlreadyMarkduped = wasAlreadyMarkduped
        self.totalReads = totalReads
        self.duplicateReads = duplicateReads
        self.durationSeconds = durationSeconds
    }
}

/// Errors from `MarkdupService` operations.
public enum MarkdupError: Error, LocalizedError, Sendable {
    case toolNotFound
    case fileNotFound(URL)
    case pipelineFailed(stage: String, stderr: String)
    case indexFailed(stderr: String)
    case corruptOutput(reason: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "samtools binary not found"
        case .fileNotFound(let url):
            return "BAM file not found: \(url.path)"
        case .pipelineFailed(let stage, let stderr):
            return "markdup pipeline failed at stage '\(stage)': \(stderr)"
        case .indexFailed(let stderr):
            return "samtools index failed: \(stderr)"
        case .corruptOutput(let reason):
            return "markdup produced corrupt output: \(reason)"
        }
    }
}
