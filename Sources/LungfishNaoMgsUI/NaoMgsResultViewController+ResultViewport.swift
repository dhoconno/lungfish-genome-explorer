// NaoMgsResultViewController+ResultViewport.swift - configure/export helpers for NAO-MGS
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file adds the shared configure/export surface to
// ``NaoMgsResultViewController`` via an extension, keeping the large
// implementation file untouched.
//
// - configure(result:) adapts parser output into cached viewport rows
// - exportResults(to:format:) supports .tsv only; other formats throw

import AppKit
import Foundation
import LungfishIO
import LungfishWorkflow
import LungfishKit

// MARK: - Unsupported Export Format Error

private enum NaoMgsExportError: LocalizedError {
    case unsupportedFormat(ResultExportFormat)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt):
            return "Export format '\(fmt.rawValue)' is not supported for this result type."
        }
    }
}

// MARK: - NaoMgsResultViewController: configure/export

/// Adds the shared configure/export surface to ``NaoMgsResultViewController``.
///
/// Parser-backed ``NaoMgsResult`` values are displayed from cached rows. Imported
/// bundles should still use `configure(database:manifest:bundleURL:)` so detail
/// panes can query the SQLite database.
extension NaoMgsResultViewController {

    /// Delegates to `configure(result:bundleURL:)` with `nil` bundle URL.
    public func configure(result: NaoMgsResult) {
        configure(result: result, bundleURL: nil)
    }

    /// Exports NAO-MGS results to `url` in the requested format.
    ///
    /// Only `.tsv` is supported; all other formats throw an unsupported-format error.
    /// Writes directly to the supplied URL from the currently displayed rows.
    ///
    /// - Parameters:
    ///   - url: Destination file URL. Written atomically.
    ///   - format: The desired export format.
    /// - Throws: ``NaoMgsExportError/unsupportedFormat(_:)`` for non-TSV formats;
    ///   rethrows file-system errors from `String.write(to:atomically:encoding:)`.
    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        switch format {
        case .tsv:
            try writeSummaryTSV(to: url)

        case .csv, .json, .fasta:
            throw NaoMgsExportError.unsupportedFormat(format)
        }
    }
}
