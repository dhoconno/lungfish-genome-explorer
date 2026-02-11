// ViewerViewController.swift - Main sequence/track viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import Quartz  // For QLPreviewView
import PDFKit  // For PDF rendering (more reliable than QLPreviewView for PDFs)
import os.log

// MARK: - QuickLookItem

/// Wrapper class that properly implements QLPreviewItem protocol.
///
/// Direct casting of URL to QLPreviewItem is unreliable - QuickLook may not
/// correctly resolve the file and shows an indefinite loading spinner.
/// This wrapper ensures proper protocol implementation.
final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    @objc dynamic var previewItemURL: URL? {
        return url
    }
    
    @objc dynamic var previewItemTitle: String? {
        return url.lastPathComponent
    }
}

// MARK: - Logging

/// Logger for viewer operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "ViewerViewController")

// MARK: - Base Colors (IGV Standard)

/// Standard IGV-like base colors for DNA visualization
/// Reference: IGV's SequenceTrack.java
public enum BaseColors {
    /// A = Green (#00CC00)
    public static let A = NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.0, alpha: 1.0)
    /// T = Red (#CC0000)
    public static let T = NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 1.0)
    /// C = Blue (#0000CC)
    public static let C = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.8, alpha: 1.0)
    /// G = Orange/Yellow (#FFB300)
    public static let G = NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.0, alpha: 1.0)
    /// N = Gray (#888888)
    public static let N = NSColor(calibratedRed: 0.53, green: 0.53, blue: 0.53, alpha: 1.0)
    /// U = Red (RNA, same as T)
    public static let U = T

    /// Returns the color for a given base character
    public static func color(for base: Character) -> NSColor {
        switch base.uppercased().first {
        case "A": return A
        case "T": return T
        case "C": return C
        case "G": return G
        case "U": return U
        case "N": return N
        default: return N
        }
    }

    /// Dictionary mapping base characters to colors
    public static let colorMap: [Character: NSColor] = [
        "A": A, "a": A,
        "T": T, "t": T,
        "C": C, "c": C,
        "G": G, "g": G,
        "U": U, "u": U,
        "N": N, "n": N,
    ]
}

/// Controller for the main viewer panel containing sequence and track display.
@MainActor
public class ViewerViewController: NSViewController {

    // MARK: - UI Components

    /// The custom view for rendering sequences and tracks
    public private(set) var viewerView: SequenceViewerView!

    /// Header view for track labels
    var headerView: TrackHeaderView!

    /// Enhanced coordinate ruler at the top with mini-map and navigation
    public private(set) var enhancedRulerView: EnhancedCoordinateRulerView!

    /// Status bar at the bottom
    public private(set) var statusBar: ViewerStatusBar!

    /// Progress indicator overlay
    private var progressOverlay: ProgressOverlayView!

    /// Leading constraints for ruler, viewer, and overlay — animated by chromosome drawer
    var contentLeadingConstraints: [NSLayoutConstraint] = []
    
    /// QuickLook preview view for non-genomics files (images, text, etc.)
    private var quickLookView: QLPreviewView?
    
    /// PDF view for displaying PDF files (more reliable than QLPreviewView)
    private var pdfView: PDFView?
    
    /// URL currently being previewed with QuickLook or PDFKit
    private var quickLookURL: URL?

    // MARK: - State

    /// Current reference frame for coordinate mapping
    public var referenceFrame: ReferenceFrame?

    /// Currently displayed document
    public private(set) var currentDocument: LoadedDocument?

    /// Track height constant
    private let sequenceTrackY: CGFloat = 20
    private let sequenceTrackHeight: CGFloat = SequenceAppearance.load().trackHeight

    // MARK: - Annotation Display Settings

    /// Whether to show annotations in the viewer
    var showAnnotations: Bool = true

    /// Height of each annotation box in pixels
    var annotationDisplayHeight: CGFloat = 16

    /// Vertical spacing between annotation rows
    var annotationDisplaySpacing: CGFloat = 2

    /// Set of annotation types to display (nil means show all)
    var visibleAnnotationTypes: Set<AnnotationType>?

    /// Text filter for annotations (empty string means no filter)
    var annotationFilterText: String = ""

    // MARK: - Nucleotide Display Mode

    /// Whether to display sequences as RNA (U instead of T).
    /// When true, thymine (T) bases are displayed as uracil (U).
    public var isRNAMode: Bool = false {
        didSet {
            // Propagate to viewer view
            viewerView?.isRNAMode = isRNAMode
        }
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true

        // Create enhanced ruler view with mini-map and navigation
        enhancedRulerView = EnhancedCoordinateRulerView()
        enhancedRulerView.translatesAutoresizingMaskIntoConstraints = false
        enhancedRulerView.delegate = self
        containerView.addSubview(enhancedRulerView)

        // Header view no longer displayed — left margin removed for cleaner layout
        headerView = TrackHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.isHidden = true

        // Create main viewer view
        viewerView = SequenceViewerView()
        viewerView.translatesAutoresizingMaskIntoConstraints = false
        viewerView.viewController = self
        viewerView.trackY = sequenceTrackY
        viewerView.trackHeight = sequenceTrackHeight
        containerView.addSubview(viewerView)

        // Create status bar
        statusBar = ViewerStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusBar)

        // Create progress overlay (initially hidden)
        progressOverlay = ProgressOverlayView()
        progressOverlay.translatesAutoresizingMaskIntoConstraints = false
        progressOverlay.isHidden = true
        containerView.addSubview(progressOverlay)

        // Layout — leading constraints stored for chromosome drawer resize
        let rulerHeight: CGFloat = EnhancedCoordinateRulerView.recommendedHeight  // 56px with info bar, mini-map, ruler
        let statusHeight: CGFloat = 24

