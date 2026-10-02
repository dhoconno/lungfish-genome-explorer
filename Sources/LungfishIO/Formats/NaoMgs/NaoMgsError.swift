// NaoMgsError.swift - Errors that can occur during NAO-MGS result parsing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - NaoMgsError

/// Errors that can occur during NAO-MGS result parsing.
public enum NaoMgsError: Error, LocalizedError, Sendable {
    /// The input file was not found.
    case fileNotFound(URL)

    /// The TSV header is missing or does not contain expected columns.
    case invalidHeader(String)

    /// A data row could not be parsed.
    case malformedRow(lineNumber: Int, reason: String)

    /// The results directory does not contain the expected output files.
    case missingResultFiles(URL)

    /// SAM conversion failed.
    case samConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "NAO-MGS result file not found: \(url.path)"
        case .invalidHeader(let details):
            return "Invalid NAO-MGS TSV header: \(details)"
        case .malformedRow(let line, let reason):
            return "Malformed row at line \(line): \(reason)"
        case .missingResultFiles(let url):
            return "No NAO-MGS result files found in: \(url.path)"
        case .samConversionFailed(let reason):
            return "SAM conversion failed: \(reason)"
        }
    }
}
