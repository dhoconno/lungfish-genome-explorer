// TaxonomyResultViewController.swift - ResultViewportController conformances for taxonomy tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file adds `ResultViewportController` protocol conformances to the two
// taxonomy result view controllers via extensions, keeping the large
// implementation files untouched.
//
// ## Conformance notes
//
// ### TaxonomyViewController (Kraken2)
//   - ResultType = ClassificationResult
//   - configure(result:) already exists — satisfied automatically
//   - summaryBarView returns the TaxonomySummaryBar subview
//   - exportResults(to:format:) supports .csv and .tsv via the existing
//     buildDelimitedExport helper; .json and .fasta throw unsupported errors
//
// ### NaoMgsResultViewController
//   - ResultType = NaoMgsResult
//   - configure(result:) already exists — satisfied automatically
//   - summaryBarView returns the NaoMgsSummaryBar subview
//   - exportResults(to:format:) supports .tsv only; other formats throw
//
// ### BlastVerifiable
//   Both classes carry a pre-existing `onBlastVerification` callback with
//   tool-specific signatures that pre-date the `BlastVerifiable` protocol.
//   Full conformance to `BlastVerifiable` (which requires the uniform
//   `((BlastRequest) -> Void)?` callback) is deferred until those callbacks
//   are migrated to the uniform `BlastRequest` type.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Unsupported Export Format Error

private enum TaxonomyExportError: LocalizedError {
    case unsupportedFormat(ResultExportFormat)
    case noData

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt):
            return "Export format '\(fmt.rawValue)' is not supported for this result type."
        case .noData:
            return "No result data is loaded; cannot export."
        }
    }
}

// MARK: - TaxonomyViewController: ResultViewportController

/// Adds `ResultViewportController` conformance to ``TaxonomyViewController``.
///
/// `TaxonomyViewController` already implements `configure(result:ClassificationResult)`,
/// so only the three remaining protocol requirements are synthesised here:
/// `summaryBarView`, `exportResults(to:format:)`, and `resultTypeName`.
extension TaxonomyViewController: ResultViewportController {

    public typealias ResultType = ClassificationResult

    // MARK: ResultViewportController

    /// Returns the summary bar that sits at the top of the taxonomy browser.
    ///
    /// The `TaxonomySummaryBar` is always the first subview added in `loadView`,
    /// so searching for it by type is reliable. Falls back to `view` if the
    /// subview hierarchy has not yet been built.
    public var summaryBarView: NSView {
        view.subviews.first { $0 is TaxonomySummaryBar } ?? view
    }

    /// Exports the taxonomy tree to `url` in the requested format.
    ///
    /// Supports `.csv` and `.tsv`. Other formats throw an unsupported-format error.
    ///
    /// - Parameters:
    ///   - url: Destination file URL. The file is written atomically.
    ///   - format: The desired export format.
    /// - Throws: ``TaxonomyExportError/unsupportedFormat(_:)`` for `.json` or `.fasta`;
    ///   rethrows any file-system error from `String.write(to:atomically:encoding:)`.
    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        guard let tree else {
            throw TaxonomyExportError.noData
        }

        let content: String
        switch format {
        case .csv:
            content = buildDelimitedExport(tree: tree, separator: ",")
        case .tsv:
            content = buildDelimitedExport(tree: tree, separator: "\t")
        case .json, .fasta:
            throw TaxonomyExportError.unsupportedFormat(format)
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The human-readable name shown in menus and export dialogs.
    public static var resultTypeName: String { "Classification" }
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
    /// Uses the internal `exportResults()` method which writes from `displayedRows`.
    ///
    /// - Parameters:
    ///   - url: Destination file URL. Written atomically.
    ///   - format: The desired export format.
    /// - Throws: ``TaxonomyExportError/unsupportedFormat(_:)`` for non-TSV formats;
    ///   rethrows file-system errors from `String.write(to:atomically:encoding:)`.
    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        switch format {
        case .tsv:
            // Delegate to the VC's own export which uses displayedRows from the database.
            exportResults()

        case .csv, .json, .fasta:
            throw TaxonomyExportError.unsupportedFormat(format)
        }
    }

    /// The human-readable name shown in menus and export dialogs.
    public static var resultTypeName: String { "NAO-MGS Results" }
}
