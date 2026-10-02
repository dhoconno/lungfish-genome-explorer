// TaxTriageDatabaseError.swift - Errors from TaxTriage database operations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - TaxTriageDatabaseError

/// Errors from TaxTriage database operations.
public enum TaxTriageDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case queryFailed(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open TaxTriage database: \(msg)"
        case .createFailed(let msg): return "Failed to create TaxTriage database: \(msg)"
        case .queryFailed(let msg): return "TaxTriage database query failed: \(msg)"
        case .insertFailed(let msg): return "TaxTriage database insert failed: \(msg)"
        }
    }
}
