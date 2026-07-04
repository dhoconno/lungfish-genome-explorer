// NaoMgsResultViewController+ResultViewport.swift - ResultViewportController conformance for NAO-MGS
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file adds the `ResultViewportController` protocol conformance to
// ``NaoMgsResultViewController`` via an extension, keeping the large
// implementation file untouched.
//
// ## Conformance notes
//
// ### NaoMgsResultViewController
//   - ResultType = NaoMgsResult
//   - configure(result:) already exists — satisfied automatically
//   - summaryBarView returns the NaoMgsSummaryBar subview
//   - exportResults(to:format:) supports .tsv only; other formats throw

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

// MARK: - NaoMgsResultViewController: ResultViewportController

/// Adds `ResultViewportController` conformance to ``NaoMgsResultViewController``.
///
/// `NaoMgsResultViewController` already implements `configure(result:NaoMgsResult)`,
/// so only the three remaining protocol requirements are synthesised here:
/// `summaryBarView`, `exportResults(to:format:)`, and `resultTypeName`.
extension NaoMgsResultViewController: ResultViewportController {

    public typealias ResultType = NaoMgsResult

    // MARK: ResultViewportController

    /// Satisfies the `ResultViewportController` protocol requirement.
    ///
    /// Delegates to `configure(result:bundleURL:)` with `nil` bundle URL.
    public func configure(result: NaoMgsResult) {
        configure(result: result, bundleURL: nil)
    }

    /// Returns the NAO-MGS summary bar at the top of the view.
    ///
    /// The `NaoMgsSummaryBar` is always the first subview added in `loadView`.
    public var summaryBarView: NSView {
        view.subviews.first { $0 is NaoMgsSummaryBar } ?? view
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

    /// The human-readable name shown in menus and export dialogs.
    public static var resultTypeName: String { "NAO-MGS Results" }
}