        let rulerLeading = enhancedRulerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
        let viewerLeading = viewerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
        let overlayLeading = progressOverlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)

        contentLeadingConstraints = [rulerLeading, viewerLeading, overlayLeading]

        NSLayoutConstraint.activate([
            // Enhanced ruler spans full width above content, using safe area to avoid toolbar overlap
            enhancedRulerView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            rulerLeading,
            enhancedRulerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            enhancedRulerView.heightAnchor.constraint(equalToConstant: rulerHeight),

            // Viewer fills the main area (full width)
            viewerView.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            viewerLeading,
            viewerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            viewerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: statusHeight),

            // Progress overlay covers the viewer area
            progressOverlay.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            overlayLeading,
            progressOverlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            progressOverlay.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        self.view = containerView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("viewDidLoad: ViewerViewController loaded")

        // Set background color
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Don't create a default reference frame - start with nil
        // The reference frame will be created when a sequence is actually loaded
        // This ensures the viewer shows "No sequence selected" for empty projects
        referenceFrame = nil
        logger.debug("viewDidLoad: Starting with nil referenceFrame (empty state)")

        // Set up accessibility
        setupAccessibility()

        // Set up notification observers for annotation settings
        setupAnnotationNotificationObservers()

        logger.info("viewDidLoad: Setup complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Work item for coalescing rapid layout changes into a single deferred redraw.
    /// During animation (e.g., annotation drawer open/close), viewDidLayout is called
    /// 30+ times. We update pixelWidth immediately for correct rendering, but defer
    /// the "ensure redraw" trigger until layout settles. This prevents the main thread
    /// from being monopolized by layout-draw cycles and gives GCD main queue blocks
    /// (fetch callbacks) a chance to execute.
    private var layoutSettleWorkItem: DispatchWorkItem?

    public override func viewDidLayout() {
        super.viewDidLayout()

        // Update reference frame width immediately (needed for correct rendering)
        if let frame = referenceFrame, viewerView.bounds.width > 0 {
            frame.pixelWidth = Int(viewerView.bounds.width)
            logger.debug("viewDidLayout: Updated referenceFrame width to \(frame.pixelWidth)")
        }

        // Coalesce rapid layout changes: schedule a deferred redraw that fires
        // 100ms after the last viewDidLayout call. This ensures that after
        // animation settles, any pending fetch callbacks that executed during
        // the animation will have their data rendered.
        layoutSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            logger.debug("viewDidLayout: Layout settled, triggering deferred redraw")
            self.viewerView.setNeedsDisplay(self.viewerView.bounds)
            self.enhancedRulerView.needsDisplay = true
        }
        layoutSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func setupAccessibility() {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Sequence viewer")
        view.setAccessibilityIdentifier("sequence-viewer-container")

        viewerView.setAccessibilityElement(true)
        viewerView.setAccessibilityRole(.group)
        viewerView.setAccessibilityLabel("Sequence display area")
        viewerView.setAccessibilityIdentifier("sequence-viewer")
    }

    // MARK: - Annotation Notification Observers

    /// Sets up observers for annotation-related notifications from the inspector.
    private func setupAnnotationNotificationObservers() {
        // Observer for annotation display settings (visibility, height, spacing)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationSettingsChanged(_:)),
            name: .annotationSettingsChanged,
            object: nil
        )
        logger.debug("ViewerViewController: Registered annotationSettingsChanged observer")

        // Observer for annotation filter settings (type filter, text filter)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationFilterChanged(_:)),
            name: .annotationFilterChanged,
            object: nil
        )
        logger.debug("ViewerViewController: Registered annotationFilterChanged observer")

        // Observer for CDS translation toggle from inspector
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowCDSTranslationRequested(_:)),
            name: .showCDSTranslationRequested,
            object: nil
        )
        logger.debug("ViewerViewController: Registered showCDSTranslationRequested observer")

        // Observer for variant filter changes from inspector
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVariantFilterChanged(_:)),
            name: .variantFilterChanged,
            object: nil
        )
        logger.debug("ViewerViewController: Registered variantFilterChanged observer")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleViewStateResetRequested(_:)),
            name: .bundleViewStateResetRequested,
            object: nil
        )
        logger.debug("ViewerViewController: Registered bundleViewStateResetRequested observer")
    }

    /// Handles the toggle of CDS translation display from the inspector.
    @objc private func handleShowCDSTranslationRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let annotation = userInfo["annotation"] as? SequenceAnnotation,
              let visible = userInfo["visible"] as? Bool else {
            logger.warning("handleShowCDSTranslationRequested: Missing userInfo keys")
            return
        }

        if visible {
            viewerView?.showCDSTranslation(for: annotation)
        } else {
            viewerView?.hideCDSTranslation()
        }
    }

    /// Handles annotation settings change notifications.
    ///
    /// Updates annotation display properties (visibility, height, spacing) and triggers a redraw.
    ///
    /// - Parameter notification: The notification containing userInfo with settings values.
    @objc private func handleAnnotationSettingsChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            logger.warning("handleAnnotationSettingsChanged: No userInfo in notification")
            return
        }

        logger.info("handleAnnotationSettingsChanged: Received annotation settings update")

        // Extract and apply showAnnotations setting
        if let show = userInfo["showAnnotations"] as? Bool {
            showAnnotations = show
            viewerView.showAnnotations = show
            logger.debug("handleAnnotationSettingsChanged: showAnnotations = \(show)")
        }

        // Extract and apply annotationHeight setting
        if let height = userInfo["annotationHeight"] as? CGFloat {
            annotationDisplayHeight = height
            viewerView.annotationHeight = height
            logger.debug("handleAnnotationSettingsChanged: annotationHeight = \(height)")
        } else if let height = userInfo["annotationHeight"] as? Double {
            annotationDisplayHeight = CGFloat(height)
            viewerView.annotationHeight = CGFloat(height)
            logger.debug("handleAnnotationSettingsChanged: annotationHeight = \(height)")
        }

        // Extract and apply annotationSpacing setting
        if let spacing = userInfo["annotationSpacing"] as? CGFloat {
            annotationDisplaySpacing = spacing
            viewerView.annotationRowSpacing = spacing
            logger.debug("handleAnnotationSettingsChanged: annotationSpacing = \(spacing)")
        } else if let spacing = userInfo["annotationSpacing"] as? Double {
            annotationDisplaySpacing = CGFloat(spacing)
            viewerView.annotationRowSpacing = CGFloat(spacing)
            logger.debug("handleAnnotationSettingsChanged: annotationSpacing = \(spacing)")
        }

        // Invalidate annotation tile and trigger redraw
        viewerView.invalidateAnnotationTile()
        viewerView.needsDisplay = true
        scheduleViewStateSave()
        logger.info("handleAnnotationSettingsChanged: Triggered viewer redraw")
    }

    /// Handles annotation filter change notifications.
    ///
    /// Updates annotation filtering (by type and text) and triggers a redraw.
    ///
    /// - Parameter notification: The notification containing userInfo with filter values.
    @objc private func handleAnnotationFilterChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            logger.warning("handleAnnotationFilterChanged: No userInfo in notification")
            return
        }

        logger.info("handleAnnotationFilterChanged: Received annotation filter update")

        // Extract and apply visibleTypes filter
        if let types = userInfo["visibleTypes"] as? Set<AnnotationType> {
            visibleAnnotationTypes = types
            viewerView.visibleAnnotationTypes = types
            logger.debug("handleAnnotationFilterChanged: visibleTypes = \(types.count) types")
        }

        // Extract and apply filterText
        if let text = userInfo["filterText"] as? String {
            annotationFilterText = text
            viewerView.annotationFilterText = text
            logger.debug("handleAnnotationFilterChanged: filterText = '\(text)'")
        }

        // Invalidate annotation tile and trigger redraw
        viewerView.invalidateAnnotationTile()
        viewerView.needsDisplay = true
        scheduleViewStateSave()
        logger.info("handleAnnotationFilterChanged: Triggered viewer redraw")
    }

    /// Handles variant filter changes from the inspector.
    @objc private func handleVariantFilterChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            logger.warning("handleVariantFilterChanged: No userInfo in notification")
            return
        }

        logger.info("handleVariantFilterChanged: Received variant filter update")

        if let show = userInfo[NotificationUserInfoKey.showVariants] as? Bool {
            viewerView.showVariants = show
            logger.debug("handleVariantFilterChanged: showVariants = \(show)")
        }
        if let types = userInfo[NotificationUserInfoKey.visibleVariantTypes] as? Set<String> {
            viewerView.visibleVariantTypes = types
            logger.debug("handleVariantFilterChanged: visibleVariantTypes = \(types.count) types")
        }
        if let text = userInfo[NotificationUserInfoKey.variantFilterText] as? String {
            viewerView.variantFilterText = text
            logger.debug("handleVariantFilterChanged: variantFilterText = '\(text)'")
        }

        viewerView.invalidateAnnotationTile()
        viewerView.needsDisplay = true
        scheduleViewStateSave()
        logger.info("handleVariantFilterChanged: Triggered viewer redraw")
    }

    /// Handles request to reset bundle view state to defaults.
    ///
    /// Clears type color overrides, deletes the `.viewstate.json` file,
    /// and resets the in-memory `BundleViewState` to defaults.
    @objc private func handleBundleViewStateResetRequested(_ notification: Notification) {
        logger.info("handleBundleViewStateResetRequested: Resetting bundle view state to defaults")

        // Clear type color caches and per-annotation colors (reverts to defaults)
        viewerView.resetTypeColorCaches()
        viewerView.clearAnnotationColorOverrides()

        // Reset in-memory state
        currentBundleViewState = .default

        // Delete persisted file
        if let url = currentBundleURL {
            BundleViewState.delete(from: url)
            logger.info("handleBundleViewStateResetRequested: Deleted .viewstate.json from bundle")
        }

        // Reset annotation display settings to defaults
        showAnnotations = true
        annotationDisplayHeight = 16
        annotationDisplaySpacing = 2
        visibleAnnotationTypes = nil
        isRNAMode = false
        viewerView.translationColorScheme = .zappo
        viewerView.showVariants = true
        viewerView.visibleVariantTypes = nil
    }

    // MARK: - Progress Indicator

    /// Shows the progress overlay with a message
    public func showProgress(_ message: String) {
        logger.info("showProgress: '\(message, privacy: .public)'")
        progressOverlay.message = message
        progressOverlay.isHidden = false
        progressOverlay.startAnimating()
    }

    /// Hides the progress overlay
    public func hideProgress() {
        logger.info("hideProgress: Hiding progress overlay")
        progressOverlay.stopAnimating()
        progressOverlay.isHidden = true
    }

    /// Clears the viewer, removing all displayed sequences and annotations.
    ///
    /// Call this when the sidebar selection is cleared to show an empty viewer.
    public func clearViewer() {
        logger.info("clearViewer: Clearing viewer")
        currentDocument = nil
        referenceFrame = nil

        // Clear the viewer view
        viewerView.hideTranslation()
        viewerView.clearSequences()
        viewerView.setAnnotations([])

        // Clear header
        headerView.setTrackNames([])
        if let emptyState = viewerView.multiSequenceState {
            emptyState.clear()
        }
        headerView.setStackedSequences([])

        // Clear ruler
        enhancedRulerView.referenceFrame = nil

        // Update status bar
        statusBar.update(position: "No sequence loaded", selection: nil, scale: 1.0)

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        logger.info("clearViewer: Viewer cleared")
    }

    /// Shows the "No sequence selected" state.
    ///
    /// Call this when a project is open but has no sequences, or when no sequence is selected.
    /// This differs from clearViewer() in the message shown - this indicates an active project
    /// context where the user hasn't selected a sequence yet.
    public func showNoSequenceSelected() {
        logger.info("showNoSequenceSelected: Setting empty state with 'No sequence selected'")

        // First ensure any progress overlay is hidden
        hideProgress()

        // Clear current state
        currentDocument = nil
        referenceFrame = nil

        // Clear the viewer view
        viewerView.hideTranslation()
        viewerView.clearSequences()
        viewerView.setAnnotations([])

        // Clear header
        headerView.setTrackNames([])
        if let emptyState = viewerView.multiSequenceState {
            emptyState.clear()
        }
        headerView.setStackedSequences([])

        // Clear ruler
        enhancedRulerView.referenceFrame = nil

        // Update status bar with the specific message
        statusBar.update(position: "No sequence selected", selection: nil, scale: 1.0)

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        logger.info("showNoSequenceSelected: Empty state set")
    }

    // MARK: - Document Display

    /// Displays a loaded document in the viewer.
    public func displayDocument(_ document: LoadedDocument) {
        logger.info("displayDocument: Starting to display '\(document.name, privacy: .public)'")
        
        // Hide any QuickLook preview when showing a genomics document
        hideQuickLookPreview()
        logger.info("displayDocument: Document has \(document.sequences.count) sequences, \(document.annotations.count) annotations")

        currentDocument = document

        // Update reference frame based on first sequence
        if let firstSequence = document.sequences.first {
            let length = firstSequence.length
            logger.info("displayDocument: First sequence '\(firstSequence.name, privacy: .public)' has length \(length)")

            // IMPORTANT: Force layout to ensure bounds are valid before creating ReferenceFrame
            view.layoutSubtreeIfNeeded()

            // Use a reasonable default width if bounds are still 0
            let effectiveWidth = max(800, Int(viewerView.bounds.width))

            referenceFrame = ReferenceFrame(
                chromosome: firstSequence.name,
                start: 0,
                end: Double(min(length, 10000)),  // Start zoomed in
                pixelWidth: effectiveWidth,
                sequenceLength: length
            )
            logger.debug("displayDocument: Created referenceFrame start=0 end=\(min(length, 10000)) width=\(effectiveWidth)")

            // Pass data to viewer
            logger.info("displayDocument: Setting sequence on viewerView...")
            viewerView.setSequence(firstSequence)
            viewerView.setAnnotations(document.annotations)
            logger.info("displayDocument: Sequence and annotations set on viewerView")

            // Update header with track names
            let trackNames = [firstSequence.name] + (document.annotations.isEmpty ? [] : ["Annotations"])
            headerView.setTrackNames(trackNames)
            logger.debug("displayDocument: Set track names: \(trackNames, privacy: .public)")

            // Update ruler
            enhancedRulerView.referenceFrame = referenceFrame
            logger.debug("displayDocument: Updated ruler reference frame")
        } else {
            logger.warning("displayDocument: No sequences in document!")
        }

        // Trigger immediate redraw
        logger.info("displayDocument: Triggering redraw of all views...")
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true
        updateStatusBar()

        // Schedule another redraw after a short delay to handle any remaining layout timing issues
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            // Update reference frame width if it changed
            if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                frame.pixelWidth = Int(self.viewerView.bounds.width)
            }

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
        }

        logger.info("displayDocument: Completed displaying document")
    }
    
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

        // Hide the progress overlay first - it may be covering the view area
        hideProgress()

        // Hide the genomics viewer components including the ruler
        hideGenomicsViewer()

        // Remove any existing preview views
        removePreviewViews()

        // Store the URL
        quickLookURL = fileURL

        // For PDFs, use PDFKit (more reliable than QLPreviewView for embedded use)
        let ext = fileURL.pathExtension.lowercased()

        if ext == "pdf" {
            displayPDFPreview(url: fileURL)
            return
        }

        // For other files, use QLPreviewView with proper QuickLookItem wrapper
        displayQLPreview(url: fileURL)
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
        logger.debug("displayPDFPreview: Parent wantsLayer: \(self.view.wantsLayer)")
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

        // Create PDF view - DON'T set wantsLayer, let PDFKit manage its own rendering
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
        logger.debug("displayPDFPreview: PDFView wantsLayer: \(pdfDisplayView.wantsLayer)")
        logger.debug("displayPDFPreview: PDFView layer: \(String(describing: pdfDisplayView.layer))")

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

        logger.debug("removePreviewViews: Cleanup complete")
    }
    
    /// Hides the QuickLook/PDF preview and shows the genomics viewer
    public func hideQuickLookPreview() {
        guard quickLookView != nil || pdfView != nil else { return }
        
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
    private func showGenomicsViewer() {
        viewerView.isHidden = false
        headerView.isHidden = false
        enhancedRulerView.isHidden = false
    }

    /// Displays multiple loaded documents in the viewer with stacked sequences.
    ///
    /// This method collects all sequences from the provided documents and displays them
    /// using the multi-sequence stacking system. Each sequence appears as a separate
    /// track in the viewer, allowing side-by-side comparison.
    ///
    /// - Parameter documents: Array of documents to display
    public func displayDocuments(_ documents: [LoadedDocument]) {
        logger.info("displayDocuments: Displaying \(documents.count) documents with multi-sequence stacking")
        
        guard !documents.isEmpty else {
            logger.warning("displayDocuments: No documents provided")
            return
        }
        
        // Collect all sequences from all documents
        var allSequences: [Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []
        
        for document in documents {
            allSequences.append(contentsOf: document.sequences)
            allAnnotations.append(contentsOf: document.annotations)
            logger.debug("displayDocuments: Added \(document.sequences.count) sequences from '\(document.name)'")
        }
        
        logger.info("displayDocuments: Total collected: \(allSequences.count) sequences, \(allAnnotations.count) annotations")
        
        guard !allSequences.isEmpty else {
            logger.warning("displayDocuments: No sequences found in any document")
            return
        }
        
        // Use first document as the "current" document for UI purposes
        currentDocument = documents.first
        
        // Find the longest sequence to set up the reference frame
        let longestSequence = allSequences.max(by: { $0.length < $1.length }) ?? allSequences.first!
        let maxLength = longestSequence.length
        
        logger.info("displayDocuments: Longest sequence '\(longestSequence.name)' has length \(maxLength)")
        
        // Force layout to ensure valid bounds
        view.layoutSubtreeIfNeeded()
        
        let effectiveWidth = max(800, Int(viewerView.bounds.width))
        
        // Create reference frame based on the longest sequence
        referenceFrame = ReferenceFrame(
            chromosome: longestSequence.name,
            start: 0,
            end: Double(maxLength),
            pixelWidth: effectiveWidth,
            sequenceLength: maxLength
        )
        logger.debug("displayDocuments: Created referenceFrame for max length \(maxLength)")
        
        // Pass all sequences to the viewer using multi-sequence support
        viewerView.setSequences(allSequences)
        viewerView.setAnnotations(allAnnotations)

        // Update header with stacked sequence info for precise alignment
        if let stackedSeqs = viewerView.multiSequenceState?.stackedSequences, !stackedSeqs.isEmpty {
            headerView.setStackedSequences(stackedSeqs)
            logger.debug("displayDocuments: Set \(stackedSeqs.count) stacked sequence entries in header")
        } else {
            // Fallback to simple track names
            let trackNames = allSequences.map { $0.name }
            headerView.setTrackNames(trackNames)
            logger.debug("displayDocuments: Set \(trackNames.count) track names (fallback)")
        }

        // Update ruler
        enhancedRulerView.referenceFrame = referenceFrame

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true
        updateStatusBar()

        // Schedule delayed redraw for layout timing and header sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                frame.pixelWidth = Int(self.viewerView.bounds.width)
            }

            // Re-sync header with updated stacked sequences
            if let stackedSeqs = self.viewerView.multiSequenceState?.stackedSequences, !stackedSeqs.isEmpty {
                self.headerView.setStackedSequences(stackedSeqs)
            }

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
        }
        
        logger.info("displayDocuments: Completed displaying \(allSequences.count) sequences stacked")
    }
    
    // MARK: - Reference Bundle Display
    
    /// Displays a reference genome bundle in the viewer.
    ///
    /// This method loads and displays a `.lungfishref` bundle, using the indexed
    /// readers for efficient random access to the compressed genome sequence
    /// and SQLite annotation tracks.
    ///
    /// - Parameter bundle: The ReferenceBundle to display
    public func displayReferenceBundle(_ bundle: LungfishIO.ReferenceBundle) async {
        logger.info("displayReferenceBundle: Starting to display bundle '\(bundle.name, privacy: .public)'")

        // Hide any QuickLook preview
        hideQuickLookPreview()

        // Store bundle reference for later use
        currentReferenceBundle = bundle
        currentDocument = nil  // Bundle replaces regular document

        // Force layout to ensure valid bounds
        view.layoutSubtreeIfNeeded()
        let effectiveWidth = max(800, Int(viewerView.bounds.width))

        // Get the first chromosome to display
        guard let firstChrom = bundle.manifest.genome.chromosomes.first else {
            logger.error("displayReferenceBundle: No chromosomes in bundle")
            return
        }

        let chromLength = Int(firstChrom.length)
        logger.info("displayReferenceBundle: First chromosome '\(firstChrom.name, privacy: .public)' length=\(chromLength)")

        // Create reference frame for the chromosome
        referenceFrame = ReferenceFrame(
            chromosome: firstChrom.name,
            start: 0,
            end: Double(min(chromLength, 10000)),  // Start zoomed to first 10kb
            pixelWidth: effectiveWidth,
            sequenceLength: chromLength
        )

        // Set up the viewer with bundle information
        viewerView.setReferenceBundle(bundle)

        // Update header with chromosome names
        let trackNames = [firstChrom.name] + bundle.annotationTrackIds.map { "Annotations: \($0)" }
        headerView.setTrackNames(trackNames)

        // Update ruler
        enhancedRulerView.referenceFrame = referenceFrame

        // Update status bar
        updateStatusBar()

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        // Schedule delayed redraw for layout timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                frame.pixelWidth = Int(self.viewerView.bounds.width)
            }

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
        }

        logger.info("displayReferenceBundle: Completed displaying bundle")
    }
    
    /// The currently displayed reference bundle, if any.
    public private(set) var currentReferenceBundle: LungfishIO.ReferenceBundle?

    // MARK: - Public API

    /// Zooms in on the current view
    public func zoomIn() {
        referenceFrame?.zoomIn(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
        scheduleViewStateSave()
    }

    /// Zooms out from the current view
    public func zoomOut() {
        referenceFrame?.zoomOut(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
        scheduleViewStateSave()
    }

    /// Zooms to fit the entire sequence
    public func zoomToFit() {
        guard let sequence = viewerView.sequence else { return }
        referenceFrame?.start = 0
        referenceFrame?.end = Double(sequence.length)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
    }

    /// Resets zoom to show ~10kb window centered on current view
    public func zoomReset() {
        guard let frame = referenceFrame else { return }
        
        let center = (frame.start + frame.end) / 2
        let defaultWindow: Double = 10000  // 10kb default window
        
        var newStart = center - defaultWindow / 2
        var newEnd = center + defaultWindow / 2
        
        // Clamp to bounds
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), defaultWindow)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - defaultWindow)
        }
        
        frame.start = newStart
        frame.end = newEnd
        
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
    }

    /// Navigates to a specific genomic region
    public func navigate(to region: GenomicRegion) {
        let seqLength = viewerView.sequence?.length ?? Int.max
        referenceFrame = ReferenceFrame(
            chromosome: region.chromosome,
            start: Double(region.start),
            end: Double(region.end),
            pixelWidth: Int(view.bounds.width),
            sequenceLength: seqLength
        )
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
    }

    /// Navigates to a specific position or range in the sequence.
    ///
    /// This method handles various input formats for genomic navigation:
    /// - Single position: "1000" - centers view on position 1000 with a default window
    /// - With chromosome: "chr1:1000" - navigates to position on specified chromosome
    /// - Range formats: "chr1:1000-2000" or "chr1:1000..2000" - shows the specified range
    ///
    /// - Parameters:
    ///   - chromosome: Optional chromosome/sequence name (uses current if nil)
    ///   - start: Start position (0-based)
    ///   - end: End position (optional, if nil centers on start with default window)
    /// - Returns: True if navigation succeeded, false if no sequence loaded or invalid coordinates
    @discardableResult
    public func navigateToPosition(chromosome: String?, start: Int, end: Int?) -> Bool {
        guard let frame = referenceFrame else {
            logger.warning("navigateToPosition: No reference frame available")
            return false
        }
        
        let seqLength = frame.sequenceLength
        
        // Validate start position
        guard start >= 0 && start < seqLength else {
            logger.warning("navigateToPosition: Start position \(start) out of bounds (0..<\(seqLength))")
            return false
        }
        
        let effectiveEnd: Int
        if let end = end {
            // Range specified - validate end position
            guard end > start && end <= seqLength else {
                logger.warning("navigateToPosition: End position \(end) invalid (must be >\(start) and <=\(seqLength))")
                return false
            }
            effectiveEnd = end
        } else {
            // Single position - create a centered window
            // Use a default window size of 1000 bp, or smaller if near boundaries
            let defaultWindow = 1000
            let halfWindow = defaultWindow / 2
            
            var windowStart = max(0, start - halfWindow)
            var windowEnd = min(seqLength, start + halfWindow)
            
            // Adjust if window hits a boundary
            if windowStart == 0 {
                windowEnd = min(seqLength, defaultWindow)
            }
            if windowEnd == seqLength {
                windowStart = max(0, seqLength - defaultWindow)
            }
            
            frame.start = Double(windowStart)
            frame.end = Double(windowEnd)
            
            // Update chromosome if provided
            if let chr = chromosome {
                frame.chromosome = chr
            }
            
            viewerView.setNeedsDisplay(viewerView.bounds)
            enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
            updateStatusBar()
            
            logger.info("navigateToPosition: Centered on position \(start), window \(windowStart)-\(windowEnd)")
            return true
        }
        
        // Navigate to the specified range
        frame.start = Double(start)
        frame.end = Double(effectiveEnd)
        
        // Update chromosome if provided
        if let chr = chromosome {
            frame.chromosome = chr
        }
        
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
        
        logger.info("navigateToPosition: Showing range \(start)-\(effectiveEnd)")
        return true
    }

    public func updateStatusBar() {
        guard let frame = referenceFrame else { return }
        // Preserve selection info if we have one from the viewer
        let selectionInfo = viewerView.selectionRange.map { range in
            let length = range.upperBound - range.lowerBound
            return "\(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)"
        }
        statusBar.update(
            position: "\(frame.chromosome):\(Int(frame.start))-\(Int(frame.end))",
            selection: selectionInfo,
            scale: frame.scale
        )

        // Notify toolbar / other observers about coordinate changes
        NotificationCenter.default.post(
            name: .viewerCoordinatesChanged,
            object: self,
            userInfo: [
                NotificationUserInfoKey.chromosome: frame.chromosome,
                NotificationUserInfoKey.start: Int(frame.start),
                NotificationUserInfoKey.end: Int(frame.end),
            ]
        )
    }

    /// Updates track heights in all views when appearance settings change.
    public func updateTrackHeights(_ newHeight: CGFloat) {
        viewerView.trackHeight = newHeight
        headerView.trackHeight = newHeight
        viewerView.needsDisplay = true
        headerView.needsDisplay = true
    }

    /// Handles file drop from the viewer view
    ///
    /// For files already in the project folder, loads them directly.
    /// For external files, copies them into the project's downloads folder first.
    func handleFileDrop(_ urls: [URL]) {
        logger.info("handleFileDrop: Received \(urls.count) URLs")

        // Process files sequentially
        guard let firstURL = urls.first else {
            logger.warning("handleFileDrop: No URLs to process")
            return
        }

        logger.info("handleFileDrop: Processing '\(firstURL.lastPathComponent, privacy: .public)'")

        // Get the project/working directory to determine if file is internal or external
        let projectURL = DocumentManager.shared.activeProject?.url
        let workingURL = (NSApp.delegate as? AppDelegate)?.getWorkingDirectoryURL()

        let isInternalFile: Bool
        if let project = projectURL {
            isInternalFile = firstURL.path.hasPrefix(project.path)
        } else if let working = workingURL {
            isInternalFile = firstURL.path.hasPrefix(working.path)
        } else {
            isInternalFile = false
        }

        logger.info("handleFileDrop: isInternalFile=\(isInternalFile)")

        // Use DispatchQueue.main.async to exit the drag operation context first,
        // then use Task to avoid deadlock with @MainActor DocumentManager
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Show progress after exiting drag context
            self.showProgress("Loading \(firstURL.lastPathComponent)...")

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                do {
                    let urlToLoad: URL

                    if isInternalFile {
                        // File is already in project, load directly
                        urlToLoad = firstURL
                        logger.info("handleFileDrop: Loading internal file directly")
                    } else {
                        // External file - copy to project downloads folder
                        logger.info("handleFileDrop: External file, copying to project")
                        urlToLoad = try await self.copyExternalFileToProject(firstURL, projectURL: projectURL, workingURL: workingURL)
                    }

                    let document = try await DocumentManager.shared.loadDocument(at: urlToLoad)

                    self.hideProgress()
                    self.displayDocument(document)

                    // With filesystem-backed sidebar: if file is inside project, watcher handles refresh
                    // Otherwise add to "Open Documents" section
                    if let appDelegate = NSApp.delegate as? AppDelegate,
                       let sidebarController = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                        if let projectURL = sidebarController.currentProjectURL {
                            let docPath = document.url.standardizedFileURL.path
                            let projectPath = projectURL.standardizedFileURL.path
                            if !docPath.hasPrefix(projectPath) {
                                // File is outside project - add to sidebar
                                sidebarController.addLoadedDocument(document)
                            }
                            // Else: File is inside project, FileSystemWatcher handles it
                        } else {
                            // No project open - add to sidebar
                            sidebarController.addLoadedDocument(document)
                        }
                    }
                } catch {
                    logger.error("handleFileDrop: Load failed: \(error.localizedDescription, privacy: .public)")

                    self.hideProgress()
                    let alert = NSAlert()
                    alert.messageText = "Failed to Open File"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Copies an external file into the project's downloads folder
    private func copyExternalFileToProject(_ sourceURL: URL, projectURL: URL?, workingURL: URL?) async throws -> URL {
        let fileManager = FileManager.default

        // Determine destination directory
        let destinationDirectory: URL
        if let project = projectURL {
            destinationDirectory = project.appendingPathComponent("downloads", isDirectory: true)
        } else if let working = workingURL {
            destinationDirectory = working.appendingPathComponent("downloads", isDirectory: true)
        } else {
            // Fallback to user's Downloads folder
            let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create directory if needed
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        // Generate unique filename
        var destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 1
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        while fileManager.fileExists(atPath: destinationURL.path) {
            let newName = "\(baseName)_\(counter).\(ext)"
            destinationURL = destinationDirectory.appendingPathComponent(newName)
            counter += 1
        }

        // Copy file
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        logger.info("handleFileDrop: Copied to \(destinationURL.path, privacy: .public)")

        return destinationURL
    }
}

// MARK: - ProgressOverlayView

/// A translucent overlay showing a spinner and message during loading.
///
/// Includes a safety timeout that auto-hides the overlay after 30 seconds
/// to prevent indefinitely stuck progress indicators.
public class ProgressOverlayView: NSView {

    private var spinner: NSProgressIndicator!
    private var messageLabel: NSTextField!
    private nonisolated(unsafe) var timeoutTimer: Timer?

    /// Default timeout in seconds before auto-hiding the progress overlay.
    /// This prevents stuck spinners from indefinite operations.
    private let defaultTimeout: TimeInterval = 30.0

    public var message: String = "Loading..." {
        didSet {
            messageLabel?.stringValue = message
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor

        // Spinner
        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        addSubview(spinner)

        // Message label
        messageLabel = NSTextField(labelWithString: message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),

            messageLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    /// Starts the spinner animation with an optional timeout.
    ///
    /// If the overlay isn't hidden before the timeout, it will auto-hide as a safety measure.
    /// - Parameter timeout: Optional custom timeout. Defaults to 30 seconds.
    public func startAnimating(timeout: TimeInterval? = nil) {
        spinner.startAnimation(nil)

        // Cancel any existing timeout
        timeoutTimer?.invalidate()

        // Set new timeout as safety net
        let timeoutInterval = timeout ?? defaultTimeout
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stopAnimating()
            self.isHidden = true
        }
    }

    /// Stops the spinner animation and cancels any pending timeout.
    public func stopAnimating() {
        spinner.stopAnimation(nil)
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    deinit {
        timeoutTimer?.invalidate()
    }
}

// MARK: - SequenceViewerView

/// The main view for rendering sequence and track data.
/// Note: Uses @MainActor for thread safety as it contains mutable UI state.
@MainActor
public class SequenceViewerView: NSView {

    /// Reference to the parent controller
    weak var viewController: ViewerViewController?

    /// The sequence being displayed
    private(set) var sequence: Sequence?

    /// Annotations to overlay
    private var annotations: [SequenceAnnotation] = []
    
    /// The reference bundle being displayed (for .lungfishref bundles)
    private(set) var currentReferenceBundle: ReferenceBundle?
    
    /// Cached sequence data for the current visible region (for bundle mode)
    private var cachedBundleSequence: String?

    /// The region for which we have cached sequence data
    private var cachedSequenceRegion: GenomicRegion?

    /// Error message from the last failed bundle fetch, if any
    private var bundleFetchError: String?

    /// Region of the last failed fetch (to prevent infinite retry for the same region)
    private var failedFetchRegion: GenomicRegion?

    /// Cached annotations for the current visible region (for bundle mode)
    private var cachedBundleAnnotations: [SequenceAnnotation] = []

    /// The region for which we have cached annotation data
    private var cachedAnnotationRegion: GenomicRegion?

    /// Whether we're currently fetching bundle data (sequence)
    private var isFetchingBundleData: Bool = false

    /// Timestamp when the current sequence fetch started (for stuck-state detection)
    private var sequenceFetchStartTime: Date?

    /// Generation counter for sequence fetches — prevents stale results from overwriting newer ones
    private var sequenceFetchGeneration: Int = 0

    /// Whether we're currently fetching annotation data
    private var isFetchingAnnotations: Bool = false

    /// Timestamp when the current annotation fetch started (for stuck-state detection)
    private var annotationFetchStartTime: Date?

    /// Generation counter for annotation fetches — prevents stale results from overwriting newer ones
    private var annotationFetchGeneration: Int = 0

    /// Cached variant annotations for the current visible region (rendered alongside gene annotations)
    private var cachedVariantAnnotations: [SequenceAnnotation] = []

    /// The region for which we have cached variant data
    private var cachedVariantRegion: GenomicRegion?

    /// Whether we're currently fetching variant data
    private var isFetchingVariants: Bool = false

    /// Generation counter for variant fetches — prevents stale results from overwriting newer ones
    private var variantFetchGeneration: Int = 0

    /// Whether drag is active (for highlighting)
    private var isDragActive = false

    /// Current appearance settings for sequence visualization
    private var sequenceAppearance: SequenceAppearance = .load()

    // MARK: - Selection State

    /// Current selection range in base coordinates (nil if no selection)
    public private(set) var selectionRange: Range<Int>?

    /// Mouse drag start position for selection
    private var selectionStartBase: Int?

    /// Whether we're currently dragging to select
    private var isSelecting = false

    /// Currently selected annotation (nil if no annotation selected).
    /// Internal so the AnnotationDrawer extension can set it from table selection.
    var selectedAnnotation: SequenceAnnotation?

    /// Popover for annotation details on double-click
    private var annotationPopover: NSPopover?

    /// Track positioning (shared with header)
    var trackY: CGFloat = 20
    var trackHeight: CGFloat = 40

    /// Whether to show complement strand
    var showComplementStrand: Bool = false

    /// Whether to display as RNA (U instead of T)
    var isRNAMode: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    // MARK: - Translation Track State

    /// Whether the translation track is visible below the sequence track.
    var showTranslationTrack: Bool = false

    /// Pre-computed CDS translation result (set when user clicks "Translate" on a CDS annotation).
    var activeTranslationResult: TranslationResult?

    /// Color scheme for amino acid rendering.
    var translationColorScheme: AminoAcidColorScheme = .zappo

    /// Reading frames to display in frame-translation mode (empty = CDS mode).
    var frameTranslationFrames: [ReadingFrame] = []

    /// Codon table for frame translations.
    var frameTranslationTable: CodonTable = .standard

    /// Whether to render stop codon cells in translation tracks.
    var translationShowStopCodons: Bool = true

    // MARK: - Annotation Track Layout Constants

    /// Y offset where annotation track starts (below sequence + optional translation track).
    ///
    /// Only reserves space for the translation track when it is actually rendering
    /// at the current zoom level (scale < showLettersThreshold). At zoom levels where
    /// translation doesn't render, annotations are placed directly below the sequence.
    private var annotationTrackY: CGFloat {
        var y = trackY + trackHeight + 4
        if showTranslationTrack {
            let currentScale = viewController?.referenceFrame?.scale ?? Double.greatestFiniteMagnitude
            if currentScale < showLettersThreshold {
                y += translationTrackTotalHeight + 4
            }
        }
        return y
    }

    /// Total height of the translation track area.
    private var translationTrackTotalHeight: CGFloat {
        if !frameTranslationFrames.isEmpty {
            return TranslationTrackRenderer.totalHeight(for: frameTranslationFrames)
        } else {
            return TranslationTrackRenderer.cdsTrackHeight()
        }
    }

    /// Whether to show annotations (controlled by inspector)
    var showAnnotations: Bool = true

    /// Height of each annotation box (configurable via inspector)
    var annotationHeight: CGFloat = 16

    /// Vertical spacing between annotation rows (configurable via inspector)
    var annotationRowSpacing: CGFloat = 2

    /// Set of annotation types to display (nil means show all)
    var visibleAnnotationTypes: Set<AnnotationType>?

    /// Text filter for annotations (empty string means no filter)
    var annotationFilterText: String = ""

    /// Whether to show variant annotations (controlled by inspector)
    var showVariants: Bool = true

    /// Set of variant types to display (nil means show all). Values are VariantType rawValues: "SNP", "INS", "DEL", etc.
    var visibleVariantTypes: Set<String>?

    /// Text filter for variants (searches variant IDs)
    var variantFilterText: String = ""

    // MARK: - Annotation Color Cache

    /// Cached CGColors keyed by AnnotationType to avoid NSColor allocation per-draw.
    /// Cleared on appearance change (dark mode toggle). Also stores per-type color overrides
    /// loaded from BundleViewState.
    var typeColorCache: [AnnotationType: (fill: CGColor, stroke: CGColor)] = [:]

    /// Returns cached (fill, stroke) CGColor pair for an annotation.
    /// Uses the annotation's custom color if set, otherwise caches by type.
    private func cachedColors(for annot: SequenceAnnotation) -> (fill: CGColor, stroke: CGColor) {
        // Fast path: no custom color → use type-based cache
        if annot.color == nil, let cached = typeColorCache[annot.type] {
            return cached
        }
        let annotColor = annot.color ?? annot.type.defaultColor
        let nsColor = NSColor(
            calibratedRed: CGFloat(annotColor.red),
            green: CGFloat(annotColor.green),
            blue: CGFloat(annotColor.blue),
            alpha: 1.0
        )
        let fill = nsColor.withAlphaComponent(0.7).cgColor
        let stroke = nsColor.cgColor
        if annot.color == nil {
            typeColorCache[annot.type] = (fill, stroke)
        }
        return (fill, stroke)
    }

    /// Cached CGColors for density histogram bars keyed by AnnotationType.
    var typeDensityColorCache: [AnnotationType: CGColor] = [:]

    /// Returns a cached density-bar CGColor (0.6 alpha) for a given annotation type.
    private func cachedDensityColor(for type: AnnotationType) -> CGColor {
        if let cached = typeDensityColorCache[type] { return cached }
        let typeColor = type.defaultColor
        let nsColor = NSColor(
            calibratedRed: CGFloat(typeColor.red),
            green: CGFloat(typeColor.green),
            blue: CGFloat(typeColor.blue),
            alpha: 0.6
        )
        let color = nsColor.cgColor
        typeDensityColorCache[type] = color
        return color
    }

    // MARK: - Offscreen Annotation Tile

    /// Pre-rendered annotation tile image for fast pan blitting.
    private var annotationTile: CGImage?

    /// Genomic start position of the rendered tile.
    private var tileGenomicStart: Double = 0

    /// Genomic end position of the rendered tile.
    private var tileGenomicEnd: Double = 0

    /// The bp/pixel scale at which the tile was rendered.
    private var tileScale: Double = 0

    /// Pixel width of the tile image.
    private var tileWidth: Int = 0

    /// Pixel height of the tile image.
    private var tileHeight: Int = 0

    /// The chromosome the tile was rendered for.
    private var tileChromosome: String = ""

    /// Invalidates the annotation tile, forcing re-render on next draw.
    func invalidateAnnotationTile() {
        annotationTile = nil
    }

    // MARK: - Scroll Coalescing

    /// Timer for coalescing scroll-triggered redraws at 60fps.
    private var scrollRedrawTimer: Timer?

    // MARK: - Zoom Thresholds (bp/pixel)
    //
    // Rendering modes based on zoom level:
    // - BASE_MODE: < 10 bp/pixel - Individual colored bases with letters
    // - BLOCK_MODE: 10-500 bp/pixel - Colored blocks showing dominant base
    // - LINE_MODE: > 500 bp/pixel - Simple gray horizontal line

    /// Below this threshold: show individual base letters with colors
    /// At this zoom level, bases are large enough to read
    private let showLettersThreshold: Double = 10.0

    /// Above this threshold: switch from colored blocks to simple line
    /// Beyond this zoom level, colored blocks become uninformative visual noise
    private let showLineThreshold: Double = 500.0

    // MARK: - Quality Score Colors

    /// Quality score color thresholds for overlay rendering.
    /// Maps Phred quality scores to colors indicating confidence levels.
    private enum QualityColors {
        /// Q < 10: Dark red - very low quality (>10% error rate)
        static let veryLow = NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 0.5)

        /// Q 10-19: Red - low quality (1-10% error rate)
        static let low = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)

        /// Q 20-29: Orange - medium quality (0.1-1% error rate)
        static let medium = NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.0, alpha: 0.5)

        /// Q 30-39: Light green - good quality (0.01-0.1% error rate)
        static let good = NSColor(calibratedRed: 0.56, green: 0.93, blue: 0.56, alpha: 0.5)

        /// Q >= 40: Green - high quality (<0.01% error rate)
        static let high = NSColor(calibratedRed: 0.0, green: 0.67, blue: 0.0, alpha: 0.5)

        /// Returns the appropriate color for a given quality score.
        ///
        /// - Parameter score: Phred quality score (0-93)
        /// - Returns: Color indicating the quality level
        static func color(forScore score: UInt8) -> NSColor {
            switch score {
            case 0..<10:
                return veryLow
            case 10..<20:
                return low
            case 20..<30:
                return medium
            case 30..<40:
                return good
            default:
                return high
            }
        }
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDragAndDrop()
        setupAppearanceObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDragAndDrop()
        setupAppearanceObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupDragAndDrop() {
        // Register for file drops
        logger.info("SequenceViewerView.setupDragAndDrop: Registering for file URL drag type")
        registerForDraggedTypes([.fileURL])
        logger.info("SequenceViewerView.setupDragAndDrop: Registration complete")
    }

    /// Sets up observer for appearance change notifications.
    private func setupAppearanceObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChanged(_:)),
            name: .appearanceChanged,
            object: nil
        )
        logger.debug("SequenceViewerView: Appearance change observer registered")
    }

    /// Handles appearance change notifications by reloading settings and redrawing.
    @objc private func handleAppearanceChanged(_ notification: Notification) {
        sequenceAppearance = .load()

        // Update track height from appearance settings
        trackHeight = sequenceAppearance.trackHeight
        logger.info("SequenceViewerView: Track height updated to \(self.trackHeight)")

        // Also update the header view track height
        viewController?.updateTrackHeights(sequenceAppearance.trackHeight)

        needsDisplay = true
        logger.info("SequenceViewerView: Appearance changed, triggering redraw")
    }

    // MARK: - Data Setters

    func setSequence(_ seq: Sequence) {
        logger.info("SequenceViewerView.setSequence: Setting sequence '\(seq.name, privacy: .public)' length=\(seq.length)")
        if sequence?.id != seq.id {
            // Translation overlays are tied to a specific sequence context.
            hideTranslation()
        }
        self.sequence = seq
        logger.info("SequenceViewerView.setSequence: self.sequence is now \(self.sequence == nil ? "nil" : "SET", privacy: .public)")

        // Request immediate display refresh
        needsDisplay = true

        // If bounds are not valid yet, schedule a redraw after layout
        if bounds.width <= 0 || bounds.height <= 0 {
            logger.info("SequenceViewerView.setSequence: bounds not ready (\(self.bounds.width)x\(self.bounds.height)), scheduling delayed redraw")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.needsDisplay = true
                logger.info("SequenceViewerView.setSequence: Delayed redraw triggered, bounds=\(self.bounds.width)x\(self.bounds.height)")
            }
        }

        logger.info("SequenceViewerView.setSequence: Requested display refresh, bounds=\(self.bounds.width, privacy: .public)x\(self.bounds.height, privacy: .public)")
    }

    func setAnnotations(_ annots: [SequenceAnnotation]) {
        logger.info("SequenceViewerView.setAnnotations: Setting \(annots.count) annotations")
        self.annotations = annots

        // Update multi-sequence state with annotations if in multi-sequence mode
        if isMultiSequenceMode {
            updateMultiSequenceAnnotations(annots)
            logger.debug("SequenceViewerView.setAnnotations: Updated multi-sequence annotations")
        }

        // Clear selection if the selected annotation is no longer in the list
        if let selected = selectedAnnotation,
           !annots.contains(where: { $0.id == selected.id }) {
            selectedAnnotation = nil
        }
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        logger.debug("SequenceViewerView.setAnnotations: Requested display refresh")
    }

    /// Updates a single annotation in-place (both document and bundle caches).
    ///
    /// Used when the inspector changes an annotation's color, name, or other properties.
    /// Handles both document mode (`annotations`) and bundle mode (`cachedBundleAnnotations`).
    func updateAnnotation(_ annotation: SequenceAnnotation) {
        var updated = false

        // Update in document-mode annotations
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = annotation
            updated = true
        }

        // Update in bundle-mode cached annotations
        if let index = cachedBundleAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            cachedBundleAnnotations[index] = annotation
            updated = true
        }

        // Update in variant annotations
        if let index = cachedVariantAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            cachedVariantAnnotations[index] = annotation
            updated = true
        }

        if updated {
            // Persist per-annotation color override to BundleViewState
            if let color = annotation.color, let vc = viewController {
                let key = annotation.colorOverrideKey
                var state = vc.currentBundleViewState ?? .default
                state.annotationColorOverrides[key] = color
                vc.currentBundleViewState = state
                vc.scheduleViewStateSave()
            }

            invalidateAnnotationTile()
            setNeedsDisplay(bounds)
        }
    }

    /// Applies a color to all annotations of a given type (both document and bundle caches).
    ///
    /// Used when the inspector applies a color to all annotations of a specific type.
    func applyColorToType(_ type: AnnotationType, color: AnnotationColor) {
        var updatedCount = 0

        // Update in document-mode annotations
        for (index, annotation) in annotations.enumerated() where annotation.type == type {
            var updated = annotation
            updated.color = color
            annotations[index] = updated
            updatedCount += 1
        }

        // Update in bundle-mode cached annotations
        for (index, annotation) in cachedBundleAnnotations.enumerated() where annotation.type == type {
            var updated = annotation
            updated.color = color
            cachedBundleAnnotations[index] = updated
            updatedCount += 1
        }

        if updatedCount > 0 {
            // Clear CGColor caches since type colors changed
            typeColorCache.removeAll()
            typeDensityColorCache.removeAll()
            invalidateAnnotationTile()
            setNeedsDisplay(bounds)
            logger.info("applyColorToType: Updated \(updatedCount) \(type.rawValue) annotations")
        }

        // Propagate to bundle view state for persistence
        if let vc = viewController {
            var state = vc.currentBundleViewState ?? .default
            state.typeColorOverrides[type] = color
            vc.currentBundleViewState = state
            vc.scheduleViewStateSave()
        }
    }

    /// Applies per-type color overrides from a saved view state.
    ///
    /// Pre-populates the type color caches so that annotations of the given types
    /// render with the override color instead of the default. The color resolution
    /// order remains: per-annotation color > per-type override > default type color.
    func applyTypeColorOverrides(_ overrides: [AnnotationType: AnnotationColor]) {
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()

        for (type, color) in overrides {
            let nsColor = NSColor(
                calibratedRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: 1.0
            )
            let fill = nsColor.withAlphaComponent(0.7).cgColor
            let stroke = nsColor.cgColor
            typeColorCache[type] = (fill, stroke)

            let density = nsColor.withAlphaComponent(0.6).cgColor
            typeDensityColorCache[type] = density
        }

        invalidateAnnotationTile()
    }

    /// Resets all type color caches to empty (causes rebuild from defaults on next draw).
    func resetTypeColorCaches() {
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()
        needsDisplay = true
    }

    /// Strips per-annotation custom colors from all cached annotations (used on reset).
    func clearAnnotationColorOverrides() {
        for i in cachedBundleAnnotations.indices {
            cachedBundleAnnotations[i].color = nil
        }
        for i in annotations.indices {
            annotations[i].color = nil
        }
        invalidateAnnotationTile()
        needsDisplay = true
    }

    // MARK: - Translation Track Control

    /// Shows a CDS translation track for the given annotation.
    ///
    /// Computes the translation using `TranslationEngine.translateCDS()` with the
    /// sequence data from the current bundle or loaded sequence. The translation result
    /// is cached in `activeTranslationResult` and the track is made visible.
    ///
    /// - Parameter annotation: The CDS/mRNA annotation to translate.
    func showCDSTranslation(for annotation: SequenceAnnotation) {
        // Build a sequence provider from the available data source
        let sequenceProvider: (Int, Int) -> String?
        if let bundle = currentReferenceBundle {
            // Bundle mode: use sync sequence fetch
            sequenceProvider = { start, end in
                let region = GenomicRegion(
                    chromosome: annotation.chromosome ?? bundle.chromosomeNames.first ?? "",
                    start: start, end: end
                )
                return try? bundle.fetchSequenceSync(region: region)
            }
        } else if let seq = sequence {
            // Single-sequence mode: extract from loaded sequence
            sequenceProvider = { start, end in
                let clampedStart = max(0, start)
                let clampedEnd = min(seq.length, end)
                guard clampedStart < clampedEnd else { return nil }
                return seq[clampedStart..<clampedEnd]
            }
        } else {
            logger.warning("showCDSTranslation: No sequence data available")
            return
        }

        guard let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: sequenceProvider
        ) else {
            logger.warning("showCDSTranslation: translateCDS returned nil for '\(annotation.name, privacy: .public)'")
            return
        }

        activeTranslationResult = result
        frameTranslationFrames = []
        showTranslationTrack = true
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        logger.info("showCDSTranslation: Showing translation for '\(annotation.name, privacy: .public)' (\(result.protein.count) aa)")
    }

    /// Hides the translation track and clears all translation state.
    func hideTranslation() {
        guard showTranslationTrack else { return }
        showTranslationTrack = false
        activeTranslationResult = nil
        frameTranslationFrames = []
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        logger.info("hideTranslation: Translation track hidden")
    }

    /// Hides only the CDS translation, preserving any active frame translation.
    ///
    /// Use this when the user explicitly hides a CDS translation from the inspector.
    /// If frame translation is also active, the translation track remains visible.
    func hideCDSTranslation() {
        guard activeTranslationResult != nil else { return }
        activeTranslationResult = nil
        if frameTranslationFrames.isEmpty {
            showTranslationTrack = false
        }
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        logger.info("hideCDSTranslation: CDS translation cleared")
    }

    /// Enables multi-frame translation mode for the specified reading frames.
    ///
    /// Translates the visible nucleotide sequence on-the-fly in each specified frame.
    /// This replaces any active CDS translation.
    ///
    /// - Parameters:
    ///   - frames: The reading frames to display (e.g., `ReadingFrame.forwardFrames`).
    ///   - table: The codon table to use.
    func applyFrameTranslation(frames: [ReadingFrame], table: CodonTable = .standard) {
        activeTranslationResult = nil
        frameTranslationFrames = frames
        frameTranslationTable = table
        showTranslationTrack = !frames.isEmpty
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        logger.info("applyFrameTranslation: \(frames.count) frames, table=\(table.shortName, privacy: .public)")
    }

    /// Sets a reference bundle for display.
    ///
    /// When a reference bundle is set, the viewer fetches sequence and annotation
    /// data on-demand using the bundle's indexed readers for efficient random access.
    ///
    /// - Parameter bundle: The ReferenceBundle to display
    func setReferenceBundle(_ bundle: ReferenceBundle) {
        logger.info("SequenceViewerView.setReferenceBundle: Setting bundle '\(bundle.name, privacy: .public)'")

        // Store the bundle reference
        self.currentReferenceBundle = bundle

        // Clear any existing sequence/annotations since we'll fetch on-demand
        self.sequence = nil
        self.annotations = []

        // Clear cached bundle data
        self.cachedBundleSequence = nil
        self.cachedSequenceRegion = nil
        self.cachedBundleAnnotations = []
        self.cachedAnnotationRegion = nil
        self.cachedVariantAnnotations = []
        self.cachedVariantRegion = nil
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.sequenceFetchStartTime = nil
        self.annotationFetchStartTime = nil
        self.bundleFetchError = nil
        self.failedFetchRegion = nil

        // Clear rendering caches
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()

        // Clear translation track state
        showTranslationTrack = false
        activeTranslationResult = nil
        frameTranslationFrames = []

        // Clear multi-sequence state if active
        if isMultiSequenceMode {
            clearSequences()
        }

        // Request display refresh - drawing will fetch data based on visible region
        needsDisplay = true

        logger.info("SequenceViewerView.setReferenceBundle: Bundle set, ready for on-demand fetching")
    }

    /// Clears the current reference bundle.
    func clearReferenceBundle() {
        logger.info("SequenceViewerView.clearReferenceBundle: Clearing bundle")
        self.currentReferenceBundle = nil
        self.cachedBundleSequence = nil
        self.cachedSequenceRegion = nil
        self.cachedBundleAnnotations = []
        self.cachedAnnotationRegion = nil
        self.cachedVariantAnnotations = []
        self.cachedVariantRegion = nil
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.sequenceFetchStartTime = nil
        self.annotationFetchStartTime = nil

        // Clear rendering caches
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()

        needsDisplay = true
    }

    /// Clears sequence fetch error state, allowing retry for a new region.
    func clearSequenceFetchError() {
        if bundleFetchError != nil {
            logger.info("clearSequenceFetchError: Clearing error '\(self.bundleFetchError ?? "nil", privacy: .public)' for region \(self.failedFetchRegion?.description ?? "nil")")
        }
        bundleFetchError = nil
        failedFetchRegion = nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dark mode toggle invalidates all cached CGColors
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            logger.warning("SequenceViewerView.draw: No graphics context available")
            return
        }

        // Background
        if isDragActive {
            // Highlight when dragging
            context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor)
        } else {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        }
        context.fill(bounds)

        // Draw drag border if active
        if isDragActive {
            context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
            context.setLineWidth(3)
            context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
        }

        // Check for multi-sequence mode first
        let hasBundle = currentReferenceBundle != nil
        let hasFrame = viewController?.referenceFrame != nil
        let hasVC = viewController != nil
        logger.debug("SequenceViewerView.draw: hasVC=\(hasVC), hasFrame=\(hasFrame), hasBundle=\(hasBundle), bounds=\(self.bounds.width)x\(self.bounds.height)")
        
        if let frame = viewController?.referenceFrame {
            if shouldDrawMultiSequence, let state = multiSequenceState {
                // Multi-sequence mode: draw stacked sequences with per-sequence annotations
                logger.debug("SequenceViewerView.draw: Drawing \(state.stackedSequences.count) stacked sequences")
                drawStackedSequences(state.stackedSequences, frame: frame, context: context)
            } else if currentReferenceBundle != nil {
                // Reference bundle mode: draw from cached bundle data
                logger.debug("SequenceViewerView.draw: Drawing bundle content for \(frame.chromosome)")
                drawBundleContent(frame: frame, context: context)
            } else if let seq = sequence {
                // Single sequence mode
                logger.debug("SequenceViewerView.draw: Drawing single sequence '\(seq.name, privacy: .public)' in bounds \(self.bounds.width)x\(self.bounds.height)")
                drawSequence(seq, frame: frame, context: context)
            } else {
                // No sequence loaded
                logger.debug("SequenceViewerView.draw: No content to draw, showing placeholder")
                drawPlaceholder(context: context)
            }
        } else {
            // Placeholder message - no reference frame
            logger.debug("SequenceViewerView.draw: No reference frame, showing placeholder")
            drawPlaceholder(context: context)
        }
    }
    
    /// Draws content from a reference bundle.
    ///
    /// Sequence and annotations are fetched and cached independently:
    /// - Annotations are always fetched for the visible region from SQLite
    /// - Sequence is only fetched when zoomed in enough to be visible (<500 bp/pixel)
    ///   because reading 240 MB of bgzip data for a full chromosome is impractical
    private func drawBundleContent(frame: ReferenceFrame, context: CGContext) {
        guard let bundle = currentReferenceBundle else {
            logger.warning("drawBundleContent: currentReferenceBundle is nil")
            return
        }

        let visibleRegion = GenomicRegion(
            chromosome: frame.chromosome,
            start: Int(frame.start),
            end: Int(frame.end)
        )
        let scale = frame.scale  // bp/pixel
        let needsSequence = scale < showLineThreshold  // Only fetch sequence when it would be visible

        // Only fetch and render annotations when zoomed in enough (< 100 Kbp visible).
        // At wider zoom levels, annotations would be too dense to be useful — similar to
        // how the sequence is only shown when zoomed in past showLineThreshold.
        let visibleSpan = visibleRegion.end - visibleRegion.start
        let showAnnotationThreshold = 100_000  // bp
        let needsAnnotations = visibleSpan <= showAnnotationThreshold

        // Check if annotation cache covers the visible region
        let annotationsCovered = cachedAnnotationRegion?.chromosome == visibleRegion.chromosome
            && (cachedAnnotationRegion?.start ?? Int.max) <= visibleRegion.start
            && (cachedAnnotationRegion?.end ?? Int.min) >= visibleRegion.end

        // Diagnostic: log cache state at key decision points
        logger.debug("""
            drawBundleContent: scale=\(scale, format: .fixed(precision: 2)) bp/px, \
            span=\(visibleSpan) bp, \
            needsSeq=\(needsSequence), needsAnnot=\(needsAnnotations), \
            annotCovered=\(annotationsCovered), fetchingAnnot=\(self.isFetchingAnnotations), \
            cachedAnnotCount=\(self.cachedBundleAnnotations.count), \
            fetchingSeq=\(self.isFetchingBundleData), \
            cachedSeqLen=\(self.cachedBundleSequence?.count ?? 0)
            """)

        // Detect stuck fetch states — if a fetch has been running for more than 10 seconds,
        // assume it failed silently and reset the flag to allow retry.
        let stuckThreshold: TimeInterval = 10.0
        if isFetchingAnnotations, let startTime = annotationFetchStartTime,
           Date().timeIntervalSince(startTime) > stuckThreshold {
            logger.warning("drawBundleContent: Annotation fetch stuck for >\(stuckThreshold)s, resetting")
            isFetchingAnnotations = false
            annotationFetchStartTime = nil
        }
        if isFetchingBundleData, let startTime = sequenceFetchStartTime,
           Date().timeIntervalSince(startTime) > stuckThreshold {
            logger.warning("drawBundleContent: Sequence fetch stuck for >\(stuckThreshold)s, resetting")
            isFetchingBundleData = false
            sequenceFetchStartTime = nil
        }

        // Fetch annotations if cache is stale (only when zoomed in enough).
        // Always fetch asynchronously to avoid blocking the main thread — the sync path
        // caused hangs when first zooming past the 100Kbp threshold on a chromosome.
        if needsAnnotations && !annotationsCovered && !isFetchingAnnotations {
            logger.info("drawBundleContent: Triggering annotation fetch for \(visibleRegion.description)")
            fetchAnnotationsAsync(bundle: bundle, region: visibleRegion)
        } else if needsAnnotations && !annotationsCovered && isFetchingAnnotations {
            logger.debug("drawBundleContent: Annotation fetch already in progress, waiting")
        }

        // Clear fetch error when user has navigated to a completely different region
        // (different chromosome or non-overlapping position), allowing retry.
        if bundleFetchError != nil, let failed = failedFetchRegion {
            if failed.chromosome != visibleRegion.chromosome
                || visibleRegion.end < failed.start || visibleRegion.start > failed.end {
                logger.info("drawBundleContent: Auto-clearing fetch error (navigated away from failed region \(failed.description))")
                bundleFetchError = nil
                failedFetchRegion = nil
            }
        }

        // Check if sequence cache covers the visible region
        if needsSequence {
            let sequenceCovered = cachedBundleSequence != nil
                && cachedSequenceRegion?.chromosome == visibleRegion.chromosome
                && (cachedSequenceRegion?.start ?? Int.max) <= visibleRegion.start
                && (cachedSequenceRegion?.end ?? Int.min) >= visibleRegion.end

            if !sequenceCovered && !isFetchingBundleData && bundleFetchError == nil {
                fetchSequenceAsync(bundle: bundle, region: visibleRegion)
            }
        }

        // Draw sequence (or line placeholder)
        if needsSequence {
            if let cached = cachedBundleSequence,
               let cachedRegion = cachedSequenceRegion,
               cachedRegion.chromosome == visibleRegion.chromosome,
               cachedRegion.start <= visibleRegion.start,
               cachedRegion.end >= visibleRegion.end {
                logger.debug("drawBundleContent: Drawing sequence at scale=\(scale) bp/px, cached=\(cached.count) bp, region=\(cachedRegion.description)")
                drawBundleSequence(cached, region: cachedRegion, frame: frame, context: context)
            } else if let fetchError = bundleFetchError {
                logger.debug("drawBundleContent: Sequence fetch failed (showing error): \(fetchError)")
                drawSequenceError(fetchError, frame: frame, context: context)
            } else {
                let hasCached = cachedBundleSequence != nil
                let cachedChrom = cachedSequenceRegion?.chromosome ?? "nil"
                let cachedStart = cachedSequenceRegion?.start ?? -1
                let cachedEnd = cachedSequenceRegion?.end ?? -1
                logger.debug("drawBundleContent: No sequence cache for visible region. hasCached=\(hasCached), cachedChrom=\(cachedChrom), cachedRange=\(cachedStart)-\(cachedEnd), visibleRange=\(visibleRegion.start)-\(visibleRegion.end), fetching=\(self.isFetchingBundleData)")
                drawSequenceLine(frame: frame, context: context)
            }
        } else {
            drawSequenceLine(frame: frame, context: context)
        }

        // Draw translation track if active and zoomed in enough for individual bases
        if showTranslationTrack && scale < showLettersThreshold {
            let transY = trackY + trackHeight + 4
            if let result = activeTranslationResult {
                TranslationTrackRenderer.drawCDSTranslation(
                    result: result,
                    frame: frame,
                    context: context,
                    yOffset: transY,
                    colorScheme: translationColorScheme,
                    showStopCodons: translationShowStopCodons
                )
            } else if !frameTranslationFrames.isEmpty, let seq = cachedBundleSequence,
                      let seqRegion = cachedSequenceRegion {
                TranslationTrackRenderer.drawFrameTranslations(
                    frames: frameTranslationFrames,
                    sequence: seq,
                    sequenceStart: seqRegion.start,
                    frame: frame,
                    context: context,
                    yOffset: transY,
                    table: frameTranslationTable,
                    colorScheme: translationColorScheme,
                    showStopCodons: translationShowStopCodons
                )
            }
        }

        // Check if variant cache covers the visible region
        let variantsCovered = cachedVariantRegion?.chromosome == visibleRegion.chromosome
            && (cachedVariantRegion?.start ?? Int.max) <= visibleRegion.start
            && (cachedVariantRegion?.end ?? Int.min) >= visibleRegion.end

        // Fetch variants if cache is stale (only when zoomed in enough for annotations)
        if needsAnnotations && !variantsCovered && !isFetchingVariants {
            fetchVariantsAsync(bundle: bundle, region: visibleRegion)
        }

        // Draw annotations + variants from cache when zoomed in enough
        if needsAnnotations,
           cachedAnnotationRegion?.chromosome == visibleRegion.chromosome
            || cachedVariantRegion?.chromosome == visibleRegion.chromosome {
            // Filter variants by visibility settings before combining
            let filteredVariants: [SequenceAnnotation]
            if showVariants {
                var variants = cachedVariantAnnotations
                if let typeFilter = visibleVariantTypes, !typeFilter.isEmpty {
                    variants = variants.filter { ann in
                        let vtypeStr = ann.qualifiers["variant_type"]?.values.first ?? ""
                        return typeFilter.contains(vtypeStr)
                    }
                }
                if !variantFilterText.isEmpty {
                    let lower = variantFilterText.lowercased()
                    variants = variants.filter { $0.name.lowercased().contains(lower) }
                }
                filteredVariants = variants
            } else {
                filteredVariants = []
            }
            let combined = cachedBundleAnnotations + filteredVariants
            if !combined.isEmpty {
                logger.debug("drawBundleContent: Drawing \(combined.count) annotations (\(self.cachedBundleAnnotations.count) annot + \(filteredVariants.count) variant)")
                drawBundleAnnotations(combined, frame: frame, context: context)
            } else {
                logger.debug("drawBundleContent: No annotations to draw (cache empty for current chromosome)")
            }
        }

        // Show "Fetching annotations..." indicator when annotations are loading
        if needsAnnotations && isFetchingAnnotations && cachedBundleAnnotations.isEmpty {
            let label = "Fetching annotations..." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = label.size(withAttributes: attributes)
            let labelRect = CGRect(
                x: (bounds.width - size.width) / 2,
                y: annotationTrackY + 4,
                width: size.width,
                height: size.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }
    }

    /// Fetches annotations asynchronously for the visible region from SQLite annotation databases.
    /// Runs database queries on a background thread to avoid blocking the UI.
    /// Dedicated queue for annotation I/O to avoid being starved by the search index build.
    private static let annotationFetchQueue = DispatchQueue(label: "com.lungfish.annotationFetch", qos: .userInteractive)

    /// Schedules UI state updates on the main run loop common modes.
    /// This avoids starvation during AppKit tracking/layout-heavy loops.
    private static func enqueueMainRunLoop(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
            return
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func fetchAnnotationsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        annotationFetchGeneration += 1
        let thisGeneration = annotationFetchGeneration
        isFetchingAnnotations = true
        annotationFetchStartTime = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        // Pre-fetch 200% extra on each side so panning doesn't invalidate cache.
        // User can pan 2 full screen-widths before a refetch is needed.
        let visibleSpan = region.end - region.start
        let expandAmount = max(50_000, visibleSpan * 2)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)
        let trackIds = bundle.annotationTrackIds

        // Capture per-annotation color overrides for application after loading
        let colorOverrides = viewController?.currentBundleViewState?.annotationColorOverrides ?? [:]

        logger.info("fetchAnnotationsAsync: gen=\(thisGeneration), Fetching \(expandedRegion.description) (\(trackIds.count) tracks) on background thread")

        Self.annotationFetchQueue.async { [weak self] in
            var allAnnotations: [SequenceAnnotation] = []

            for trackId in trackIds {
                guard let trackInfo = bundle.annotationTrack(id: trackId) else { continue }

                guard let dbPath = trackInfo.databasePath else {
                    logger.error("fetchAnnotationsAsync: Annotation track \(trackId) has no databasePath")
                    continue
                }

                let dbURL = bundle.url.appendingPathComponent(dbPath)
                guard FileManager.default.fileExists(atPath: dbURL.path) else {
                    logger.error("fetchAnnotationsAsync: Annotation database missing for \(trackId) at \(dbPath)")
                    continue
                }

                do {
                    let db = try AnnotationDatabase(url: dbURL)
                    let records = db.queryByRegion(
                        chromosome: expandedRegion.chromosome,
                        start: expandedRegion.start,
                        end: expandedRegion.end,
                        limit: 50_000
                    )
                    let annotations = records.map { $0.toAnnotation() }
                    allAnnotations.append(contentsOf: annotations)
                    logger.info("fetchAnnotationsAsync: SQLite query returned \(annotations.count) annotations for track \(trackId)")
                } catch {
                    logger.error("fetchAnnotationsAsync: SQLite query failed for \(trackId): \(error.localizedDescription)")
                }
            }

            // Apply per-annotation color overrides from BundleViewState
            if !colorOverrides.isEmpty {
                for i in allAnnotations.indices {
                    let key = allAnnotations[i].colorOverrideKey
                    if let override = colorOverrides[key] {
                        allAnnotations[i].color = override
                    }
                }
            }

            let count = allAnnotations.count
            logger.info("fetchAnnotationsAsync[RUNLOOP_V2]: gen=\(thisGeneration), background done, \(count) annotations found, scheduling main-runloop commit")

            Self.enqueueMainRunLoop { [weak self] in
                logger.info("fetchAnnotationsAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                guard let viewer = self else {
                    logger.error("fetchAnnotationsAsync: self is nil in main-runloop callback, \(count) annotations lost")
                    return
                }
                // Check generation counter: discard stale results from superseded fetches
                guard thisGeneration == viewer.annotationFetchGeneration else {
                    logger.info("fetchAnnotationsAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.annotationFetchGeneration))")
                    return
                }
                let elapsed = viewer.annotationFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                viewer.cachedBundleAnnotations = allAnnotations
                viewer.cachedAnnotationRegion = expandedRegion
                viewer.isFetchingAnnotations = false
                viewer.annotationFetchStartTime = nil
                viewer.invalidateAnnotationTile()
                logger.info("fetchAnnotationsAsync: Cached \(count) annotations for \(expandedRegion.description) in \(elapsed, format: .fixed(precision: 3))s, triggering redraw")
                viewer.setNeedsDisplay(viewer.bounds)
            }
        }
    }

    /// Fetches variant annotations asynchronously from the VariantDatabase.
    /// Runs SQLite queries on a background thread, converts to SequenceAnnotation,
    /// and merges with the annotation rendering pipeline.
    private static let variantFetchQueue = DispatchQueue(label: "com.lungfish.variantFetch", qos: .userInteractive)

    private func fetchVariantsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        let variantTrackIds = bundle.variantTrackIds
        guard !variantTrackIds.isEmpty else { return }

        variantFetchGeneration += 1
        let thisGeneration = variantFetchGeneration
        isFetchingVariants = true
        let fetchStart = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(50_000, visibleSpan * 2)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        logger.info("fetchVariantsAsync: gen=\(thisGeneration), Fetching variants for \(expandedRegion.description)")

        Self.variantFetchQueue.async { [weak self] in
            var allVariantAnnotations: [SequenceAnnotation] = []
            for trackId in variantTrackIds {
                do {
                    let annotations = try bundle.getVariantAnnotations(trackId: trackId, region: expandedRegion)
                    allVariantAnnotations.append(contentsOf: annotations)
                } catch {
                    logger.error("fetchVariantsAsync: Failed to fetch variants for track \(trackId): \(error.localizedDescription)")
                }
            }

            let count = allVariantAnnotations.count
            logger.info("fetchVariantsAsync[RUNLOOP_V2]: gen=\(thisGeneration), background done, \(count) variants found")

            Self.enqueueMainRunLoop { [weak self] in
                logger.info("fetchVariantsAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                guard let viewer = self else {
                    logger.error("fetchVariantsAsync: self is nil in main-runloop callback, \(count) variants lost")
                    return
                }
                guard thisGeneration == viewer.variantFetchGeneration else {
                    logger.info("fetchVariantsAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.variantFetchGeneration))")
                    return
                }
                let elapsed = Date().timeIntervalSince(fetchStart)
                viewer.cachedVariantAnnotations = allVariantAnnotations
                viewer.cachedVariantRegion = expandedRegion
                viewer.isFetchingVariants = false
                viewer.invalidateAnnotationTile()
                logger.info("fetchVariantsAsync: Cached \(count) variant annotations in \(elapsed, format: .fixed(precision: 3))s")
                viewer.setNeedsDisplay(viewer.bounds)
            }
        }
    }

    /// Fetches sequence data asynchronously from bgzip-compressed FASTA.
    /// Runs decompression on a background thread to avoid blocking the UI.
    /// Only called when zoomed in enough to display sequence (<500 bp/pixel).
    /// Dedicated queue for sequence I/O to avoid being starved by annotation scanning
    /// on the global concurrent queue.
    private static let sequenceFetchQueue = DispatchQueue(label: "com.lungfish.sequenceFetch", qos: .userInteractive)

    private func fetchSequenceAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        sequenceFetchGeneration += 1
        let thisGeneration = sequenceFetchGeneration
        isFetchingBundleData = true
        sequenceFetchStartTime = Date()
        bundleFetchError = nil

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)

        // Limit fetch to a reasonable size to avoid loading hundreds of MB.
        // Always fetch at least 100 Kb to provide buffer for panning.
        let maxFetchSize = 500_000  // 500 Kb max per fetch
        let center = (region.start + region.end) / 2
        let visibleSpan = region.end - region.start
        let halfFetch = min(maxFetchSize / 2, max(50_000, visibleSpan / 2 + visibleSpan))
        let expandedStart = max(0, center - halfFetch)
        let expandedEnd = min(Int(chromLength), center + halfFetch)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        logger.info("fetchSequenceAsync: gen=\(thisGeneration), Fetching \(expandedRegion.description) (\(expandedRegion.length) bp)")

        // Use a dedicated serial queue rather than DispatchQueue.global to prevent
        // thread starvation when the annotation search index is doing heavy annotation I/O
        // scanning on the global concurrent queue.
        Self.sequenceFetchQueue.async { [weak self] in
            logger.info("fetchSequenceAsync: gen=\(thisGeneration), background block started, self alive: \(self != nil)")
            do {
                let sequence = try bundle.fetchSequenceSync(region: expandedRegion)
                let count = sequence.count
                logger.info("fetchSequenceAsync: gen=\(thisGeneration), fetchSequenceSync returned \(count) bp")

                Self.enqueueMainRunLoop { [weak self] in
                    logger.info("fetchSequenceAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                    guard let viewer = self else {
                        logger.error("fetchSequenceAsync: CRITICAL - self is nil in main-runloop callback! \(count) bp lost.")
                        return
                    }
                    guard thisGeneration == viewer.sequenceFetchGeneration else {
                        logger.info("fetchSequenceAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.sequenceFetchGeneration))")
                        return
                    }
                    let elapsed = viewer.sequenceFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    viewer.cachedBundleSequence = sequence
                    viewer.cachedSequenceRegion = expandedRegion
                    viewer.isFetchingBundleData = false
                    viewer.sequenceFetchStartTime = nil
                    viewer.bundleFetchError = nil
                    viewer.failedFetchRegion = nil
                    logger.info("fetchSequenceAsync: Cached \(count) bp for \(expandedRegion.description) in \(elapsed, format: .fixed(precision: 3))s, triggering redraw")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            } catch {
                let errorDesc = error.localizedDescription
                logger.error("fetchSequenceAsync: gen=\(thisGeneration), FAILED - \(errorDesc, privacy: .public)")

                Self.enqueueMainRunLoop { [weak self] in
                    logger.info("fetchSequenceAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback (error path) executing")
                    guard let viewer = self else {
                        logger.error("fetchSequenceAsync: self is nil in main-runloop callback (error path)")
                        return
                    }
                    guard thisGeneration == viewer.sequenceFetchGeneration else {
                        logger.info("fetchSequenceAsync: Discarding stale error gen=\(thisGeneration) (current=\(viewer.sequenceFetchGeneration))")
                        return
                    }
                    logger.error("fetchSequenceAsync: Error delivered to main thread - \(errorDesc, privacy: .public)")
                    viewer.failedFetchRegion = expandedRegion
                    viewer.isFetchingBundleData = false
                    viewer.sequenceFetchStartTime = nil
                    viewer.bundleFetchError = errorDesc
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }
    
    /// Draws sequence data from a bundle.
    private func drawBundleSequence(_ sequenceString: String, region: GenomicRegion, frame: ReferenceFrame, context: CGContext) {
        let scale = frame.scale  // bp/pixel
        
        // Calculate the offset within the cached sequence for the visible region
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        let offsetInCache = visibleStart - region.start
        
        // Extract the visible portion of the sequence
        let startIndex = sequenceString.index(sequenceString.startIndex, offsetBy: max(0, offsetInCache))
        let endIndex = sequenceString.index(startIndex, offsetBy: min(visibleEnd - visibleStart, sequenceString.count - offsetInCache), limitedBy: sequenceString.endIndex) ?? sequenceString.endIndex
        let visibleSequence = String(sequenceString[startIndex..<endIndex])
        
        // Draw based on zoom level
        if scale < showLettersThreshold {
            // High zoom: draw individual bases with letters
            drawBasesWithLetters(visibleSequence, startPosition: visibleStart, frame: frame, context: context)
        } else if scale < showLineThreshold {
            // Medium zoom: draw colored blocks
            drawColoredBlocks(visibleSequence, startPosition: visibleStart, frame: frame, context: context)
        } else {
            // Low zoom: draw simple line
            drawSequenceLine(frame: frame, context: context)
        }
    }
    
    /// Draws bases with individual letters (high zoom level).
    private func drawBasesWithLetters(_ sequence: String, startPosition: Int, frame: ReferenceFrame, context: CGContext) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let pixelsPerBase = bounds.width / CGFloat(max(1, frame.end - frame.start))
        
        for (index, base) in sequence.enumerated() {
            let position = startPosition + index
            let x = frame.screenPosition(for: Double(position))
            let baseWidth = pixelsPerBase
            
            // Draw background
            let color = BaseColors.color(for: base)
            context.setFillColor(color.cgColor)
            let rect = CGRect(x: x, y: trackY, width: baseWidth, height: trackHeight)
            context.fill(rect)
            
            // Draw letter if space permits
            if baseWidth >= 8 {
                let displayChar = isRNAMode && base.uppercased() == "T" ? "U" : String(base).uppercased()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let size = (displayChar as NSString).size(withAttributes: attributes)
                let letterRect = CGRect(
                    x: x + (baseWidth - size.width) / 2,
                    y: trackY + (trackHeight - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                (displayChar as NSString).draw(in: letterRect, withAttributes: attributes)
            }
        }
    }
    
    /// Draws colored blocks for bases (medium zoom level).
    private func drawColoredBlocks(_ sequence: String, startPosition: Int, frame: ReferenceFrame, context: CGContext) {
        // Group consecutive bases of the same type for efficient drawing
        var currentBase: Character?
        var blockStart = startPosition
        
        for (index, base) in sequence.enumerated() {
            let position = startPosition + index
            
            if base != currentBase {
                // Draw previous block if any
                if let prevBase = currentBase {
                    let x = frame.screenPosition(for: Double(blockStart))
                    let width = frame.screenPosition(for: Double(position)) - x
                    let color = BaseColors.color(for: prevBase)
                    context.setFillColor(color.cgColor)
                    let rect = CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight)
                    context.fill(rect)
                }
                
                currentBase = base
                blockStart = position
            }
        }
        
        // Draw final block
        if let prevBase = currentBase {
            let x = frame.screenPosition(for: Double(blockStart))
            let endX = frame.screenPosition(for: Double(startPosition + sequence.count))
            let width = endX - x
            let color = BaseColors.color(for: prevBase)
            context.setFillColor(color.cgColor)
            let rect = CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight)
            context.fill(rect)
        }
    }
    
    /// Draws a simple line representing the sequence (low zoom level).
    private func drawSequenceLine(frame: ReferenceFrame, context: CGContext) {
        let startX = frame.screenPosition(for: frame.start)
        let endX = frame.screenPosition(for: frame.end)
        let centerY = trackY + trackHeight / 2

        context.setStrokeColor(NSColor.systemGray.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: startX, y: centerY))
        context.addLine(to: CGPoint(x: endX, y: centerY))
        context.strokePath()

        // Show "Fetching sequence..." if we're loading data for this zoom level
        if isFetchingBundleData && frame.scale < showLineThreshold {
            let label = "Fetching sequence..." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = label.size(withAttributes: attributes)
            let labelRect = CGRect(
                x: (bounds.width - size.width) / 2,
                y: trackY + (trackHeight - size.height) / 2,
                width: size.width,
                height: size.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }
    }
    
    /// Draws an error message in the sequence track when fetch failed.
    private func drawSequenceError(_ error: String, frame: ReferenceFrame, context: CGContext) {
        let startX = frame.screenPosition(for: frame.start)
        let endX = frame.screenPosition(for: frame.end)
        let centerY = trackY + trackHeight / 2

        // Draw a red-tinted line
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: startX, y: centerY))
        context.addLine(to: CGPoint(x: endX, y: centerY))
        context.strokePath()

        let label = "Sequence error: \(error)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemRed
        ]
        let size = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: trackY + (trackHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        label.draw(in: labelRect, withAttributes: attributes)
    }

    // MARK: - Annotation Rendering Thresholds (inspired by IGV)
    //
    // Three rendering tiers based on zoom level:
    // - DENSITY MODE:  > 50,000 bp/pixel — feature density histogram
    // - SQUISHED MODE: 500–50,000 bp/pixel — packed thin rectangles, no labels
    // - EXPANDED MODE: < 500 bp/pixel — full boxes with labels, strand arrows

    /// Above this threshold (bp/pixel): draw density histogram instead of features
    private let annotationDensityThreshold: Double = 50_000

    /// Above this threshold (bp/pixel): draw squished (thin, no labels) features
    private let annotationSquishedThreshold: Double = 500

    /// Maximum annotation rows before showing "+N more" indicator
    private let maxAnnotationRows: Int = 50

    /// Minimum feature width for expanded labels to avoid visual clutter.
    private let minExpandedLabelWidth: CGFloat = 72

    /// Do not draw per-feature labels when packed rows exceed this count.
    private let maxLabeledRows: Int = 12

    /// Minimum pixel gap between features in the same row during packing
    private let minPixelGap: CGFloat = 2

    /// Formats annotation labels for rendering (single-line, whitespace-normalized).
    private func displayLabel(for annotation: SequenceAnnotation) -> String {
        let collapsed = annotation.name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? annotation.type.rawValue : collapsed
    }

    /// Returns true when this annotation type should render an inline label in expanded mode.
    private func shouldRenderExpandedLabel(for annotation: SequenceAnnotation, width: CGFloat, rowCount: Int) -> Bool {
        guard rowCount <= maxLabeledRows, width >= minExpandedLabelWidth else { return false }
        switch annotation.type {
        case .gene, .mRNA, .transcript, .cds:
            return true
        default:
            return false
        }
    }

    /// Draws annotations from a bundle using zoom-dependent rendering tiers.
    ///
    /// Uses an offscreen tile cache for fast pan blitting. When the user pans within
    /// tile bounds, this method just blits the pre-rendered tile image with an X offset
    /// (O(1) per frame). The tile covers 3x the view width so the user can pan a full
    /// screen-width in each direction before the tile needs re-rendering.
    private func drawBundleAnnotations(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        guard showAnnotations, !annotations.isEmpty else { return }

        // Clip strictly to the annotation lane so labels/features never overlap sequence track.
        context.saveGState()
        let annotationClipRect = CGRect(
            x: 0,
            y: annotationTrackY,
            width: CGFloat(frame.pixelWidth),
            height: max(0, bounds.height - annotationTrackY)
        )
        context.clip(to: annotationClipRect)

        // Render directly in view coordinates to keep annotation rows anchored
        // directly beneath the sequence track.
        let displayAnnotations = filterAnnotationsForDisplay(annotations, frame: frame, context: context)

        guard let displayAnnotations else {
            context.restoreGState()
            return
        }

        renderAnnotationsDirect(displayAnnotations, frame: frame, context: context)

        context.restoreGState()
    }

    /// Filters cached annotations for display based on visible region, type/text filters,
    /// and display-time feature size constraints.
    ///
    /// Returns nil if no features pass the filter (draws a hint label if appropriate).
    private func filterAnnotationsForDisplay(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        context: CGContext
    ) -> [SequenceAnnotation]? {
        let scale = frame.scale
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Render rows based on the visible interval only so row packing starts
        // directly beneath the sequence track (no offscreen row inflation).
        let visibleSpan = max(1, visibleEnd - visibleStart)
        let visibleAnnotations = annotations.filter { annot in
            annot.end > visibleStart && annot.start < visibleEnd
        }

        // Apply type filter if set
        let filteredAnnotations: [SequenceAnnotation]
        if let typeFilter = visibleAnnotationTypes {
            filteredAnnotations = visibleAnnotations.filter { typeFilter.contains($0.type) }
        } else {
            filteredAnnotations = visibleAnnotations
        }

        // Apply text filter if set
        let finalAnnotations: [SequenceAnnotation]
        if !annotationFilterText.isEmpty {
            let filterLower = annotationFilterText.lowercased()
            finalAnnotations = filteredAnnotations.filter { annot in
                annot.name.lowercased().contains(filterLower)
            }
        } else {
            finalAnnotations = filteredAnnotations
        }

        guard !finalAnnotations.isEmpty else { return nil }

        // Display-time filtering:
        // - keep partially visible features
        // - skip sub-pixel features in detail modes
        // - suppress only giant region-container rows that would obscure detail
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(visibleSpan) * 0.98)
            }
        } else {
            let minFeatureBp = max(1, Int(scale))
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                guard span >= minFeatureBp else { return false }
                return annot.type != .region || span < Int(Double(visibleSpan) * 0.98)
            }
        }

        guard !displayAnnotations.isEmpty else {
            if !finalAnnotations.isEmpty {
                let font = NSFont.systemFont(ofSize: 10)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let text = "\(finalAnnotations.count) features (zoom in to see details)"
                let labelRect = CGRect(x: 4, y: annotationTrackY + 2, width: CGFloat(frame.pixelWidth) - 8, height: 14)
                (text as NSString).draw(in: labelRect, withAttributes: attrs)
            }
            return nil
        }

        return displayAnnotations
    }

    /// Renders annotations to an offscreen CGImage tile covering 3x the visible view width.
    ///
    /// The tile can then be blitted with an X offset during subsequent pans, avoiding
    /// the expensive filtering/packing/drawing pipeline until the user pans past the tile edge.
    private func renderAnnotationTile(annotations: [SequenceAnnotation], frame: ReferenceFrame) {
        let viewWidth = frame.pixelWidth
        let viewHeight = Int(bounds.height)
        guard viewWidth > 0, viewHeight > 0 else { return }

        let tilePixelWidth = viewWidth * 3
        let visibleSpan = frame.end - frame.start
        let tileStartBP = max(0, frame.start - visibleSpan)
        let tileEndBP = frame.end + visibleSpan

        // Create a temporary ReferenceFrame for the wider tile region
        let tileFrame = ReferenceFrame(
            chromosome: frame.chromosome,
            start: tileStartBP,
            end: tileEndBP,
            pixelWidth: tilePixelWidth,
            sequenceLength: frame.sequenceLength
        )

        // Create bitmap context for the tile
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let tileContext = CGContext(
            data: nil,
            width: tilePixelWidth,
            height: viewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // The view is flipped (isFlipped = true), so we need to flip the tile context too
        tileContext.translateBy(x: 0, y: CGFloat(viewHeight))
        tileContext.scaleBy(x: 1, y: -1)

        // Render annotations into the tile
        renderAnnotationsDirect(annotations, frame: tileFrame, context: tileContext)

        // Store tile metadata
        self.tileGenomicStart = tileStartBP
        self.tileGenomicEnd = tileEndBP
        self.tileScale = frame.scale
        self.tileWidth = tilePixelWidth
        self.tileHeight = viewHeight
        self.tileChromosome = frame.chromosome
        self.annotationTile = tileContext.makeImage()
    }

    /// Renders annotations directly into a context (used for both tile and fallback rendering).
    private func renderAnnotationsDirect(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let scale = frame.scale
        let maxSquishedFeatures = 5_000
        let useDensityMode = scale > annotationDensityThreshold
            || (annotations.count > maxSquishedFeatures && scale > annotationSquishedThreshold)

        if useDensityMode {
            drawAnnotationDensity(annotations, frame: frame, context: context)
        } else if scale > annotationSquishedThreshold {
            drawAnnotationsSquished(annotations, frame: frame, context: context)
        } else {
            drawAnnotationsExpanded(annotations, frame: frame, context: context)
        }
    }

    // MARK: - Density Histogram (whole-chromosome zoom level)

    /// Draws a density histogram of annotation counts per pixel column.
    private func drawAnnotationDensity(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let viewWidth = CGFloat(frame.pixelWidth)
        let binCount = max(1, Int(viewWidth))
        let bpPerBin = (frame.end - frame.start) / Double(binCount)

        // Build density histogram with per-type tracking
        var bins = [Int](repeating: 0, count: binCount)
        var binTypeCounts = [[AnnotationType: Int]](repeating: [:], count: binCount)
        for annot in annotations {
            let startBin = max(0, Int((Double(annot.start) - frame.start) / bpPerBin))
            let endBin = min(binCount - 1, Int((Double(annot.end) - frame.start) / bpPerBin))
            for bin in startBin...endBin {
                bins[bin] += 1
                binTypeCounts[bin][annot.type, default: 0] += 1
            }
        }

        let maxCount = bins.max() ?? 1
        guard maxCount > 0 else { return }

        let trackHeight: CGFloat = 30
        let y = annotationTrackY

        // Draw background
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: 0, y: y, width: viewWidth, height: trackHeight))

        // Draw density bars colored by dominant annotation type per bin
        for (i, count) in bins.enumerated() {
            guard count > 0 else { continue }
            let barHeight = trackHeight * CGFloat(count) / CGFloat(maxCount)
            let rect = CGRect(x: CGFloat(i), y: y + trackHeight - barHeight, width: 1, height: barHeight)
            // Color by the most frequent type in this bin (cached CGColor)
            let dominantType = binTypeCounts[i].max(by: { $0.value < $1.value })?.key ?? .gene
            context.setFillColor(cachedDensityColor(for: dominantType))
            context.fill(rect)
        }

        // Draw label
        let labelText = "\(annotations.count) features (zoom in to see details)"
        let font = NSFont.systemFont(ofSize: 10)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelRect = CGRect(x: 4, y: y + 2, width: viewWidth - 8, height: 14)
        (labelText as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    // MARK: - Squished Mode (medium zoom — thin features, no labels)

    /// Draws annotations as thin packed rectangles without labels.
    private func drawAnnotationsSquished(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let squishedHeight: CGFloat = 6
        let squishedSpacing: CGFloat = 1
        let (rows, overflow) = packAnnotationsLayered(annotations, frame: frame)

        for (rowIndex, row) in rows.enumerated() {
            let y = annotationTrackY + CGFloat(rowIndex) * (squishedHeight + squishedSpacing)

            for annot in row {
                let colors = cachedColors(for: annot)

                if annot.isDiscontinuous {
                    // Discontiguous: connector line + block rectangles
                    let fullStartX = frame.screenPosition(for: Double(annot.start))
                    let fullEndX = frame.screenPosition(for: Double(annot.end))
                    let midY = y + squishedHeight / 2

                    // Draw connector line through intron regions
                    context.setStrokeColor(colors.fill)
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: fullStartX, y: midY))
                    context.addLine(to: CGPoint(x: fullEndX, y: midY))
                    context.strokePath()

                    // Draw each interval (exon) as a filled block
                    context.setFillColor(colors.fill)
                    for interval in annot.intervals {
                        let ix = frame.screenPosition(for: Double(interval.start))
                        let ix2 = frame.screenPosition(for: Double(interval.end))
                        let iw = max(1, ix2 - ix)
                        context.fill(CGRect(x: ix, y: y, width: iw, height: squishedHeight))
                    }
                } else {
                    // Continuous: single filled rectangle
                    let startX = frame.screenPosition(for: Double(annot.start))
                    let endX = frame.screenPosition(for: Double(annot.end))
                    let width = max(1, endX - startX)
                    let rect = CGRect(x: startX, y: y, width: width, height: squishedHeight)
                    context.setFillColor(colors.fill)
                    context.fill(rect)
                }
            }
        }

        if overflow > 0 {
            drawOverflowIndicator(rowCount: rows.count, height: squishedHeight + squishedSpacing,
                                  overflow: overflow, frame: frame, context: context)
        }
    }

    // MARK: - Expanded Mode (close zoom — full detail with labels)

    /// Draws annotations as full-height boxes with labels and strand indicators.
    /// Discontiguous features (e.g., transcripts with exons) are rendered with a
    /// thin connector line and thick blocks for each interval, like IGV/Geneious.
    private func drawAnnotationsExpanded(_ annotations: [SequenceAnnotation], frame: ReferenceFrame, context: CGContext) {
        let (rows, overflow) = packAnnotationsLayered(annotations, frame: frame)
        let rowCount = rows.count

        for (rowIndex, row) in rows.enumerated() {
            let y = annotationTrackY + CGFloat(rowIndex) * (annotationHeight + annotationRowSpacing)

            for annot in row {
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(3, endX - startX)

                let colors = cachedColors(for: annot)

                if annot.isDiscontinuous {
                    // Discontiguous: connector line + block rectangles (IGV-style)
                    let midY = y + annotationHeight / 2
                    let connectorHeight: CGFloat = 2

                    // Draw connector line (thin bar through intron regions)
                    context.setFillColor(colors.fill)
                    context.fill(CGRect(x: startX, y: midY - connectorHeight / 2,
                                        width: width, height: connectorHeight))

                    // Draw each interval (exon) as a full-height filled block
                    for interval in annot.intervals {
                        let ix = frame.screenPosition(for: Double(interval.start))
                        let ix2 = frame.screenPosition(for: Double(interval.end))
                        let iw = max(1, ix2 - ix)
                        let blockRect = CGRect(x: ix, y: y, width: iw, height: annotationHeight)
                        context.setFillColor(colors.fill)
                        context.fill(blockRect)
                        context.setStrokeColor(colors.stroke)
                        context.setLineWidth(1)
                        context.stroke(blockRect)
                    }

                    // Draw strand arrows on connector if feature is wide enough
                    let boundingRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)
                    if width > 8 {
                        drawStrandArrow(strand: annot.strand, rect: boundingRect, context: context)
                    }

                    // Draw label above or inside the feature
                    if shouldRenderExpandedLabel(for: annot, width: width, rowCount: rowCount) {
                        let label = displayLabel(for: annot)
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byTruncatingTail
                        let font = NSFont.systemFont(ofSize: 10)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: NSColor.textColor,
                            .paragraphStyle: paragraph,
                        ]
                        let labelRect = CGRect(x: startX + 2, y: y + 1, width: width - 4, height: annotationHeight - 2)
                        (label as NSString).draw(
                            with: labelRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: attributes
                        )
                    }
                } else {
                    // Continuous: single filled rectangle with border
                    let rect = CGRect(x: startX, y: y, width: width, height: annotationHeight)
                    context.setFillColor(colors.fill)
                    context.fill(rect)

                    // Draw border
                    context.setStrokeColor(colors.stroke)
                    context.setLineWidth(1)
                    context.stroke(rect)

                    // Draw label if space permits
                    if shouldRenderExpandedLabel(for: annot, width: width, rowCount: rowCount) {
                        let label = displayLabel(for: annot)
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byTruncatingTail
                        let font = NSFont.systemFont(ofSize: 10)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: NSColor.textColor,
                            .paragraphStyle: paragraph,
                        ]
                        let labelRect = CGRect(x: startX + 2, y: y + 1, width: width - 4, height: annotationHeight - 2)
                        (label as NSString).draw(
                            with: labelRect,
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                            attributes: attributes
                        )
                    }

                    // Draw strand arrow if feature is wide enough
                    if width > 8 {
                        drawStrandArrow(strand: annot.strand, rect: rect, context: context)
                    }
                }
            }
        }

        if overflow > 0 {
            drawOverflowIndicator(rowCount: rows.count, height: annotationHeight + annotationRowSpacing,
                                  overflow: overflow, frame: frame, context: context)
        }
    }

    // MARK: - Pixel-Based Row Packing

    /// Packs annotations into layered rows:
    /// - genome landmarks first (genes/transcripts/etc.)
    /// - variant-like features (SNP/indel/etc.) beneath landmarks
    private func packAnnotationsLayered(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame
    ) -> (rows: [[SequenceAnnotation]], overflow: Int) {
        let landmarks = annotations.filter { !isVariantAnnotationType($0.type) }
        let variants = annotations.filter { isVariantAnnotationType($0.type) }

        let (landmarkRows, landmarkOverflow) = packAnnotationsPixelBased(landmarks, frame: frame, maxRows: maxAnnotationRows)
        let remainingRows = max(0, maxAnnotationRows - landmarkRows.count)
        let (variantRows, variantOverflow) = packAnnotationsPixelBased(variants, frame: frame, maxRows: remainingRows)

        return (landmarkRows + variantRows, landmarkOverflow + variantOverflow)
    }

    private func isVariantAnnotationType(_ type: AnnotationType) -> Bool {
        switch type {
        case .snp, .variation, .insertion, .deletion:
            return true
        default:
            return false
        }
    }

    /// Packs annotations into rows using pixel-based gap detection.
    /// Returns the packed rows and number of overflow features that couldn't be placed.
    private func packAnnotationsPixelBased(
        _ annotations: [SequenceAnnotation],
        frame: ReferenceFrame,
        maxRows: Int
    ) -> (rows: [[SequenceAnnotation]], overflow: Int) {
        let sortedAnnotations = annotations.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }

        var rows: [[SequenceAnnotation]] = []
        var rowEndPixels: [CGFloat] = []  // Track rightmost pixel in each row
        var overflow = 0

        for annot in sortedAnnotations {
            let startX = frame.screenPosition(for: Double(annot.start))

            var placed = false
            for rowIndex in 0..<rows.count {
                if startX >= rowEndPixels[rowIndex] + minPixelGap {
                    rows[rowIndex].append(annot)
                    let endX = frame.screenPosition(for: Double(annot.end))
                    rowEndPixels[rowIndex] = max(endX, startX + 3)  // min 3px feature width
                    placed = true
                    break
                }
            }

            if !placed {
                if rows.count < maxRows {
                    rows.append([annot])
                    let endX = frame.screenPosition(for: Double(annot.end))
                    rowEndPixels.append(max(endX, startX + 3))
                } else {
                    overflow += 1
                }
            }
        }

        return (rows, overflow)
    }

    // MARK: - Annotation Drawing Helpers

    /// Draws a small strand arrow inside an annotation rect.
    private func drawStrandArrow(strand: Strand, rect: CGRect, context: CGContext) {
        guard strand == .forward || strand == .reverse else { return }

        let arrowSize: CGFloat = 4
        let midY = rect.midY
        context.setStrokeColor(NSColor.textColor.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)

        if strand == .forward {
            let x = rect.maxX - arrowSize - 2
            context.move(to: CGPoint(x: x, y: midY - arrowSize / 2))
            context.addLine(to: CGPoint(x: x + arrowSize, y: midY))
            context.addLine(to: CGPoint(x: x, y: midY + arrowSize / 2))
        } else {
            let x = rect.minX + 2
            context.move(to: CGPoint(x: x + arrowSize, y: midY - arrowSize / 2))
            context.addLine(to: CGPoint(x: x, y: midY))
            context.addLine(to: CGPoint(x: x + arrowSize, y: midY + arrowSize / 2))
        }
        context.strokePath()
    }

    /// Draws a "+N more features" indicator below the last row.
    private func drawOverflowIndicator(rowCount: Int, height: CGFloat, overflow: Int,
                                       frame: ReferenceFrame, context: CGContext) {
        let y = annotationTrackY + CGFloat(rowCount) * height
        let text = "+\(overflow) more features"
        let font = NSFont.systemFont(ofSize: 9)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelRect = CGRect(x: 4, y: y, width: CGFloat(frame.pixelWidth) - 8, height: 12)
        (text as NSString).draw(in: labelRect, withAttributes: attrs)
    }
    
    /// Draws a loading indicator.
    private func drawLoadingIndicator(context: CGContext, message: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
        
        let size = (message as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        
        (message as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawPlaceholder(context: CGContext) {
        // isFlipped=true: Y=0 is top, Y increases downward
        let centerY = bounds.height / 2

        // Draw SF Symbol icon centered above the text
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
        if let symbolImage = NSImage(
            systemSymbolName: "doc.viewfinder",
            accessibilityDescription: "No file selected"
        )?.withSymbolConfiguration(symbolConfig) {
            let imageSize = symbolImage.size
            let imageRect = NSRect(
                x: (bounds.width - imageSize.width) / 2,
                y: centerY - imageSize.height - 8,
                width: imageSize.width,
                height: imageSize.height
            )

            NSGraphicsContext.saveGraphicsState()
            NSColor.tertiaryLabelColor.set()
            symbolImage.draw(in: imageRect, from: .zero, operation: .destinationIn, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()

            // Draw tinted version
            let tintedImage = symbolImage.copy() as! NSImage
            tintedImage.lockFocus()
            NSColor.tertiaryLabelColor.withAlphaComponent(0.5).set()
            NSRect(origin: .zero, size: tintedImage.size).fill(using: .sourceAtop)
            tintedImage.unlockFocus()
            tintedImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Draw text below the icon
        let message = "Select a file from the sidebar to view"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 4

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]

        let size = (message as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: centerY + 8,
            width: size.width,
            height: size.height
        )

        (message as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let scale = frame.scale  // bp/pixel

        // Decide rendering mode based on zoom level (scale = bp/pixel)
        // Three modes based on user feedback:
        // - BASE_MODE: < 10 bp/pixel - Individual colored bases with letters
        // - BLOCK_MODE: 10-300 bp/pixel - Colored blocks showing dominant base (no letters)
        // - LINE_MODE: > 300 bp/pixel - Simple gray horizontal line
        //
        // User feedback: Show colors when ~300bp visible (~1% of typical sequence)
        // This corresponds to about 0.3 bp/pixel on a 1000px screen,
        // but the block mode threshold is set at 300 bp/pixel for the transition
        // from colored blocks to gray line.
        let blockModeThreshold: Double = 300.0  // Show colored blocks up to 300 bp/pixel

        if scale < showLettersThreshold {
            // High zoom (< 10 bp/pixel): show individual bases with letters
            // Colors: A=Green, T=Red, C=Blue, G=Orange, N=Gray
            drawBaseLevelSequence(seq, frame: frame, context: context)
        } else if scale < blockModeThreshold {
            // Medium zoom (10-300 bp/pixel): show colored blocks without letters
            // Shows dominant base color per bin for pattern visualization
            drawBlockLevelSequence(seq, frame: frame, context: context)
        } else {
            // Low zoom (>= 300 bp/pixel): show simple gray line
            // At this scale, individual bases provide no useful information
            drawLineSequence(seq, frame: frame, context: context)
        }

        // Draw translation track if active and zoomed in enough
        if showTranslationTrack && frame.scale < showLettersThreshold {
            let transY = trackY + trackHeight + 4
            if let result = activeTranslationResult {
                TranslationTrackRenderer.drawCDSTranslation(
                    result: result,
                    frame: frame,
                    context: context,
                    yOffset: transY,
                    colorScheme: translationColorScheme,
                    showStopCodons: translationShowStopCodons
                )
            } else if !frameTranslationFrames.isEmpty {
                // For single-sequence mode, extract the visible portion
                let visStart = max(0, Int(frame.start))
                let visEnd = min(seq.length, Int(frame.end))
                if visStart < visEnd {
                    let bases = seq[visStart..<visEnd]
                    TranslationTrackRenderer.drawFrameTranslations(
                        frames: frameTranslationFrames,
                        sequence: bases,
                        sequenceStart: visStart,
                        frame: frame,
                        context: context,
                        yOffset: transY,
                        table: frameTranslationTable,
                        colorScheme: translationColorScheme,
                        showStopCodons: translationShowStopCodons
                    )
                }
            }
        }

        // Draw selection highlight
        drawSelectionHighlight(frame: frame, context: context)

        // Draw annotations if present and enabled
        if showAnnotations && !annotations.isEmpty {
            drawAnnotations(frame: frame, context: context)
        }

        // Draw sequence info header
        drawSequenceInfo(seq, frame: frame, context: context)
    }

    /// Draws the selection highlight overlay
    private func drawSelectionHighlight(frame: ReferenceFrame, context: CGContext) {
        guard let range = selectionRange else { return }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Calculate screen coordinates for selection
        let startX = CGFloat(range.lowerBound - Int(frame.start)) * pixelsPerBase
        let endX = CGFloat(range.upperBound - Int(frame.start)) * pixelsPerBase
        let selectionRect = CGRect(
            x: max(0, startX),
            y: trackY,
            width: min(bounds.width - startX, endX - startX),
            height: trackHeight
        )

        // Draw selection highlight with blue tint
        context.saveGState()
        context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor)
        context.fill(selectionRect)

        // Draw selection border
        context.setStrokeColor(NSColor.selectedTextBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.stroke(selectionRect)
        context.restoreGState()
    }


    /// Returns the filtered annotations based on current filter settings.
    private func filteredAnnotations() -> [SequenceAnnotation] {
        var result = annotations

        // Filter by type if visibleAnnotationTypes is set
        if let visibleTypes = visibleAnnotationTypes {
            result = result.filter { visibleTypes.contains($0.type) }
        }

        // Filter by text if filterText is not empty
        if !annotationFilterText.isEmpty {
            let lowercaseFilter = annotationFilterText.lowercased()
            result = result.filter { annotation in
                annotation.name.lowercased().contains(lowercaseFilter) ||
                annotation.type.rawValue.lowercased().contains(lowercaseFilter) ||
                (annotation.note?.lowercased().contains(lowercaseFilter) ?? false)
            }
        }

        return result
    }

    /// Draws annotation features below the sequence track
    private func drawAnnotations(frame: ReferenceFrame, context: CGContext) {
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Standard annotation colors by type
        let typeColors: [AnnotationType: NSColor] = [
            .gene: NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.2, alpha: 1.0),
            .cds: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0),
            .exon: NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.8, alpha: 1.0),
            .mRNA: NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.2, alpha: 1.0),
            .transcript: NSColor(calibratedRed: 0.7, green: 0.5, blue: 0.3, alpha: 1.0),
            .misc_feature: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),
            .region: NSColor(calibratedRed: 0.4, green: 0.7, blue: 0.7, alpha: 1.0),
            .primer: NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.2, alpha: 1.0),
            .restrictionSite: NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0),
        ]

        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Track row assignments to avoid overlaps
        var rowEndPositions: [CGFloat] = []

        // Use filtered annotations
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            // Get the first interval (simplified - could handle discontinuous features)
            guard let interval = annotation.intervals.first else { continue }

            // Check if annotation is visible
            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            // Calculate screen coordinates
            let rawStartX = CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = CGFloat(interval.end - visibleStart) * pixelsPerBase
            // Clamp startX to view bounds to prevent drawing into gutter/outside area
            let startX = max(0, rawStartX)
            let width = max(2, endX - startX)

            // Find a row that doesn't overlap
            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            // Extend rows array if needed
            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)

            // Get color for this annotation type
            let color = typeColors[annotation.type] ?? NSColor.gray

            // Draw annotation box
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)
            context.setFillColor(color.cgColor)
            context.fill(annotRect)

            // Draw border
            context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(annotRect)

            // Draw selection highlight if this annotation is selected
            if let selected = selectedAnnotation, selected.id == annotation.id {
                drawAnnotationSelectionHighlight(rect: annotRect, context: context)
            }

            // Draw label if space permits
            if width > 30 {
                let label = annotation.name
                let labelAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let labelSize = (label as NSString).size(withAttributes: labelAttributes)

                if labelSize.width < width - 4 {
                    let labelX = startX + (width - labelSize.width) / 2
                    let labelY = y + (annotationHeight - labelSize.height) / 2
                    (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
                }
            }

            // Draw strand direction indicator
            if annotation.strand == .forward || annotation.strand == .reverse {
                let arrowSize: CGFloat = 6
                context.setFillColor(NSColor.white.cgColor)

                if annotation.strand == .forward {
                    // Arrow pointing right
                    let arrowX = min(startX + width - arrowSize - 2, bounds.width - arrowSize)
                    let arrowY = y + annotationHeight / 2
                    context.move(to: CGPoint(x: arrowX, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                } else {
                    // Arrow pointing left
                    let arrowX = max(startX + 2, 0)
                    let arrowY = y + annotationHeight / 2
                    context.move(to: CGPoint(x: arrowX + arrowSize, y: arrowY - arrowSize/2))
                    context.addLine(to: CGPoint(x: arrowX, y: arrowY))
                    context.addLine(to: CGPoint(x: arrowX + arrowSize, y: arrowY + arrowSize/2))
                    context.closePath()
                    context.fillPath()
                }
            }
        }
    }

    /// Draws a dashed selection highlight around the selected annotation
    private func drawAnnotationSelectionHighlight(rect: CGRect, context: CGContext) {
        context.saveGState()

        // Use system selection color
        let selectionColor = NSColor.selectedContentBackgroundColor

        // Draw a slightly expanded rect with dashed border
        let expandedRect = rect.insetBy(dx: -2, dy: -2)

        // Set up dashed line pattern
        context.setStrokeColor(selectionColor.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [4, 2])

        // Draw the dashed rectangle
        context.stroke(expandedRect)

        // Also draw a semi-transparent fill to emphasize selection
        context.setFillColor(selectionColor.withAlphaComponent(0.2).cgColor)
        context.fill(expandedRect)

        context.restoreGState()
    }

    /// Draws quality score overlay behind bases when enabled.
    ///
    /// This method renders semi-transparent colored rectangles behind each base
    /// to indicate the quality/confidence of the sequencing at that position.
    /// Quality scores are typically from FASTQ files.
    ///
    /// - Parameters:
    ///   - context: The graphics context to draw into
    ///   - sequence: The sequence containing quality scores
    ///   - frame: The current reference frame for coordinate mapping
    ///   - rect: The rectangle area to draw within
    private func drawQualityOverlay(
        context: CGContext,
        sequence: Sequence,
        frame: ReferenceFrame,
        rect: CGRect
    ) {
        // Only draw if quality overlay is enabled and quality scores exist
        guard sequenceAppearance.showQualityOverlay,
              let qualityScores = sequence.qualityScores else {
            return
        }

        let startBase = max(0, Int(frame.start))
        let endBase = min(sequence.length, Int(frame.end) + 1)

        // Ensure we have quality scores for the visible range
        guard startBase < qualityScores.count else { return }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        context.saveGState()

        // Draw quality overlay for each visible base
        for i in startBase..<min(endBase, qualityScores.count) {
            let x = CGFloat(i - startBase) * pixelsPerBase
            let qualityScore = qualityScores[i]
            let qualityColor = QualityColors.color(forScore: qualityScore)

            context.setFillColor(qualityColor.cgColor)
            context.fill(CGRect(
                x: x,
                y: rect.origin.y,
                width: max(1, pixelsPerBase - 0.5),
                height: rect.height
            ))
        }

        context.restoreGState()
    }

    private func drawBaseLevelSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Font sizing based on available space
        let fontSize = min(pixelsPerBase * 0.75, trackHeight * 0.8)
        let showLetters = pixelsPerBase >= 8 && fontSize >= 6
        let font = NSFont.monospacedSystemFont(ofSize: max(6, fontSize), weight: .bold)

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        for i in startBase..<endBase {
            let x = CGFloat(i - startBase) * pixelsPerBase
            let baseChar = seq[i]

            // Draw background color using appearance settings
            let color = sequenceAppearance.color(forBase: baseChar)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, pixelsPerBase - 0.5), height: trackHeight))

            // Draw letter if space permits
            if showLetters {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white,
                ]
                // Handle T/U conversion based on RNA mode:
                // - Default (DNA mode): U → T (show as DNA)
                // - RNA mode: T → U (show as RNA)
                var displayBase = String(baseChar).uppercased()
                if isRNAMode && displayBase == "T" {
                    displayBase = "U"
                } else if !isRNAMode && displayBase == "U" {
                    displayBase = "T"
                }
                let strSize = (displayBase as NSString).size(withAttributes: attributes)
                let strX = x + (pixelsPerBase - strSize.width) / 2
                let strY = trackY + (trackHeight - strSize.height) / 2
                (displayBase as NSString).draw(at: CGPoint(x: strX, y: strY), withAttributes: attributes)
            }
        }
    }

    private func drawBlockLevelSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        // Aggregate bases into bins for colored bar display
        let basesPerBin = max(1, Int(frame.scale))

        for binStart in stride(from: startBase, to: endBase, by: basesPerBin) {
            let binEnd = min(binStart + basesPerBin, endBase)
            let x = CGFloat(binStart - startBase) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Find dominant base in this bin
            var counts: [Character: Int] = ["A": 0, "T": 0, "C": 0, "G": 0, "N": 0]
            for i in binStart..<binEnd {
                let base = Character(seq[i].uppercased())
                counts[base, default: 0] += 1
            }
            let dominantBase = counts.max(by: { $0.value < $1.value })?.key ?? "N"

            // Use appearance settings for color
            let color = sequenceAppearance.color(forBase: dominantBase)

            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight))
        }
    }

    private func drawOverviewSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Calculate bin size for density display (2 pixels per bin minimum)
        let binSize = max(1, Int(frame.scale * 2))

        // GC content color gradient
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for binStart in stride(from: startBase, to: endBase, by: binSize) {
            let binEnd = min(binStart + binSize, endBase)
            let x = CGFloat(binStart - startBase) * pixelsPerBase
            let width = CGFloat(binEnd - binStart) * pixelsPerBase

            // Calculate GC content for this bin
            var gcCount = 0
            var totalCount = 0
            for i in binStart..<binEnd {
                let base = seq[i].uppercased().first ?? "N"
                if base == "G" || base == "C" {
                    gcCount += 1
                }
                totalCount += 1
            }
            let gcContent = totalCount > 0 ? CGFloat(gcCount) / CGFloat(totalCount) : 0.5

            // Interpolate color based on GC content
            let color = interpolateColor(from: lowGCColor, to: highGCColor, factor: gcContent)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: trackY, width: max(1, width), height: trackHeight))
        }

        // Draw GC legend
        drawGCLegend(context: context)
    }

    /// Draws a simple line representation for very zoomed out view.
    ///
    /// When zoomed out beyond showLineThreshold, individual bases and GC content
    /// become meaningless noise. This method draws a clean, simple line to
    /// represent the sequence extent without visual clutter.
    ///
    /// - Parameters:
    ///   - seq: The sequence to draw
    ///   - frame: The current reference frame for coordinate mapping
    ///   - context: The graphics context to draw into
    private func drawLineSequence(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        let startBase = max(0, Int(frame.start))
        let endBase = min(seq.length, Int(frame.end) + 1)

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Calculate the visible portion of the sequence
        let startX = CGFloat(startBase - Int(frame.start)) * pixelsPerBase
        let endX = CGFloat(endBase - Int(frame.start)) * pixelsPerBase
        let lineWidth = max(1, endX - startX)

        // Draw a simple gray bar to represent the sequence
        // Use a thicker bar that's proportional to track height for better visibility at low zoom
        let lineColor = NSColor.systemGray
        let lineY = trackY + trackHeight / 2
        let lineThickness: CGFloat = max(8, trackHeight * 0.4)  // At least 8px, up to 40% of track height

        context.saveGState()

        // Draw sequence extent as a solid bar
        context.setFillColor(lineColor.cgColor)
        context.fill(CGRect(
            x: max(0, startX),
            y: lineY - lineThickness / 2,
            width: lineWidth,
            height: lineThickness
        ))

        // Draw subtle border for definition
        context.setStrokeColor(lineColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(
            x: max(0, startX),
            y: lineY - lineThickness / 2,
            width: lineWidth,
            height: lineThickness
        ))

        context.restoreGState()

        // Draw scale indicator
        drawLineScaleIndicator(context: context, frame: frame)
    }

    /// Draws a scale indicator when in line mode.
    private func drawLineScaleIndicator(context: CGContext, frame: ReferenceFrame) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let visibleBases = Int(frame.end - frame.start)
        let scaleText: String
        if visibleBases >= 1_000_000 {
            scaleText = "\(visibleBases / 1_000_000) Mb visible"
        } else if visibleBases >= 1_000 {
            scaleText = "\(visibleBases / 1_000) kb visible"
        } else {
            scaleText = "\(visibleBases) bp visible"
        }

        let textSize = (scaleText as NSString).size(withAttributes: attributes)
        let textX = bounds.maxX - textSize.width - 8
        let textY = trackY + 2

        (scaleText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    private func interpolateColor(from: NSColor, to: NSColor, factor: CGFloat) -> NSColor {
        let f = max(0, min(1, factor))
        let fromComponents = from.cgColor.components ?? [0, 0, 0, 1]
        let toComponents = to.cgColor.components ?? [0, 0, 0, 1]

        let r = fromComponents[0] + (toComponents[0] - fromComponents[0]) * f
        let g = fromComponents[1] + (toComponents[1] - fromComponents[1]) * f
        let b = fromComponents[2] + (toComponents[2] - fromComponents[2]) * f

        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    private func drawGCLegend(context: CGContext) {
        let legendWidth: CGFloat = 60
        let legendHeight: CGFloat = 10
        let legendX = bounds.maxX - legendWidth - 8
        let legendY = trackY

        // Draw gradient
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for i in 0..<Int(legendWidth) {
            let factor = CGFloat(i) / legendWidth
            let color = interpolateColor(from: lowGCColor, to: highGCColor, factor: factor)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: legendX + CGFloat(i), y: legendY, width: 1, height: legendHeight))
        }

        // Draw labels
        let labelFont = NSFont.systemFont(ofSize: 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ("AT" as NSString).draw(at: CGPoint(x: legendX - 14, y: legendY), withAttributes: attributes)
        ("GC" as NSString).draw(at: CGPoint(x: legendX + legendWidth + 2, y: legendY), withAttributes: attributes)
    }

    private func drawSequenceInfo(_ seq: Sequence, frame: ReferenceFrame, context: CGContext) {
        // Draw info below the sequence track
        var info = "\(seq.name) | \(seq.length.formatted()) bp | \(seq.alphabet)"

        // Add quality overlay indicator if enabled
        if sequenceAppearance.showQualityOverlay && seq.qualityScores != nil {
            info += " | Quality overlay enabled"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let infoY = trackY + trackHeight + 8
        (info as NSString).draw(at: CGPoint(x: 4, y: infoY), withAttributes: attributes)
    }

    // MARK: - Annotation Hit-Testing

    /// Finds the annotation at the given point, if any.
    ///
    /// - Parameter point: The point in view coordinates to test.
    /// - Returns: The annotation at that point, or nil if no annotation is at the point.
    private func annotationAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard let frame = viewController?.referenceFrame else { return nil }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        // Track row assignments to find correct Y positions (must match drawAnnotations logic)
        var rowEndPositions: [CGFloat] = []

        // Use filtered annotations for hit testing
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            // Use bounding region for both continuous and discontiguous annotations
            let annotStart = annotation.start
            let annotEnd = annotation.end

            // Check if annotation is visible
            if annotEnd < visibleStart || annotStart > visibleEnd {
                continue
            }

            // Calculate screen coordinates (must match drawAnnotations logic exactly)
            let rawStartX = CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = CGFloat(annotEnd - visibleStart) * pixelsPerBase
            // Clamp startX to view bounds (same as in drawAnnotations)
            let startX = max(0, rawStartX)
            let width = max(2, endX - startX)

            // Find row assignment (same logic as drawAnnotations)
            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)

            // Create bounding rect for this annotation
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

            // Check if point is within this annotation's rect
            if annotRect.contains(point) {
                return annotation
            }
        }

        return nil
    }

    /// Returns the bounding rect of the annotation at the given point.
    ///
    /// This method uses the same logic as `annotationAtPoint` but returns the rect
    /// for anchoring popovers.
    ///
    /// - Parameter point: The point to test in view coordinates
    /// - Returns: The bounding rect of the annotation at the point, or nil if none found
    private func annotationRectAtPoint(_ point: NSPoint) -> CGRect? {
        guard let frame = viewController?.referenceFrame else { return nil }

        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)

        var rowEndPositions: [CGFloat] = []
        let displayAnnotations = filteredAnnotations()

        for annotation in displayAnnotations {
            let annotStart = annotation.start
            let annotEnd = annotation.end

            if annotEnd < visibleStart || annotStart > visibleEnd {
                continue
            }

            let rawStartX = CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = CGFloat(annotEnd - visibleStart) * pixelsPerBase
            let startX = max(0, rawStartX)
            let width = max(2, endX - startX)

            var row = 0
            for (i, endPos) in rowEndPositions.enumerated() {
                if startX >= endPos + 2 {
                    row = i
                    break
                }
                row = i + 1
            }

            while rowEndPositions.count <= row {
                rowEndPositions.append(0)
            }
            rowEndPositions[row] = startX + width

            let y = annotationTrackY + CGFloat(row) * (annotationHeight + annotationRowSpacing)
            let annotRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

            if annotRect.contains(point) {
                return annotRect
            }
        }

        return nil
    }

    /// Posts a notification that an annotation was selected.
    /// Internal so the AnnotationDrawer extension can post from table selection.
    func postAnnotationSelectedNotification(_ annotation: SequenceAnnotation?) {
        if let annotation = annotation {
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: self,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
            logger.info("Posted annotationSelected notification for '\(annotation.name, privacy: .public)'")
        } else {
            // Post notification with nil to indicate deselection
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: self,
                userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
            )
            logger.info("Posted annotationSelected notification (deselection)")
        }
    }

    /// Shows a popover with annotation details at the specified location.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to display details for
    ///   - rect: The bounding rectangle to anchor the popover to
    private func showAnnotationPopover(for annotation: SequenceAnnotation, at rect: CGRect) {
        // Close any existing popover
        annotationPopover?.close()

        // Create popover content
        let contentView = NSHostingView(rootView: AnnotationPopoverView(annotation: annotation))
        let popoverController = NSViewController()
        popoverController.view = contentView
        contentView.frame = NSRect(x: 0, y: 0, width: 280, height: 200)

        // Create and configure popover
        let popover = NSPopover()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = true

        // Show popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        annotationPopover = popover

        logger.info("Showing annotation popover for '\(annotation.name, privacy: .public)'")
    }

    // MARK: - Drag and Drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        logger.info("SequenceViewerView.draggingEntered: Drag entered view")
        let canAccept = canAcceptDrag(sender)
        logger.info("SequenceViewerView.draggingEntered: canAcceptDrag = \(canAccept)")
        if canAccept {
            isDragActive = true
            setNeedsDisplay(bounds)
            return .copy
        }
        return []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return canAcceptDrag(sender) ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        logger.info("SequenceViewerView.draggingExited: Drag exited view")
        isDragActive = false
        setNeedsDisplay(bounds)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let canAccept = canAcceptDrag(sender)
        logger.info("SequenceViewerView.prepareForDragOperation: Preparing, canAccept = \(canAccept)")
        return canAccept
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        logger.info("SequenceViewerView.performDragOperation: Starting drop operation")
        isDragActive = false

        guard let urls = getURLsFromDrag(sender) else {
            logger.warning("SequenceViewerView.performDragOperation: No URLs from drag")
            return false
        }

        logger.info("SequenceViewerView.performDragOperation: Got \(urls.count) URLs from drag")
        for (index, url) in urls.enumerated() {
            logger.info("SequenceViewerView.performDragOperation: URL[\(index)] = '\(url.path, privacy: .public)'")
        }

        // Filter to supported file types
        let supportedURLs = urls.filter { url in
            let detected = DocumentType.detect(from: url)
            logger.info("SequenceViewerView.performDragOperation: '\(url.lastPathComponent, privacy: .public)' -> type=\(detected?.rawValue ?? "nil", privacy: .public)")
            return detected != nil
        }

        logger.info("SequenceViewerView.performDragOperation: \(supportedURLs.count) supported URLs after filtering")

        guard !supportedURLs.isEmpty else {
            logger.warning("SequenceViewerView.performDragOperation: No supported file types found")
            return false
        }

        // Hand off to view controller
        if let vc = viewController {
            logger.info("SequenceViewerView.performDragOperation: Handing off to viewController.handleFileDrop")
            vc.handleFileDrop(supportedURLs)
        } else {
            logger.error("SequenceViewerView.performDragOperation: viewController is nil!")
            return false
        }
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        logger.info("SequenceViewerView.concludeDragOperation: Drag operation concluded")
        isDragActive = false
        setNeedsDisplay(bounds)
    }

    private func canAcceptDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = getURLsFromDrag(sender) else {
            logger.debug("SequenceViewerView.canAcceptDrag: No URLs in pasteboard")
            return false
        }
        let hasSupported = urls.contains { DocumentType.detect(from: $0) != nil }
        logger.debug("SequenceViewerView.canAcceptDrag: hasSupported = \(hasSupported)")
        return hasSupported
    }

    private func getURLsFromDrag(_ sender: NSDraggingInfo) -> [URL]? {
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
        logger.debug("SequenceViewerView.getURLsFromDrag: Got \(urls?.count ?? 0) URLs from pasteboard")
        return urls
    }

    // MARK: - Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow - pan left (use bounded pan)
            viewController?.referenceFrame?.pan(by: -100)
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
            viewController?.updateStatusBar()
        case 124: // Right arrow - pan right (use bounded pan)
            viewController?.referenceFrame?.pan(by: 100)
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
            viewController?.updateStatusBar()
        case 126: // Up arrow
            viewController?.zoomIn()
        case 125: // Down arrow
            viewController?.zoomOut()
        case 8: // 'C' key - copy selection
            if event.modifierFlags.contains(.command) {
                copySelectionToClipboard()
            } else {
                super.keyDown(with: event)
            }
        case 0: // 'A' key - select all
            if event.modifierFlags.contains(.command) {
                selectAll()
            } else {
                super.keyDown(with: event)
            }
        case 53: // Escape - clear selection
            clearSelection()
            // Also clear annotation selection
            if selectedAnnotation != nil {
                selectedAnnotation = nil
                postAnnotationSelectedNotification(nil)
                setNeedsDisplay(bounds)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Mouse Selection

    public override func mouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        let location = convert(event.locationInWindow, from: nil)
        let isDoubleClick = event.clickCount == 2

        // Check for annotation click — bundle mode, multi-sequence mode, or single-sequence mode
        if currentReferenceBundle != nil {
            // Bundle mode: use bundle-specific hit testing
            if let annotation = bundleAnnotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                selectionRange = nil
                selectionStartBase = nil
                isSelecting = false
                setNeedsDisplay(bounds)
                updateSelectionStatus()

                if isDoubleClick {
                    showAnnotationPopover(for: annotation, at: CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                }
                return
            }
        } else if isMultiSequenceMode, let state = multiSequenceState {
            // Multi-sequence mode: check each track for annotation click
            for stackedInfo in state.stackedSequences {
                if let annotation = annotationAtPoint(location, forSequence: stackedInfo, frame: frame) {
                    selectedAnnotation = annotation
                    postAnnotationSelectedNotification(annotation)
                    selectionRange = nil
                    selectionStartBase = nil
                    isSelecting = false
                    setNeedsDisplay(bounds)
                    updateSelectionStatus()

                    if isDoubleClick {
                        let annotRect = annotationRectAtPoint(location, forSequence: stackedInfo, frame: frame)
                        showAnnotationPopover(for: annotation, at: annotRect ?? CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                    }
                    return
                }
            }
        } else {
            // Single-sequence mode: use original method
            if let annotation = annotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                selectionRange = nil
                selectionStartBase = nil
                isSelecting = false
                setNeedsDisplay(bounds)
                updateSelectionStatus()

                if isDoubleClick {
                    let annotRect = annotationRectAtPoint(location)
                    showAnnotationPopover(for: annotation, at: annotRect ?? CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                }
                return
            }
        }

        // If click is in the annotation track area but not on an annotation, deselect
        if selectedAnnotation != nil {
            // In multi-sequence mode, check if clicking in any track's annotation area
            var inAnnotationArea = false
            if isMultiSequenceMode, let state = multiSequenceState {
                for stackedInfo in state.stackedSequences {
                    if isPointInAnnotationArea(location, forSequence: stackedInfo) {
                        inAnnotationArea = true
                        break
                    }
                }
            } else {
                inAnnotationArea = location.y >= annotationTrackY
            }

            if inAnnotationArea {
                selectedAnnotation = nil
                postAnnotationSelectedNotification(nil)
                setNeedsDisplay(bounds)
            }
        }

        // Continue with existing region selection behavior for sequence track
        let basePosition = basePositionAt(x: location.x, frame: frame)

        // Start selection
        selectionStartBase = basePosition
        selectionRange = basePosition..<(basePosition + 1)
        isSelecting = true

        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isSelecting,
              let startBase = selectionStartBase,
              let frame = viewController?.referenceFrame else { return }

        let location = convert(event.locationInWindow, from: nil)
        let currentBase = basePositionAt(x: location.x, frame: frame)

        // Update selection range
        let minBase = min(startBase, currentBase)
        let maxBase = max(startBase, currentBase) + 1
        selectionRange = minBase..<maxBase

        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseUp(with event: NSEvent) {
        isSelecting = false
        // Keep the selection visible
    }

    // MARK: - Right-Click Context Menu

    /// Handles right-click/control-click to show contextual menu
    public override func rightMouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }
        let location = convert(event.locationInWindow, from: nil)

        // Check if right-clicking on an annotation - use multi-sequence aware method if applicable
        var clickedAnnotation: SequenceAnnotation?
        if isMultiSequenceMode, let state = multiSequenceState {
            for stackedInfo in state.stackedSequences {
                if let annotation = annotationAtPoint(location, forSequence: stackedInfo, frame: frame) {
                    clickedAnnotation = annotation
                    break
                }
            }
        } else {
            clickedAnnotation = annotationAtPoint(location)
        }

        if let annotation = clickedAnnotation {
            // Select the annotation if not already selected
            if selectedAnnotation?.id != annotation.id {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                setNeedsDisplay(bounds)
            }
            // Show annotation context menu
            showAnnotationContextMenu(for: annotation, at: event)
            return
        }

        // Check if right-clicking on a selection
        if selectionRange != nil {
            showSelectionContextMenu(at: event)
            return
        }

        // No selection - show general context menu
        showGeneralContextMenu(at: event)
    }

    /// Creates and shows context menu for annotation
    private func showAnnotationContextMenu(for annotation: SequenceAnnotation, at event: NSEvent) {
        let menu = NSMenu(title: "Annotation")

        // Edit annotation
        let editItem = NSMenuItem(title: "Edit Annotation...", action: #selector(editAnnotationAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = annotation
        menu.addItem(editItem)

        menu.addItem(NSMenuItem.separator())

        // Copy annotation name
        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyAnnotationName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        menu.addItem(copyNameItem)

        // Copy annotation sequence
        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copyAnnotationSequence(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        menu.addItem(copySeqItem)

        menu.addItem(NSMenuItem.separator())

        // Delete annotation
        let deleteItem = NSMenuItem(title: "Delete Annotation", action: #selector(deleteAnnotationAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        menu.addItem(deleteItem)

        menu.addItem(NSMenuItem.separator())

        // Show in Inspector
        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showAnnotationInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Creates and shows context menu for sequence selection
    private func showSelectionContextMenu(at event: NSEvent) {
        let menu = NSMenu(title: "Selection")

        // Copy selection
        let copyItem = NSMenuItem(title: "Copy Selection", action: #selector(copySelectionAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Create annotation from selection
        let annotateItem = NSMenuItem(title: "Create Annotation from Selection...", action: #selector(createAnnotationFromSelection(_:)), keyEquivalent: "")
        annotateItem.target = self
        menu.addItem(annotateItem)

        menu.addItem(NSMenuItem.separator())

        // Get complement
        let complementItem = NSMenuItem(title: "Copy Complement", action: #selector(copyComplementAction(_:)), keyEquivalent: "")
        complementItem.target = self
        menu.addItem(complementItem)

        // Get reverse complement
        let revCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyReverseComplementAction(_:)), keyEquivalent: "")
        revCompItem.target = self
        menu.addItem(revCompItem)

        menu.addItem(NSMenuItem.separator())

        // Zoom to selection
        let zoomItem = NSMenuItem(title: "Zoom to Selection", action: #selector(zoomToSelectionAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        menu.addItem(zoomItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Creates and shows general context menu (no selection)
    private func showGeneralContextMenu(at event: NSEvent) {
        let menu = NSMenu(title: "Sequence")

        // Select All
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        menu.addItem(NSMenuItem.separator())

        // Zoom to Fit
        let zoomFitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFitAction(_:)), keyEquivalent: "")
        zoomFitItem.target = self
        menu.addItem(zoomFitItem)

        // Multi-sequence translation toggle
        if isMultiSequenceMode, let state = multiSequenceState {
            let location = convert(event.locationInWindow, from: nil)
            if let clickedInfo = stackedSequenceAtPoint(location) {
                menu.addItem(NSMenuItem.separator())

                // Per-track translation toggle
                let translationTitle = clickedInfo.showTranslation ? "Hide Translation" : "Show Translation"
                let translationItem = NSMenuItem(title: translationTitle, action: #selector(toggleTrackTranslation(_:)), keyEquivalent: "")
                translationItem.target = self
                translationItem.representedObject = clickedInfo.trackIndex as NSNumber
                menu.addItem(translationItem)
            }

            // Global translation toggle (show/hide all)
            menu.addItem(NSMenuItem.separator())
            let anyShowing = state.stackedSequences.contains { $0.showTranslation }
            let globalTitle = anyShowing ? "Hide All Translations" : "Show All Translations"
            let globalItem = NSMenuItem(title: globalTitle, action: #selector(toggleAllTranslations(_:)), keyEquivalent: "")
            globalItem.target = self
            menu.addItem(globalItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show in Inspector (Document tab)
        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showDocumentInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        menu.addItem(inspectorItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Context Menu Actions

    @objc private func copySelectionAction(_ sender: Any?) {
        copySelectionToClipboard()
    }

    @objc private func selectAllAction(_ sender: Any?) {
        selectAll()
    }

    @objc private func zoomToFitAction(_ sender: Any?) {
        viewController?.zoomToFit()
    }

    @objc private func zoomToSelectionAction(_ sender: Any?) {
        guard let range = selectionRange,
              let frame = viewController?.referenceFrame else { return }
        frame.start = Double(range.lowerBound)
        frame.end = Double(range.upperBound)
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
    }

    @objc private func createAnnotationFromSelection(_ sender: Any?) {
        guard let range = selectionRange else { return }
        // Post notification for AppDelegate to handle with dialog
        NotificationCenter.default.post(
            name: NSNotification.Name("createAnnotationFromSelection"),
            object: self,
            userInfo: ["range": range]
        )
    }

    @objc private func copyComplementAction(_ sender: Any?) {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }

        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Compute complement
        let complement = selectedBases.map { base -> Character in
            switch base.uppercased() {
            case "A": return "T"
            case "T": return "A"
            case "G": return "C"
            case "C": return "G"
            default: return base
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(complement), forType: .string)
        logger.info("Copied \(end - start) bases (complement) to clipboard")
    }

    @objc private func copyReverseComplementAction(_ sender: Any?) {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }

        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Compute reverse complement
        let reverseComplement = selectedBases.reversed().map { base -> Character in
            switch base.uppercased() {
            case "A": return "T"
            case "T": return "A"
            case "G": return "C"
            case "C": return "G"
            default: return base
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(reverseComplement), forType: .string)
        logger.info("Copied \(end - start) bases (reverse complement) to clipboard")
    }

    @objc private func editAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Select the annotation - the inspector will show edit controls
        selectedAnnotation = annotation
        postAnnotationSelectedNotification(annotation)
        setNeedsDisplay(bounds)
        // Open the inspector if not already visible
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
    }

    @objc private func copyAnnotationName(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
        logger.info("Copied annotation name '\(annotation.name)' to clipboard")
    }

    @objc private func copyAnnotationSequence(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation,
              let seq = sequence,
              let interval = annotation.intervals.first else { return }

        let start = max(0, interval.start)
        let end = min(seq.length, interval.end)
        let annotationBases = seq[start..<end]

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotationBases, forType: .string)
        logger.info("Copied \(end - start) bases from annotation '\(annotation.name)' to clipboard")
    }

    @objc private func deleteAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Post deletion notification
        NotificationCenter.default.post(
            name: .annotationDeleted,
            object: self,
            userInfo: [NotificationUserInfoKey.annotation: annotation]
        )
        // Clear selection if it was the selected annotation
        if selectedAnnotation?.id == annotation.id {
            selectedAnnotation = nil
            postAnnotationSelectedNotification(nil)
        }
        setNeedsDisplay(bounds)
    }

    /// Shows the selected annotation in the inspector panel.
    @objc private func showAnnotationInInspector(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        // Ensure annotation is selected
        selectedAnnotation = annotation
        postAnnotationSelectedNotification(annotation)
        setNeedsDisplay(bounds)
        // Request inspector to show with Selection tab
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
        logger.info("Show in Inspector: annotation '\(annotation.name)'")
    }

    /// Shows the document info in the inspector panel.
    @objc private func showDocumentInInspector(_ sender: NSMenuItem?) {
        // Request inspector to show with Document tab
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
        )
        logger.info("Show in Inspector: document tab")
    }

    /// Toggles translation visibility for a specific track in multi-sequence mode.
    @objc private func toggleTrackTranslation(_ sender: NSMenuItem?) {
        guard let trackIndex = sender?.representedObject as? NSNumber,
              let state = multiSequenceState else { return }
        state.toggleTranslationVisibility(at: trackIndex.intValue)
        setNeedsDisplay(bounds)
    }

    /// Toggles translation visibility for all tracks in multi-sequence mode.
    @objc private func toggleAllTranslations(_ sender: Any?) {
        guard let state = multiSequenceState else { return }
        let anyShowing = state.stackedSequences.contains { $0.showTranslation }
        if anyShowing {
            state.hideAllTranslations()
        } else {
            state.showAllTranslations()
        }
        setNeedsDisplay(bounds)
    }

    /// Scroll wheel for zooming and panning.
    /// Pan events are coalesced at 60fps to avoid redundant redraws.
    public override func scrollWheel(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // Zoom with Cmd+scroll or Option+scroll — invalidate tile and redraw immediately
            if event.scrollingDeltaY > 0 {
                viewController?.zoomIn()
            } else if event.scrollingDeltaY < 0 {
                viewController?.zoomOut()
            }
            invalidateAnnotationTile()
        } else {
            // Pan with scroll — update coordinates immediately, coalesce redraw at 60fps
            let panAmount = Double(event.scrollingDeltaX) * frame.scale * 2
            frame.pan(by: -panAmount)

            scrollRedrawTimer?.invalidate()
            scrollRedrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.setNeedsDisplay(self.bounds)
                self.viewController?.enhancedRulerView.setNeedsDisplay(self.viewController?.enhancedRulerView.bounds ?? .zero)
                self.viewController?.updateStatusBar()
                self.viewController?.scheduleViewStateSave()
            }
        }
    }

    // MARK: - Selection Helpers

    /// Converts screen X coordinate to base position
    private func basePositionAt(x: CGFloat, frame: ReferenceFrame) -> Int {
        guard let seq = sequence else { return 0 }
        let visibleBases = frame.end - frame.start
        let basesPerPixel = visibleBases / Double(bounds.width)
        let baseOffset = Double(x) * basesPerPixel
        let basePosition = Int(frame.start + baseOffset)
        return max(0, min(seq.length - 1, basePosition))
    }

    /// Selects the entire sequence
    public func selectAll() {
        guard let seq = sequence else { return }
        selectionRange = 0..<seq.length
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Clears the current selection
    public func clearSelection() {
        selectionRange = nil
        selectionStartBase = nil
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Copies the selected sequence to the clipboard
    public func copySelectionToClipboard() {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }

        // Extract the selected bases
        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedBases, forType: .string)

        logger.info("Copied \(end - start) bases to clipboard")
    }

    /// Updates the status bar with selection info
    private func updateSelectionStatus() {
        if let range = selectionRange {
            let length = range.upperBound - range.lowerBound
            let selectionText = "\(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)"
            viewController?.statusBar.update(
                position: viewController?.statusBar.positionLabel.stringValue,
                selection: selectionText,
                scale: viewController?.referenceFrame?.scale ?? 1.0
            )
        } else {
            viewController?.statusBar.update(
                position: viewController?.statusBar.positionLabel.stringValue,
                selection: nil,
                scale: viewController?.referenceFrame?.scale ?? 1.0
            )
        }
    }

    // MARK: - Hover Tooltip (Bundle Mode)

    /// Tracking area for mouse hover detection
    private var viewerTrackingArea: NSTrackingArea?

    /// Currently hovered annotation (to avoid redundant tooltip updates)
    private var hoveredAnnotation: SequenceAnnotation?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = viewerTrackingArea {
            removeTrackingArea(existing)
        }
        viewerTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
        if let area = viewerTrackingArea {
            addTrackingArea(area)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Try bundle mode hit-testing first, then single-sequence mode
        let annotation: SequenceAnnotation?
        if currentReferenceBundle != nil {
            annotation = bundleAnnotationAtPoint(location)
        } else {
            annotation = annotationAtPoint(location)
        }

        if let annot = annotation {
            if hoveredAnnotation?.id != annot.id {
                hoveredAnnotation = annot
                // Build tooltip with annotation details
                let strandStr: String
                switch annot.strand {
                case .forward: strandStr = "(+)"
                case .reverse: strandStr = "(-)"
                case .unknown: strandStr = ""
                }
                let size = annot.end - annot.start
                let sizeStr = size >= 1_000_000 ? String(format: "%.1f Mb", Double(size) / 1_000_000.0)
                    : size >= 1_000 ? String(format: "%.1f Kb", Double(size) / 1_000.0)
                    : "\(size) bp"
                let chromosome = annot.chromosome ?? (viewController?.referenceFrame?.chromosome ?? "unknown")
                let label = displayLabel(for: annot)
                let coords = "\(chromosome):\(annot.start.formatted())-\(annot.end.formatted())"
                var tooltip = "\(label)\n\(annot.type.rawValue) \(strandStr)\n\(coords) (\(sizeStr))"

                // Enrich tooltip with annotation note
                if let note = annot.note, !note.isEmpty {
                    tooltip += "\n\(note)"
                }

                // Enrich from qualifiers["extra"] (raw BED column 13+ data)
                if let extraStr = annot.qualifier("extra") {
                    let parsed = LungfishIO.AnnotationDatabase.parseAttributes(extraStr)
                    if let desc = parsed["description"] {
                        tooltip += "\n\(desc)"
                    }
                    if let biotype = parsed["gene_biotype"] {
                        tooltip += "\nBiotype: \(biotype)"
                    }
                }

                // Enrich from SQLite annotation database (if available)
                if let db = viewController?.annotationSearchIndex?.annotationDatabase {
                    let record = db.lookupAnnotation(name: annot.name, chromosome: chromosome, start: annot.start, end: annot.end)
                    if let attrs = record?.attributes {
                        let parsed = LungfishIO.AnnotationDatabase.parseAttributes(attrs)
                        if annot.qualifier("extra") == nil {
                            if let desc = parsed["description"] {
                                tooltip += "\n\(desc)"
                            }
                            if let biotype = parsed["gene_biotype"] {
                                tooltip += "\nBiotype: \(biotype)"
                            }
                        }
                        if let gene = parsed["gene"] {
                            tooltip += "\nGene: \(gene)"
                        }
                        if let product = parsed["product"] {
                            tooltip += "\nProduct: \(product)"
                        }
                        let dbxref = parsed["Dbxref"] ?? parsed["db_xref"]
                        if let dbxref {
                            tooltip += "\nRef: \(dbxref)"
                        }
                    }
                }

                self.toolTip = tooltip

                if let controller = viewController {
                    let hoverSummary = "Hover: \(label) • \(annot.type.rawValue) \(strandStr) • \(coords)"
                    controller.statusBar.update(
                        position: controller.statusBar.positionLabel.stringValue,
                        selection: hoverSummary,
                        scale: controller.referenceFrame?.scale ?? 1.0
                    )
                }
            }
            NSCursor.pointingHand.set()
        } else {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                self.toolTip = nil
                updateSelectionStatus()
            }
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredAnnotation = nil
        self.toolTip = nil
        NSCursor.arrow.set()
        updateSelectionStatus()
    }

    /// Hit-tests cached bundle annotations at the given point.
    ///
    /// Uses the same coordinate system as `drawBundleAnnotations` — screen positions
    /// computed via `frame.screenPosition(for:)` and pixel-based row packing.
    private func bundleAnnotationAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard let frame = viewController?.referenceFrame else { return nil }
        let scale = frame.scale
        guard point.y >= annotationTrackY else { return nil }

        // Only hit-test in squished and expanded modes (not density histogram)
        guard scale <= annotationDensityThreshold else { return nil }

        // Use the same annotation pool rendered in drawBundleContent.
        let bundlePool = cachedBundleAnnotations + cachedVariantAnnotations

        // Match visible region filtering used by render path.
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        let visibleAnnotations = bundlePool.filter { annot in
            annot.end > visibleStart && annot.start < visibleEnd
        }

        // Match inspector type/text filters used by rendering.
        let typeFiltered: [SequenceAnnotation]
        if let typeFilter = visibleAnnotationTypes {
            typeFiltered = visibleAnnotations.filter { typeFilter.contains($0.type) }
        } else {
            typeFiltered = visibleAnnotations
        }

        let textFiltered: [SequenceAnnotation]
        if annotationFilterText.isEmpty {
            textFiltered = typeFiltered
        } else {
            let needle = annotationFilterText.lowercased()
            textFiltered = typeFiltered.filter { annot in
                annot.name.lowercased().contains(needle)
            }
        }

        let visibleSpan = max(1, visibleEnd - visibleStart)
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = textFiltered.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(visibleSpan) * 0.98)
            }
        } else {
            let minFeatureBp = max(1, Int(scale))
            displayAnnotations = textFiltered.filter { annot in
                let span = annot.end - annot.start
                guard span >= minFeatureBp else { return false }
                return annot.type != .region || span < Int(Double(visibleSpan) * 0.98)
            }
        }

        // Use the same layered packing used by rendering.
        let (rows, _) = packAnnotationsLayered(displayAnnotations, frame: frame)

        let rowHeight: CGFloat = scale > annotationSquishedThreshold ? 7 : (annotationHeight + annotationRowSpacing)

        for (rowIndex, row) in rows.enumerated() {
            let rowY = annotationTrackY + CGFloat(rowIndex) * rowHeight

            for annot in row {
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(scale > annotationSquishedThreshold ? 1 : 3, endX - startX)
                let height: CGFloat = scale > annotationSquishedThreshold ? 6 : annotationHeight
                let annotRect = CGRect(x: startX, y: rowY, width: width, height: height)

                if annotRect.contains(point) {
                    return annot
                }
            }
        }

        return nil
    }
}

