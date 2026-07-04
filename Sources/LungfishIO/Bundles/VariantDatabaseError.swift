// VariantDatabaseError.swift - Error type for the variant database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - Errors

public enum VariantDatabaseError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case createFailed(String)
    case invalidSchema(String)
    case queryFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open variant database: \(msg)"
        case .createFailed(let msg): return "Failed to create variant database: \(msg)"
        case .invalidSchema(let msg): return "Invalid variant database schema: \(msg)"
        case .queryFailed(let msg): return "Failed to query variant database: \(msg)"
        case .cancelled: return "VCF import was cancelled"
        }
    }
}
