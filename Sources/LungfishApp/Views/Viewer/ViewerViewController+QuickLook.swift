// ViewerViewController+QuickLook.swift - The preview of a file the viewer shows without a result of its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log
import Quartz

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

extension ViewerViewController {
    /// Previews a file the viewer has no result for, as text, with PDFKit or with Quick Look.
    ///
    /// The preview shows through the surface host, and its load reads the file. A file that does not read says why in
    /// the status bar, in place of whatever the viewer showed.
    ///
    /// - Parameter url: The URL of the file to preview
    /// - Returns: Whether the preview opened, so a caller can tell a person what it shows.
    @discardableResult
    public func displayQuickLookPreview(url: URL) -> Bool {
        logger.info("displayQuickLookPreview: Starting preview for '\(url.lastPathComponent, privacy: .public)'")

        // Ensure we have a proper file URL
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)

        hidePrimerAnalysisView()

        // Hide any dataset-specific views that may be covering the viewer
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideMHCReferenceBundleView()
        hideGenotypeResultView()
        hideTwelveSAmpliconResultView()
        hideAlignmentTreeBundleViews()

        // Hide the progress overlay first - it may be covering the view area
        hideProgress()

        let controller = QuickLookPreviewController(url: fileURL)
        do {
            _ = try showSurface(.view(.quickLook), input: QuickLookPreviewSurface.Input(controller: controller), as: QuickLookPreviewSurface.self)
        } catch {
            logger.error("displayQuickLookPreview: '\(fileURL.lastPathComponent, privacy: .public)' did not open: \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: surfaceFailureWords("Unable to open the preview.", error))
            return false
        }

        // A preview's words stay in the status bar, which every writer of the bar can reach, so the bar comes back
        // after the show and the preview ends at its top.
        statusBar.isHidden = false
        controller.endContent(at: statusBar.topAnchor)

        let name = fileURL.lastPathComponent
        switch controller.content {
        case .text(let text):
            controller.showText(text)
            statusBar.positionLabel.stringValue = "Previewing: \(name)"
            if text.isTruncated {
                let shown = ByteCountFormatter.string(fromByteCount: Int64(PlainTextPreview.maxPreviewBytes), countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: Int64(text.totalBytes), countStyle: .file)
                statusBar.selectionLabel.stringValue = "Truncated: showing the first \(shown) of \(total)"
            } else {
                statusBar.selectionLabel.stringValue = ""
            }
        case .pdf(let document):
            controller.showPDF(document)
            let pageCount = document.pageCount
            statusBar.positionLabel.stringValue = "\(name) (\(pageCount) page\(pageCount == 1 ? "" : "s"))"
            statusBar.selectionLabel.stringValue = ""
        case .quickLook, nil:
            embeddedFilePreviewRenderer(self, fileURL)
        }
        return quickLookPreviewController === controller
    }

    /// The production `embeddedFilePreviewRenderer`. `.normal` is the style that works in an embedded view.
    func renderEmbeddedFilePreview(
        url fileURL: URL,
        makeView: (NSRect) -> QLPreviewView? = { QLPreviewView(frame: $0, style: .normal) }
    ) {
        do {
            try quickLookPreviewController?.showQuickLookView(makeView: makeView)
            statusBar.positionLabel.stringValue = "Previewing: \(fileURL.lastPathComponent)"
            statusBar.selectionLabel.stringValue = ""
        } catch {
            logger.error("renderEmbeddedFilePreview: '\(fileURL.lastPathComponent, privacy: .public)' did not draw: \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: surfaceFailureWords("Unable to open the preview.", error))
        }
    }

    /// Hides the preview, a shim that other display routes call until the hide list goes in Phase 3.2.
    public func hideQuickLookPreview() {
        clearSurface(ifShowing: .view(.quickLook))
    }

    /// Shows the genomics viewer components
    func showGenomicsViewer() {
        viewerView.isHidden = false
        headerView.isHidden = false
        enhancedRulerView.isHidden = false
    }
}