// MARK: - TrackHeaderViewDelegate

/// Delegate protocol for TrackHeaderView interactions.
@MainActor
public protocol TrackHeaderViewDelegate: AnyObject {
    /// Called when the user clicks the disclosure triangle to toggle annotation visibility.
    func trackHeaderView(_ headerView: TrackHeaderView, didToggleAnnotationsForTrackAt index: Int)
}

// MARK: - TrackHeaderView

/// View for displaying track labels and annotation expand/collapse controls.
///
/// Layout must match the SequenceStackLayout values used by multi-sequence rendering:
/// - startY: Starting Y offset (default: 20)
/// - trackHeight: Height of each sequence track (default: 28)
/// - trackSpacing: Gap between tracks (default: 4)
///
/// Features:
/// - Disclosure triangles for sequences with annotations
/// - Click-to-expand/collapse annotation tracks
/// - Visual feedback for expanded/collapsed state
public class TrackHeaderView: NSView {

    private var trackNames: [String] = []

    /// Stacked sequence info for precise alignment with viewer
    private var stackedSequences: [StackedSequenceInfo] = []

    /// Track positioning (should match SequenceStackLayout values)
    var trackY: CGFloat = SequenceStackLayout.defaultTrackHeight  // startY for first track
    var trackHeight: CGFloat = SequenceStackLayout.defaultTrackHeight
    var trackSpacing: CGFloat = SequenceStackLayout.trackSpacing

