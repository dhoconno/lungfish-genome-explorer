// GATKPipelineExecutionError.swift - Errors thrown by the GATK pipeline executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum GATKPipelineExecutionError: Error, LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, provenanceURL: URL)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let exitCode, let provenanceURL):
            return "GATK command failed with exit code \(exitCode). Provenance was written to \(provenanceURL.path)."
        }
    }
}
