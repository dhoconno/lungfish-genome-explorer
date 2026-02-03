// ViewerViewController.swift - Main sequence/track viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import UniformTypeIdentifiers
import os.log

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
    private var headerView: TrackHeaderView!

    /// Enhanced coordinate ruler at the top with mini-map and navigation
    public private(set) var enhancedRulerView: EnhancedCoordinateRulerView!

    /// Status bar at the bottom
    public private(set) var statusBar: ViewerStatusBar!

    /// Progress indicator overlay
    private var progressOverlay: ProgressOverlayView!

    // MARK: - State

    /// Current reference frame for coordinate mapping
    public var referenceFrame: ReferenceFrame?

    /// Currently displayed document
    public private(set) var currentDocument: LoadedDocument?

    /// Track height constant
    private let sequenceTrackY: CGFloat = 20
    private let sequenceTrackHeight: CGFloat = 40

    // MARK: - Annotation Display Settings

    /// Whether to show annotations in the viewer
    private var showAnnotations: Bool = true

    /// Height of each annotation box in pixels
    private var annotationDisplayHeight: CGFloat = 16

    /// Vertical spacing between annotation rows
    private var annotationDisplaySpacing: CGFloat = 2

    /// Set of annotation types to display (nil means show all)
    private var visibleAnnotationTypes: Set<AnnotationType>?

    /// Text filter for annotations (empty string means no filter)
    private var annotationFilterText: String = ""

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

        // Create track header view - sync with SequenceStackLayout values
        headerView = TrackHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.trackY = SequenceStackLayout.defaultTrackHeight  // Use same startY as layout (20)
        headerView.trackHeight = SequenceStackLayout.defaultTrackHeight
        headerView.trackSpacing = SequenceStackLayout.trackSpacing
        headerView.delegate = self
        containerView.addSubview(headerView)

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

        // Layout
        let headerWidth: CGFloat = 100
        let rulerHeight: CGFloat = EnhancedCoordinateRulerView.recommendedHeight  // 56px with info bar, mini-map, ruler
        let statusHeight: CGFloat = 24

        NSLayoutConstraint.activate([
            // Enhanced ruler spans full width above content, using safe area to avoid toolbar overlap
            enhancedRulerView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            enhancedRulerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: headerWidth),
            enhancedRulerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            enhancedRulerView.heightAnchor.constraint(equalToConstant: rulerHeight),

            // Header on the left
            headerView.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            headerView.widthAnchor.constraint(equalToConstant: headerWidth),
            headerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Viewer fills the main area
            viewerView.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            viewerView.leadingAnchor.constraint(equalTo: headerView.trailingAnchor),
            viewerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            viewerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: statusHeight),

            // Progress overlay covers the viewer area
            progressOverlay.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            progressOverlay.leadingAnchor.constraint(equalTo: headerView.trailingAnchor),
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

        // Create initial reference frame with a reasonable default width
        // (bounds may not be set yet at this point)
        let initialWidth = max(800, Int(view.bounds.width))
        referenceFrame = ReferenceFrame(
            chromosome: "chr1",
            start: 0,
            end: 10000,
            pixelWidth: initialWidth
        )
        logger.debug("viewDidLoad: Created initial referenceFrame with width=\(initialWidth)")

        // Set up accessibility
        setupAccessibility()

        // Set up notification observers for annotation settings
        setupAnnotationNotificationObservers()

        logger.info("viewDidLoad: Setup complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        // Update reference frame width when layout completes
        if let frame = referenceFrame, viewerView.bounds.width > 0 {
            frame.pixelWidth = Int(viewerView.bounds.width)
            logger.debug("viewDidLayout: Updated referenceFrame width to \(frame.pixelWidth)")
        }
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

        // Trigger redraw
        viewerView.needsDisplay = true
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

        // Trigger redraw
        viewerView.needsDisplay = true
        logger.info("handleAnnotationFilterChanged: Triggered viewer redraw")
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

    // MARK: - Document Display

    /// Displays a loaded document in the viewer.
    public func displayDocument(_ document: LoadedDocument) {
        logger.info("displayDocument: Starting to display '\(document.name, privacy: .public)'")
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

    // MARK: - Public API

    /// Zooms in on the current view
    public func zoomIn() {
        referenceFrame?.zoomIn(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
    }

    /// Zooms out from the current view
    public func zoomOut() {
        referenceFrame?.zoomOut(factor: 2.0)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
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

                    // Add to sidebar if we have access to it
                    if let appDelegate = NSApp.delegate as? AppDelegate,
                       let sidebarController = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                        sidebarController.addLoadedDocument(document)
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
public class ProgressOverlayView: NSView {

    private var spinner: NSProgressIndicator!
    private var messageLabel: NSTextField!

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

    public func startAnimating() {
        spinner.startAnimation(nil)
    }

    public func stopAnimating() {
        spinner.stopAnimation(nil)
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

    /// Currently selected annotation (nil if no annotation selected)
    private var selectedAnnotation: SequenceAnnotation?

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

    // MARK: - Annotation Track Layout Constants

    /// Y offset where annotation track starts (below sequence track)
    private var annotationTrackY: CGFloat {
        trackY + trackHeight + 30
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
        setNeedsDisplay(bounds)
        logger.debug("SequenceViewerView.setAnnotations: Requested display refresh")
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
        if let frame = viewController?.referenceFrame {
            if shouldDrawMultiSequence, let state = multiSequenceState {
                // Multi-sequence mode: draw stacked sequences with per-sequence annotations
                logger.debug("SequenceViewerView.draw: Drawing \(state.stackedSequences.count) stacked sequences")
                drawStackedSequences(state.stackedSequences, frame: frame, context: context)
            } else if let seq = sequence {
                // Single sequence mode
                logger.debug("SequenceViewerView.draw: Drawing single sequence '\(seq.name, privacy: .public)' in bounds \(self.bounds.width)x\(self.bounds.height)")
                drawSequence(seq, frame: frame, context: context)
            } else {
                // No sequence loaded
                drawPlaceholder(context: context)
            }
        } else {
            // Placeholder message - no reference frame
            let hasSeq = sequence != nil
            let hasFrame = viewController?.referenceFrame != nil
            let hasVC = viewController != nil
            logger.debug("SequenceViewerView.draw: Drawing placeholder (sequence=\(hasSeq), frame=\(hasFrame), viewController=\(hasVC))")
            drawPlaceholder(context: context)
        }
    }

    private func drawPlaceholder(context: CGContext) {
        let message = "Sequence Viewer\n\nDrop files here or use File > Open"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
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
            guard let interval = annotation.intervals.first else { continue }

            // Check if annotation is visible
            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            // Calculate screen coordinates (must match drawAnnotations logic exactly)
            let rawStartX = CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = CGFloat(interval.end - visibleStart) * pixelsPerBase
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
            guard let interval = annotation.intervals.first else { continue }

            if interval.end < visibleStart || interval.start > visibleEnd {
                continue
            }

            let rawStartX = CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = CGFloat(interval.end - visibleStart) * pixelsPerBase
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
    private func postAnnotationSelectedNotification(_ annotation: SequenceAnnotation?) {
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
                userInfo: nil
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

        // Check for annotation click - use multi-sequence aware method if applicable
        if isMultiSequenceMode, let state = multiSequenceState {
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

                    // Show popover on double-click
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

                // Show popover on double-click
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
            name: NSNotification.Name("showInspector"),
            object: self,
            userInfo: nil
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

    /// Scroll wheel for zooming and panning
    public override func scrollWheel(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // Zoom with Cmd+scroll or Option+scroll
            if event.scrollingDeltaY > 0 {
                viewController?.zoomIn()
            } else if event.scrollingDeltaY < 0 {
                viewController?.zoomOut()
            }
        } else {
            // Pan with scroll (use bounded pan method)
            let panAmount = Double(event.scrollingDeltaX) * frame.scale * 2
            frame.pan(by: -panAmount)
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
            viewController?.updateStatusBar()
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
            userInfo: nil
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
        case .contig: return "Contig"
        case .gap: return "Gap"
        case .scaffold: return "Scaffold"
        case .region: return "Region"
        case .source: return "Source"
        case .custom: return "Custom"
        }
    }
}