    /// Delegate for handling user interactions
    weak var delegate: TrackHeaderViewDelegate?

    /// Tracking area for mouse events
    private var trackingArea: NSTrackingArea?

    /// Currently hovered track index
    private var hoveredTrackIndex: Int?

    /// Size of disclosure triangle
    private let disclosureSize: CGFloat = 10

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
    }

    func setTrackNames(_ names: [String]) {
        self.trackNames = names
        self.stackedSequences = []
        setNeedsDisplay(bounds)
    }

    /// Sets the stacked sequences for precise Y alignment.
    /// When set, uses the actual yOffset from each sequence info.
    func setStackedSequences(_ sequences: [StackedSequenceInfo]) {
        self.stackedSequences = sequences
        self.trackNames = sequences.map { $0.sequence.name }
        setNeedsDisplay(bounds)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )

        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background - use same color as viewer when empty
        if trackNames.isEmpty {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        } else {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.fill(bounds)

        // Only draw right border when we have tracks
        if !trackNames.isEmpty {
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
            context.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
            context.strokePath()

            // Track labels - aligned with viewer tracks
            let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor,
            ]

            for (index, label) in trackNames.enumerated() {
                drawTrackRow(index: index, label: label, attributes: attributes, context: context)
            }
        }
    }

    /// Draws a single track row with label and disclosure triangle.
    private func drawTrackRow(index: Int, label: String, attributes: [NSAttributedString.Key: Any], context: CGContext) {
        // Calculate Y position - use stacked sequence info if available
        let rowY: CGFloat
        let hasAnnotations: Bool
        let annotationsExpanded: Bool

        if index < stackedSequences.count {
            // Use actual offset from multi-sequence layout
            rowY = stackedSequences[index].yOffset
            hasAnnotations = !stackedSequences[index].annotations.isEmpty
            annotationsExpanded = stackedSequences[index].showAnnotations
        } else {
            // Fallback to simple calculation matching SequenceStackLayout
            rowY = trackY + CGFloat(index) * (trackHeight + trackSpacing)
            hasAnnotations = false
            annotationsExpanded = false
        }

        let labelSize = (label as NSString).size(withAttributes: attributes)
        let labelY = rowY + (trackHeight - labelSize.height) / 2

        // Left margin for label (leave space for disclosure triangle if needed)
        var labelX: CGFloat = 8

        // Draw disclosure triangle if this track has annotations
        if hasAnnotations {
            let triangleX: CGFloat = 4
            let triangleY = rowY + (trackHeight - disclosureSize) / 2

            drawDisclosureTriangle(
                at: CGPoint(x: triangleX, y: triangleY),
                expanded: annotationsExpanded,
                hovered: hoveredTrackIndex == index,
                context: context
            )

            labelX = 4 + disclosureSize + 4  // triangle + spacing
        }

        // Truncate long names
        let maxWidth = bounds.width - labelX - 8
        let truncatedLabel = truncateLabel(label, maxWidth: maxWidth, attributes: attributes)

        (truncatedLabel as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)

        // Draw annotation count badge if collapsed but has annotations
        if hasAnnotations && !annotationsExpanded && index < stackedSequences.count {
            let count = stackedSequences[index].annotations.count
            drawAnnotationBadge(count: count, y: rowY + trackHeight - 4, context: context)
        }
    }

    /// Draws a disclosure triangle (pointing right when collapsed, down when expanded).
    private func drawDisclosureTriangle(at point: CGPoint, expanded: Bool, hovered: Bool, context: CGContext) {
        context.saveGState()

        let color = hovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        context.setFillColor(color.cgColor)

        context.translateBy(x: point.x + disclosureSize / 2, y: point.y + disclosureSize / 2)

        if expanded {
            // Pointing down (expanded)
            context.move(to: CGPoint(x: -4, y: -2))
            context.addLine(to: CGPoint(x: 4, y: -2))
            context.addLine(to: CGPoint(x: 0, y: 3))
        } else {
            // Pointing right (collapsed)
            context.move(to: CGPoint(x: -2, y: -4))
            context.addLine(to: CGPoint(x: 3, y: 0))
            context.addLine(to: CGPoint(x: -2, y: 4))
        }

        context.closePath()
        context.fillPath()

        context.restoreGState()
    }

    /// Draws a small badge showing annotation count.
    private func drawAnnotationBadge(count: Int, y: CGFloat, context: CGContext) {
        let badgeFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let badgeText = "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.white
        ]

        let size = (badgeText as NSString).size(withAttributes: attributes)
        let badgeWidth = max(size.width + 6, 14)
        let badgeHeight: CGFloat = 12

        let badgeRect = CGRect(
            x: bounds.width - badgeWidth - 4,
            y: y - badgeHeight + 2,
            width: badgeWidth,
            height: badgeHeight
        )

        // Badge background
        context.setFillColor(NSColor.tertiaryLabelColor.cgColor)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()

        // Badge text
        let textX = badgeRect.midX - size.width / 2
        let textY = badgeRect.minY + (badgeHeight - size.height) / 2
        (badgeText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    private func truncateLabel(_ label: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        let size = (label as NSString).size(withAttributes: attributes)
        if size.width <= maxWidth {
            return label
        }

        var truncated = label
        while truncated.count > 3 {
            truncated = String(truncated.dropLast())
            let testLabel = truncated + "..."
            let testSize = (testLabel as NSString).size(withAttributes: attributes)
            if testSize.width <= maxWidth {
                return testLabel
            }
        }
        return "..."
    }

    // MARK: - Mouse Event Handling

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Find which track was clicked
        if let index = trackIndex(at: location) {
            // Check if click was on disclosure triangle area
            if index < stackedSequences.count && !stackedSequences[index].annotations.isEmpty {
                let rowY = stackedSequences[index].yOffset
                let triangleRect = CGRect(x: 0, y: rowY, width: 20, height: trackHeight)

                if triangleRect.contains(location) {
                    delegate?.trackHeaderView(self, didToggleAnnotationsForTrackAt: index)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newHoveredIndex = trackIndex(at: location)

        if newHoveredIndex != hoveredTrackIndex {
            hoveredTrackIndex = newHoveredIndex
            needsDisplay = true
        }

        // Update cursor based on hover state
        if let index = newHoveredIndex,
           index < stackedSequences.count,
           !stackedSequences[index].annotations.isEmpty {
            let rowY = stackedSequences[index].yOffset
            let triangleRect = CGRect(x: 0, y: rowY, width: 20, height: trackHeight)
            if triangleRect.contains(location) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredTrackIndex = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// Returns the track index at the given Y coordinate, or nil if outside tracks.
    private func trackIndex(at point: CGPoint) -> Int? {
        if !stackedSequences.isEmpty {
            for (index, info) in stackedSequences.enumerated() {
                if point.y >= info.yOffset && point.y < info.yOffset + info.height {
                    return index
                }
            }
        } else {
            // Fallback for simple track names
            for index in 0..<trackNames.count {
                let rowY = trackY + CGFloat(index) * (trackHeight + trackSpacing)
                if point.y >= rowY && point.y < rowY + trackHeight {
                    return index
                }
            }
        }
        return nil
    }
}


// MARK: - CoordinateRulerView

/// Enhanced coordinate ruler view inspired by IGV and Geneious.
///
/// Features:
/// - Dynamic tick intervals based on zoom level using 1-2-5-10 rule
/// - Major ticks (10px) with labels, minor ticks (4px) without labels
/// - Formatted labels (1K, 10K, 1M, etc.) centered above major ticks
/// - Chromosome/sequence name displayed on left side
/// - Current visible range display
public class CoordinateRulerView: NSView {

    // MARK: - Properties

    /// The reference frame providing coordinate mapping
    var referenceFrame: ReferenceFrame?

    // MARK: - Layout Constants

    /// Height of major tick marks in pixels
    private let majorTickHeight: CGFloat = 10

    /// Height of minor tick marks in pixels
    private let minorTickHeight: CGFloat = 4

    /// Left margin for chromosome name label
    private let leftMargin: CGFloat = 8

    /// Font for coordinate labels
    private var labelFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    /// Font for chromosome name
    private var chromosomeFont: NSFont {
        NSFont.systemFont(ofSize: 10, weight: .medium)
    }

    // MARK: - View Properties

    public override var isFlipped: Bool { true }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Bottom border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: bounds.maxY - 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        context.strokePath()

        // Draw ruler with coordinates
        if let frame = referenceFrame {
            drawEnhancedRuler(frame: frame, context: context)
        } else {
            drawPlaceholderRuler(context: context)
        }
    }

    // MARK: - Enhanced Ruler Drawing

    /// Draws the enhanced ruler with dynamic tick intervals and formatted labels.
    private func drawEnhancedRuler(frame: ReferenceFrame, context: CGContext) {
        let visibleRange = frame.end - frame.start
        guard visibleRange > 0 else { return }

        let pixelsPerBase = bounds.width / CGFloat(visibleRange)

        // Calculate tick intervals using 1-2-5-10 rule
        let (majorInterval, minorInterval) = calculateTickIntervals(visibleRange: visibleRange)

        // Draw chromosome name and visible range on left
        drawChromosomeLabel(frame: frame, context: context)

        // Draw minor ticks first (so major ticks draw over them if needed)
        drawMinorTicks(
            frame: frame,
            context: context,
            interval: minorInterval,
            majorInterval: majorInterval,
            pixelsPerBase: pixelsPerBase
        )

        // Draw major ticks with labels
        drawMajorTicks(
            frame: frame,
            context: context,
            interval: majorInterval,
            pixelsPerBase: pixelsPerBase
        )
    }

    /// Calculates major and minor tick intervals based on visible range using 1-2-5-10 rule.
    ///
    /// The 1-2-5-10 rule creates visually pleasing intervals by using multiples of
    /// 1, 2, and 5 at each order of magnitude (e.g., 1, 2, 5, 10, 20, 50, 100...).
    ///
    /// - Parameter visibleRange: The number of base pairs currently visible
    /// - Returns: Tuple of (majorInterval, minorInterval) in base pairs
    private func calculateTickIntervals(visibleRange: Double) -> (major: Double, minor: Double) {
        // Target approximately 5-10 major ticks on screen for readability
        let targetMajorTicks = 7.0
        let idealInterval = visibleRange / targetMajorTicks

        // Find the order of magnitude
        let magnitude = pow(10, floor(log10(idealInterval)))

        // Determine the multiplier using 1-2-5-10 rule
        let normalized = idealInterval / magnitude
        let multiplier: Double
        if normalized < 1.5 {
            multiplier = 1
        } else if normalized < 3.5 {
            multiplier = 2
        } else if normalized < 7.5 {
            multiplier = 5
        } else {
            multiplier = 10
        }

        let majorInterval = magnitude * multiplier

        // Minor interval is 1/10th or 1/5th of major, depending on multiplier
        let minorInterval: Double
        switch multiplier {
        case 1, 2:
            minorInterval = majorInterval / 10
        case 5:
            minorInterval = majorInterval / 5
        default:
            minorInterval = majorInterval / 10
        }

        // Apply the specific rules from requirements for edge cases
        let effectiveMajor: Double
        let effectiveMinor: Double

        if visibleRange < 100 {
            // < 100 bp visible: every 10 bp with minor ticks at 1 bp
            effectiveMajor = 10
            effectiveMinor = 1
        } else if visibleRange < 1000 {
            // 100-1000 bp: every 100 bp with minor at 10 bp
            effectiveMajor = 100
            effectiveMinor = 10
        } else if visibleRange < 10000 {
            // 1K-10K bp: every 1K with minor at 100 bp
            effectiveMajor = 1000
            effectiveMinor = 100
        } else if visibleRange < 100000 {
            // 10K-100K bp: every 10K with minor at 1K
            effectiveMajor = 10000
            effectiveMinor = 1000
        } else {
            // > 100K bp: every 100K with minor at 10K
            effectiveMajor = 100000
            effectiveMinor = 10000
        }

        // Use the more appropriate of calculated vs. requirement-based intervals
        // Prefer the calculated interval if it provides better granularity
        if majorInterval > 0 && majorInterval < effectiveMajor && visibleRange >= 100 {
            return (majorInterval, minorInterval)
        }

        return (effectiveMajor, effectiveMinor)
    }

    /// Draws minor tick marks (without labels).
    private func drawMinorTicks(
        frame: ReferenceFrame,
        context: CGContext,
        interval: Double,
        majorInterval: Double,
        pixelsPerBase: CGFloat
    ) {
        guard interval > 0 else { return }

        // Calculate minimum pixel spacing to avoid overlapping ticks
        let minPixelSpacing: CGFloat = 3
        let pixelInterval = CGFloat(interval) * pixelsPerBase
        guard pixelInterval >= minPixelSpacing else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.quaternaryLabelColor.cgColor)
        context.setLineWidth(0.5)

        var pos = (frame.start / interval).rounded(.up) * interval
        while pos < frame.end {
            // Skip positions that are major tick positions
            let isMajorTick = majorInterval > 0 && abs(pos.truncatingRemainder(dividingBy: majorInterval)) < 0.001
            if !isMajorTick {
                let x = CGFloat((pos - frame.start)) * pixelsPerBase

                // Draw minor tick at bottom
                context.move(to: CGPoint(x: x, y: bounds.maxY - minorTickHeight))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                context.strokePath()
            }

            pos += interval
        }

        context.restoreGState()
    }

    /// Draws major tick marks with centered labels.
    private func drawMajorTicks(
        frame: ReferenceFrame,
        context: CGContext,
        interval: Double,
        pixelsPerBase: CGFloat
    ) {
        guard interval > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        context.saveGState()
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(1)

        // Track label positions to avoid overlap
        var lastLabelEndX: CGFloat = -100

        var pos = (frame.start / interval).rounded(.up) * interval
        while pos < frame.end {
            let x = CGFloat((pos - frame.start)) * pixelsPerBase

            // Draw major tick at bottom
            context.move(to: CGPoint(x: x, y: bounds.maxY - majorTickHeight))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            context.strokePath()

            // Draw label centered above tick
            let label = formatPosition(Int(pos))
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let labelX = x - labelSize.width / 2

            // Only draw label if it fits and doesn't overlap with previous label
            let labelPadding: CGFloat = 4
            if labelX > lastLabelEndX + labelPadding &&
               labelX >= 0 &&
               labelX + labelSize.width <= bounds.width {
                // Position label above the tick, leaving room for tick marks
                let labelY = bounds.maxY - majorTickHeight - labelSize.height - 2
                (label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
                lastLabelEndX = labelX + labelSize.width
            }

            pos += interval
        }

        context.restoreGState()
    }

    /// Draws chromosome name and visible range on the left side of the ruler.
    private func drawChromosomeLabel(frame: ReferenceFrame, context: CGContext) {
        // Build the range string: "chr1:1,000-10,000"
        let startFormatted = formatPositionWithCommas(Int(frame.start))
        let endFormatted = formatPositionWithCommas(Int(frame.end))
        let rangeString = "\(frame.chromosome):\(startFormatted)-\(endFormatted)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: chromosomeFont,
            .foregroundColor: NSColor.labelColor,
        ]

        let labelSize = (rangeString as NSString).size(withAttributes: attributes)

        // Position in top-left area of ruler
        let labelY = (bounds.height - majorTickHeight - labelSize.height) / 2
        let labelRect = CGRect(
            x: leftMargin,
            y: max(2, labelY),
            width: min(labelSize.width, bounds.width / 3),
            height: labelSize.height
        )

        // Draw background for visibility
        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor)
        context.fill(labelRect.insetBy(dx: -2, dy: -1))
        context.restoreGState()

        // Draw the text (truncated if necessary)
        (rangeString as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    /// Draws placeholder ruler when no reference frame is set.
    private func drawPlaceholderRuler(context: CGContext) {
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(0.5)

        // Draw evenly spaced minor ticks
        let tickSpacing: CGFloat = 50
        for x in stride(from: CGFloat(0), to: bounds.width, by: tickSpacing) {
            context.move(to: CGPoint(x: x, y: bounds.maxY - minorTickHeight))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            context.strokePath()
        }

        // Draw a centered message
        let message = "No sequence loaded"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - majorTickHeight - size.height) / 2
        (message as NSString).draw(at: CGPoint(x: x, y: max(2, y)), withAttributes: attributes)
    }

    // MARK: - Position Formatting

    /// Formats a genomic position with appropriate suffix (K, M, G).
    ///
    /// - Parameter pos: Position in base pairs
    /// - Returns: Formatted string (e.g., "1.5M", "10K", "500")
    private func formatPosition(_ pos: Int) -> String {
        let absPos = abs(pos)

        if absPos >= 1_000_000_000 {
            // Gigabases
            let value = Double(pos) / 1_000_000_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fG", value)
            }
            return String(format: "%.1fG", value)
        } else if absPos >= 1_000_000 {
            // Megabases
            let value = Double(pos) / 1_000_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fM", value)
            }
            return String(format: "%.1fM", value)
        } else if absPos >= 1_000 {
            // Kilobases
            let value = Double(pos) / 1_000
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fK", value)
            }
            return String(format: "%.1fK", value)
        } else {
            // Base pairs
            return "\(pos)"
        }
    }

    /// Formats a position with comma separators for the range display.
    ///
    /// - Parameter pos: Position in base pairs
    /// - Returns: Formatted string with comma separators (e.g., "1,234,567")
    private func formatPositionWithCommas(_ pos: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: pos)) ?? "\(pos)"
    }
}

