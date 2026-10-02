// GFF3WriterError.swift - Errors that can occur when writing GFF3 files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - GFF3WriterError

/// Errors that can occur when writing GFF3 files.
public enum GFF3WriterError: Error, LocalizedError, Sendable {

    /// File is not open for writing
    case fileNotOpen

    /// Failed to write to file
    case writeFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotOpen:
            return "GFF3 file not open for writing"
        case .writeFailed(let error):
            return "Failed to write GFF3 file: \(error.localizedDescription)"
        }
    }
}
