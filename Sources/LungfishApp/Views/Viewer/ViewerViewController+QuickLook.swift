// ViewerViewController+QuickLook.swift - The preview of a file the viewer shows without a result of its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log
import PDFKit
import Quartz

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

extension ViewerViewController {
    /// Displays a file using QuickLook preview or PDFKit (for non-genomics files).
    ///
    /// For PDF files, uses PDFKit which provides more reliable embedded rendering.
    /// For other files (images, text, etc.), uses QLPreviewView with a proper
    /// QuickLookItem wrapper to ensure the preview loads correctly.
    ///
    /// - Parameter url: The URL of the file to preview
    public func displayQuickLookPreview(url: URL) {
        logger.info("displayQuickLookPreview: Starting preview for '\(url.lastPathComponent, privacy: .public)'")
        logger.debug("displayQuickLookPreview: URL scheme=\(url.scheme ?? "nil", privacy: .public) extension=\(url.pathExtension, privacy: .public)")

        // Ensure we have a proper file URL
        let fileURL: URL
        if url.isFileURL {
            fileURL = url
        } else {
            fileURL = URL(fileURLWithPath: url.path)
        }

        // Verify file exists and is readable
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.error("displayQuickLookPreview: File does not exist at path")
            showNoSequenceSelected()
            return
        }

        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            logger.error("displayQuickLookPreview: File is not readable")
            showNoSequenceSelected()
            return
        }

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

        // Hide the genomics viewer components including the ruler
        hideGenomicsViewer()

        // Remove any existing preview views
        removePreviewViews()

        // Store the URL
        quickLookURL = fileURL

        // Files macOS has no preview for (Nextflow main.nf, Snakefile, ...) show as text.
        if PlainTextPreview.decision(for: fileURL) == .text,
           displayPlainTextPreview(url: fileURL) {
            return
        }

        embeddedFilePreviewRenderer(self, fileURL)
    }

    /// The production `embeddedFilePreviewRenderer`.
    func renderEmbeddedFilePreview(url fileURL: URL) {
        // For PDFs, use PDFKit (more reliable than QLPreviewView for embedded use)
        let ext = fileURL.pathExtension.lowercased()

        if ext == "pdf" {
            displayPDFPreview(url: fileURL)
            return
        }

        // For other files, use QLPreviewView with proper QuickLookItem wrapper
        displayQLPreview(url: fileURL)
    }
    
    /// Displays a file as read-only monospaced text. Returns false when the file
    /// cannot be read as UTF-8 so the caller can fall back to Quick Look.
    private func displayPlainTextPreview(url: URL) -> Bool {
        guard let content = PlainTextPreview.load(from: url) else { return false }

        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityLabel("Text preview of \(url.lastPathComponent)")
        scrollView.setAccessibilityIdentifier("viewer-plain-text-preview")

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.isHorizontallyResizable = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.textContainerInset = NSSize(width: 12, height: 10)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textColor = .textColor
            textView.backgroundColor = .textBackgroundColor
            textView.string = content.text
            textView.setAccessibilityLabel("Contents of \(url.lastPathComponent)")
            textView.setAccessibilityIdentifier("viewer-plain-text-preview-text")
        }

        view.addSubview(scrollView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        plainTextPreviewScrollView = scrollView

        statusBar.positionLabel.stringValue = "Previewing: \(url.lastPathComponent)"
        if content.isTruncated {
            let shown = ByteCountFormatter.string(fromByteCount: Int64(PlainTextPreview.maxPreviewBytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(content.totalBytes), countStyle: .file)
            statusBar.selectionLabel.stringValue = "Truncated: showing the first \(shown) of \(total)"
        } else {
            statusBar.selectionLabel.stringValue = ""
        }
        logger.info("displayPlainTextPreview: Showing '\(url.lastPathComponent, privacy: .public)' as text")
        return true
    }

    /// Displays a PDF file using PDFKit.
    ///
    /// PDFKit provides more reliable embedded rendering than QLPreviewView,
    /// especially within NSSplitViewController hierarchies.
    private func displayPDFPreview(url: URL) {
        logger.info("displayPDFPreview: Loading PDF from '\(url.lastPathComponent, privacy: .public)'")
        logger.debug("displayPDFPreview: Full URL path: \(url.path, privacy: .public)")

        // Log view hierarchy state BEFORE changes
        logger.debug("displayPDFPreview: Parent view bounds: \(NSStringFromRect(self.view.bounds), privacy: .public)")
        logger.debug("displayPDFPreview: Parent view frame: \(NSStringFromRect(self.view.frame), privacy: .public)")
        logger.debug("displayPDFPreview: Subview count before: \(self.view.subviews.count)")
        for (index, subview) in self.view.subviews.enumerated() {
            logger.debug("displayPDFPreview: Subview[\(index)]: \(type(of: subview)) hidden=\(subview.isHidden) frame=\(NSStringFromRect(subview.frame), privacy: .public)")
        }

        // Load the PDF document FIRST to validate it
        guard let pdfDocument = PDFDocument(url: url) else {
            logger.error("displayPDFPreview: Failed to create PDFDocument from URL")
            showNoSequenceSelected()
            return
        }

        let pageCount = pdfDocument.pageCount
        logger.info("displayPDFPreview: PDFDocument created with \(pageCount) pages")

        // Log page details
        for i in 0..<min(pageCount, 3) {
            if let page = pdfDocument.page(at: i) {
                let pageBounds = page.bounds(for: .mediaBox)
                logger.debug("displayPDFPreview: Page[\(i)] mediaBox: \(NSStringFromRect(pageBounds), privacy: .public)")
            }
        }

        let pdfDisplayView = PDFView()
        pdfDisplayView.translatesAutoresizingMaskIntoConstraints = false

        // Configure display options BEFORE adding to hierarchy
        pdfDisplayView.displayMode = .singlePageContinuous
        pdfDisplayView.displaysAsBook = false
        pdfDisplayView.displayDirection = .vertical
        pdfDisplayView.backgroundColor = .white
        pdfDisplayView.autoScales = true

        // Set document BEFORE adding to view hierarchy
        // This allows PDFKit to initialize its rendering pipeline with document dimensions
        pdfDisplayView.document = pdfDocument
        logger.debug("displayPDFPreview: Document assigned to PDFView")

        // Add to view hierarchy at the TOP of z-order
        view.addSubview(pdfDisplayView, positioned: .above, relativeTo: nil)
        logger.debug("displayPDFPreview: PDFView added to hierarchy")

        // Position to fill the entire viewer area (excluding status bar)
        NSLayoutConstraint.activate([
            pdfDisplayView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfDisplayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfDisplayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfDisplayView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        logger.debug("displayPDFPreview: Constraints activated")

        // Force layout to establish bounds
        view.layoutSubtreeIfNeeded()

        // Log bounds AFTER layout
        logger.debug("displayPDFPreview: PDFView bounds after layout: \(NSStringFromRect(pdfDisplayView.bounds), privacy: .public)")
        logger.debug("displayPDFPreview: PDFView frame after layout: \(NSStringFromRect(pdfDisplayView.frame), privacy: .public)")

        // Verify document is still attached
        if let doc = pdfDisplayView.document {
            logger.debug("displayPDFPreview: Document still attached, pageCount=\(doc.pageCount)")
        } else {
            logger.error("displayPDFPreview: Document became nil after layout!")
        }

        // Log scale factors
        logger.debug("displayPDFPreview: autoScales=\(pdfDisplayView.autoScales)")
        logger.debug("displayPDFPreview: scaleFactor=\(pdfDisplayView.scaleFactor)")
        logger.debug("displayPDFPreview: scaleFactorForSizeToFit=\(pdfDisplayView.scaleFactorForSizeToFit)")
        logger.debug("displayPDFPreview: minScaleFactor=\(pdfDisplayView.minScaleFactor)")
        logger.debug("displayPDFPreview: maxScaleFactor=\(pdfDisplayView.maxScaleFactor)")

        // If bounds are valid, ensure scale is set properly
        if pdfDisplayView.bounds.width > 0 && pdfDisplayView.bounds.height > 0 {
            // Force scale to fit
            let fitScale = pdfDisplayView.scaleFactorForSizeToFit
            if fitScale > 0 {
                pdfDisplayView.scaleFactor = fitScale
                logger.debug("displayPDFPreview: Applied scaleFactorForSizeToFit=\(fitScale)")
            }
        } else {
            logger.warning("displayPDFPreview: PDFView has zero bounds!")
        }

        // Go to first page explicitly
        if let firstPage = pdfDocument.page(at: 0) {
            pdfDisplayView.go(to: firstPage)
            logger.debug("displayPDFPreview: Navigated to first page")
        }

        // Force redraw
        pdfDisplayView.needsDisplay = true
        pdfDisplayView.needsLayout = true

        pdfView = pdfDisplayView

        // Update status bar
        statusBar.positionLabel.stringValue = "\(url.lastPathComponent) (\(pageCount) page\(pageCount == 1 ? "" : "s"))"
        statusBar.selectionLabel.stringValue = ""

        // Log final view hierarchy state
        logger.debug("displayPDFPreview: Final subview count: \(self.view.subviews.count)")
        for (index, subview) in self.view.subviews.enumerated() {
            let isOnTop = (index == self.view.subviews.count - 1)
            logger.debug("displayPDFPreview: Final subview[\(index)]: \(type(of: subview)) hidden=\(subview.isHidden) onTop=\(isOnTop)")
        }

        logger.info("displayPDFPreview: PDF display setup complete for '\(url.lastPathComponent, privacy: .public)'")
    }
    
    /// Displays a file using QLPreviewView with proper QuickLookItem wrapper.
    private func displayQLPreview(url: URL) {
        logger.info("displayQLPreview: Creating QLPreviewView for '\(url.lastPathComponent, privacy: .public)'")
        logger.debug("displayQLPreview: Full URL path: \(url.path, privacy: .public)")
        logger.debug("displayQLPreview: Parent view bounds: \(NSStringFromRect(self.view.bounds), privacy: .public)")

        // Create a new QuickLook preview view
        // Use .normal style which works better in embedded contexts
        let previewView = QLPreviewView(frame: view.bounds, style: .normal)
        previewView?.translatesAutoresizingMaskIntoConstraints = false

        guard let preview = previewView else {
            logger.error("displayQLPreview: Failed to create QLPreviewView")
            showNoSequenceSelected()
            return
        }

        logger.debug("displayQLPreview: QLPreviewView created")

        // Add to the container view FIRST (before setting constraints or preview item)
        view.addSubview(preview)

        // Position to fill the entire viewer area (excluding status bar)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        logger.debug("displayQLPreview: Constraints activated")

        // Force layout before setting the preview item - QLPreviewView needs valid bounds
        view.layoutSubtreeIfNeeded()

        logger.debug("displayQLPreview: Preview bounds after layout: \(NSStringFromRect(preview.bounds), privacy: .public)")
        logger.debug("displayQLPreview: Preview frame after layout: \(NSStringFromRect(preview.frame), privacy: .public)")

        // Verify bounds are valid
        guard !preview.bounds.isEmpty else {
            logger.error("displayQLPreview: Preview bounds are empty after layout")
            preview.removeFromSuperview()
            showNoSequenceSelected()
            return
        }

        // Create a proper QuickLookItem wrapper - this is critical!
        // Direct URL casting to QLPreviewItem is unreliable and causes infinite spinner
        let quickLookItem = QuickLookItem(url: url)
        logger.debug("displayQLPreview: QuickLookItem created for '\(url.lastPathComponent, privacy: .public)'")

        // Set the preview item using the wrapper
        preview.previewItem = quickLookItem

        // Refresh the preview to trigger loading
        preview.refreshPreviewItem()
        logger.debug("displayQLPreview: refreshPreviewItem called")

        quickLookView = preview

        // Update status bar
        statusBar.positionLabel.stringValue = "Previewing: \(url.lastPathComponent)"
        statusBar.selectionLabel.stringValue = ""

        logger.info("displayQLPreview: QLPreviewView configured for '\(url.lastPathComponent, privacy: .public)'")
    }
    
    /// Removes any existing preview views (QuickLook or PDF).
    private func removePreviewViews() {
        logger.debug("removePreviewViews: Cleaning up existing preview views")
        logger.debug("removePreviewViews: quickLookView=\(self.quickLookView != nil) pdfView=\(self.pdfView != nil)")

        if let ql = quickLookView {
            logger.debug("removePreviewViews: Removing QuickLook view from hierarchy")
            ql.close()
            ql.removeFromSuperview()
        }
        quickLookView = nil

        if let pdf = pdfView {
            logger.debug("removePreviewViews: Removing PDF view from hierarchy")
            pdf.removeFromSuperview()
        }
        pdfView = nil

        plainTextPreviewScrollView?.removeFromSuperview()
        plainTextPreviewScrollView = nil

        logger.debug("removePreviewViews: Cleanup complete")
    }
    
    /// Hides the QuickLook/PDF preview and shows the genomics viewer
    public func hideQuickLookPreview() {
        guard quickLookView != nil || pdfView != nil || plainTextPreviewScrollView != nil else { return }
        
        logger.info("hideQuickLookPreview: Removing preview views")
        
        removePreviewViews()
        quickLookURL = nil
        
        // Show the genomics viewer components
        showGenomicsViewer()
    }
    
    /// Hides the genomics viewer components (for QuickLook preview)
    private func hideGenomicsViewer() {
        logger.debug("hideGenomicsViewer: Hiding genomics components")
        logger.debug("hideGenomicsViewer: viewerView frame before: \(NSStringFromRect(self.viewerView.frame), privacy: .public)")

        viewerView.isHidden = true
        headerView.isHidden = true
        enhancedRulerView.isHidden = true
        progressOverlay.isHidden = true

        logger.debug("hideGenomicsViewer: Components hidden - viewerView=\(self.viewerView.isHidden) headerView=\(self.headerView.isHidden) rulerView=\(self.enhancedRulerView.isHidden)")
    }
    
    /// Shows the genomics viewer components (after QuickLook preview)
    func showGenomicsViewer() {
        viewerView.isHidden = false
        headerView.isHidden = false
        enhancedRulerView.isHidden = false
    }
}
