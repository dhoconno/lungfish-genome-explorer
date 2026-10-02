// SRAError.swift - Errors from SRA operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log

// MARK: - SRA Errors

/// Errors from SRA operations.
public enum SRAError: Error, LocalizedError {
    case toolkitNotFound
    case downloadFailed(String)
    case conversionFailed(String)
    case fetchFailed(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .toolkitNotFound:
            return "SRA Toolkit not found in the managed Lungfish tool environment."
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .conversionFailed(let message):
            return "FASTQ conversion failed: \(message)"
        case .fetchFailed(let message):
            return "Failed to fetch SRA info: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}
