// TaxonomyResultViewController.swift - ResultViewportController conformances for taxonomy tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file adds the `ResultViewportController` protocol conformance to the
// Kraken2 taxonomy result view controller via an extension, keeping the large
// implementation file untouched.
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
import LungfishKit

// MARK: - Unsupported Export Format Error

private enum TaxonomyExportError: LocalizedError {
    case unsupportedFormat(ResultExportFormat)
    case noData
    case noSourceInputs

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt):
            return "Export format '\(fmt.rawValue)' is not supported for this result type."
        case .noData:
            return "No result data is loaded; cannot export."
        case .noSourceInputs:
            return "Cannot export classification results because no durable source result files are available for provenance."
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

        let startedAt = Date()
        let sourceURLs = try taxonomyExportSourceURLs()
        let content: String
        switch format {
        case .csv:
            content = buildDelimitedExport(tree: tree, separator: ",")
        case .tsv:
            content = buildDelimitedExport(tree: tree, separator: "\t")
        case .json, .fasta:
            throw TaxonomyExportError.unsupportedFormat(format)
        }

        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxonomy result export",
            sourceURLs: sourceURLs,
            outputURL: url,
            outputFormat: .text,
            argv: taxonomyExportArgv(format: format, outputURL: url, sourceURLs: sourceURLs),
            explicitOptions: [
                "sourcePaths": .array(sourceURLs.map { .file($0) }),
                "outputPath": .file(url),
                "outputFormat": .string(format.rawValue),
            ],
            resolved: [
                "rowCount": .integer(tree.allNodes().count),
                "totalReads": .integer(tree.totalReads),
            ],
            startedAt: startedAt
        )) { tempURL in
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
        }
    }

    /// The human-readable name shown in menus and export dialogs.
    public static var resultTypeName: String { "Classification" }

    private func taxonomyExportSourceURLs() throws -> [URL] {
        guard let result = classificationResult else {
            throw TaxonomyExportError.noSourceInputs
        }
        var candidates = [result.reportURL, result.outputURL]
        if let brackenURL = result.brackenURL {
            candidates.append(brackenURL)
        }
        for requiredURL in candidates {
            guard FileManager.default.fileExists(atPath: requiredURL.path) else {
                throw TaxonomyExportError.noSourceInputs
            }
        }
        if FileManager.default.fileExists(atPath: result.config.databasePath.path) {
            candidates.append(result.config.databasePath)
        }
        let configuredInputs = result.config.originalInputFiles ?? result.config.inputFiles
        candidates.append(contentsOf: configuredInputs)
        let sourceURLs = uniqueExistingURLs(candidates)
        guard !sourceURLs.isEmpty else {
            throw TaxonomyExportError.noSourceInputs
        }
        return sourceURLs
    }

    private func taxonomyExportArgv(
        format: ResultExportFormat,
        outputURL: URL,
        sourceURLs: [URL]
    ) -> [String] {
        var argv = [
            "Lungfish.app",
            "export-taxonomy-results",
            "--format", format.rawValue,
            "--output", outputURL.path,
        ]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        return argv
    }

    private func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized
        }
    }
}
