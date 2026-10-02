// AlignmentMetadataError.swift - Errors from alignment metadata database operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - Error Types

/// Errors from alignment metadata database operations.
public enum AlignmentMetadataError: Error, LocalizedError {
    case openFailed(URL, String)
    case schemaFailed(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let url, let msg):
            return "Cannot open alignment database at \(url.lastPathComponent): \(msg)"
        case .schemaFailed(let msg):
            return "Failed to create alignment database schema: \(msg)"
        case .importFailed(let msg):
            return "Failed to import alignment metadata: \(msg)"
        }
    }
}
