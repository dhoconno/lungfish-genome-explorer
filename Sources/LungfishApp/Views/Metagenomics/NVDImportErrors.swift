// NVDImportErrors.swift - NVD import presentation errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Errors thrown during the NVD import pipeline.
enum NvdImportError: Error, LocalizedError {
    case csvNotFound(String)
    case bundleCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .csvNotFound(let message):
            return "NVD CSV not found: \(message)"
        case .bundleCreationFailed(let message):
            return "Failed to create NVD bundle: \(message)"
        }
    }
}