// MARK: - ViewerStatusBar

/// Status bar showing current position and selection info.
public class ViewerStatusBar: NSView {

    public private(set) var positionLabel: NSTextField!
    public private(set) var selectionLabel: NSTextField!
    private var scaleLabel: NSTextField!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        positionLabel = createLabel()
        positionLabel.stringValue = "No sequence loaded"
        addSubview(positionLabel)

        selectionLabel = createLabel()
        selectionLabel.stringValue = ""
        addSubview(selectionLabel)

        scaleLabel = createLabel()
        scaleLabel.stringValue = ""
        scaleLabel.alignment = .right
        addSubview(scaleLabel)

        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            selectionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scaleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scaleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            scaleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        // Accessibility
        positionLabel.setAccessibilityIdentifier("position-label")
        selectionLabel.setAccessibilityIdentifier("selection-label")
        scaleLabel.setAccessibilityIdentifier("scale-label")
    }

    private func createLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Top border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: 0.5))
        context.strokePath()
    }

    public func update(position: String?, selection: String?, scale: Double) {
        positionLabel.stringValue = position ?? "No sequence loaded"
        selectionLabel.stringValue = selection ?? ""
        scaleLabel.stringValue = String(format: "%.1f bp/px", scale)
    }
}

// MARK: - ReferenceFrame

