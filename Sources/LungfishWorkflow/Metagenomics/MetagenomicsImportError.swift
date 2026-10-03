// MetagenomicsImportError.swift - Errors thrown while importing classifier outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Errors thrown while importing classifier outputs.
public enum MetagenomicsImportError: Error, LocalizedError, Sendable {
    case inputNotFound(URL)
    case outputDirectoryCreationFailed(URL, String)
    case copyFailed(source: URL, destination: URL, reason: String)
    case parseFailed(URL, String)
    case toolUnavailable(String)
    case outputAlreadyExists(URL)
    case importAborted(resultDirectory: URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url):
            return "Input path not found: \(url.path)"
        case .outputDirectoryCreationFailed(let url, let reason):
            return "Could not create output directory at \(url.path): \(reason)"
        case .copyFailed(let source, let destination, let reason):
            return "Failed to copy \(source.lastPathComponent) to \(destination.path): \(reason)"
        case .parseFailed(let url, let reason):
            return "Failed to parse \(url.lastPathComponent): \(reason)"
        case .toolUnavailable(let tool):
            return "Required tool is unavailable: \(tool)"
        case .outputAlreadyExists(let url):
            return "Output already exists: \(url.path)"
        case .importAborted(_, let underlying):
            return "Import aborted: \(underlying.localizedDescription)"
        }
    }
}
