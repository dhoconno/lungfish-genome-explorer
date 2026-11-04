// QuickLookPreviewController.swift - The one child that holds a file's preview on the surface host
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import PDFKit
import Quartz

/// Why a file has no preview, in the words a person reads after "Unable to open the preview."
enum QuickLookPreviewError: LocalizedError {
    case missing(String)
    case unreadable(String)
    case damagedPDF(String)
    case notDrawable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "\(name) is no longer where it was saved."
        case .unreadable(let name): "This Mac does not allow \(name) to be read."
        case .damagedPDF(let name): "\(name) does not read as a PDF."
        case .notDrawable(let name): "Quick Look could not draw \(name)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missing: "Check that the file is still in the project folder, then select it again."
        case .unreadable: "Check the file's permissions in Finder, then select it again."
        case .damagedPDF: "The file may be damaged, so open it in another app or export it again."
        case .notDrawable: "Make the window larger, then select the file again."
        }
    }
}

/// Holds the view that previews one file, as text, with PDFKit or with Quick Look.
///
/// The host adds this controller as its one child. Its own view draws nothing, and the content ends at the viewer's
/// status bar, which stays on screen under the preview with the preview's words, so the bar shows where the content ends.
@MainActor
final class QuickLookPreviewController: NSViewController {
    /// What reading the file found.
    enum Content {
        case text(PlainTextPreview.Content)
        case pdf(PDFDocument)
        case quickLook
    }

    let url: URL
    private(set) var content: Content?
    private let contentArea = NSView()

    /// Quick Look's view of a file that macOS can preview, such as an image, a table, a movie or a web page.
    private(set) var quickLookView: QLPreviewView?
    /// PDFKit's view of a PDF, more reliable than Quick Look's within a split view.
    private(set) var pdfView: PDFView?
    /// A read-only text view of a workflow or script file Quick Look cannot preview.
    private(set) var plainTextScrollView: NSScrollView?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentArea)
        NSLayoutConstraint.activate([
            contentArea.topAnchor.constraint(equalTo: root.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    /// Checks the person's file and reads what the preview needs. A failure throws the file's own words.
    func readFile() throws {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { throw QuickLookPreviewError.missing(name) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw QuickLookPreviewError.unreadable(name) }
        // Files macOS has no preview for (Nextflow main.nf, Snakefile, ...) show as text.
        if PlainTextPreview.decision(for: url) == .text, let text = PlainTextPreview.load(from: url) {
            content = .text(text)
        } else if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw QuickLookPreviewError.damagedPDF(name) }
            content = .pdf(document)
        } else {
            content = .quickLook
        }
    }

    /// Ends the content at `statusBarTop`. The two views only share an ancestor once the host has installed this one.
    func endContent(at statusBarTop: NSLayoutYAxisAnchor) {
        contentArea.bottomAnchor.constraint(equalTo: statusBarTop).isActive = true
    }

    /// Shows `text` as read-only monospaced text.
    func showText(_ text: PlainTextPreview.Content) {
        let scrollView = NSTextView.scrollableTextView()
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
            textView.string = text.text
            textView.setAccessibilityLabel("Contents of \(url.lastPathComponent)")
            textView.setAccessibilityIdentifier("viewer-plain-text-preview-text")
        }

        fillContentArea(with: scrollView)
        plainTextScrollView = scrollView
    }

    /// Shows `document` scaled to fit, from its first page.
    func showPDF(_ document: PDFDocument) {
        let pdfDisplayView = PDFView()
        // PDFKit starts its rendering from the document's dimensions, so the document comes before the hierarchy.
        pdfDisplayView.displayMode = .singlePageContinuous
        pdfDisplayView.displaysAsBook = false
        pdfDisplayView.displayDirection = .vertical
        pdfDisplayView.backgroundColor = .white
        pdfDisplayView.autoScales = true
        pdfDisplayView.document = document

        fillContentArea(with: pdfDisplayView)
        layOutInViewer()

        if pdfDisplayView.bounds.width > 0 && pdfDisplayView.bounds.height > 0 {
            let fitScale = pdfDisplayView.scaleFactorForSizeToFit
            if fitScale > 0 {
                pdfDisplayView.scaleFactor = fitScale
            }
        }
        if let firstPage = document.page(at: 0) {
            pdfDisplayView.go(to: firstPage)
        }
        pdfDisplayView.needsDisplay = true
        pdfDisplayView.needsLayout = true
        pdfView = pdfDisplayView
    }

    /// Asks Quick Look to draw the file. Quick Look's view needs valid bounds before it gets its item, and the item is
    /// a `QuickLookItem`, since a URL cast to a preview item leaves an endless spinner.
    func showQuickLookView(makeView: (NSRect) -> QLPreviewView?) throws {
        let name = url.lastPathComponent
        guard let preview = makeView(contentArea.bounds) else { throw QuickLookPreviewError.notDrawable(name) }
        fillContentArea(with: preview)
        layOutInViewer()
        guard !preview.bounds.isEmpty else {
            preview.close()
            preview.removeFromSuperview()
            throw QuickLookPreviewError.notDrawable(name)
        }
        preview.previewItem = QuickLookItem(url: url)
        preview.refreshPreviewItem()
        quickLookView = preview
    }

    /// Closes what shows the file, so a movie or a sound stops and nothing keeps the file open. The host calls this
    /// through the surface on every removal.
    func closePreview() {
        quickLookView?.close()
        quickLookView?.removeFromSuperview()
        quickLookView = nil
        pdfView?.document = nil
        pdfView?.removeFromSuperview()
        pdfView = nil
        plainTextScrollView?.removeFromSuperview()
        plainTextScrollView = nil
        content = nil
    }

    private func fillContentArea(with preview: NSView) {
        preview.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: contentArea.topAnchor),
            preview.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
    }

    /// Lays out from the viewer's view, since the content's end is a constraint on the viewer's status bar.
    private func layOutInViewer() {
        (view.superview ?? view).layoutSubtreeIfNeeded()
    }
}