/// Coordinate system for genomic visualization (following IGV pattern).
/// Note: Uses @MainActor for thread safety as it contains mutable UI state.
@MainActor
public class ReferenceFrame {
    /// Chromosome/sequence name
    public var chromosome: String

    /// Start position in base pairs
    public var start: Double

    /// End position in base pairs
    public var end: Double

    /// Width of the view in pixels
    public var pixelWidth: Int

    /// Maximum sequence length (for bounds checking)
    public var sequenceLength: Int

    /// Base pairs per pixel
    public var scale: Double {
        (end - start) / Double(max(1, pixelWidth))
    }

    public init(chromosome: String, start: Double, end: Double, pixelWidth: Int, sequenceLength: Int = Int.max) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.pixelWidth = max(1, pixelWidth)
        self.sequenceLength = sequenceLength
    }

    /// Converts a screen X coordinate to genomic position
    public func genomicPosition(for screenX: CGFloat) -> Double {
        start + Double(screenX) * scale
    }

    /// Converts a genomic position to screen X coordinate
    public func screenPosition(for genomicPos: Double) -> CGFloat {
        CGFloat((genomicPos - start) / scale)
    }

    /// Pans by the specified amount in base pairs, respecting sequence bounds.
    public func pan(by deltaBP: Double) {
        let windowLength = end - start
        var newStart = start + deltaBP
        var newEnd = end + deltaBP

        // Clamp to bounds: don't go before 0 or past sequence length
        if newStart < 0 {
            newStart = 0
            newEnd = windowLength
        }
        if newEnd > Double(sequenceLength) {
            newEnd = Double(sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }

        start = newStart
        end = newEnd
    }

    /// Zooms in by the specified factor, respecting sequence bounds.
    public func zoomIn(factor: Double) {
        let center = (start + end) / 2
        let halfWidth = (end - start) / (2 * factor)
        start = max(0, center - halfWidth)
        end = min(Double(sequenceLength), center + halfWidth)
    }

    /// Zooms out by the specified factor, respecting sequence bounds.
    public func zoomOut(factor: Double) {
        let center = (start + end) / 2
        let halfWidth = (end - start) * factor / 2
        var newStart = center - halfWidth
        var newEnd = center + halfWidth

        // Clamp to bounds
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(sequenceLength), newStart + halfWidth * 2)
        }
        if newEnd > Double(sequenceLength) {
            newEnd = Double(sequenceLength)
            newStart = max(0, newEnd - halfWidth * 2)
        }

        start = newStart
        end = newEnd
    }
}

