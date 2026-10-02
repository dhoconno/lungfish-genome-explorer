// DocumentLoadError.swift - Errors that can occur during document loading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - Errors

/// Errors that can occur during document loading.
public enum DocumentLoadError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(URL)
    case parseError(String)
    case accessDenied(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: \(ext)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .accessDenied(let url):
            return "Access denied: \(url.lastPathComponent)"
        }
    }
}
