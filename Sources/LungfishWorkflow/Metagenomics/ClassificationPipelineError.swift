// ClassificationPipelineError.swift - Errors of the Kraken2 classification and Bracken profiling orchestrator
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ClassificationPipelineError

/// Errors produced during classification pipeline execution.
public enum ClassificationPipelineError: Error, LocalizedError, Sendable {

    /// Kraken2 exited with a non-zero status.
    case kraken2Failed(exitCode: Int32, stderr: String)

    /// Bracken exited with a non-zero status.
    case brackenFailed(exitCode: Int32, stderr: String)

    /// The kraken2 tool is not installed in the conda environment.
    case kraken2NotInstalled

    /// The bracken tool is not installed in the conda environment.
    case brackenNotInstalled

    /// The kreport output file was not produced by kraken2.
    case kreportNotProduced(URL)

    /// The result sidecar could not be persisted.
    case resultSidecarSaveFailed(URL, String)

    /// Could not determine the kraken2 version.
    case versionDetectionFailed

    /// The pipeline was cancelled.
    case cancelled

    /// A strictly interleaved input could not be split into mate files.
    case interleavedSplitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .interleavedSplitFailed(let reason):
            return "Could not split interleaved input for kraken2: \(reason)"
        case .kraken2Failed(let code, let stderr):
            return "kraken2 failed with exit code \(code): \(stderr)"
        case .brackenFailed(let code, let stderr):
            return "bracken failed with exit code \(code): \(stderr)"
        case .kraken2NotInstalled:
            return "kraken2 is not installed. Run: lungfish-cli conda install --pack metagenomics"
        case .brackenNotInstalled:
            return "bracken is not installed. Run: lungfish-cli conda install --pack metagenomics"
        case .kreportNotProduced(let url):
            return "kraken2 did not produce a report file at \(url.path)"
        case .resultSidecarSaveFailed(let url, let reason):
            return "Failed to save classification result sidecar at \(url.path): \(reason)"
        case .versionDetectionFailed:
            return "Could not determine kraken2 version"
        case .cancelled:
            return "Classification pipeline was cancelled"
        }
    }
}