// MARK: - Annotation Popover View

/// SwiftUI view for displaying annotation details in a popover.
struct AnnotationPopoverView: View {
    let annotation: SequenceAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with name and type
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.name)
                        .font(.headline)

                    Text(annotationTypeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Type color indicator
                Circle()
                    .fill(colorForAnnotation)
                    .frame(width: 16, height: 16)
            }

            Divider()

            // Location info
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Location", value: "\(annotation.start)–\(annotation.end)")
                LabeledContent("Length", value: "\(annotation.totalLength) bp")

                if annotation.isDiscontinuous {
                    LabeledContent("Intervals", value: "\(annotation.intervals.count) segments")
                }

                if annotation.strand != .unknown {
                    LabeledContent("Strand", value: annotation.strand == .forward ? "Forward (+)" : "Reverse (−)")
                }
            }
            .font(.callout)

            // Notes if present
            if let note = annotation.note, !note.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(note)
                        .font(.caption)
                        .lineLimit(4)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var colorForAnnotation: Color {
        let annotationColor = annotation.color ?? annotation.type.defaultColor
        return Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    /// Human-readable name for annotation type
    private var annotationTypeName: String {
        switch annotation.type {
        case .gene: return "Gene"
        case .mRNA: return "mRNA"
        case .transcript: return "Transcript"
        case .exon: return "Exon"
        case .intron: return "Intron"
        case .cds: return "CDS"
        case .utr5: return "5' UTR"
        case .utr3: return "3' UTR"
        case .promoter: return "Promoter"
        case .enhancer: return "Enhancer"
        case .silencer: return "Silencer"
        case .terminator: return "Terminator"
        case .polyASignal: return "PolyA Signal"
        case .regulatory: return "Regulatory"
        case .ncRNA: return "ncRNA"
        case .primer: return "Primer"
        case .primerPair: return "Primer Pair"
        case .amplicon: return "Amplicon"
        case .restrictionSite: return "Restriction Site"
        case .snp: return "SNP"
        case .variation: return "Variation"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .repeatRegion: return "Repeat Region"
        case .stem_loop: return "Stem Loop"
        case .misc_feature: return "Misc Feature"
        case .mat_peptide: return "Mature Peptide"
        case .sig_peptide: return "Signal Peptide"
        case .transit_peptide: return "Transit Peptide"
        case .misc_binding: return "Misc Binding"
        case .protein_bind: return "Protein Binding"
        case .contig: return "Contig"
        case .gap: return "Gap"
        case .scaffold: return "Scaffold"
        case .region: return "Region"
        case .source: return "Source"
        case .custom: return "Custom"
        }
    }
}
