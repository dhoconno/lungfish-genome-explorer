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

/// Canonicalizes chromosome labels for loose matching (e.g. `chr1` == `1`, `NC_000001.11` == `NC_000001`).
func canonicalVariantChromosomeLookupKey(_ name: String) -> String {
    var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("chr") {
        value = String(value.dropFirst(3))
    }
    if let dot = value.firstIndex(of: ".") {
        value = String(value[..<dot])
    }
    return value
}

/// Resolves the ordered list of chromosome query candidates for a track database.
///
/// Order is:
/// 1) Requested chromosome (exact) when present in the database
/// 2) Alias-map forward/reverse matches
/// 3) Canonicalized fallback matches
/// 4) Requested chromosome as final fallback (for legacy databases with unknown chromosome sets)
func resolveVariantChromosomeCandidates(
    requestedChromosome: String,
    availableChromosomes: Set<String>,
    aliasMap: [String: String]
) -> [String] {
    if availableChromosomes.isEmpty {
        return [requestedChromosome]
    }

    var ordered: [String] = []
    if availableChromosomes.contains(requestedChromosome) {
        ordered.append(requestedChromosome)
    }

    if let aliased = aliasMap[requestedChromosome], availableChromosomes.contains(aliased) {
        ordered.append(aliased)
    }

    for (refName, vcfName) in aliasMap where vcfName == requestedChromosome {
        if availableChromosomes.contains(refName) {
            ordered.append(refName)
        }
    }

    let canonical = canonicalVariantChromosomeLookupKey(requestedChromosome)
    for candidate in availableChromosomes {
        if canonicalVariantChromosomeLookupKey(candidate) == canonical {
            ordered.append(candidate)
        }
    }

    if ordered.isEmpty {
        ordered.append(requestedChromosome)
    }

    // Deduplicate while preserving priority order (Swift-native, avoids NSObject bridging).
    var seen = Set<String>()
    return ordered.filter { seen.insert($0).inserted }
}

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

    /// Gene tab bar for multi-gene navigation (hidden when not in gene list mode)
    var geneTabBarView: GeneTabBarView!

    /// Leading constraints for ruler, viewer, and overlay — animated by chromosome drawer
    var contentLeadingConstraints: [NSLayoutConstraint] = []
    
    /// QuickLook preview view for non-genomics files (images, text, etc.)
    private var quickLookView: QLPreviewView?
    
    /// PDF view for displaying PDF files (more reliable than QLPreviewView)
    private var pdfView: PDFView?
    
    /// URL currently being previewed with QuickLook or PDFKit
    private var quickLookURL: URL?

    /// FASTQ dataset dashboard (shown in place of sequence viewer for FASTQ files)
    var fastqDatasetController: FASTQDatasetViewController?

    /// VCF dataset dashboard (shown in place of sequence viewer for standalone VCF files)
    private var vcfDatasetController: VCFDatasetViewController?

    // MARK: - State

    /// Current reference frame for coordinate mapping
    public var referenceFrame: ReferenceFrame?

    /// Currently displayed document
    public private(set) var currentDocument: LoadedDocument?

    /// Track height constant
    private let sequenceTrackY: CGFloat = 20
    private let sequenceTrackHeight: CGFloat = AppSettings.shared.sequenceAppearance.trackHeight

    // MARK: - Annotation Display Settings

    /// Whether to show annotations in the viewer
    var showAnnotations: Bool = true

    /// Height of each annotation box in pixels
    var annotationDisplayHeight: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationHeight)

    /// Vertical spacing between annotation rows
    var annotationDisplaySpacing: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationSpacing)

    /// Set of annotation types to display (nil means show all)
    var visibleAnnotationTypes: Set<AnnotationType>?

    /// Text filter for annotations (empty string means no filter)
    var annotationFilterText: String = ""

    /// Last app-level theme applied as a default to sample rendering.
    private var lastAppliedAppVariantThemeName: String = AppSettings.shared.variantColorThemeName

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

        // Create enhanced ruler view with mini-map and navigation
        enhancedRulerView = EnhancedCoordinateRulerView()
        enhancedRulerView.translatesAutoresizingMaskIntoConstraints = false
        enhancedRulerView.delegate = self
        containerView.addSubview(enhancedRulerView)

        // Header view no longer displayed — left margin removed for cleaner layout
        headerView = TrackHeaderView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.isHidden = true

        // Create gene tab bar (initially hidden with 0 height)
        geneTabBarView = GeneTabBarView()
        geneTabBarView.translatesAutoresizingMaskIntoConstraints = false
        geneTabBarView.delegate = self
        containerView.addSubview(geneTabBarView)

        // Create main viewer view
        viewerView = SequenceViewerView()
        viewerView.translatesAutoresizingMaskIntoConstraints = false
        viewerView.viewController = self
        viewerView.trackY = sequenceTrackY
        viewerView.trackHeight = sequenceTrackHeight
        viewerView.layer?.masksToBounds = true
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
        let geneTabLeading = geneTabBarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
        let viewerLeading = viewerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
        let overlayLeading = progressOverlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)

        contentLeadingConstraints = [rulerLeading, geneTabLeading, viewerLeading, overlayLeading]

        NSLayoutConstraint.activate([
            // Enhanced ruler spans full width above content, using safe area to avoid toolbar overlap
            enhancedRulerView.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor),
            rulerLeading,
            enhancedRulerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            enhancedRulerView.heightAnchor.constraint(equalToConstant: rulerHeight),

            // Gene tab bar sits between ruler and viewer (0 height when hidden)
            geneTabBarView.topAnchor.constraint(equalTo: enhancedRulerView.bottomAnchor),
            geneTabLeading,
            geneTabBarView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            // Viewer fills the main area (full width)
            viewerView.topAnchor.constraint(equalTo: geneTabBarView.bottomAnchor),
            viewerLeading,
            viewerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            viewerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at the bottom
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: statusHeight),

            // Progress overlay covers the viewer area
            progressOverlay.topAnchor.constraint(equalTo: geneTabBarView.bottomAnchor),
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

        lastAppliedAppVariantThemeName = AppSettings.shared.variantColorThemeName
        if viewerView.sampleDisplayState.colorThemeName != lastAppliedAppVariantThemeName {
            var seededState = viewerView.sampleDisplayState
            seededState.colorThemeName = lastAppliedAppVariantThemeName
            viewerView.sampleDisplayState = seededState
        }

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
    private var deferredRedrawWorkItem: DispatchWorkItem?
    /// Debounced drawer height save to avoid 60+ UserDefaults writes/sec during drag.
    var _drawerHeightSaveWorkItem: DispatchWorkItem?

    public override func viewDidLayout() {
        super.viewDidLayout()

        // wantsLayer and masksToBounds are set once in loadView(); no need to repeat here.

        // Update reference frame width immediately (needed for correct rendering)
        if let frame = referenceFrame, viewerView.bounds.width > 0 {
            frame.pixelWidth = Int(viewerView.bounds.width)
            frame.leadingInset = viewerView.variantDataStartX
            frame.trailingInset = ReferenceFrame.defaultTrailingInset
            logger.debug("viewDidLayout: Updated referenceFrame width to \(frame.pixelWidth) inset=\(frame.leadingInset)")
        }

        // Coalesce rapid layout changes: schedule a deferred redraw that fires
        // 100ms after the last viewDidLayout call. This ensures that after
        // animation settles, any pending fetch callbacks that executed during
        // the animation will have their data rendered.
        layoutSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                logger.debug("viewDidLayout: Layout settled, triggering deferred redraw")
                self.viewerView.setNeedsDisplay(self.viewerView.bounds)
                self.enhancedRulerView.needsDisplay = true
            }
        }
        layoutSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    /// Schedules a cancellable deferred redraw after 0.1s to handle layout timing issues.
    /// Cancels any previously scheduled deferred redraw to avoid stale renders.
    /// Optionally syncs the header with stacked sequences.
    private func scheduleDeferredRedraw(syncStackedSequences: Bool = false) {
        deferredRedrawWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let frame = self.referenceFrame, self.viewerView.bounds.width > 0 {
                    frame.pixelWidth = Int(self.viewerView.bounds.width)
                    frame.leadingInset = self.viewerView.variantDataStartX
                    frame.trailingInset = ReferenceFrame.defaultTrailingInset
                }
                if syncStackedSequences,
                   let stackedSeqs = self.viewerView.multiSequenceState?.stackedSequences,
                   !stackedSeqs.isEmpty {
                    self.headerView.setStackedSequences(stackedSeqs)
                }
                self.viewerView.needsDisplay = true
                self.enhancedRulerView.needsDisplay = true
                self.headerView.needsDisplay = true
            }
        }
        deferredRedrawWorkItem = item
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

        // Observer for sample display state changes from inspector
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSampleDisplayStateChanged(_:)),
            name: .sampleDisplayStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleViewStateResetRequested(_:)),
            name: .bundleViewStateResetRequested,
            object: nil
        )
        logger.debug("ViewerViewController: Registered bundleViewStateResetRequested observer")

        // Observer for variant track deletion
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleVariantTracksDeleted(_:)),
            name: .bundleVariantTracksDeleted,
            object: nil
        )

        // Observer for read display settings from inspector
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReadDisplaySettingsChanged(_:)),
            name: .readDisplaySettingsChanged,
            object: nil
        )

        // Observer for extraction requests from inspector
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExtractSequenceRequested(_:)),
            name: .extractSequenceRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCopyAnnotationAsFASTARequested(_:)),
            name: .copyAnnotationAsFASTARequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCopyTranslationAsFASTARequested(_:)),
            name: .copyTranslationAsFASTARequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleZoomToAnnotationRequested(_:)),
            name: .zoomToAnnotationRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCopyAnnotationSequenceRequested(_:)),
            name: .copyAnnotationSequenceRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCopyAnnotationReverseComplementRequested(_:)),
            name: .copyAnnotationReverseComplementRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged(_:)),
            name: .appSettingsChanged,
            object: nil
        )
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

    @objc private func handleExtractSequenceRequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.presentExtractionSheet(for: .annotation(annotation))
    }

    @objc private func handleCopyAnnotationAsFASTARequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.copyAnnotationAsFASTAImpl(annotation)
    }

    @objc private func handleCopyTranslationAsFASTARequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.copyAnnotationTranslationAsFASTAImpl(annotation)
    }

    @objc private func handleZoomToAnnotationRequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.zoomToAnnotation(annotation)
    }

    @objc private func handleCopyAnnotationSequenceRequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.copyAnnotationSequenceImpl(annotation)
    }

    @objc private func handleCopyAnnotationReverseComplementRequested(_ notification: Notification) {
        guard let annotation = notification.userInfo?["annotation"] as? SequenceAnnotation else { return }
        viewerView?.copyAnnotationReverseComplementImpl(annotation)
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

        viewerView.invalidateFilteredVariantCache()
        viewerView.invalidateAnnotationTile()
        viewerView.needsDisplay = true
        scheduleViewStateSave()
        logger.info("handleVariantFilterChanged: Triggered viewer redraw")
    }

    /// Handles sample display state changes from the inspector.
    @objc private func handleSampleDisplayStateChanged(_ notification: Notification) {
        guard let state = notification.userInfo?[NotificationUserInfoKey.sampleDisplayState] as? SampleDisplayState else {
            return
        }

        logger.info("handleSampleDisplayStateChanged: showRows=\(state.showGenotypeRows) rowHeight=\(state.rowHeight)")
        viewerView.sampleDisplayState = state
        viewerView.clearGenotypeCache()
        viewerView.invalidateAnnotationTile()
        viewerView.needsDisplay = true
        scheduleViewStateSave()
    }

    /// Handles app-level settings changes and updates default-driven viewer state.
    @objc private func handleAppSettingsChanged(_ notification: Notification) {
        let settings = AppSettings.shared

        // Only apply annotation dimension defaults when no per-bundle view-state override is active.
        if currentBundleViewState == nil {
            annotationDisplayHeight = CGFloat(settings.defaultAnnotationHeight)
            annotationDisplaySpacing = CGFloat(settings.defaultAnnotationSpacing)
            viewerView.annotationHeight = annotationDisplayHeight
            viewerView.annotationRowSpacing = annotationDisplaySpacing
            viewerView.invalidateAnnotationTile()
        }

        // App-level theme acts as default unless a per-sample override diverged from that default.
        if viewerView.sampleDisplayState.colorThemeName == lastAppliedAppVariantThemeName {
            var updatedState = viewerView.sampleDisplayState
            updatedState.colorThemeName = settings.variantColorThemeName
            viewerView.sampleDisplayState = updatedState
            annotationDrawerView?.setSampleDisplayState(updatedState)
            viewerView.needsDisplay = true
        }

        lastAppliedAppVariantThemeName = settings.variantColorThemeName
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

        let settings = AppSettings.shared

        // Reset in-memory state using current app defaults for annotation dimensions.
        currentBundleViewState = BundleViewState(
            typeColorOverrides: [:],
            annotationColorOverrides: [:],
            annotationHeight: settings.defaultAnnotationHeight,
            annotationSpacing: settings.defaultAnnotationSpacing,
            showAnnotations: true,
            visibleAnnotationTypes: nil,
            showVariants: true,
            visibleVariantTypes: nil,
            translationColorScheme: .zappo,
            isRNAMode: false,
            lastChromosome: nil,
            lastOrigin: nil,
            lastScale: nil
        )

        // Delete persisted file
        if let url = currentBundleURL {
            BundleViewState.delete(from: url)
            logger.info("handleBundleViewStateResetRequested: Deleted .viewstate.json from bundle")
        }

        // Reset annotation display settings to defaults
        showAnnotations = true
        annotationDisplayHeight = CGFloat(settings.defaultAnnotationHeight)
        annotationDisplaySpacing = CGFloat(settings.defaultAnnotationSpacing)
        visibleAnnotationTypes = nil
        isRNAMode = false
        viewerView.translationColorScheme = .zappo
        viewerView.showVariants = true
        viewerView.visibleVariantTypes = nil
        viewerView.annotationHeight = annotationDisplayHeight
        viewerView.annotationRowSpacing = annotationDisplaySpacing
        viewerView.invalidateFilteredVariantCache()
    }

    @objc private func handleBundleVariantTracksDeleted(_ notification: Notification) {
        guard let deletedURL = notification.userInfo?[NotificationUserInfoKey.bundleURL] as? URL else { return }
        guard let myURL = currentBundleURL,
              myURL.standardizedFileURL == deletedURL.standardizedFileURL else { return }

        logger.info("handleBundleVariantTracksDeleted: Clearing variant data for current bundle")

        // Clear variant display state
        viewerView.showVariants = false
        viewerView.visibleVariantTypes = nil
        viewerView.invalidateFilteredVariantCache()

        // Clear variant databases from search index
        annotationSearchIndex?.clearVariantDatabases()

        // Refresh the drawer to remove variant data
        if let index = annotationSearchIndex {
            annotationDrawerView?.setSearchIndex(index)
        }

        viewerView.needsDisplay = true
    }

    @objc private func handleReadDisplaySettingsChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        if let showReads = userInfo[NotificationUserInfoKey.showReads] as? Bool {
            viewerView.showReads = showReads
        }
        if let maxRows = userInfo[NotificationUserInfoKey.maxReadRows] as? Int {
            viewerView.maxReadRowsSetting = maxRows
        }
        if let limitRows = userInfo[NotificationUserInfoKey.limitReadRows] as? Bool {
            viewerView.limitReadRowsSetting = limitRows
        }
        if let compressed = userInfo[NotificationUserInfoKey.verticalCompressContig] as? Bool {
            viewerView.verticallyCompressContigSetting = compressed
        }
        if let minQ = userInfo[NotificationUserInfoKey.minMapQ] as? Int {
            viewerView.minMapQSetting = minQ
        }
        if let show = userInfo[NotificationUserInfoKey.showMismatches] as? Bool {
            viewerView.showMismatchesSetting = show
        }
        if let show = userInfo[NotificationUserInfoKey.showSoftClips] as? Bool {
            viewerView.showSoftClipsSetting = show
        }
        if let show = userInfo[NotificationUserInfoKey.showIndels] as? Bool {
            viewerView.showIndelsSetting = show
        }
        if let show = userInfo[NotificationUserInfoKey.showStrandColors] as? Bool {
            viewerView.showStrandColorsSetting = show
        }
        if let enabled = userInfo[NotificationUserInfoKey.consensusMaskingEnabled] as? Bool {
            viewerView.consensusMaskingEnabledSetting = enabled
        }
        if let threshold = userInfo[NotificationUserInfoKey.consensusGapThresholdPercent] as? Int {
            viewerView.consensusGapThresholdPercentSetting = max(50, min(99, threshold))
        }
        if let minDepth = userInfo[NotificationUserInfoKey.consensusMinDepth] as? Int {
            viewerView.consensusMinDepthSetting = max(1, min(500, minDepth))
        }
        if let minMapQ = userInfo[NotificationUserInfoKey.consensusMinMapQ] as? Int {
            viewerView.consensusMinMapQSetting = max(0, min(60, minMapQ))
        }
        if let minBaseQ = userInfo[NotificationUserInfoKey.consensusMinBaseQ] as? Int {
            viewerView.consensusMinBaseQSetting = max(0, min(60, minBaseQ))
        }
        if let showConsensus = userInfo[NotificationUserInfoKey.showConsensusTrack] as? Bool {
            viewerView.showConsensusTrackSetting = showConsensus
        }
        if let modeRaw = userInfo[NotificationUserInfoKey.consensusMode] as? String,
           let mode = AlignmentConsensusMode(rawValue: modeRaw.lowercased()) {
            viewerView.consensusModeSetting = mode
        }
        if let useAmbiguity = userInfo[NotificationUserInfoKey.consensusUseAmbiguity] as? Bool {
            viewerView.consensusUseAmbiguitySetting = useAmbiguity
        }
        if let flags = userInfo[NotificationUserInfoKey.excludeFlags] as? UInt16 {
            viewerView.excludeFlagsSetting = flags
        }
        if let rgs = userInfo[NotificationUserInfoKey.selectedReadGroups] as? Set<String> {
            viewerView.selectedReadGroupsSetting = rgs
        }

        // Force read refetch if fetch-time filters changed
        if userInfo[NotificationUserInfoKey.minMapQ] != nil
            || userInfo[NotificationUserInfoKey.consensusMinMapQ] != nil
            || userInfo[NotificationUserInfoKey.consensusMinBaseQ] != nil
            || userInfo[NotificationUserInfoKey.consensusMinDepth] != nil
            || userInfo[NotificationUserInfoKey.showConsensusTrack] != nil
            || userInfo[NotificationUserInfoKey.consensusMode] != nil
            || userInfo[NotificationUserInfoKey.consensusUseAmbiguity] != nil
            || userInfo[NotificationUserInfoKey.excludeFlags] != nil
            || userInfo[NotificationUserInfoKey.selectedReadGroups] != nil {
            viewerView.cachedReadRegion = nil
            viewerView.cachedDepthRegion = nil
            viewerView.cachedConsensusRegion = nil
        }

        viewerView.needsDisplay = true
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

    public var isDisplayingFASTQDataset: Bool {
        fastqDatasetController != nil
    }

    public func updateFASTQOperationStatus(_ message: String) {
        fastqDatasetController?.updateOperationStatus(message)
    }

    // MARK: - FASTQ Dataset Display

    /// Displays the FASTQ dataset dashboard in place of the normal sequence viewer.
    ///
    /// Hides the ruler, viewer, and header; adds the FASTQDatasetViewController
    /// as a child view controller filling the content area.
    public func displayFASTQDataset(
        statistics: FASTQDatasetStatistics,
        records: [FASTQRecord],
        fastqURL: URL? = nil,
        sraRunInfo: SRARunInfo? = nil,
        enaReadRecord: ENAReadRecord? = nil,
        ingestionMetadata: IngestionMetadata? = nil,
        fastqSourceURL: URL? = nil,
        fastqDerivativeManifest: FASTQDerivedBundleManifest? = nil,
        onRunOperation: ((FASTQDerivativeRequest) async throws -> Void)? = nil
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()

        let controller = FASTQDatasetViewController()
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        let dashBottomConstraint = dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashBottomConstraint,
        ])

        controller.configure(
            statistics: statistics,
            records: records,
            fastqURL: fastqURL,
            sourceURL: fastqSourceURL,
            derivativeManifest: fastqDerivativeManifest
        )
        controller.onRunOperation = onRunOperation
        controller.onOpenDemuxDrawer = { [weak self] in
            self?.openDemuxSetupDrawer()
        }
        controller.onOpenPrimerTrimDrawer = { [weak self] in
            self?.openPrimerTrimDrawer()
        }
        controller.onStatisticsUpdated = { [weak self] updatedStats in
            guard let self else { return }
            var updatedUserInfo: [String: Any] = ["statistics": updatedStats]
            if let sra = sraRunInfo { updatedUserInfo["sraRunInfo"] = sra }
            if let ena = enaReadRecord { updatedUserInfo["enaReadRecord"] = ena }
            if let ingestion = ingestionMetadata { updatedUserInfo["ingestionMetadata"] = ingestion }
            if let source = fastqSourceURL { updatedUserInfo["fastqSourceURL"] = source }
            if let derivative = fastqDerivativeManifest { updatedUserInfo["fastqDerivativeManifest"] = derivative }
            NotificationCenter.default.post(
                name: .fastqDatasetLoaded,
                object: self,
                userInfo: updatedUserInfo
            )
        }
        fastqDatasetController = controller
        fastqDashboardView = dashView
        fastqDashboardBottomConstraint = dashBottomConstraint
        // Sync any existing drawer demux config into the new controller
        syncDemuxConfigToController()
        currentFASTQDatasetURL = fastqURL

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        // Post notification for inspector (includes metadata if available)
        var userInfo: [String: Any] = ["statistics": statistics]
        if let sra = sraRunInfo { userInfo["sraRunInfo"] = sra }
        if let ena = enaReadRecord { userInfo["enaReadRecord"] = ena }
        if let ingestion = ingestionMetadata { userInfo["ingestionMetadata"] = ingestion }
        if let source = fastqSourceURL { userInfo["fastqSourceURL"] = source }
        if let derivative = fastqDerivativeManifest { userInfo["fastqDerivativeManifest"] = derivative }
        NotificationCenter.default.post(
            name: .fastqDatasetLoaded,
            object: self,
            userInfo: userInfo
        )

        if fastqMetadataDrawerView != nil {
            refreshFASTQMetadataDrawerContent()
        }

        logger.info("displayFASTQDataset: Showing dashboard with \(statistics.readCount) reads")
    }

    /// Removes the FASTQ dataset dashboard and restores normal viewer components.
    public func hideFASTQDatasetView() {
        guard let controller = fastqDatasetController else { return }
        teardownFASTQMetadataDrawer()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        fastqDatasetController = nil
        fastqDashboardView = nil
        fastqDashboardBottomConstraint = nil
        currentFASTQDatasetURL = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }

    /// Displays a standalone VCF dataset dashboard in place of the sequence viewer.
    public func displayVCFDataset(
        summary: LungfishIO.VCFSummary,
        variants: [LungfishIO.VCFVariant],
        onDownloadReference: ((ReferenceInference.Result) -> Void)? = nil
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()

        let controller = VCFDatasetViewController()
        controller.onDownloadReferenceRequested = onDownloadReference
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(summary: summary, variants: variants)
        vcfDatasetController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        // Post notification
        NotificationCenter.default.post(
            name: .vcfDatasetLoaded,
            object: self,
            userInfo: ["summary": summary]
        )

        logger.info("displayVCFDataset: Showing dashboard with \(summary.variantCount) variants")
    }

    /// Removes the VCF dataset dashboard and restores normal viewer components.
    public func hideVCFDatasetView() {
        guard let controller = vcfDatasetController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        vcfDatasetController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }

    /// Invalidates the offscreen annotation tile so it will be re-rendered
    /// at the correct size on the next draw cycle.
    public func invalidateAnnotationTile() {
        viewerView?.invalidateAnnotationTile()
    }

    /// Forces a complete redraw after a window frame change
    /// (e.g., entering or exiting full-screen mode).
    ///
    /// Does NOT set `view.needsLayout` — AppKit already triggers layout during
    /// full-screen transitions, and an extra layout pass would cause redundant
    /// viewDidLayout → deferred-redraw cycles.
    public func forceFullRedraw() {
        guard let viewerView else { return }

        // Update reference frame to match the new view size
        if let frame = referenceFrame, viewerView.bounds.width > 0 {
            frame.pixelWidth = Int(viewerView.bounds.width)
            frame.leadingInset = viewerView.variantDataStartX
            frame.trailingInset = ReferenceFrame.defaultTrailingInset
        }

        // Invalidate the pre-rendered tile — its dimensions are stale
        viewerView.invalidateAnnotationTile()

        // Mark all subviews as needing display
        viewerView.needsDisplay = true
        enhancedRulerView?.needsDisplay = true
        statusBar?.needsDisplay = true
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
        
        // Hide any non-document views when showing a genomics document
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
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

        scheduleDeferredRedraw()

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

        // Hide any dataset-specific views that may be covering the viewer
        hideFASTQDatasetView()
        hideVCFDatasetView()

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

        scheduleDeferredRedraw(syncStackedSequences: true)

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

        // Get the first chromosome to display (from genome or synthesized from variants)
        var chromosomes = bundle.manifest.genome?.chromosomes ?? []
        if chromosomes.isEmpty && !bundle.manifest.variants.isEmpty {
            chromosomes = Self.synthesizeChromosomesFromVariants(bundle: bundle)
        }
        guard let firstChrom = chromosomes.first else {
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

        scheduleDeferredRedraw()

        logger.info("displayReferenceBundle: Completed displaying bundle")
    }
    
    /// The currently displayed reference bundle, if any.
    public private(set) var currentReferenceBundle: LungfishIO.ReferenceBundle?

    // MARK: - Public API

    /// Zooms in on the current view
    public func zoomIn() {
        guard let frame = referenceFrame else { return }
        let center = (frame.start + frame.end) / 2.0
        let halfWidth = (frame.end - frame.start) / (2 * 2.0)
        frame.start = max(0, center - halfWidth)
        frame.end = min(Double(frame.sequenceLength), center + halfWidth)
        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
        scheduleViewStateSave()
    }

    /// Zooms out from the current view
    public func zoomOut() {
        guard let frame = referenceFrame else { return }
        let center = (frame.start + frame.end) / 2.0
        let halfWidth = (frame.end - frame.start) * 2.0 / 2
        var newStart = center - halfWidth
        var newEnd = center + halfWidth
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), newStart + halfWidth * 2)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - halfWidth * 2)
        }
        frame.start = newStart
        frame.end = newEnd
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
        let selectionInfo: String?
        if viewerView.isUserColumnSelection, let range = viewerView.selectionRange {
            let length = range.upperBound - range.lowerBound
            selectionInfo = "Selected: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)"
        } else {
            selectionInfo = viewerView.selectionRange.map { range in
                let length = range.upperBound - range.lowerBound
                return "Visible: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)"
            }
        }
        statusBar.update(
            position: "\(frame.chromosome):\(Int(frame.start))-\(Int(frame.end))",
            selection: selectionInfo,
            scale: frame.scale
        )

        // Notify toolbar / other observers about coordinate changes
        NotificationCenter.default.post(
            name: .viewerCoordinatesChanged,
            object: viewerView,
            userInfo: [
                NotificationUserInfoKey.chromosome: frame.chromosome,
                NotificationUserInfoKey.variantChromosome: viewerView.variantDatabaseChromosomeName(for: frame.chromosome),
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

        guard !urls.isEmpty else {
            logger.warning("handleFileDrop: No URLs to process")
            return
        }

        let vcfURLs = urls.filter { isVCFFile($0) }
        let otherURLs = urls.filter { !isVCFFile($0) }

        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let mainSplit = appDelegate.mainWindowController?.mainSplitViewController else {
            logger.error("handleFileDrop: Unable to resolve MainSplitViewController")
            return
        }

        if !vcfURLs.isEmpty {
            logger.info("handleFileDrop: Routing \(vcfURLs.count) VCF file(s) to auto-ingest pipeline")
            mainSplit.loadVCFFilesInBackground(urls: vcfURLs)
        }

        for url in otherURLs {
            logger.info("handleFileDrop: Routing '\(url.lastPathComponent, privacy: .public)' through sidebar import pipeline")
            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: self,
                userInfo: ["url": url, "destination": NSNull()]
            )
        }
    }

    private func isVCFFile(_ url: URL) -> Bool {
        MainSplitViewController.isVCFFile(url)
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

    // MARK: - Read Alignment State

    /// Cached aligned reads for the current visible region
    private var cachedAlignedReads: [AlignedRead] = []

    /// The region for which we have cached read data
    var cachedReadRegion: GenomicRegion?

    /// Cached sparse depth points for the current visible region (coverage tier).
    private var cachedDepthPoints: [ReadTrackRenderer.CoveragePoint] = []

    /// The region for which we have cached depth data.
    var cachedDepthRegion: GenomicRegion?

    /// Cached consensus sequence for the current region.
    private var cachedConsensusSequence: String?

    /// The region for which we have cached consensus sequence.
    var cachedConsensusRegion: GenomicRegion?

    /// Option signature used to compute `cachedConsensusSequence`.
    private var cachedConsensusOptionsSignature: String = ""

    /// Whether we're currently fetching read data
    private var isFetchingReads: Bool = false {
        didSet { updateTrackLoadingAnimationState() }
    }

    /// Timestamp when the current read fetch started.
    private var readFetchStartTime: Date?

    /// Whether we're currently fetching depth data.
    private var isFetchingDepth: Bool = false {
        didSet { updateTrackLoadingAnimationState() }
    }

    /// Timestamp when the current depth fetch started.
    private var depthFetchStartTime: Date?

    /// Timer driving the in-track loading badge spinner.
    private nonisolated(unsafe) var trackLoadingAnimationTimer: Timer?

    /// Current spinner phase in radians.
    private var trackLoadingAnimationPhase: CGFloat = 0

    /// Whether we're currently fetching consensus sequence data.
    private var isFetchingConsensus: Bool = false

    /// Generation counter for read fetches — prevents stale results from overwriting newer ones
    private var readFetchGeneration: Int = 0

    /// Generation counter for depth fetches — prevents stale results from overwriting newer ones.
    private var depthFetchGeneration: Int = 0

    /// Generation counter for consensus fetches — prevents stale results from overwriting newer ones.
    private var consensusFetchGeneration: Int = 0

    /// Coverage stats from the currently cached depth points.
    private var cachedCoverageStats: ReadTrackRenderer.CoverageStats?

    /// Whether to show the read alignment track
    var showReads: Bool = true

    /// Maximum read rows (configurable from Inspector)
    var maxReadRowsSetting: Int = 75

    /// Whether read row count is capped by `maxReadRowsSetting`.
    var limitReadRowsSetting: Bool = false

    /// Whether read rows use compact vertical heights.
    var verticallyCompressContigSetting: Bool = true

    /// Minimum MAPQ filter (configurable from Inspector)
    var minMapQSetting: Int = 0

    /// Whether to show mismatches (configurable from Inspector)
    var showMismatchesSetting: Bool = true

    /// Whether to show soft clips (configurable from Inspector)
    var showSoftClipsSetting: Bool = true

    /// Whether to show insertions/deletions (configurable from Inspector)
    var showIndelsSetting: Bool = true

    /// Whether to tint read backgrounds by strand direction.
    var showStrandColorsSetting: Bool = true

    /// Whether to mask columns that are mostly gaps (consensus-style filtering).
    var consensusMaskingEnabledSetting: Bool = false

    /// Gap masking threshold in percent (e.g., 90 = hide columns with >=90% gaps).
    var consensusGapThresholdPercentSetting: Int = 90

    /// Minimum spanning depth required before gap masking is applied.
    var consensusMinDepthSetting: Int = 8

    /// Minimum mapping quality used for consensus/depth calculations.
    var consensusMinMapQSetting: Int = 0

    /// Minimum base quality used for consensus/depth calculations.
    var consensusMinBaseQSetting: Int = 0

    /// Whether the consensus row is shown under depth.
    var showConsensusTrackSetting: Bool = true

    /// Consensus caller mode.
    var consensusModeSetting: AlignmentConsensusMode = .bayesian

    /// Whether to emit IUPAC ambiguity codes in consensus output.
    var consensusUseAmbiguitySetting: Bool = false

    /// Exclude flags bitmask for samtools view (configurable from Inspector)
    /// Default: unmapped(0x4) + secondary(0x100) + dup(0x400) + supplementary(0x800) = 0xD04
    var excludeFlagsSetting: UInt16 = 0xD04

    /// Selected read group IDs to display (empty = show all)
    var selectedReadGroupsSetting: Set<String> = []

    /// Alignment data providers for each imported alignment track
    private var alignmentDataProviders: [(trackId: String, provider: AlignmentDataProvider)] = []

    /// Currently hovered read (for tooltip caching)
    private var hoveredRead: AlignedRead?

    /// Set of read UUIDs currently selected (for multi-read selection).
    var selectedReadIDs: Set<UUID> = []

    /// Currently selected read (for inspector display — first selected read).
    var selectedRead: AlignedRead? {
        guard let firstID = selectedReadIDs.first else { return nil }
        return cachedPackedReads.first(where: { $0.read.id == firstID })?.read
    }

    /// Cached packed reads for hit-testing (updated during draw)
    private var cachedPackedReads: [(row: Int, read: AlignedRead)] = []

    /// Cached packed layout overflow count (from last pack operation)
    private var cachedPackOverflow: Int = 0

    /// Scale at which the pack layout was computed (recompute if scale changes)
    private var cachedPackScale: Double = 0

    /// Read data generation when pack layout was computed (recompute if data changes)
    private var cachedPackDataGeneration: Int = -1

    /// Max rows setting when pack layout was computed
    private var cachedPackMaxRows: Int = 0

    /// Viewport region when pack layout was computed (repack when panned significantly)
    private var cachedPackViewportStart: Int = 0
    private var cachedPackViewportEnd: Int = 0

    /// The Y offset at which reads were last rendered (for hit-testing)
    private var lastRenderedReadY: CGFloat = 0

    /// The Y offset at which coverage was last rendered (for hover).
    private var lastRenderedCoverageY: CGFloat = 0

    /// The zoom tier at which reads were last rendered
    private var lastRenderedReadTier: ReadTrackRenderer.ZoomTier = .coverage

    /// Vertical scroll offset for the read track (when rows exceed available space)
    var readScrollOffset: CGFloat = 0

    /// Maximum height allocated for the read track before requiring scrolling
    private let maxReadTrackHeight: CGFloat = 300

    /// Total content height of the packed reads (set during draw)
    private var readContentHeight: CGFloat = 0

    /// Coverage strip height rendered for alignments.
    private let coverageStripHeight: CGFloat = ReadTrackRenderer.coverageTrackHeight

    /// Consensus strip height rendered below coverage.
    /// Must match the sequence track height so reference/consensus cells are visually identical.
    private var consensusStripHeight: CGFloat { trackHeight }

    /// Spacing between coverage and consensus rows.
    private let coverageToConsensusGap: CGFloat = 2

    /// Spacing between consensus row and read rows.
    private let consensusToReadGap: CGFloat = 4

    /// Whether drag is active (for highlighting)
    private var isDragActive = false

    /// Current appearance settings for sequence visualization
    private var sequenceAppearance: SequenceAppearance = AppSettings.shared.sequenceAppearance

    // MARK: - Selection State

    /// Current selection range in base coordinates (nil if no selection)
    public private(set) var selectionRange: Range<Int>?

    /// Mouse drag start position for selection
    private var selectionStartBase: Int?

    /// Whether we're currently dragging to select.
    private var isSelecting = false

    /// Last logged selection render signature (used to suppress per-frame log spam).
    private var lastSelectionRenderSignature: String?

    /// Whether the current selectionRange was set by user click/drag.
    /// When true, ensureVisibleViewportSelection() will not overwrite it.
    var isUserColumnSelection = false

    /// Genomic position where the user started a column-selection drag.
    private var columnDragStartBase: Int?

    /// Currently selected annotation (nil if no annotation selected).
    /// Internal so the AnnotationDrawer extension can set it from table selection.
    var selectedAnnotation: SequenceAnnotation?

    /// Genomic position under the latest context-menu click.
    private var contextMenuGenomicPosition: Int?

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

    /// Cached per-annotation CDS translations for auto-CDS display in expanded mode.
    /// Keyed by annotation UUID. Invalidated on chromosome/sequence change.
    var cachedCDSTranslations: [UUID: TranslationResult] = [:]

    /// Cached CDS coding contexts used for codon-level consequence fallback in hover text.
    /// Keyed by annotation UUID. Invalidated on chromosome/sequence change.
    private var cachedCDSCodingContexts: [UUID: CDSCodingContext] = [:]

    /// Color scheme for amino acid rendering.
    var translationColorScheme: AminoAcidColorScheme = .zappo

    /// Reading frames to display in frame-translation mode (empty = CDS mode).
    var frameTranslationFrames: [ReadingFrame] = []

    /// Codon table for frame translations.
    var frameTranslationTable: CodonTable = .standard

    /// Whether to render stop codon cells in translation tracks.
    var translationShowStopCodons: Bool = true

    /// Precomputed CDS coordinate/codon mapping for local consequence prediction.
    private struct CDSCodingContext {
        let annotation: SequenceAnnotation
        let codingBases: [Character]
        let codingGenomePositions: [Int]
        let phaseOffset: Int
        let codonTable: CodonTable
    }

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

    /// Y position where the variant track starts (below annotations).
    /// Updated after annotation rendering to reflect actual annotation height.
    private var lastAnnotationBottomY: CGFloat = 0

    /// Extra spacing to prevent annotation labels from colliding with variant labels/rows.
    private let annotationToVariantPadding: CGFloat = 10
    /// Reserve text descender space below annotation rows (overflow/hint labels).
    private let annotationLabelClearance: CGFloat = 14

    /// Y offset where variant summary bar starts (below annotations).
    private var variantTrackY: CGFloat {
        max(lastAnnotationBottomY + annotationToVariantPadding, annotationTrackY + annotationToVariantPadding)
    }

    /// Y position where the variant track ends (updated during variant rendering).
    private var lastVariantBottomY: CGFloat = 0

    /// Spacing between variant and read tracks.
    private let variantToReadPadding: CGFloat = 10

    /// Y offset where the read alignment track starts (below variants).
    private var readTrackY: CGFloat {
        if showVariants && !filteredVisibleVariantAnnotations.isEmpty {
            return max(lastVariantBottomY + variantToReadPadding, variantTrackY + variantToReadPadding)
        }
        // No variants visible → reads go where variants would
        return variantTrackY
    }

    /// Cached filtered variant annotations. Invalidated by `invalidateFilteredVariantCache()`.
    private var _cachedFilteredVariants: [SequenceAnnotation]?
    /// Viewport signature used to validate `_cachedFilteredVariants`.
    private var filteredVariantCacheViewportSignature: (chromosome: String, start: Int, end: Int)?

    /// Optional row-level variant render filter from the drawer (`trackId:variantRowId`).
    /// `nil` means render all variants that pass inspector filters.
    private var localVariantRenderFilterKeys: Set<String>?
    /// Cached genotype dataset after applying table-synced row filtering.
    private var _cachedFilteredGenotypeData: GenotypeDisplayData?

    /// Variant annotations after applying current type/text filters.
    /// Caches the result to avoid re-filtering on every access during a draw cycle.
    private var filteredVisibleVariantAnnotations: [SequenceAnnotation] {
        let currentViewportSignature: (chromosome: String, start: Int, end: Int)?
        if let frame = viewController?.referenceFrame {
            currentViewportSignature = (
                chromosome: frame.chromosome,
                start: Int(frame.start),
                end: Int(ceil(frame.end))
            )
        } else {
            currentViewportSignature = nil
        }

        if filteredVariantCacheViewportSignature?.chromosome != currentViewportSignature?.chromosome
            || filteredVariantCacheViewportSignature?.start != currentViewportSignature?.start
            || filteredVariantCacheViewportSignature?.end != currentViewportSignature?.end {
            _cachedFilteredVariants = nil
            filteredVariantCacheViewportSignature = currentViewportSignature
        }

        if let cached = _cachedFilteredVariants { return cached }
        guard showVariants else {
            _cachedFilteredVariants = []
            return []
        }
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
        if let localKeys = localVariantRenderFilterKeys {
            variants = variants.filter { annotation in
                guard let trackId = annotation.qualifiers["variant_track_id"]?.values.first,
                      let rowId = annotation.qualifiers["variant_row_id"]?.values.first else { return false }
                return localKeys.contains("\(trackId):\(rowId)")
            }
        }
        if let frame = viewController?.referenceFrame {
            let visibleStart = Int(frame.start)
            let visibleEnd = Int(frame.end)
            let visibleChromosome = frame.chromosome
            variants = variants.filter { annotation in
                annotation.chromosome == visibleChromosome
                    && annotation.end > visibleStart
                    && annotation.start < visibleEnd
            }
        }
        _cachedFilteredVariants = variants
        return variants
    }

    /// Genotype data after applying the optional drawer-local render filter (`trackId:rowId`).
    private func filteredVisibleGenotypeData() -> GenotypeDisplayData? {
        guard let genotypeData = cachedGenotypeData else { return nil }
        guard let localKeys = localVariantRenderFilterKeys else { return genotypeData }
        if let cached = _cachedFilteredGenotypeData { return cached }
        let filteredSites = genotypeData.sites.filter { site in
            guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { return false }
            return localKeys.contains("\(trackId):\(rowId)")
        }
        let filtered = GenotypeDisplayData(sampleNames: genotypeData.sampleNames, sites: filteredSites, region: genotypeData.region)
        _cachedFilteredGenotypeData = filtered
        return filtered
    }

    /// Invalidates the filtered variant cache so it's recomputed on next access.
    func invalidateFilteredVariantCache() {
        _cachedFilteredVariants = nil
        filteredVariantCacheViewportSignature = nil
    }

    /// Updates the optional drawer-local variant render filter and invalidates cached filtering.
    func setLocalVariantRenderFilterKeys(_ keys: Set<String>?) {
        guard localVariantRenderFilterKeys != keys else { return }
        localVariantRenderFilterKeys = keys
        _cachedFilteredGenotypeData = nil

        // If the current genotype cache does not contain any of the newly-selected
        // table-synced variant keys, force a genotype refetch on next draw. This
        // recovers from zoom churn where a broad cached genotype window "covers"
        // the region but was limited/truncated and misses current visible rows.
        if let keys, !keys.isEmpty, let genotypeData = cachedGenotypeData {
            let hasOverlap = genotypeData.sites.contains { site in
                guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { return false }
                return keys.contains("\(trackId):\(rowId)")
            }
            if !hasOverlap {
                cachedGenotypeRegion = nil
                logger.info("setLocalVariantRenderFilterKeys: No overlap with cached genotype sites; scheduling refetch")
            }
        }

        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil
        invalidateFilteredVariantCache()
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
    var annotationHeight: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationHeight)

    /// Vertical spacing between annotation rows (configurable via inspector)
    var annotationRowSpacing: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationSpacing)

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

    // MARK: - Genotype Track State

    /// Effective summary bar height based on display state. Returns 0 when summary bar is hidden.
    private var effectiveSummaryBarHeight: CGFloat {
        sampleDisplayState.showSummaryBar ? sampleDisplayState.summaryBarHeight : 0
    }

    /// Effective gap between summary bar and genotype rows.
    private var effectiveSummaryToRowGap: CGFloat {
        sampleDisplayState.showSummaryBar ? VariantTrackRenderer.summaryToRowGap : 0
    }

    /// Cached genotype display data for the visible region.
    private var cachedGenotypeData: GenotypeDisplayData? {
        didSet { _cachedFilteredGenotypeData = nil }
    }

    /// Optional display labels per sample for genotype row rendering.
    private var cachedGenotypeSampleDisplayNames: [String: String] = [:]

    /// Region for which genotype data is cached.
    private var cachedGenotypeRegion: GenomicRegion?

    /// Whether we're currently fetching genotype data.
    private var isFetchingGenotypes: Bool = false

    /// Generation counter for genotype fetches.
    private var genotypeFetchGeneration: Int = 0

    /// Display state controlling sample sort, filter, and visibility.
    var sampleDisplayState: SampleDisplayState = {
        var state = SampleDisplayState()
        state.colorThemeName = AppSettings.shared.variantColorThemeName
        return state
    }() {
        didSet { invalidateGutterWidth() }
    }

    /// Whether the user is dragging the sample gutter edge.
    private var isDraggingGutterEdge: Bool = false

    /// Number of samples in the current variant database (cached for layout).
    private var cachedSampleCount: Int = 0

    /// Horizontal inset used by genotype labels before data cells begin.
    /// Adds a 10px safety pad beyond `variantDataStartX` to keep navigation targets
    /// away from the label column edge.
    var navigationLeadingInsetPixels: CGFloat {
        let base = variantDataStartX
        return base > 0 ? base + 10 : 0
    }

    /// Cached value of the gutter width. Updated by `invalidateGutterWidth()`.
    private var _cachedVariantDataStartX: CGFloat?

    /// The X pixel where variant data begins (after sample gutter + margin).
    /// Returns 0 when genotype rows are hidden or no samples exist.
    /// Cached to avoid per-frame text measurement in draw().
    var variantDataStartX: CGFloat {
        if let cached = _cachedVariantDataStartX { return cached }
        let value = computeVariantDataStartX()
        _cachedVariantDataStartX = value
        return value
    }

    /// Recomputes the gutter width from current state. Call when sample names,
    /// display names, row height, or gutter override change.
    private func computeVariantDataStartX() -> CGFloat {
        guard sampleDisplayState.showGenotypeRows, sampleDisplayState.rowHeight >= 8 else { return 0 }
        let sampleNames = cachedGenotypeData?.sampleNames ?? []
        guard !sampleNames.isEmpty else { return 0 }
        let gutterW = VariantTrackRenderer.sampleLabelGutterWidth(
            samples: sampleNames,
            sampleDisplayNames: cachedGenotypeSampleDisplayNames,
            rowHeight: sampleDisplayState.rowHeight,
            override: sampleDisplayState.sampleGutterWidthOverride
        )
        return gutterW + VariantTrackRenderer.sampleLabelToDataMargin
    }

    /// Invalidates the cached gutter width, forcing recomputation on next access.
    func invalidateGutterWidth() {
        _cachedVariantDataStartX = nil
    }

    /// Vertical scroll offset for genotype rows (in pixels).
    /// Zero = first sample row at top. Positive = scrolled down.
    var genotypeScrollOffset: CGFloat = 0

    /// Maximum vertical scroll offset for genotype rows at the current frame/layout.
    private func maxGenotypeScrollOffset(frame: ReferenceFrame) -> CGFloat {
        let sampleCount = cachedGenotypeData?.sampleNames.count ?? cachedSampleCount
        guard sampleCount > 0 else { return 0 }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        let rowH = sampleDisplayState.rowHeight
        guard rowH > 0 else { return 0 }
        let availableHeight = max(0, bounds.height - genotypeTopY)
        return max(0, CGFloat(sampleCount) * rowH - availableHeight)
    }

    /// Clamps genotype scroll offset to the valid range for current content/layout.
    private func clampGenotypeScrollOffset(frame: ReferenceFrame? = nil) {
        let activeFrame = frame ?? viewController?.referenceFrame
        guard let activeFrame else {
            genotypeScrollOffset = 0
            return
        }
        let maxOffset = maxGenotypeScrollOffset(frame: activeFrame)
        genotypeScrollOffset = max(0, min(genotypeScrollOffset, maxOffset))
    }

    /// Maps reference chromosome names to variant DB chromosome names.
    /// Built at bundle load time by matching chromosome lengths when names differ.
    /// Empty if all names match or no variant tracks are loaded.
    private var variantChromosomeAliasMap: [String: String] = [:]
    /// Cached per-track chromosome name sets from variant databases.
    private var variantTrackChromosomeMap: [String: Set<String>] = [:]

    /// Maps reference chromosome names to BAM/CRAM chromosome names.
    /// Built at bundle load time from AlignmentMetadataDatabase chromosome_stats.
    /// Empty if all names match or no alignment tracks are loaded.
    private var alignmentChromosomeAliasMap: [String: String] = [:]

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
    private var showLettersThreshold: Double { AppSettings.shared.showLettersThresholdBpPerPixel }

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
        trackLoadingAnimationTimer?.invalidate()
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
        // Reload appearance from centralized settings
        sequenceAppearance = AppSettings.shared.sequenceAppearance

        // Update track height from appearance settings
        trackHeight = sequenceAppearance.trackHeight
        logger.info("SequenceViewerView: Track height updated to \(self.trackHeight)")

        // Also update the header view track height
        viewController?.updateTrackHeights(sequenceAppearance.trackHeight)

        // Invalidate tile cache so annotation colors/dimensions are re-rendered
        invalidateAnnotationTile()

        needsDisplay = true
        logger.info("SequenceViewerView: Appearance changed, triggering redraw")
    }

    /// Starts/stops the loading-badge animation timer based on fetch state.
    private func updateTrackLoadingAnimationState() {
        let shouldAnimate = isFetchingReads || isFetchingDepth
        if shouldAnimate {
            guard trackLoadingAnimationTimer == nil else { return }
            trackLoadingAnimationPhase = 0
            let timer = Timer(timeInterval: 1.0 / 18.0, repeats: true) { [weak self] _ in
                // Timer fires on RunLoop.main in .common modes — guaranteed main thread.
                // Use MainActor.assumeIsolated instead of Task { @MainActor in } to avoid
                // cooperative executor scheduling delays during AppKit layout-draw cycles.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackLoadingAnimationPhase += 0.34
                    if self.trackLoadingAnimationPhase > .pi * 2 {
                        self.trackLoadingAnimationPhase -= .pi * 2
                    }
                    self.setNeedsDisplay(self.bounds)
                }
            }
            trackLoadingAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        if let timer = trackLoadingAnimationTimer {
            timer.invalidate()
            trackLoadingAnimationTimer = nil
            trackLoadingAnimationPhase = 0
        }
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
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.needsDisplay = true
                    logger.info("SequenceViewerView.setSequence: Delayed redraw triggered, bounds=\(self.bounds.width)x\(self.bounds.height)")
                }
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

    /// Clears cached genotype rendering data so the next draw refetches using current display state.
    func clearGenotypeCache() {
        genotypeFetchGeneration += 1
        cachedGenotypeData = nil
        cachedGenotypeSampleDisplayNames = [:]
        cachedGenotypeRegion = nil
        isFetchingGenotypes = false
        invalidateGutterWidth()
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
        self.cachedCDSTranslations = [:]
        self.cachedCDSCodingContexts = [:]
        self.localVariantRenderFilterKeys = nil
        self.invalidateFilteredVariantCache()
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.sequenceFetchStartTime = nil
        self.annotationFetchStartTime = nil
        self.bundleFetchError = nil
        self.failedFetchRegion = nil

        // Clear genotype track state
        self.cachedGenotypeData = nil
        self.cachedGenotypeSampleDisplayNames = [:]
        self.cachedGenotypeRegion = nil
        self.isFetchingGenotypes = false
        self.genotypeScrollOffset = 0
        self.invalidateGutterWidth()

        // Clear read alignment state
        self.cachedAlignedReads = []
        self.cachedReadRegion = nil
        self.cachedDepthPoints = []
        self.cachedDepthRegion = nil
        self.cachedConsensusSequence = nil
        self.cachedConsensusRegion = nil
        self.cachedConsensusOptionsSignature = ""
        self.cachedCoverageStats = nil
        self.isFetchingReads = false
        self.isFetchingDepth = false
        self.isFetchingConsensus = false
        self.readFetchStartTime = nil
        self.depthFetchStartTime = nil
        self.readFetchGeneration = 0
        self.depthFetchGeneration = 0
        self.consensusFetchGeneration = 0
        self.lastVariantBottomY = 0
        self.alignmentChromosomeAliasMap = [:]
        self.cachedPackedReads = []
        self.cachedPackOverflow = 0
        self.cachedPackScale = 0
        self.cachedPackDataGeneration = -1
        self.cachedPackViewportStart = 0
        self.cachedPackViewportEnd = 0
        self.readScrollOffset = 0
        self.readContentHeight = 0

        // Cache sample count and build a fast chromosome alias map from variant databases.
        // Skip expensive MAX(position) scans on the main thread; those are warmed asynchronously.
        self.cachedSampleCount = 0
        self.variantChromosomeAliasMap = [:]
        self.variantTrackChromosomeMap = [:]
        for trackId in bundle.variantTrackIds {
            if let trackInfo = bundle.variantTrack(id: trackId),
               let dbPath = trackInfo.databasePath {
                let dbURL = bundle.url.appendingPathComponent(dbPath)
                if let db = try? VariantDatabase(url: dbURL) {
                    let count = db.sampleCount()
                    if count > 0 {
                        self.cachedSampleCount = max(self.cachedSampleCount, count)
                        logger.info("SequenceViewerView.setReferenceBundle: Found \(count) samples in variant track '\(trackId, privacy: .public)'")
                    }

                    let trackChromosomes = Set(db.allChromosomes())
                    self.variantTrackChromosomeMap[trackId] = trackChromosomes

                    // Fast path: name/alias/contig-length matching only.
                    let aliasMap = Self.buildVariantChromosomeAliasMap(
                        bundleChromosomes: bundle.manifest.genome?.chromosomes ?? [],
                        variantDB: db,
                        logger: logger,
                        includeMaxPositionFallback: false
                    )
                    if !aliasMap.isEmpty {
                        for (refChrom, dbChrom) in aliasMap where self.variantChromosomeAliasMap[refChrom] == nil {
                            self.variantChromosomeAliasMap[refChrom] = dbChrom
                        }
                    }
                }
            }
        }
        if let vc = self.viewController {
            vc.annotationDrawerView?.variantChromosomeAliasMap = self.variantChromosomeAliasMap
        }

        // Warm expensive length-from-positions alias inference in the background so bundle
        // selection returns immediately even for very large variant databases.
        Self.warmVariantChromosomeAliasesAsync(
            bundle: bundle,
            initialAliasMap: self.variantChromosomeAliasMap
        ) { [weak self] mergedAliasMap in
            guard let self else { return }
            guard self.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL else { return }
            self.variantChromosomeAliasMap = mergedAliasMap
            if let vc = self.viewController {
                vc.annotationDrawerView?.variantChromosomeAliasMap = mergedAliasMap
            }
        }

        // Initialize alignment data providers from bundle manifest
        self.alignmentDataProviders = []
        for trackId in bundle.alignmentTrackIds {
            if let trackInfo = bundle.alignmentTrack(id: trackId),
               let resolvedPath = try? bundle.resolveAlignmentPath(trackInfo),
               let resolvedIndexPath = try? bundle.resolveAlignmentIndexPath(trackInfo) {
                let provider = AlignmentDataProvider(
                    alignmentPath: resolvedPath,
                    indexPath: resolvedIndexPath,
                    format: trackInfo.format,
                    referenceFastaPath: bundle.referenceFASTAPath()
                )
                self.alignmentDataProviders.append((trackId, provider))
                logger.info("SequenceViewerView.setReferenceBundle: Initialized alignment provider for '\(trackInfo.name, privacy: .public)'")
            }
        }

        // Build alignment chromosome alias map from metadata databases
        if !alignmentDataProviders.isEmpty {
            self.alignmentChromosomeAliasMap = Self.buildAlignmentChromosomeAliasMap(
                bundleChromosomes: bundle.manifest.genome?.chromosomes ?? [],
                alignmentTracks: bundle.manifest.alignments,
                bundleURL: bundle.url,
                logger: logger
            )
        }

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

    /// Keeps extraction selection synchronized to the currently visible viewport.
    ///
    /// Dynamic freehand region selection is intentionally disabled; extraction always operates
    /// on the visible region (or a selected annotation via annotation menus).
    private func ensureVisibleViewportSelection(frame: ReferenceFrame) {
        // Do not overwrite a user-initiated column selection
        guard !isUserColumnSelection else { return }

        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        let viewportRange = lower..<upper
        guard selectionRange != viewportRange else { return }
        selectionRange = viewportRange
        selectionStartBase = lower
        isSelecting = false
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
        self.cachedCDSTranslations = [:]
        self.cachedCDSCodingContexts = [:]
        self.localVariantRenderFilterKeys = nil
        self.invalidateFilteredVariantCache()
        self.cachedGenotypeData = nil
        self.cachedGenotypeSampleDisplayNames = [:]
        self.cachedGenotypeRegion = nil
        self.invalidateGutterWidth()
        self.cachedAlignedReads = []
        self.cachedReadRegion = nil
        self.cachedDepthPoints = []
        self.cachedDepthRegion = nil
        self.cachedConsensusSequence = nil
        self.cachedConsensusRegion = nil
        self.cachedConsensusOptionsSignature = ""
        self.cachedCoverageStats = nil
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.isFetchingGenotypes = false
        self.isFetchingReads = false
        self.isFetchingDepth = false
        self.isFetchingConsensus = false
        self.readFetchStartTime = nil
        self.depthFetchStartTime = nil
        self.readFetchGeneration = 0
        self.depthFetchGeneration = 0
        self.consensusFetchGeneration = 0
        self.cachedSampleCount = 0
        self.variantChromosomeAliasMap = [:]
        self.variantTrackChromosomeMap = [:]
        self.alignmentChromosomeAliasMap = [:]
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

    /// Clears cached variant data so the viewer re-fetches from the database on next draw.
    func clearCachedVariants() {
        cachedVariantAnnotations = []
        cachedVariantRegion = nil
        invalidateFilteredVariantCache()
        isFetchingVariants = false
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
            // Insets are set in viewDidLayout/scheduleDeferredRedraw/handleViewResize.
            // draw() should not mutate frame state — just ensure consistency.


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

        ensureVisibleViewportSelection(frame: frame)

        let visibleRegion = GenomicRegion(
            chromosome: frame.chromosome,
            start: max(0, Int(frame.start)),
            end: max(Int(frame.start) + 1, Int(ceil(frame.end)))
        )
        let scale = frame.scale  // bp/pixel
        let needsSequence = scale < showLineThreshold  // Only fetch sequence when it would be visible

        // Always fetch annotations — at wide zoom levels, density mode handles large counts.
        // The density histogram works at any scale; detailed rendering kicks in when zoomed in.
        let visibleSpan = visibleRegion.end - visibleRegion.start
        let needsAnnotations = true

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

        // --- Draw annotations (above variants) ---
        if cachedAnnotationRegion?.chromosome == visibleRegion.chromosome,
           !cachedBundleAnnotations.isEmpty {
            logger.debug("drawBundleContent: Drawing \(self.cachedBundleAnnotations.count) annotations")
            drawBundleAnnotations(cachedBundleAnnotations, frame: frame, context: context)
        } else {
            // No annotations yet — update bottom Y for variant positioning
            lastAnnotationBottomY = annotationTrackY
        }

        // Show annotation loading status whenever annotation fetch is in flight.
        if isFetchingAnnotations {
            let message = cachedBundleAnnotations.isEmpty ? "Fetching annotations..." : "Updating annotations..."
            drawTrackLoadingBadge(context: context, message: message, yOffset: annotationTrackY + 2)
        }

        // --- Variants below annotations ---
        // Check if variant cache covers the visible region
        let variantsCovered = cachedVariantRegion?.chromosome == visibleRegion.chromosome
            && (cachedVariantRegion?.start ?? Int.max) <= visibleRegion.start
            && (cachedVariantRegion?.end ?? Int.min) >= visibleRegion.end

        // Fetch variants if cache is stale
        if !variantsCovered && !isFetchingVariants {
            fetchVariantsAsync(bundle: bundle, region: visibleRegion)
        }

        let filteredVariants: [SequenceAnnotation] = filteredVisibleVariantAnnotations

        // Draw variant summary bar + genotype rows (below annotations)
        let variantDisplayCap = 5_000
        if showVariants && !filteredVariants.isEmpty {
            let vY = variantTrackY

            let activeTheme = VariantColorTheme.named(sampleDisplayState.colorThemeName)

            if sampleDisplayState.showSummaryBar {
                VariantTrackRenderer.drawSummaryBar(
                    variants: filteredVariants,
                    frame: frame,
                    context: context,
                    yOffset: vY,
                    barHeight: sampleDisplayState.summaryBarHeight,
                    theme: activeTheme
                )
            }

            if filteredVariants.count > variantDisplayCap {
                // Auto-enable summary bar so density histogram is always visible at zoomed-out views
                if !sampleDisplayState.showSummaryBar {
                    sampleDisplayState.showSummaryBar = true
                }
                // Too many variants for genotype display — show zoom-in message
                let msg = "Zoom in to display genotypes (\(filteredVariants.count) variants visible)" as NSString
                let msgAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let msgY = vY + effectiveSummaryBarHeight + 4
                msg.draw(at: CGPoint(x: 4, y: msgY), withAttributes: msgAttrs)
            } else {
                // Draw per-sample genotype rows if available and enabled
                if let genotypeData = filteredVisibleGenotypeData(), cachedSampleCount > 0,
                   sampleDisplayState.showGenotypeRows {
                    clampGenotypeScrollOffset(frame: frame)
                    let genotypeY = vY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
                    let availableHeight = max(0, bounds.height - genotypeY)
                    VariantTrackRenderer.drawGenotypeRows(
                        genotypeData: genotypeData,
                        frame: frame,
                        context: context,
                        yOffset: genotypeY,
                        state: sampleDisplayState,
                        useHaploidAFShading: sampleDisplayState.useHaploidAFShading,
                        sampleDisplayNames: cachedGenotypeSampleDisplayNames,
                        scrollOffset: genotypeScrollOffset,
                        availableHeight: availableHeight,
                        theme: activeTheme
                    )
                }

                // Fetch genotype data if needed and we have samples
                if cachedSampleCount > 0 && !isFetchingGenotypes {
                    let genotypeCovered = cachedGenotypeRegion?.chromosome == visibleRegion.chromosome
                        && (cachedGenotypeRegion?.start ?? Int.max) <= visibleRegion.start
                        && (cachedGenotypeRegion?.end ?? Int.min) >= visibleRegion.end
                    if !genotypeCovered {
                        fetchGenotypesAsync(bundle: bundle, region: visibleRegion)
                    }
                }
            }

            // Track the bottom Y of the variant track so reads can stack below
            let totalVariantHeight = VariantTrackRenderer.totalHeight(
                sampleCount: cachedSampleCount,
                state: sampleDisplayState
            )
            lastVariantBottomY = vY + totalVariantHeight

            if isFetchingVariants {
                drawTrackLoadingBadge(context: context, message: "Updating variants...", yOffset: vY + 2)
            }
            if isFetchingGenotypes && filteredVariants.count <= variantDisplayCap {
                let genotypeBadgeY = vY + effectiveSummaryBarHeight + effectiveSummaryToRowGap + 2
                drawTrackLoadingBadge(context: context, message: "Updating genotypes...", yOffset: genotypeBadgeY)
            }
        } else if showVariants && !bundle.variantTrackIds.isEmpty {
            // Variant tracks exist but nothing to display — show status badge
            let vY = variantTrackY
            let message: String
            if isFetchingVariants {
                message = "Fetching variants\u{2026}"
            } else if cachedVariantAnnotations.isEmpty {
                message = "No variants in this region"
            } else {
                message = "All \(cachedVariantAnnotations.count) variants filtered out"
            }
            drawTrackLoadingBadge(context: context, message: message, yOffset: vY + 2)
        }

        // --- Read alignments below variants ---
        if !alignmentDataProviders.isEmpty && showReads {
            let tier = ReadTrackRenderer.zoomTier(scale: scale)
            let coverageY = readTrackY
            let maxRowsLimit: Int? = limitReadRowsSetting ? max(1, maxReadRowsSetting) : nil
            let maxRowsCacheKey = maxRowsLimit ?? 0

            let displaySettings = ReadTrackRenderer.DisplaySettings(
                showMismatches: showMismatchesSetting,
                showSoftClips: showSoftClipsSetting,
                showIndels: showIndelsSetting,
                consensusMaskingEnabled: consensusMaskingEnabledSetting,
                consensusGapThreshold: Double(consensusGapThresholdPercentSetting) / 100.0,
                consensusMinDepth: consensusMinDepthSetting,
                showStrandColors: showStrandColorsSetting
            )

            // Coverage strip is always visible.
            let depthCovered = cachedDepthRegion?.chromosome == visibleRegion.chromosome
                && (cachedDepthRegion?.start ?? Int.max) <= visibleRegion.start
                && (cachedDepthRegion?.end ?? Int.min) >= visibleRegion.end
            if !depthCovered && !isFetchingDepth {
                fetchDepthAsync(bundle: bundle, region: visibleRegion)
            }
            lastRenderedCoverageY = coverageY
            let coverageRect = CGRect(
                x: 0,
                y: coverageY,
                width: bounds.width,
                height: coverageStripHeight
            )
            ReadTrackRenderer.drawCoverage(
                depthPoints: cachedDepthPoints,
                regionStart: visibleRegion.start,
                regionEnd: visibleRegion.end,
                frame: frame,
                context: context,
                rect: coverageRect
            )
            if isFetchingDepth && cachedDepthPoints.isEmpty {
                let elapsed = depthFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                if elapsed > 0.15 {
                    drawTrackLoadingBadge(
                        context: context,
                        message: "Loading depth...",
                        yOffset: coverageRect.minY + 2
                    )
                }
            }

            var rowsY = coverageRect.maxY + coverageToConsensusGap
            if showConsensusTrackSetting {
                let consensusOptions = currentConsensusOptionsSignature()
                let consensusCovered = cachedConsensusRegion?.chromosome == visibleRegion.chromosome
                    && (cachedConsensusRegion?.start ?? Int.max) <= visibleRegion.start
                    && (cachedConsensusRegion?.end ?? Int.min) >= visibleRegion.end
                    && cachedConsensusOptionsSignature == consensusOptions
                if !consensusCovered && !isFetchingConsensus {
                    fetchConsensusAsync(bundle: bundle, region: visibleRegion)
                }
                let consensusRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: consensusStripHeight)
                drawConsensusTrack(
                    sequenceString: cachedConsensusSequence,
                    region: cachedConsensusRegion,
                    frame: frame,
                    context: context,
                    rect: consensusRect
                )
                rowsY = consensusRect.maxY + consensusToReadGap
            }

            // Cache rendering state for hit-testing.
            lastRenderedReadY = rowsY
            lastRenderedReadTier = tier

            if tier == .coverage {
                cachedPackedReads = []
                readContentHeight = 0
                if bounds.height - rowsY > 20 {
                    drawReadZoomHint(context: context, yOffset: rowsY + 2, scale: scale)
                }
            } else {
                let readsCovered = cachedReadRegion?.chromosome == visibleRegion.chromosome
                    && (cachedReadRegion?.start ?? Int.max) <= visibleRegion.start
                    && (cachedReadRegion?.end ?? Int.min) >= visibleRegion.end
                if !readsCovered && !isFetchingReads {
                    fetchReadsAsync(bundle: bundle, region: visibleRegion)
                }

                if !cachedAlignedReads.isEmpty {
                    // Reuse cached pack layout if scale, data, viewport, and settings haven't changed.
                    // Viewport position matters because reads are filtered to near-viewport before
                    // packing — if the user pans significantly, the visible reads change.
                    let viewportShift = abs(visibleRegion.start - cachedPackViewportStart)
                    let viewportSpan = max(1, visibleRegion.end - visibleRegion.start)
                    let scaleChanged = (scale != cachedPackScale)
                    let dataChanged = (readFetchGeneration != cachedPackDataGeneration)
                    let needsRepack = scaleChanged
                        || dataChanged
                        || (maxRowsCacheKey != cachedPackMaxRows)
                        || (viewportShift > viewportSpan / 4) // Repack when panned >25% of viewport

                    if needsRepack {
                        // New zoom/data fetch should snap back to top rows for predictable navigation.
                        if scaleChanged || dataChanged {
                            readScrollOffset = 0
                        }
                        // Filter reads to viewport +/- safety padding while ensuring reads that
                        // overlap the visible window are never dropped.
                        // The cached read region can be much wider than the viewport (especially
                        // when zooming in from a wider view). Packing all reads wastes the limited
                        // 75-row budget on far off-screen reads, potentially leaving no rows for
                        // reads in the visible window.
                        let viewportSpan = visibleRegion.end - visibleRegion.start
                        let maxReadSpan = max(
                            1,
                            cachedAlignedReads.lazy.prefix(50_000).map { max(1, $0.alignmentEnd - $0.position) }.max() ?? 500
                        )
                        let packPadding = max(maxReadSpan, min(10_000, max(500, viewportSpan)))
                        let packStart = max(0, visibleRegion.start - packPadding)
                        let packEnd = visibleRegion.end + packPadding

                        let readsForPacking = cachedAlignedReads.filter { read in
                            read.alignmentEnd > packStart && read.position < packEnd
                        }

                        let (packed, packOverflow) = ReadTrackRenderer.packReads(
                            readsForPacking,
                            frame: frame,
                            maxRows: maxRowsLimit,
                            sortMode: .position,
                            prioritizedRegion: visibleRegion.start..<visibleRegion.end
                        )
                        cachedPackedReads = packed
                        cachedPackOverflow = packOverflow
                        cachedPackScale = scale
                        cachedPackDataGeneration = readFetchGeneration
                        cachedPackMaxRows = maxRowsCacheKey
                        cachedPackViewportStart = visibleRegion.start
                        cachedPackViewportEnd = visibleRegion.end
                    }
                    let rowCount = (cachedPackedReads.map(\.row).max() ?? -1) + 1
                    let contentHeight = ReadTrackRenderer.totalHeight(
                        rowCount: rowCount,
                        tier: tier,
                        verticalCompress: verticallyCompressContigSetting
                    )
                    readContentHeight = contentHeight

                    // Available vertical space: from rY to bottom of view
                    let availableHeight = max(0, bounds.height - rowsY)
                    let visibleHeight = min(contentHeight, max(availableHeight, maxReadTrackHeight))

                    // Clamp scroll offset
                    let maxScroll = max(0, contentHeight - visibleHeight)
                    if readScrollOffset > maxScroll { readScrollOffset = maxScroll }

                    // Clip to visible read area and translate by scroll offset
                    let clipRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: visibleHeight)
                    context.saveGState()
                    context.clip(to: clipRect)
                    context.translateBy(x: 0, y: -readScrollOffset)

                    let drawRect = CGRect(x: 0, y: rowsY, width: bounds.width, height: contentHeight)
                    let maskedPositions: Set<Int>
                    if displaySettings.consensusMaskingEnabled {
                        maskedPositions = ReadTrackRenderer.computeHighGapMaskedPositions(
                            packedReads: cachedPackedReads,
                            visibleRegion: visibleRegion.start..<visibleRegion.end,
                            minDepth: displaySettings.consensusMinDepth,
                            gapThreshold: displaySettings.consensusGapThreshold
                        )
                    } else {
                        maskedPositions = []
                    }

                    if tier == .packed {
                        ReadTrackRenderer.drawPackedReads(
                            packedReads: cachedPackedReads, overflow: cachedPackOverflow, frame: frame,
                            referenceSequence: cachedBundleSequence,
                            referenceStart: cachedSequenceRegion?.start ?? Int(frame.start),
                            settings: displaySettings,
                            verticalCompress: verticallyCompressContigSetting,
                            maxRowsLimit: maxRowsLimit,
                            maskedPositions: maskedPositions,
                            context: context, rect: drawRect
                        )
                    } else {
                        ReadTrackRenderer.drawBaseReads(
                            packedReads: cachedPackedReads, overflow: cachedPackOverflow, frame: frame,
                            referenceSequence: cachedBundleSequence,
                            referenceStart: cachedSequenceRegion?.start ?? Int(frame.start),
                            settings: displaySettings,
                            verticalCompress: verticallyCompressContigSetting,
                            maxRowsLimit: maxRowsLimit,
                            maskedPositions: maskedPositions,
                            context: context, rect: drawRect
                        )
                    }

                    context.restoreGState()

                    // Draw scroll indicator if content exceeds visible area
                    if contentHeight > visibleHeight && maxScroll > 0 {
                        drawReadScrollIndicator(
                            context: context, clipRect: clipRect,
                            contentHeight: contentHeight, scrollOffset: readScrollOffset
                        )
                    }
                } else {
                    cachedPackedReads = []
                    readContentHeight = 0
                }

                if isFetchingReads {
                    let elapsed = readFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    if elapsed > 0.15 {
                        let message = cachedAlignedReads.isEmpty ? "Loading mapped reads..." : "Updating mapped reads..."
                        drawTrackLoadingBadge(context: context, message: message, yOffset: rowsY + 2)
                    }
                }
            }
        }

        // Draw gutter background overlays for non-variant content areas
        // (sequence track, annotation track). The variant track handles its own gutter.
        let gutterInset = frame.leadingInset
        let contentTop: CGFloat = 0
        let contentBottom = variantTrackY
        let contentHeight = max(0, contentBottom - contentTop)

        if gutterInset > 0 && contentHeight > 0 {
            // Left gutter background
            context.setFillColor(VariantTrackRenderer.gutterBackgroundColor)
            context.fill(CGRect(x: 0, y: contentTop, width: gutterInset, height: contentHeight))
            // Left vertical separator
            context.setStrokeColor(VariantTrackRenderer.gutterSeparatorColor)
            context.setLineWidth(0.5)
            let sepX = gutterInset - VariantTrackRenderer.sampleLabelToDataMargin / 2
            context.move(to: CGPoint(x: sepX, y: contentTop))
            context.addLine(to: CGPoint(x: sepX, y: contentBottom))
            context.strokePath()
        }

        // Right margin overlay — clean visual boundary before inspector
        let trailingInset = frame.trailingInset
        if trailingInset > 0 {
            let rightX = bounds.width - trailingInset
            // Right margin background (full height)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: rightX, y: 0, width: trailingInset, height: bounds.height))
            // Right vertical separator
            context.setStrokeColor(VariantTrackRenderer.gutterSeparatorColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: rightX + 0.5, y: 0))
            context.addLine(to: CGPoint(x: rightX + 0.5, y: bounds.height))
            context.strokePath()
        }

        // Draw selection overlays on top of all content
        drawColumnSelectionHighlight(frame: frame, context: context)
        drawSelectedReadHighlights(frame: frame, context: context)
    }

    /// Fetches annotations asynchronously for the visible region from SQLite annotation databases.
    /// Runs database queries on a background thread to avoid blocking the UI.
    /// Dedicated queue for annotation I/O to avoid being starved by the search index build.
    private static let annotationFetchQueue = DispatchQueue(label: "com.lungfish.annotationFetch", qos: .userInteractive)

    /// Schedules UI state updates on the main run loop common modes.
    /// This avoids starvation during AppKit tracking/layout-heavy loops.
    ///
    /// Uses `MainActor.assumeIsolated` inside the CFRunLoop block to guarantee
    /// the compiler knows we're on the main actor (GCD main queue is always drained).
    private static func enqueueMainRunLoop(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
            return
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { block() }
        }
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
                viewer.cachedCDSCodingContexts = [:]
                viewer.isFetchingAnnotations = false
                viewer.annotationFetchStartTime = nil
                viewer.invalidateAnnotationTile()
                logger.info("fetchAnnotationsAsync: Cached \(count) annotations for \(expandedRegion.description) in \(elapsed, format: .fixed(precision: 3))s, triggering redraw")
                viewer.setNeedsDisplay(viewer.bounds)
            }
        }
    }

    /// Builds a map from reference chromosome names to variant DB chromosome names.
    ///
    /// When a VCF uses different chromosome naming (e.g., "7" vs "NC_041760.1"),
    /// this method matches chromosomes by comparing reference lengths to variant
    /// database max positions. A VCF chromosome matches a reference chromosome
    /// if its max variant position is within 1% of the reference length.
    nonisolated private static func buildVariantChromosomeAliasMap(
        bundleChromosomes: [ChromosomeInfo],
        variantDB: VariantDatabase,
        logger: Logger,
        includeMaxPositionFallback: Bool = true
    ) -> [String: String] {
        let vcfChroms = Set(variantDB.allChromosomes())
        let refChromNames = Set(bundleChromosomes.map(\.name))

        // Check if all VCF chromosomes already match reference names
        let unmatched = vcfChroms.subtracting(refChromNames)
        if unmatched.isEmpty { return [:] }

        var aliasMap: [String: String] = [:]  // ref name → VCF name
        var usedVCFChroms = Set<String>()

        // Strategy 1: Name-based matching (fast, reliable with populated aliases)
        // mapVCFChromosomes checks: exact match, aliases, version stripping, chr prefix,
        // fuzzy prefix, and FASTA description matching
        let nameMap = mapVCFChromosomes(Array(unmatched), toBundleChromosomes: bundleChromosomes)
        // nameMap is [vcfChrom: bundleName] — invert to [bundleName: vcfChrom]
        for (vcfChrom, bundleName) in nameMap {
            if aliasMap[bundleName] == nil {
                aliasMap[bundleName] = vcfChrom
                usedVCFChroms.insert(vcfChrom)
            }
        }

        // Strategy 2: Length-based matching for any remaining unmatched chromosomes.
        // Uses VCF ##contig header lengths and optionally MAX(end_pos) as fallback.
        let afterNameMatching = unmatched.subtracting(usedVCFChroms)
        if !afterNameMatching.isEmpty {
            let vcfContigLengths = variantDB.contigLengths()
            let vcfMaxPositions: [String: Int]
            if includeMaxPositionFallback && vcfContigLengths.isEmpty {
                vcfMaxPositions = variantDB.chromosomeMaxPositions()
            } else {
                vcfMaxPositions = [:]
            }

            for chrom in bundleChromosomes {
                if vcfChroms.contains(chrom.name) { continue }
                if aliasMap[chrom.name] != nil { continue }  // Already matched by name

                var bestMatch: String?
                var bestDelta = Int64.max

                for vcfChrom in afterNameMatching where !usedVCFChroms.contains(vcfChrom) {
                    if let contigLength = vcfContigLengths[vcfChrom] {
                        let delta = abs(chrom.length - contigLength)
                        guard delta <= 10 else { continue }
                        if delta < bestDelta {
                            bestDelta = delta
                            bestMatch = vcfChrom
                        }
                    } else if let maxPos = vcfMaxPositions[vcfChrom] {
                        let maxPos64 = Int64(maxPos)
                        guard maxPos64 <= chrom.length else { continue }
                        let delta = chrom.length - maxPos64
                        let tolerance = chrom.length > 1_000_000
                            ? chrom.length / 20
                            : chrom.length / 5
                        guard delta < tolerance else { continue }
                        if delta < bestDelta {
                            bestDelta = delta
                            bestMatch = vcfChrom
                        }
                    }
                }

                if let match = bestMatch {
                    aliasMap[chrom.name] = match
                    usedVCFChroms.insert(match)
                }
            }
        }

        // Warn if we still have unmatched chromosomes
        let finalUnmatched = unmatched.subtracting(usedVCFChroms)
        if aliasMap.isEmpty && !finalUnmatched.isEmpty {
            let vcfSample = Array(finalUnmatched.prefix(3)).joined(separator: ", ")
            let refSample = Array(bundleChromosomes.prefix(3).map(\.name)).joined(separator: ", ")
            logger.warning("buildVariantChromosomeAliasMap: Could not match VCF chromosomes [\(vcfSample)] to reference chromosomes [\(refSample)] — variant queries may return empty results")
        }

        if !aliasMap.isEmpty {
            let nameMatchCount = nameMap.count
            let lengthMatchCount = aliasMap.count - nameMatchCount
            let mode = includeMaxPositionFallback ? "full" : "fast"
            logger.info("buildVariantChromosomeAliasMap[\(mode, privacy: .public)]: Built \(aliasMap.count) chromosome aliases (\(nameMatchCount) name-based, \(lengthMatchCount) length-based) (e.g., \(aliasMap.first?.key ?? "") → \(aliasMap.first?.value ?? ""))")
        }

        return aliasMap
    }

    nonisolated private static let variantAliasWarmupQueue = DispatchQueue(
        label: "com.lungfish.variantAliasWarmup",
        qos: .utility
    )

    /// Computes expensive variant chromosome aliases off the main thread and merges them with fast aliases.
    nonisolated private static func warmVariantChromosomeAliasesAsync(
        bundle: ReferenceBundle,
        initialAliasMap: [String: String],
        onComplete: @escaping @MainActor @Sendable ([String: String]) -> Void
    ) {
        guard !bundle.variantTrackIds.isEmpty else { return }
        let bundleChromosomes = bundle.manifest.genome?.chromosomes ?? []
        let initial = initialAliasMap

        variantAliasWarmupQueue.async {
            var merged = initial
            for trackId in bundle.variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                let dbURL = bundle.url.appendingPathComponent(dbPath)
                guard let db = try? VariantDatabase(url: dbURL) else { continue }

                let aliasMap = Self.buildVariantChromosomeAliasMap(
                    bundleChromosomes: bundleChromosomes,
                    variantDB: db,
                    logger: logger,
                    includeMaxPositionFallback: true
                )
                for (refChrom, dbChrom) in aliasMap where merged[refChrom] == nil {
                    merged[refChrom] = dbChrom
                }
            }

            guard merged != initial else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onComplete(merged)
                }
            }
        }
    }

    /// Translates a reference chromosome name to the variant DB chromosome name.
    /// Returns the original name if no alias is needed.
    private func variantDBChromosomeName(for refChrom: String) -> String {
        variantChromosomeAliasMap[refChrom] ?? refChrom
    }

    /// Public wrapper for components that need the active variant DB chromosome alias.
    func variantDatabaseChromosomeName(for refChrom: String) -> String {
        variantDBChromosomeName(for: refChrom)
    }

    /// Translates a variant DB chromosome name back to the reference chromosome name.
    /// Returns the original chromosome when no reverse mapping is available.
    func referenceChromosomeName(forVariantDBChromosome variantChrom: String) -> String {
        if let direct = viewController?.currentBundleDataProvider?.chromosomeInfo(named: variantChrom)?.name {
            return direct
        }
        if let mapped = variantChromosomeAliasMap.first(where: { $0.value == variantChrom })?.key {
            return mapped
        }
        return variantChrom
    }

    // MARK: - Alignment Chromosome Aliasing

    /// Translates a reference chromosome name to the BAM/CRAM chromosome name.
    /// Returns the original name if no alias is needed.
    private func alignmentChromosomeName(for refChrom: String) -> String {
        alignmentChromosomeAliasMap[refChrom] ?? refChrom
    }

    /// Builds a map from reference chromosome names to BAM/CRAM chromosome names.
    ///
    /// BAM files often use different chromosome naming from the reference
    /// (e.g., "MN908947.3" vs "MN908947", or "chr1" vs "1").
    /// This method reads the AlignmentMetadataDatabase (populated from samtools idxstats
    /// at import time) and matches chromosomes by exact sequence length.
    private static func buildAlignmentChromosomeAliasMap(
        bundleChromosomes: [ChromosomeInfo],
        alignmentTracks: [AlignmentTrackInfo],
        bundleURL: URL,
        logger: Logger
    ) -> [String: String] {
        let refChromNames = Set(bundleChromosomes.map(\.name))

        // Collect BAM chromosome names and lengths from metadata databases
        var bamChromLengths: [String: Int64] = [:]
        for track in alignmentTracks {
            guard let dbRelPath = track.metadataDBPath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbRelPath)
            guard let db = try? AlignmentMetadataDatabase(url: dbURL) else { continue }
            for stat in db.chromosomeStats() {
                bamChromLengths[stat.chromosome] = stat.length
            }
        }

        guard !bamChromLengths.isEmpty else { return [:] }

        let bamChromNames = Set(bamChromLengths.keys)

        // Check if all BAM chromosomes already match reference names
        let unmatched = bamChromNames.subtracting(refChromNames)
        if unmatched.isEmpty { return [:] }

        // Build alias map: ref name → BAM name, matching by exact length
        var aliasMap: [String: String] = [:]
        var usedBAMChroms = Set<String>()

        for chrom in bundleChromosomes {
            // Skip if BAM already has this exact name
            if bamChromNames.contains(chrom.name) { continue }

            // Find a BAM chromosome with matching length
            var bestMatch: String?
            for bamChrom in unmatched where !usedBAMChroms.contains(bamChrom) {
                guard let bamLength = bamChromLengths[bamChrom] else { continue }
                if bamLength == chrom.length {
                    bestMatch = bamChrom
                    break
                }
            }

            if let match = bestMatch {
                aliasMap[chrom.name] = match
                usedBAMChroms.insert(match)
            }
        }

        if !aliasMap.isEmpty {
            logger.info("buildAlignmentChromosomeAliasMap: Built \(aliasMap.count) aliases (e.g., \(aliasMap.first?.key ?? "") → \(aliasMap.first?.value ?? ""))")
        }

        return aliasMap
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

        let aliasMapSnapshot = variantChromosomeAliasMap
        let trackChromosomeMapSnapshot = variantTrackChromosomeMap

        logger.info("fetchVariantsAsync: gen=\(thisGeneration), Fetching variants for \(expandedRegion.description)")

        Self.variantFetchQueue.async { [weak self] in
            var allVariantAnnotations: [SequenceAnnotation] = []
            for trackId in variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                let dbURL = bundle.url.appendingPathComponent(dbPath)
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }

                do {
                    let db = try VariantDatabase(url: dbURL)
                    let availableChromosomes = trackChromosomeMapSnapshot[trackId] ?? Set(db.allChromosomes())
                    let queryChromosomes = resolveVariantChromosomeCandidates(
                        requestedChromosome: region.chromosome,
                        availableChromosomes: availableChromosomes,
                        aliasMap: aliasMapSnapshot
                    )

                    var records: [VariantDatabaseRecord] = []
                    var resolvedChromosome = region.chromosome
                    for queryChrom in queryChromosomes {
                        let queried = db.query(
                            chromosome: queryChrom,
                            start: expandedStart,
                            end: expandedEnd
                        )
                        if !queried.isEmpty {
                            records = queried
                            resolvedChromosome = queryChrom
                            break
                        }
                    }

                    if resolvedChromosome != region.chromosome {
                        logger.info(
                            "fetchVariantsAsync: Track \(trackId, privacy: .public) resolved chromosome '\(region.chromosome, privacy: .public)' -> '\(resolvedChromosome, privacy: .public)'"
                        )
                    }

                    if !records.isEmpty {
                        let annotations = records.map { record -> SequenceAnnotation in
                            var annotation = record.toAnnotation()
                            // Keep rendering coordinates in the active reference chromosome namespace.
                            annotation.chromosome = region.chromosome
                            annotation.qualifiers["variant_track_id"] = AnnotationQualifier(trackId)
                            return annotation
                        }
                        allVariantAnnotations.append(contentsOf: annotations)
                    }
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
                viewer.invalidateFilteredVariantCache()
                viewer.isFetchingVariants = false
                viewer.invalidateAnnotationTile()
                logger.info("fetchVariantsAsync: Cached \(count) variant annotations in \(elapsed, format: .fixed(precision: 3))s")
                viewer.setNeedsDisplay(viewer.bounds)

                // Notify variant table drawer of updated viewport variants.
                // Send the reference chromosome label; drawer-side query logic resolves DB aliases.
                NotificationCenter.default.post(
                    name: .viewportVariantsUpdated,
                    object: viewer,
                    userInfo: [
                        NotificationUserInfoKey.chromosome: region.chromosome,
                        NotificationUserInfoKey.start: region.start,
                        NotificationUserInfoKey.end: region.end,
                        "variantCount": count,
                    ]
                )
            }
        }
    }

    // MARK: - Read Alignment Fetching

    /// Fetches sparse depth points asynchronously from samtools depth for coverage-tier rendering.
    ///
    /// This decouples zoomed-out coverage from full SAM read parsing.
    private func fetchDepthAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard !alignmentDataProviders.isEmpty else { return }

        depthFetchGeneration += 1
        let thisGeneration = depthFetchGeneration
        isFetchingDepth = true
        depthFetchStartTime = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(5_000, visibleSpan) // 1x viewport padding for panning
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = alignmentDataProviders
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = max(0, max(minMapQSetting, consensusMinMapQSetting))
        let baseQFilter = max(0, consensusMinBaseQSetting)
        let excludeFlags = excludeFlagsSetting

        logger.info(
            "fetchDepthAsync: gen=\(thisGeneration), Fetching depth for \(expandedRegion.description) (BAM chrom: \(bamChromosome), minMAPQ: \(mapQFilter), minBQ: \(baseQFilter), flags: 0x\(String(excludeFlags, radix: 16)))"
        )

        Task.detached { [weak self] in
            var depthByPosition: [Int: Int] = [:]
            depthByPosition.reserveCapacity(8192)

            for (_, provider) in providers {
                do {
                    var points = try await provider.fetchDepth(
                        chromosome: bamChromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        minMapQ: mapQFilter,
                        minBaseQ: baseQFilter,
                        excludeFlags: excludeFlags
                    )

                    if points.isEmpty, bamChromosome != region.chromosome {
                        let fallback = try await provider.fetchDepth(
                            chromosome: region.chromosome,
                            start: expandedStart,
                            end: expandedEnd,
                            minMapQ: mapQFilter,
                            minBaseQ: baseQFilter,
                            excludeFlags: excludeFlags
                        )
                        if !fallback.isEmpty {
                            logger.info(
                                "fetchDepthAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'"
                            )
                            points = fallback
                        }
                    }

                    for point in points where point.depth > 0 {
                        depthByPosition[point.position, default: 0] += point.depth
                    }
                } catch {
                    logger.error("fetchDepthAsync: Failed to fetch depth: \(error)")
                }
            }

            let mergedPoints = depthByPosition
                .map { ReadTrackRenderer.CoveragePoint(position: $0.key, depth: $0.value) }
                .sorted { $0.position < $1.position }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    guard thisGeneration == viewer.depthFetchGeneration else {
                        logger.info("fetchDepthAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.depthFetchGeneration))")
                        return
                    }
                    viewer.cachedDepthPoints = mergedPoints
                    viewer.cachedDepthRegion = expandedRegion
                    viewer.cachedCoverageStats = ReadTrackRenderer.summarizeCoverage(
                        depthPoints: mergedPoints,
                        regionStart: expandedRegion.start,
                        regionEnd: expandedRegion.end
                    )
                    viewer.isFetchingDepth = false
                    viewer.depthFetchStartTime = nil
                    logger.info("fetchDepthAsync: Cached \(mergedPoints.count) depth points")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    /// Returns a stable cache signature for consensus options.
    private func currentConsensusOptionsSignature() -> String {
        [
            consensusModeSetting.rawValue,
            showConsensusTrackSetting ? "1" : "0",
            consensusUseAmbiguitySetting ? "1" : "0",
            String(max(0, max(minMapQSetting, consensusMinMapQSetting))),
            String(max(0, consensusMinBaseQSetting)),
            String(max(1, consensusMinDepthSetting)),
            String(excludeFlagsSetting),
        ].joined(separator: "|")
    }

    /// Fetches consensus sequence asynchronously for the current alignment region.
    private func fetchConsensusAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard showConsensusTrackSetting else { return }
        guard !alignmentDataProviders.isEmpty else { return }

        consensusFetchGeneration += 1
        let thisGeneration = consensusFetchGeneration
        isFetchingConsensus = true

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(5_000, visibleSpan)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = alignmentDataProviders
        guard let provider = providers.first?.provider else { return }
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = max(0, max(minMapQSetting, consensusMinMapQSetting))
        let baseQFilter = max(0, consensusMinBaseQSetting)
        let minDepth = max(1, consensusMinDepthSetting)
        let excludeFlags = excludeFlagsSetting
        let mode = consensusModeSetting
        let useAmbiguity = consensusUseAmbiguitySetting
        let optionsSignature = currentConsensusOptionsSignature()

        logger.info(
            "fetchConsensusAsync: gen=\(thisGeneration), Fetching consensus for \(expandedRegion.description) (BAM chrom: \(bamChromosome), mode: \(mode.rawValue), minMAPQ: \(mapQFilter), minBQ: \(baseQFilter), minDepth: \(minDepth))"
        )

        Task.detached { [weak self] in
            var result = AlignmentDataProvider.ConsensusFASTAResult(sequence: "", headerStart: nil)
            do {
                result = try await provider.fetchConsensus(
                    chromosome: bamChromosome,
                    start: expandedStart,
                    end: expandedEnd,
                    mode: mode,
                    minMapQ: mapQFilter,
                    minBaseQ: baseQFilter,
                    minDepth: minDepth,
                    excludeFlags: excludeFlags,
                    useAmbiguity: useAmbiguity,
                    showDeletions: true,
                    showInsertions: false
                )
                if result.sequence.isEmpty, bamChromosome != region.chromosome {
                    let fallback = try await provider.fetchConsensus(
                        chromosome: region.chromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        mode: mode,
                        minMapQ: mapQFilter,
                        minBaseQ: baseQFilter,
                        minDepth: minDepth,
                        excludeFlags: excludeFlags,
                        useAmbiguity: useAmbiguity,
                        showDeletions: true,
                        showInsertions: false
                    )
                    if !fallback.sequence.isEmpty {
                        logger.info(
                            "fetchConsensusAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'"
                        )
                        result = fallback
                    }
                }
            } catch {
                logger.error("fetchConsensusAsync: Failed to fetch consensus: \(error)")
            }

            let consensus = result.sequence
            let headerStart = result.headerStart

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    guard thisGeneration == viewer.consensusFetchGeneration else {
                        logger.info("fetchConsensusAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.consensusFetchGeneration))")
                        return
                    }
                    // Determine the actual start position of the consensus output.
                    // The FASTA header (e.g., ">chr:101-200") tells us the 1-based start.
                    // If the header start matches our requested start, all is well.
                    // If it differs, samtools clipped to the data range and we must use
                    // the actual start to avoid a positional shift in rendering.
                    let actualStart: Int
                    if let headerStart {
                        actualStart = headerStart
                        if headerStart != expandedStart {
                            logger.warning(
                                "fetchConsensusAsync: Header start (\(headerStart)) differs from requested start (\(expandedStart)) — using header value"
                            )
                        }
                    } else {
                        actualStart = expandedStart
                    }

                    let expectedLength = expandedEnd - expandedStart
                    if !consensus.isEmpty && consensus.count != expectedLength {
                        logger.warning(
                            "fetchConsensusAsync: Consensus length (\(consensus.count)) differs from expected (\(expectedLength)) for region \(expandedRegion.description)"
                        )
                    }

                    if consensus.isEmpty {
                        viewer.cachedConsensusSequence = nil
                    } else {
                        // Normalize to the requested window so consensus and reference rows
                        // always span identical genomic widths in the viewport.
                        viewer.cachedConsensusSequence = viewer.normalizedConsensusSequence(
                            consensus,
                            sourceStart: actualStart,
                            targetStart: expandedStart,
                            targetEnd: expandedEnd
                        )
                    }
                    viewer.cachedConsensusRegion = GenomicRegion(
                        chromosome: expandedRegion.chromosome,
                        start: expandedStart,
                        end: expandedEnd
                    )
                    viewer.cachedConsensusOptionsSignature = optionsSignature
                    viewer.isFetchingConsensus = false
                    logger.info(
                        "fetchConsensusAsync: Cached consensus sourceStart=\(actualStart) sourceLength=\(consensus.count) normalizedLength=\(viewer.cachedConsensusSequence?.count ?? 0) headerStart=\(headerStart.map(String.init) ?? "nil")"
                    )
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    /// Draws consensus sequence row below the coverage strip.
    private func drawConsensusTrack(
        sequenceString: String?,
        region: GenomicRegion?,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect
    ) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("Consensus" as NSString).draw(
            at: CGPoint(x: 4, y: rect.minY + 2),
            withAttributes: labelAttrs
        )

        guard let sequenceString,
              let region,
              region.chromosome == frame.chromosome else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            return
        }

        guard let slice = visibleSequenceSlice(
            sequenceString: sequenceString,
            cachedRegion: region,
            frame: frame
        ) else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            return
        }

        let scale = frame.scale
        let inset = frame.leadingInset
        if inset > 0 {
            context.saveGState()
            let clipRect = CGRect(
                x: inset,
                y: rect.minY,
                width: max(0, bounds.width - inset),
                height: rect.height
            )
            context.clip(to: clipRect)
        }

        defer {
            if inset > 0 {
                context.restoreGState()
            }
        }

        if scale < showLettersThreshold {
            drawBasesWithLetters(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: rect,
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            )
        } else if scale < showLineThreshold {
            // Zoomed out: render as simple colored blocks aggregated by base runs.
            drawColoredBlocks(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: rect
            )
        } else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
        }
    }

    /// Fetches aligned reads asynchronously from samtools for the visible region.
    /// Uses the same generation counter pattern as other fetch methods.
    /// AlignmentDataProvider.fetchReads() is async, so we use Task.detached to avoid
    /// cooperative executor issues (see MEMORY.md), then return via GCD main queue.
    private func fetchReadsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard !alignmentDataProviders.isEmpty else { return }

        readFetchGeneration += 1
        let thisGeneration = readFetchGeneration
        isFetchingReads = true
        readFetchStartTime = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let currentScale = viewController?.referenceFrame?.scale
            ?? (Double(max(visibleSpan, 1)) / max(Double(max(bounds.width, 1)), 1.0))
        let tier = ReadTrackRenderer.zoomTier(scale: currentScale)
        let expandAmount: Int
        switch tier {
        case .coverage:
            expandAmount = max(10_000, visibleSpan * 2)
        case .packed:
            expandAmount = max(20_000, visibleSpan * 2)
        case .base:
            expandAmount = max(20_000, visibleSpan * 2)
        }
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = alignmentDataProviders
        // Translate reference chromosome name to BAM chromosome name (e.g., MN908947 → MN908947.3)
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = minMapQSetting
        let excludeFlags = excludeFlagsSetting
        let readGroupFilter = selectedReadGroupsSetting
        let maxReadsPerTrack: Int = limitReadRowsSetting ? 250_000 : Int.max

        logger.info("fetchReadsAsync: gen=\(thisGeneration), Fetching reads for \(expandedRegion.description) (BAM chrom: \(bamChromosome), tier: \(String(describing: tier)), minMAPQ: \(mapQFilter), maxReads/track: \(maxReadsPerTrack), flags: 0x\(String(excludeFlags, radix: 16)))")

        Task.detached { [weak self] in
            var allReads: [AlignedRead] = []
            for (_, provider) in providers {
                do {
                    var reads = try await provider.fetchReads(
                        chromosome: bamChromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        excludeFlags: excludeFlags,
                        minMapQ: mapQFilter,
                        maxReads: maxReadsPerTrack,
                        readGroups: readGroupFilter
                    )
                    if reads.isEmpty, bamChromosome != region.chromosome {
                        let fallbackReads = try await provider.fetchReads(
                            chromosome: region.chromosome,
                            start: expandedStart,
                            end: expandedEnd,
                            excludeFlags: excludeFlags,
                            minMapQ: mapQFilter,
                            maxReads: maxReadsPerTrack,
                            readGroups: readGroupFilter
                        )
                        if !fallbackReads.isEmpty {
                            logger.info("fetchReadsAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'")
                            reads = fallbackReads
                        }
                    }
                    allReads.append(contentsOf: reads)
                } catch {
                    logger.error("fetchReadsAsync: Failed to fetch reads: \(error)")
                }
            }

            let count = allReads.count
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    guard thisGeneration == viewer.readFetchGeneration else {
                        logger.info("fetchReadsAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.readFetchGeneration))")
                        return
                    }
                    viewer.cachedAlignedReads = allReads
                    viewer.cachedReadRegion = expandedRegion
                    viewer.isFetchingReads = false
                    viewer.readFetchStartTime = nil
                    logger.info("fetchReadsAsync: Cached \(count) reads")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    /// Fetches genotype data asynchronously for the visible region.
    /// Queries the VariantDatabase for per-sample genotype calls to populate the genotype track.
    /// Uses the same generation counter pattern as other fetch methods.
    private static let genotypeFetchQueue = DispatchQueue(label: "com.lungfish.genotypeFetch", qos: .userInitiated)

    private func fetchGenotypesAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        let variantTrackIds = bundle.variantTrackIds
        guard !variantTrackIds.isEmpty else { return }

        genotypeFetchGeneration += 1
        let thisGeneration = genotypeFetchGeneration
        isFetchingGenotypes = true
        let fetchStart = Date()

        // Query a tight viewport-centered window for genotypes.
        // Using a large expanded window with LIMIT can starve the visible viewport
        // at dense loci (first-N rows may all be outside what the user can see).
        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = min(10_000, max(1_000, visibleSpan / 2))
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)
        let displayState = sampleDisplayState

        let aliasMapSnapshot = variantChromosomeAliasMap
        let trackChromosomeMapSnapshot = variantTrackChromosomeMap

        // Capture bundle URL and track info for background thread
        let bundleURL = bundle.url

        logger.info("fetchGenotypesAsync: gen=\(thisGeneration), Fetching genotypes for \(expandedRegion.description)")

        Self.genotypeFetchQueue.async { [weak self] in
            var allSites: [VariantSite] = []
            var variantDBByTrackId: [String: VariantDatabase] = [:]
            var sampleNames: [String] = []
            var sampleNameSet = Set<String>()
            var sampleMetadata: [String: [String: String]] = [:]

            for trackId in variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                let dbURL = bundleURL.appendingPathComponent(dbPath)
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }

                do {
                    let db = try VariantDatabase(url: dbURL)
                    variantDBByTrackId[trackId] = db
                    let availableChromosomes = trackChromosomeMapSnapshot[trackId] ?? Set(db.allChromosomes())
                    let queryChromosomes = resolveVariantChromosomeCandidates(
                        requestedChromosome: region.chromosome,
                        availableChromosomes: availableChromosomes,
                        aliasMap: aliasMapSnapshot
                    )
                    var regionData: [(variant: VariantDatabaseRecord, genotypes: [GenotypeRecord])] = []
                    var resolvedChromosome = region.chromosome
                    for queryChrom in queryChromosomes {
                        let queried = db.genotypesInRegion(
                            chromosome: queryChrom,
                            start: expandedRegion.start,
                            end: expandedRegion.end,
                            limit: 5_000
                        )
                        if !queried.isEmpty {
                            regionData = queried
                            resolvedChromosome = queryChrom
                            break
                        }
                    }
                    if resolvedChromosome != region.chromosome {
                        logger.info(
                            "fetchGenotypesAsync: Track \(trackId, privacy: .public) resolved chromosome '\(region.chromosome, privacy: .public)' -> '\(resolvedChromosome, privacy: .public)'"
                        )
                    }

                    // For multi-reference / multi-source VCF imports, keep only samples that
                    // have data on this chromosome so unrelated source files don't clutter rows.
                    let chromosomeScopedSamples = db.sampleNames(chromosome: resolvedChromosome)
                    let effectiveSamples = chromosomeScopedSamples.isEmpty ? db.sampleNames() : chromosomeScopedSamples
                    let effectiveSampleSet = Set(effectiveSamples)
                    for name in effectiveSamples where sampleNameSet.insert(name).inserted {
                        sampleNames.append(name)
                    }
                    for entry in db.allSampleMetadata() where effectiveSampleSet.contains(entry.name) {
                        var merged = sampleMetadata[entry.name] ?? [:]
                        merged.merge(entry.metadata) { current, _ in current }
                        sampleMetadata[entry.name] = merged
                    }

                    for (variant, genotypes) in regionData {
                        var gtMap: [String: GenotypeDisplayCall] = [:]
                        var afMap: [String: Double] = [:]
                        for gt in genotypes {
                            let call = classifyGenotype(gt)
                            gtMap[gt.sampleName] = call
                            if let af = alleleFraction(from: gt.alleleDepths) {
                                afMap[gt.sampleName] = af
                            }
                        }
                        allSites.append(VariantSite(
                            position: variant.position,
                            ref: variant.ref,
                            alt: variant.alt,
                            variantType: variant.variantType,
                            genotypes: gtMap,
                            sampleAlleleFractions: afMap,
                            databaseRowId: variant.id,
                            variantID: variant.variantID,
                            sourceTrackId: trackId
                        ))
                    }
                } catch {
                    logger.error("fetchGenotypesAsync: Failed for track \(trackId): \(error.localizedDescription)")
                }
            }

            // Enrich variant sites with CSQ impact data (batch query)
            enrichSitesWithCSQImpact(&allSites, variantDatabasesByTrackId: variantDBByTrackId)

            let visibleOrderedSamples = displayState.visibleSamples(from: sampleNames, metadata: sampleMetadata)
            var sampleDisplayNames: [String: String] = [:]

            // Layer 1: DB display_name column
            for (_, db) in variantDBByTrackId {
                for (name, displayName) in db.allDisplayNames() {
                    sampleDisplayNames[name] = displayName
                }
            }

            // Layer 2: displayNameField metadata lookup (overrides DB)
            let displayField = displayState.displayNameField?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let field = displayField, !field.isEmpty {
                for sampleName in visibleOrderedSamples {
                    if let label = sampleMetadata[sampleName]?[field]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !label.isEmpty {
                        sampleDisplayNames[sampleName] = label
                    }
                }
            }

            // Layer 3: Explicit per-sample overrides (highest priority)
            for (name, override) in displayState.sampleDisplayNameOverrides {
                sampleDisplayNames[name] = override
            }

            let displayData = GenotypeDisplayData(
                sampleNames: visibleOrderedSamples,
                sites: allSites,
                region: expandedRegion
            )
            let siteCount = allSites.count

            Self.enqueueMainRunLoop { [weak self] in
                guard let viewer = self else { return }
                guard thisGeneration == viewer.genotypeFetchGeneration else {
                    logger.info("fetchGenotypesAsync: Discarding stale result gen=\(thisGeneration)")
                    return
                }
                let elapsed = Date().timeIntervalSince(fetchStart)
                viewer.cachedGenotypeData = displayData
                viewer.cachedGenotypeSampleDisplayNames = sampleDisplayNames
                viewer.cachedGenotypeRegion = expandedRegion
                viewer.invalidateGutterWidth()
                // Eagerly repopulate frame.leadingInset so draw() uses the correct value
                if let frame = viewer.viewController?.referenceFrame {
                    frame.leadingInset = viewer.variantDataStartX
                }
                viewer.clampGenotypeScrollOffset()
                viewer.isFetchingGenotypes = false
                viewer.invalidateAnnotationTile()
                logger.info("fetchGenotypesAsync: Cached \(siteCount) sites × \(sampleNames.count) samples in \(elapsed, format: .fixed(precision: 3))s")
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
        let maxFetchSize = AppSettings.shared.sequenceFetchCapKb * 1_000
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
                    viewer.cachedCDSCodingContexts = [:]
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
        let inset = frame.leadingInset
        let dataRight = bounds.width - frame.trailingInset
        if inset > 0 || frame.trailingInset > 0 {
            context.saveGState()
            defer { context.restoreGState() }
            let clipRect = CGRect(
                x: inset,
                y: trackY,
                width: max(0, dataRight - inset),
                height: trackHeight
            )
            context.clip(to: clipRect)
        }

        let scale = frame.scale  // bp/pixel
        guard let slice = visibleSequenceSlice(
            sequenceString: sequenceString,
            cachedRegion: region,
            frame: frame
        ) else { return }

        let sequenceRect = CGRect(x: inset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        
        // Draw based on zoom level
        if scale < showLettersThreshold {
            // High zoom: draw individual bases with letters
            drawBasesWithLetters(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: sequenceRect,
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            )
        } else if scale < showLineThreshold {
            // Medium zoom: draw colored blocks
            drawColoredBlocks(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: sequenceRect
            )
        } else {
            // Low zoom: draw simple line
            drawSequenceLine(frame: frame, context: context)
        }
    }
    
    /// Slice of sequence that overlaps the visible viewport.
    private struct VisibleSequenceSlice {
        let sequence: String
        let startPosition: Int
    }

    /// Extracts the visible base window from cached sequence data.
    /// Uses the same overlap logic for both reference and consensus rows.
    private func visibleSequenceSlice(
        sequenceString: String,
        cachedRegion: GenomicRegion,
        frame: ReferenceFrame
    ) -> VisibleSequenceSlice? {
        let viewport = visibleViewportBaseRange(frame: frame)
        let visibleStart = viewport.lowerBound
        let visibleEnd = viewport.upperBound
        guard visibleEnd > visibleStart else { return nil }

        let overlapStart = max(visibleStart, cachedRegion.start)
        let overlapEnd = min(visibleEnd, cachedRegion.end)
        guard overlapEnd > overlapStart else { return nil }

        let offsetInCache = overlapStart - cachedRegion.start
        guard offsetInCache >= 0, offsetInCache < sequenceString.count else { return nil }

        let span = min(overlapEnd - overlapStart, sequenceString.count - offsetInCache)
        guard span > 0 else { return nil }

        let startIndex = sequenceString.index(sequenceString.startIndex, offsetBy: offsetInCache)
        let endIndex = sequenceString.index(startIndex, offsetBy: span)
        return VisibleSequenceSlice(
            sequence: String(sequenceString[startIndex..<endIndex]),
            startPosition: overlapStart
        )
    }

    /// Visible genomic base range using the same rounding semantics across
    /// sequence rendering, consensus rendering, and viewport selection.
    private func visibleViewportBaseRange(frame: ReferenceFrame) -> Range<Int> {
        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        return lower..<upper
    }

    /// Converts a source consensus string into a fixed target genomic window.
    private func normalizedConsensusSequence(
        _ rawSequence: String,
        sourceStart: Int,
        targetStart: Int,
        targetEnd: Int
    ) -> String {
        let targetLength = max(0, targetEnd - targetStart)
        guard targetLength > 0 else { return "" }
        var normalized = Array(repeating: Character("N"), count: targetLength)
        guard !rawSequence.isEmpty else { return String(normalized) }

        let sourceBases = Array(rawSequence)
        let sourceEnd = sourceStart + sourceBases.count
        let overlapStart = max(sourceStart, targetStart)
        let overlapEnd = min(sourceEnd, targetEnd)
        guard overlapEnd > overlapStart else { return String(normalized) }

        let sourceOffset = overlapStart - sourceStart
        let targetOffset = overlapStart - targetStart
        let copyLength = overlapEnd - overlapStart
        for i in 0..<copyLength {
            normalized[targetOffset + i] = sourceBases[sourceOffset + i]
        }
        return String(normalized)
    }

    /// Pixel rect for one genomic base using the frame's exact transform.
    private func baseCellRect(position: Int, frame: ReferenceFrame, rowRect: CGRect) -> CGRect {
        let x = frame.screenPosition(for: Double(position))
        let nextX = frame.screenPosition(for: Double(position + 1))
        return CGRect(
            x: x,
            y: rowRect.minY,
            width: max(1, nextX - x),
            height: rowRect.height
        )
    }

    /// Draws bases with individual letters (high zoom level).
    private func drawBasesWithLetters(
        _ sequence: String,
        startPosition: Int,
        frame: ReferenceFrame,
        context: CGContext,
        rowRect: CGRect,
        font: NSFont
    ) {
        for (index, base) in sequence.enumerated() {
            let position = startPosition + index
            let cellRect = baseCellRect(position: position, frame: frame, rowRect: rowRect)

            // Draw background
            let color = BaseColors.color(for: base)
            context.setFillColor(color.cgColor)
            context.fill(cellRect)
            
            // Draw letter if space permits
            let baseWidth = cellRect.width
            if baseWidth >= 8 {
                let displayChar = isRNAMode && base.uppercased() == "T" ? "U" : String(base).uppercased()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let size = (displayChar as NSString).size(withAttributes: attributes)
                let letterRect = CGRect(
                    x: cellRect.minX + (baseWidth - size.width) / 2,
                    y: rowRect.minY + (rowRect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                (displayChar as NSString).draw(in: letterRect, withAttributes: attributes)
            }
        }
    }
    
    /// Draws colored blocks for bases (medium zoom level).
    private func drawColoredBlocks(
        _ sequence: String,
        startPosition: Int,
        frame: ReferenceFrame,
        context: CGContext,
        rowRect: CGRect
    ) {
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
                    let rect = CGRect(x: x, y: rowRect.minY, width: max(1, width), height: rowRect.height)
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
            let rect = CGRect(x: x, y: rowRect.minY, width: max(1, width), height: rowRect.height)
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
    private var annotationDensityThreshold: Double { AppSettings.shared.densityThresholdBpPerPixel }

    /// Above this threshold (bp/pixel): draw squished (thin, no labels) features
    private var annotationSquishedThreshold: Double { AppSettings.shared.squishedThresholdBpPerPixel }

    /// Maximum annotation rows before showing "+N more" indicator
    private var maxAnnotationRows: Int { AppSettings.shared.maxAnnotationRows }

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
        guard showAnnotations, !annotations.isEmpty else {
            lastAnnotationBottomY = annotationTrackY
            return
        }

        // Clip strictly to the annotation lane so labels/features never overlap sequence track.
        context.saveGState()
        let annotationClipRect = CGRect(
            x: frame.leadingInset,
            y: annotationTrackY,
            width: max(0, CGFloat(frame.pixelWidth) - frame.leadingInset - frame.trailingInset),
            height: max(0, bounds.height - annotationTrackY)
        )
        context.clip(to: annotationClipRect)

        // Render directly in view coordinates to keep annotation rows anchored
        // directly beneath the sequence track.
        let displayAnnotations = filterAnnotationsForDisplay(annotations, frame: frame, context: context)

        guard let displayAnnotations else {
            lastAnnotationBottomY = annotationTrackY
            context.restoreGState()
            return
        }

        renderAnnotationsDirect(displayAnnotations, frame: frame, context: context)

        // Compute annotation track bottom for variant positioning.
        // For expanded mode, drawAnnotationsExpanded sets lastAnnotationBottomY directly
        // (including CDS translation sub-track heights), so only compute here for other modes.
        let scale = frame.scale
        let maxSquishedFeatures = 5_000
        let useDensityMode = scale > annotationDensityThreshold
            || (displayAnnotations.count > maxSquishedFeatures && scale > annotationSquishedThreshold)

        if useDensityMode {
            lastAnnotationBottomY = annotationTrackY + 30 + annotationLabelClearance  // density histogram + label
        } else if scale > annotationSquishedThreshold {
            let (rows, _) = packAnnotationsLayered(displayAnnotations, frame: frame)
            lastAnnotationBottomY = annotationTrackY + CGFloat(rows.count) * 7 + annotationLabelClearance
        }
        // else: expanded mode — lastAnnotationBottomY was set inside drawAnnotationsExpanded

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
        // Use the larger of visibleSpan and sequenceLength for the region threshold
        // to avoid false passes when the view has padding beyond chromosome boundaries.
        let regionThresholdSpan = max(visibleSpan, frame.sequenceLength)
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        } else {
            let minFeatureBp = max(1, Int(scale))
            displayAnnotations = finalAnnotations.filter { annot in
                let span = annot.end - annot.start
                guard span >= minFeatureBp else { return false }
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
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
        let dataWidth = frame.dataPixelWidth
        let inset = frame.leadingInset
        let binCount = max(1, Int(dataWidth))
        let bpPerBin = (frame.end - frame.start) / Double(binCount)

        // Build density histogram with per-type tracking
        var bins = [Int](repeating: 0, count: binCount)
        var binTypeCounts = [[AnnotationType: Int]](repeating: [:], count: binCount)
        for annot in annotations {
            let startBin = max(0, Int((Double(annot.start) - frame.start) / bpPerBin))
            let endBin = min(binCount - 1, Int((Double(annot.end) - frame.start) / bpPerBin))
            guard startBin <= endBin else { continue }
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
        context.fill(CGRect(x: inset, y: y, width: dataWidth, height: trackHeight))

        // Draw density bars colored by dominant annotation type per bin
        for (i, count) in bins.enumerated() {
            guard count > 0 else { continue }
            let barHeight = trackHeight * CGFloat(count) / CGFloat(maxCount)
            let rect = CGRect(x: inset + CGFloat(i), y: y + trackHeight - barHeight, width: 1, height: barHeight)
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
        let labelRect = CGRect(x: inset + 4, y: y + 2, width: dataWidth - 8, height: 14)
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
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(1, endX - startX)
                let boundingRect = CGRect(x: startX, y: y, width: width, height: squishedHeight)

                if annot.isDiscontinuous {
                    // Discontiguous: connector line + block rectangles
                    let midY = y + squishedHeight / 2

                    // Draw connector line through intron regions
                    context.setStrokeColor(colors.fill)
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: startX, y: midY))
                    context.addLine(to: CGPoint(x: endX, y: midY))
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
                    context.setFillColor(colors.fill)
                    context.fill(boundingRect)
                }

                // Draw selection highlight
                if let selected = selectedAnnotation, selected.id == annot.id {
                    drawAnnotationSelectionHighlight(rect: boundingRect, context: context)
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

        // Determine if auto-CDS translation should be rendered beneath CDS annotations.
        let autoCDS = frame.scale < showLettersThreshold
            && cachedBundleSequence != nil
            && cachedSequenceRegion != nil
            && !showTranslationTrack  // don't double-render with manual translation

        // Build sequence provider from cached data (no I/O in draw loop)
        let sequenceProvider: ((Int, Int) -> String?)?
        if autoCDS, let seq = cachedBundleSequence, let region = cachedSequenceRegion {
            sequenceProvider = { start, end in
                let clampedStart = max(region.start, start)
                let clampedEnd = min(region.end, end)
                guard clampedStart < clampedEnd else { return nil }
                let offsetStart = clampedStart - region.start
                let offsetEnd = clampedEnd - region.start
                guard offsetStart >= 0, offsetEnd <= seq.count else { return nil }
                let startIdx = seq.index(seq.startIndex, offsetBy: offsetStart)
                let endIdx = seq.index(seq.startIndex, offsetBy: offsetEnd)
                return String(seq[startIdx..<endIdx])
            }
        } else {
            sequenceProvider = nil
        }

        let cdsTrackH = TranslationTrackRenderer.cdsTrackHeight() + 2

        // First pass: determine which rows contain CDS annotations needing translation sub-tracks.
        // Compute per-row Y offsets with accumulated CDS translation space.
        var rowYOffsets = [CGFloat](repeating: 0, count: rows.count)
        var cumulativeExtra: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            rowYOffsets[rowIndex] = annotationTrackY + CGFloat(rowIndex) * (annotationHeight + annotationRowSpacing) + cumulativeExtra
            if autoCDS {
                let hasCDS = row.contains { $0.type == .cds }
                if hasCDS {
                    cumulativeExtra += cdsTrackH
                }
            }
        }

        // Second pass: draw annotations and CDS translations.
        for (rowIndex, row) in rows.enumerated() {
            let y = rowYOffsets[rowIndex]

            for annot in row {
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(3, endX - startX)

                let colors = cachedColors(for: annot)

                let boundingRect = CGRect(x: startX, y: y, width: width, height: annotationHeight)

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
                    context.setFillColor(colors.fill)
                    context.fill(boundingRect)

                    // Draw border
                    context.setStrokeColor(colors.stroke)
                    context.setLineWidth(1)
                    context.stroke(boundingRect)

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
                        drawStrandArrow(strand: annot.strand, rect: boundingRect, context: context)
                    }
                }

                // Draw selection highlight around the selected annotation
                if let selected = selectedAnnotation, selected.id == annot.id {
                    drawAnnotationSelectionHighlight(rect: boundingRect, context: context)
                }

                // Draw CDS translation beneath CDS annotations in auto mode
                if autoCDS, annot.type == .cds, let provider = sequenceProvider {
                    if cachedCDSTranslations[annot.id] == nil {
                        cachedCDSTranslations[annot.id] = TranslationEngine.translateCDS(
                            annotation: annot,
                            sequenceProvider: provider
                        )
                    }
                    if let result = cachedCDSTranslations[annot.id] {
                        TranslationTrackRenderer.drawCDSTranslation(
                            result: result,
                            frame: frame,
                            context: context,
                            yOffset: y + annotationHeight + 1,
                            colorScheme: translationColorScheme,
                            showStopCodons: translationShowStopCodons
                        )
                    }
                }
            }
        }

        // Update lastAnnotationBottomY to include CDS translation heights
        let totalHeight = CGFloat(rows.count) * (annotationHeight + annotationRowSpacing) + cumulativeExtra
        lastAnnotationBottomY = annotationTrackY + totalHeight + annotationLabelClearance

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

    /// Draws a compact loading badge anchored within a track region.
    private func drawTrackLoadingBadge(context: CGContext, message: String, yOffset: CGFloat) {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = message as NSString
        let textSize = text.size(withAttributes: textAttrs)

        let spinnerSize: CGFloat = 10
        let badgeHeight: CGFloat = 18
        let horizontalPadding: CGFloat = 8
        let badgeWidth = min(
            max(120, spinnerSize + 8 + textSize.width + horizontalPadding * 2),
            max(120, bounds.width - 16)
        )
        let badgeRect = CGRect(
            x: 8,
            y: max(0, yOffset),
            width: badgeWidth,
            height: badgeHeight
        )

        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(0.8)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(badgePath)
        context.drawPath(using: .fillStroke)

        let spinnerRect = CGRect(
            x: badgeRect.minX + horizontalPadding,
            y: badgeRect.midY - spinnerSize / 2,
            width: spinnerSize,
            height: spinnerSize
        )
        context.setStrokeColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: spinnerRect)

        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.8)
        let center = CGPoint(x: spinnerRect.midX, y: spinnerRect.midY)
        let radius = spinnerSize / 2 - 1
        let phase = trackLoadingAnimationPhase
        let sweep: CGFloat = .pi * 1.1
        context.addArc(
            center: center,
            radius: radius,
            startAngle: phase,
            endAngle: phase + sweep,
            clockwise: false
        )
        context.strokePath()

        let textRect = CGRect(
            x: spinnerRect.maxX + 8,
            y: badgeRect.midY - textSize.height / 2,
            width: badgeRect.maxX - spinnerRect.maxX - horizontalPadding - 8,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttrs)
        context.restoreGState()
    }

    /// Draws a hint when zoom level is too low for per-read rendering.
    private func drawReadZoomHint(context: CGContext, yOffset: CGFloat, scale: Double) {
        let threshold = ReadTrackRenderer.coverageThresholdBpPerPx
        let message = "Zoom in to view individual mapped reads (< \(String(format: "%.1f", threshold)) bp/px)"
        let detail = "Current zoom: \(String(format: "%.1f", scale)) bp/px"
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let title = message as NSString
        let subtitle = detail as NSString
        let titleSize = title.size(withAttributes: textAttrs)
        let subtitleSize = subtitle.size(withAttributes: detailAttrs)
        let badgeWidth = min(
            max(220, max(titleSize.width, subtitleSize.width) + 16),
            max(220, bounds.width - 16)
        )
        let badgeHeight: CGFloat = 34
        let badgeRect = CGRect(x: 8, y: max(0, yOffset), width: badgeWidth, height: badgeHeight)

        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(0.8)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        title.draw(
            in: CGRect(
                x: badgeRect.minX + 8,
                y: badgeRect.minY + 6,
                width: badgeRect.width - 16,
                height: titleSize.height
            ),
            withAttributes: textAttrs
        )
        subtitle.draw(
            in: CGRect(
                x: badgeRect.minX + 8,
                y: badgeRect.minY + 18,
                width: badgeRect.width - 16,
                height: subtitleSize.height
            ),
            withAttributes: detailAttrs
        )
        context.restoreGState()
    }

    /// Draws a macOS-style scroll indicator on the right edge of the read track.
    private func drawReadScrollIndicator(
        context: CGContext, clipRect: CGRect,
        contentHeight: CGFloat, scrollOffset: CGFloat
    ) {
        let trackHeight = clipRect.height
        guard trackHeight > 0, contentHeight > trackHeight else { return }

        let indicatorWidth: CGFloat = 6
        let indicatorMinHeight: CGFloat = 20
        let margin: CGFloat = 2

        let fraction = trackHeight / contentHeight
        let indicatorHeight = max(indicatorMinHeight, trackHeight * fraction)
        let scrollFraction = scrollOffset / (contentHeight - trackHeight)
        let indicatorY = clipRect.minY + scrollFraction * (trackHeight - indicatorHeight)

        let indicatorRect = CGRect(
            x: clipRect.maxX - indicatorWidth - margin,
            y: indicatorY,
            width: indicatorWidth,
            height: indicatorHeight
        )

        context.saveGState()
        context.setFillColor(NSColor(white: 0.4, alpha: 0.5).cgColor)
        let path = CGPath(roundedRect: indicatorRect, cornerWidth: indicatorWidth / 2, cornerHeight: indicatorWidth / 2, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
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
            let tintedImage = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSColor.tertiaryLabelColor.withAlphaComponent(0.5).set()
                rect.fill(using: .sourceAtop)
                return true
            }
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
        ensureVisibleViewportSelection(frame: frame)
        let clipInset = frame.leadingInset
        let clipRight = bounds.width - frame.trailingInset
        if clipInset > 0 || frame.trailingInset > 0 {
            context.saveGState()
            defer { context.restoreGState() }
            let clipRect = CGRect(
                x: min(clipInset, bounds.width),
                y: trackY,
                width: max(0, clipRight - clipInset),
                height: trackHeight
            )
            context.clip(to: clipRect)
        }

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

        // Draw annotations if present and enabled
        if showAnnotations && !annotations.isEmpty {
            drawAnnotations(frame: frame, context: context)
        }

        // Draw sequence info header
        drawSequenceInfo(seq, frame: frame, context: context)

        // Draw column selection overlay
        drawColumnSelectionHighlight(frame: frame, context: context)
    }

    /// Draws a Geneious-style column selection highlight spanning the full view height.
    private func drawColumnSelectionHighlight(frame: ReferenceFrame, context: CGContext) {
        guard isUserColumnSelection, let range = selectionRange else { return }

        let startX = frame.screenPosition(for: Double(range.lowerBound))
        let endX = frame.screenPosition(for: Double(range.upperBound))
        let clippedStartX = max(0, startX)
        let clippedEndX = min(bounds.width, endX)
        let width = clippedEndX - clippedStartX
        guard width > 0 else { return }

        context.saveGState()

        // Full-height dark navy column fill (Geneious style)
        let columnRect = CGRect(x: clippedStartX, y: 0, width: width, height: bounds.height)
        context.setFillColor(NSColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 0.40).cgColor)
        context.fill(columnRect)

        // Edge lines at selection boundaries
        context.setStrokeColor(NSColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 0.75).cgColor)
        context.setLineWidth(1)
        if clippedStartX > 0 {
            context.move(to: CGPoint(x: clippedStartX, y: 0))
            context.addLine(to: CGPoint(x: clippedStartX, y: bounds.height))
        }
        if clippedEndX < bounds.width {
            context.move(to: CGPoint(x: clippedEndX, y: 0))
            context.addLine(to: CGPoint(x: clippedEndX, y: bounds.height))
        }
        context.strokePath()

        context.restoreGState()
    }

    /// Draws dark blue overlay highlights on selected reads.
    private func drawSelectedReadHighlights(frame: ReferenceFrame, context: CGContext) {
        guard !selectedReadIDs.isEmpty else { return }

        let metrics = ReadTrackRenderer.layoutMetrics(verticalCompress: verticallyCompressContigSetting)
        let tier = lastRenderedReadTier
        guard tier != .coverage else { return }

        let rowHeight: CGFloat = tier == .base ? metrics.baseReadHeight : metrics.packedReadHeight
        let rY = lastRenderedReadY

        context.saveGState()

        for (row, read) in cachedPackedReads {
            guard selectedReadIDs.contains(read.id) else { continue }

            let startPx = frame.screenPosition(for: Double(read.position))
            let endPx = frame.screenPosition(for: Double(read.alignmentEnd))
            let y = rY + CGFloat(row) * (rowHeight + metrics.rowGap) - readScrollOffset
            let readRect = CGRect(x: startPx, y: y, width: endPx - startPx, height: rowHeight)

            // Dark blue overlay (Geneious style)
            context.setFillColor(NSColor(red: 0.15, green: 0.22, blue: 0.50, alpha: 0.50).cgColor)
            context.fill(readRect)

            // Border
            context.setStrokeColor(NSColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 0.85).cgColor)
            context.setLineWidth(1)
            context.stroke(readRect)
        }

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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Annotation colors from user settings
        let settings = AppSettings.shared
        var typeColors: [AnnotationType: NSColor] = [:]
        for type in AnnotationType.allCases {
            typeColors[type] = settings.annotationColor(for: type)
        }

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

            // Calculate screen coordinates (offset by leadingInset for gutter)
            let rawStartX = frame.leadingInset + CGFloat(interval.start - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(interval.end - visibleStart) * pixelsPerBase
            // Clamp startX to data area start
            let startX = max(frame.leadingInset, rawStartX)
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

    /// Draws a macOS-style selection highlight around the selected annotation.
    ///
    /// Uses a solid rounded rectangle stroke with the system accent color,
    /// following macOS Human Interface Guidelines for content selection.
    private func drawAnnotationSelectionHighlight(rect: CGRect, context: CGContext) {
        context.saveGState()

        let accentColor = NSColor.controlAccentColor
        let highlightRect = rect.insetBy(dx: -1.5, dy: -1.5)
        let cornerRadius: CGFloat = 3
        let path = CGPath(roundedRect: highlightRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Solid rounded stroke with accent color
        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(2)
        context.addPath(path)
        context.strokePath()

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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        context.saveGState()

        // Draw quality overlay for each visible base
        for i in startBase..<min(endBase, qualityScores.count) {
            let x = frame.leadingInset + CGFloat(i - startBase) * pixelsPerBase
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Font sizing based on available space
        let fontSize = min(pixelsPerBase * 0.75, trackHeight * 0.8)
        let showLetters = pixelsPerBase >= 8 && fontSize >= 6
        let font = NSFont.monospacedSystemFont(ofSize: max(6, fontSize), weight: .bold)

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: frame.leadingInset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        for i in startBase..<endBase {
            let x = frame.leadingInset + CGFloat(i - startBase) * pixelsPerBase
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Draw quality overlay BEFORE the base colors so it appears behind
        let trackRect = CGRect(x: frame.leadingInset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        drawQualityOverlay(context: context, sequence: seq, frame: frame, rect: trackRect)

        // Aggregate bases into bins for colored bar display
        let basesPerBin = max(1, Int(frame.scale))

        for binStart in stride(from: startBase, to: endBase, by: basesPerBin) {
            let binEnd = min(binStart + basesPerBin, endBase)
            let x = frame.leadingInset + CGFloat(binStart - startBase) * pixelsPerBase
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Calculate bin size for density display (2 pixels per bin minimum)
        let binSize = max(1, Int(frame.scale * 2))

        // GC content color gradient
        let lowGCColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        let highGCColor = NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)

        for binStart in stride(from: startBase, to: endBase, by: binSize) {
            let binEnd = min(binStart + binSize, endBase)
            let x = frame.leadingInset + CGFloat(binStart - startBase) * pixelsPerBase
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))

        // Calculate the visible portion of the sequence
        let startX = frame.leadingInset + CGFloat(startBase - Int(frame.start)) * pixelsPerBase
        let endX = frame.leadingInset + CGFloat(endBase - Int(frame.start)) * pixelsPerBase
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))
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
            let rawStartX = frame.leadingInset + CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(annotEnd - visibleStart) * pixelsPerBase
            // Clamp startX to data area start
            let startX = max(frame.leadingInset, rawStartX)
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
        let pixelsPerBase = frame.dataPixelWidth / CGFloat(max(1, visibleBases))
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

            let rawStartX = frame.leadingInset + CGFloat(annotStart - visibleStart) * pixelsPerBase
            let endX = frame.leadingInset + CGFloat(annotEnd - visibleStart) * pixelsPerBase
            let startX = max(frame.leadingInset, rawStartX)
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
            postVariantSelectedNotificationIfNeeded(annotation)
            logger.info("Posted annotationSelected notification for '\(annotation.name, privacy: .public)'")
        } else {
            // Post notification with nil to indicate deselection
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: self,
                userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
            )
            NotificationCenter.default.post(name: .variantSelected, object: self, userInfo: nil)
            logger.info("Posted annotationSelected notification (deselection)")
        }
    }

    /// Posts a variant selection notification when the selected annotation is a variant.
    @discardableResult
    private func postVariantSelectedNotificationIfNeeded(_ annotation: SequenceAnnotation) -> Bool {
        guard let result = variantSearchResult(for: annotation) else { return false }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: [NotificationUserInfoKey.searchResult: result]
        )
        return true
    }

    /// Builds a `SearchResult` payload for a variant-like annotation.
    private func variantSearchResult(for annotation: SequenceAnnotation) -> AnnotationSearchIndex.SearchResult? {
        let variantTypes: Set<AnnotationType> = [.snp, .insertion, .deletion, .variation]
        let isVariantByType = variantTypes.contains(annotation.type)
        let isVariantByQualifiers = annotation.qualifiers["variant_row_id"] != nil
            || annotation.qualifiers["variant_type"] != nil
            || annotation.qualifiers["ref"] != nil
            || annotation.qualifiers["alt"] != nil
        guard isVariantByType || isVariantByQualifiers else { return nil }
        guard let chromosome = annotation.chromosome else { return nil }

        let rowId = annotation.qualifiers["variant_row_id"]?.values.first.flatMap { Int64($0) }
        let trackId = annotation.qualifiers["variant_track_id"]?.values.first ?? ""
        let variantType = annotation.qualifiers["variant_type"]?.values.first ?? annotation.type.rawValue
        let ref = annotation.qualifiers["ref"]?.values.first
        let alt = annotation.qualifiers["alt"]?.values.first
        let quality = annotation.qualifiers["quality"]?.values.first.flatMap(Double.init)
        let filter = annotation.qualifiers["filter"]?.values.first
        let sampleCount = annotation.qualifiers["sample_count"]?.values.first.flatMap(Int.init)

        return AnnotationSearchIndex.SearchResult(
            name: annotation.name,
            chromosome: chromosome,
            start: annotation.start,
            end: annotation.end,
            trackId: trackId,
            type: variantType,
            strand: annotation.strand.rawValue,
            ref: ref,
            alt: alt,
            quality: quality,
            filter: filter,
            sampleCount: sampleCount,
            variantRowId: rowId
        )
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

    // MARK: - Gutter Edge Drag

    /// Returns the X position of the gutter right edge, or nil if no genotype rows are showing.
    /// Uses `variantDataStartX` (cached) minus the label-to-data margin.
    private func gutterEdgeX() -> CGFloat? {
        let dataStartX = variantDataStartX
        guard dataStartX > 0 else { return nil }
        return dataStartX - VariantTrackRenderer.sampleLabelToDataMargin
    }

    /// Returns true if the point is within 6px of the gutter right edge and in the genotype area.
    private func isNearGutterEdge(at point: NSPoint) -> Bool {
        guard let edgeX = gutterEdgeX() else { return false }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return false }
        return abs(point.x - edgeX) <= 6
    }

    /// Returns the sample name if the point is within the gutter label area.
    private func sampleNameAtGutterPoint(_ point: NSPoint) -> String? {
        guard let edgeX = gutterEdgeX(),
              point.x < edgeX,
              let genotypeData = filteredVisibleGenotypeData(),
              !genotypeData.sampleNames.isEmpty else { return nil }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return nil }
        let rowH = sampleDisplayState.rowHeight
        guard rowH >= 8 else { return nil }
        let relativeY = point.y - genotypeTopY + genotypeScrollOffset
        let sampleIdx = Int(relativeY / rowH)
        guard sampleIdx >= 0, sampleIdx < genotypeData.sampleNames.count else { return nil }
        return genotypeData.sampleNames[sampleIdx]
    }

    // MARK: - Mouse Selection

    public override func mouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }

        let location = convert(event.locationInWindow, from: nil)

        // Check gutter edge drag FIRST — double-click resets to auto-size
        if isNearGutterEdge(at: location) {
            if event.clickCount == 2 {
                sampleDisplayState.sampleGutterWidthOverride = nil
                invalidateGutterWidth()
                setNeedsDisplay(bounds)
                viewController?.scheduleViewStateSave()
            } else {
                isDraggingGutterEdge = true
            }
            return
        }

        let isDoubleClick = event.clickCount == 2
        let hasCmd = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)

        // 1. Read track click — with Cmd/Shift modifier support for multi-select
        if let read = readAtPoint(location) {
            if hasCmd {
                // Cmd+click: toggle read in/out of selection
                if selectedReadIDs.contains(read.id) {
                    selectedReadIDs.remove(read.id)
                } else {
                    selectedReadIDs.insert(read.id)
                }
            } else if hasShift {
                // Shift+click: add to selection
                selectedReadIDs.insert(read.id)
            } else {
                // Plain click: replace selection with this read
                selectedReadIDs = [read.id]
            }
            NotificationCenter.default.post(
                name: .readSelected,
                object: self,
                userInfo: selectedRead.map { [NotificationUserInfoKey.alignedRead: $0] }
            )
            isSelecting = false
            setNeedsDisplay(bounds)
            updateSelectionStatus()
            return
        }
        // Clear read selection if clicking elsewhere (unless modifier held)
        if !selectedReadIDs.isEmpty && !hasCmd && !hasShift {
            selectedReadIDs.removeAll()
            NotificationCenter.default.post(name: .readSelected, object: self, userInfo: nil)
        }

        // 2. Variant track click — route to variant selection
        if let variant = variantAtPoint(location) {
            selectedAnnotation = variant
            postVariantSelectedNotificationIfNeeded(variant)
            isSelecting = false
            setNeedsDisplay(bounds)
            updateSelectionStatus()
            return
        }

        // 3. Check for annotation click — bundle mode, multi-sequence mode, or single-sequence mode
        if currentReferenceBundle != nil {
            if let annotation = bundleAnnotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
                isSelecting = false
                setNeedsDisplay(bounds)
                updateSelectionStatus()

                if isDoubleClick {
                    showAnnotationPopover(for: annotation, at: CGRect(origin: location, size: CGSize(width: 1, height: 1)))
                }
                return
            }
        } else if isMultiSequenceMode, let state = multiSequenceState {
            for stackedInfo in state.stackedSequences {
                if let annotation = annotationAtPoint(location, forSequence: stackedInfo, frame: frame) {
                    selectedAnnotation = annotation
                    postAnnotationSelectedNotification(annotation)
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
            if let annotation = annotationAtPoint(location) {
                selectedAnnotation = annotation
                postAnnotationSelectedNotification(annotation)
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

        // Clear annotation selection if clicking in annotation area but not on one
        if selectedAnnotation != nil {
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
            }
        }

        // 4. No object hit — begin column selection
        let clickedBase = basePositionAt(x: location.x, frame: frame)
        columnDragStartBase = clickedBase
        isUserColumnSelection = true
        selectionRange = clickedBase..<(clickedBase + 1)
        isSelecting = true
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDraggingGutterEdge {
            let location = convert(event.locationInWindow, from: nil)
            let newWidth = max(40, min(400, location.x))
            sampleDisplayState.sampleGutterWidthOverride = newWidth
            invalidateGutterWidth()
            // Update frame inset immediately so ruler stays in sync
            if let frame = viewController?.referenceFrame {
                frame.leadingInset = variantDataStartX
            }
            setNeedsDisplay(bounds)
            viewController?.enhancedRulerView.needsDisplay = true
            return
        }

        guard isSelecting,
              let frame = viewController?.referenceFrame,
              let dragStart = columnDragStartBase else { return }

        let location = convert(event.locationInWindow, from: nil)
        let currentBase = basePositionAt(x: location.x, frame: frame)

        let lower = min(dragStart, currentBase)
        let upper = max(dragStart, currentBase) + 1
        selectionRange = lower..<upper
        isUserColumnSelection = true

        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    public override func mouseUp(with event: NSEvent) {
        if isDraggingGutterEdge {
            isDraggingGutterEdge = false
            viewController?.scheduleViewStateSave()
            return
        }
        isSelecting = false
        columnDragStartBase = nil
    }

    // MARK: - Right-Click Context Menu

    /// Handles right-click/control-click to show contextual menu
    public override func rightMouseDown(with event: NSEvent) {
        guard let frame = viewController?.referenceFrame else { return }
        let location = convert(event.locationInWindow, from: nil)
        contextMenuGenomicPosition = clampedContextMenuPosition(for: location, frame: frame)

        // Variant context menu takes priority over generic annotation menus.
        let hoveredVariantResult = genotypeTooltipAtPoint(location)?.variantSearchResult
        if let variant = variantAtPoint(location),
           let variantResult = variantSearchResult(for: variant) ?? hoveredVariantResult {
            if selectedAnnotation?.id != variant.id {
                selectedAnnotation = variant
                postAnnotationSelectedNotification(variant)
                setNeedsDisplay(bounds)
            }
            showVariantContextMenu(for: variantResult, at: event)
            return
        } else if let variantResult = hoveredVariantResult {
            showVariantContextMenu(for: variantResult, at: event)
            return
        }

        // Check if right-clicking on an annotation — bundle mode, multi-sequence mode, or single-sequence mode
        var clickedAnnotation: SequenceAnnotation?
        if currentReferenceBundle != nil {
            clickedAnnotation = bundleAnnotationAtPoint(location)
        } else if isMultiSequenceMode, let state = multiSequenceState {
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

    /// Creates and shows context menu for variant actions.
    private func showVariantContextMenu(for result: AnnotationSearchIndex.SearchResult, at event: NSEvent) {
        let menu = NSMenu(title: "Variant")

        let viewVariantItem = NSMenuItem(title: "View Variant in Table", action: #selector(viewVariantInTableAction(_:)), keyEquivalent: "")
        viewVariantItem.target = self
        viewVariantItem.representedObject = result
        menu.addItem(viewVariantItem)

        let viewGenotypesItem = NSMenuItem(title: "View Genotypes at Site", action: #selector(viewVariantGenotypesAction(_:)), keyEquivalent: "")
        viewGenotypesItem.target = self
        viewGenotypesItem.representedObject = result
        menu.addItem(viewGenotypesItem)

        menu.addItem(NSMenuItem.separator())
        addCenterViewMenuItem(to: menu)

        if selectionRange != nil {
            let zoomItem = NSMenuItem(title: "Zoom to Visible Region", action: #selector(zoomToSelectionAction(_:)), keyEquivalent: "")
            zoomItem.target = self
            menu.addItem(zoomItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Creates and shows context menu for annotation
    private func showAnnotationContextMenu(for annotation: SequenceAnnotation, at event: NSEvent) {
        let menu = NSMenu(title: "Annotation")

        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyAnnotationName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        copyMenu.addItem(copyNameItem)

        let copyCoordItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyAnnotationCoordinates(_:)), keyEquivalent: "")
        copyCoordItem.target = self
        copyCoordItem.representedObject = annotation
        copyMenu.addItem(copyCoordItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copyAnnotationSequence(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        copyMenu.addItem(copySeqItem)

        let copyCompItem = NSMenuItem(title: "Copy Complement", action: #selector(copyAnnotationComplement(_:)), keyEquivalent: "")
        copyCompItem.target = self
        copyCompItem.representedObject = annotation
        copyMenu.addItem(copyCompItem)

        let copyRevCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyAnnotationReverseComplement(_:)), keyEquivalent: "")
        copyRevCompItem.target = self
        copyRevCompItem.representedObject = annotation
        copyMenu.addItem(copyRevCompItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyFASTAItem = NSMenuItem(title: "Copy as FASTA", action: #selector(copyAnnotationAsFASTA(_:)), keyEquivalent: "")
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        copyMenu.addItem(copyFASTAItem)

        if annotation.type == .cds {
            let copyProteinItem = NSMenuItem(title: "Copy Translation as FASTA", action: #selector(copyAnnotationTranslationAsFASTA(_:)), keyEquivalent: "")
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            copyMenu.addItem(copyProteinItem)
        }

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        // --- Extract ---
        let extractItem = NSMenuItem(title: "Extract Sequence\u{2026}", action: #selector(extractAnnotationSequence(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        addCenterViewMenuItem(to: menu)

        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showAnnotationInInspector(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        menu.addItem(NSMenuItem.separator())

        // --- Edit/Delete ---
        let editItem = NSMenuItem(title: "Edit Annotation\u{2026}", action: #selector(editAnnotationAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = annotation
        menu.addItem(editItem)

        let deleteItem = NSMenuItem(title: "Delete Annotation", action: #selector(deleteAnnotationAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Creates and shows context menu for visible-region actions.
    private func showSelectionContextMenu(at event: NSEvent) {
        let menu = NSMenu(title: "Visible Region")

        // Copy visible region bases.
        let copyItem = NSMenuItem(title: "Copy Visible Region", action: #selector(copySelectionAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        // Extraction actions
        addSelectionExtractionMenuItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        // View navigation helper.
        addCenterViewMenuItem(to: menu)

        let zoomItem = NSMenuItem(title: "Zoom to Visible Region", action: #selector(zoomToSelectionAction(_:)), keyEquivalent: "")
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

        addCenterViewMenuItem(to: menu)

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

    private func clampedContextMenuPosition(for location: NSPoint, frame: ReferenceFrame) -> Int {
        let dataMinX = frame.leadingInset
        let dataMaxX = max(dataMinX, min(bounds.width - frame.trailingInset, bounds.width))
        let clampedX = max(dataMinX, min(location.x, dataMaxX))
        let genomicPos = Int(frame.genomicPosition(for: clampedX).rounded(.down))
        let maxPos = max(0, frame.sequenceLength - 1)
        return max(0, min(maxPos, genomicPos))
    }

    private func addCenterViewMenuItem(to menu: NSMenu) {
        guard let position = contextMenuGenomicPosition else { return }
        let item = NSMenuItem(title: "Center View Here", action: #selector(centerViewHereAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: position)
        menu.addItem(item)
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

    @objc private func centerViewHereAction(_ sender: NSMenuItem?) {
        guard let frame = viewController?.referenceFrame else { return }

        let targetPos: Int
        if let encodedPos = sender?.representedObject as? NSNumber {
            targetPos = encodedPos.intValue
        } else if let cachedPos = contextMenuGenomicPosition {
            targetPos = cachedPos
        } else {
            return
        }

        let maxPos = max(0, frame.sequenceLength - 1)
        let clampedPos = max(0, min(maxPos, targetPos))
        let windowLength = max(1.0, frame.end - frame.start)

        var newStart = Double(clampedPos) - (windowLength / 2.0)
        var newEnd = newStart + windowLength

        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), windowLength)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }

        frame.start = newStart
        frame.end = newEnd
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
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

    @objc private func viewVariantInTableAction(_ sender: NSMenuItem?) {
        guard let result = sender?.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: [
                NotificationUserInfoKey.searchResult: result,
                NotificationUserInfoKey.variantSelectionMode: "calls",
            ]
        )
    }

    @objc private func viewVariantGenotypesAction(_ sender: NSMenuItem?) {
        guard let result = sender?.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        NotificationCenter.default.post(
            name: .variantSelected,
            object: self,
            userInfo: [
                NotificationUserInfoKey.searchResult: result,
                NotificationUserInfoKey.variantSelectionMode: "genotypes",
            ]
        )
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
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        guard let bases = fetchAnnotationBases(annotation) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bases, forType: .string)
        logger.info("Copied \(bases.count) bases from annotation '\(annotation.name)' to clipboard")
    }

    @objc private func copyAnnotationCoordinates(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        let chrom = annotation.chromosome ?? viewController?.referenceFrame?.chromosome ?? ""
        let coordString = "\(chrom):\(annotation.start)-\(annotation.end)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coordString, forType: .string)
        logger.info("Copied coordinates '\(coordString)' to clipboard")
    }

    @objc private func copyAnnotationComplement(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        guard let bases = fetchAnnotationBases(annotation) else {
            NSSound.beep()
            return
        }
        let complement = complementString(bases)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(complement, forType: .string)
        logger.info("Copied \(complement.count) bases (complement) from annotation '\(annotation.name)' to clipboard")
    }

    @objc private func copyAnnotationReverseComplement(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        guard let bases = fetchAnnotationBases(annotation) else {
            NSSound.beep()
            return
        }
        let revComp = reverseComplementString(bases)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(revComp, forType: .string)
        logger.info("Copied \(revComp.count) bases (reverse complement) from annotation '\(annotation.name)' to clipboard")
    }

    @objc private func zoomToAnnotationAction(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        zoomToAnnotation(annotation)
    }

    /// Zooms the viewer to show the given annotation (callable from notification handlers).
    func zoomToAnnotation(_ annotation: SequenceAnnotation) {
        guard let frame = viewController?.referenceFrame else { return }
        let annotationLength = max(1, annotation.end - annotation.start)
        let padding = max(10, Double(annotationLength) * 0.05)
        let windowLength = Double(annotationLength) + 2 * padding
        let maxPixelWidth = max(1, frame.pixelWidth)
        let insetPixels = min(Double(navigationLeadingInsetPixels), Double(maxPixelWidth - 1))
        let leadingInsetBP = windowLength * insetPixels / Double(maxPixelWidth)
        var newStart = Double(annotation.start) - padding - leadingInsetBP
        var newEnd = newStart + windowLength
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), windowLength)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }
        frame.start = newStart
        frame.end = newEnd
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        viewController?.enhancedRulerView.setNeedsDisplay(viewController?.enhancedRulerView.bounds ?? .zero)
        viewController?.updateStatusBar()
    }

    /// Copies the annotation's raw sequence to the clipboard (callable from notification handlers).
    func copyAnnotationSequenceImpl(_ annotation: SequenceAnnotation) {
        guard let bases = fetchAnnotationBases(annotation) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bases, forType: .string)
        logger.info("Copied \(bases.count) bases from annotation '\(annotation.name)' to clipboard")
    }

    /// Copies the current selection's reverse complement to the clipboard.
    /// Called by the Sequence > Reverse Complement menu item.
    func performReverseComplement() {
        guard let seq = sequence,
              let range = selectionRange else {
            NSSound.beep()
            return
        }
        let start = max(0, range.lowerBound)
        let end = min(seq.length, range.upperBound)
        let selectedBases = seq[start..<end]
        let revComp = reverseComplementString(selectedBases)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(revComp, forType: .string)
        logger.info("Reverse complement: copied \(end - start) bases to clipboard")
    }

    /// Copies the annotation's reverse complement to the clipboard (callable from notification handlers).
    func copyAnnotationReverseComplementImpl(_ annotation: SequenceAnnotation) {
        guard let bases = fetchAnnotationBases(annotation) else {
            NSSound.beep()
            return
        }
        let revComp = reverseComplementString(bases)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(revComp, forType: .string)
        logger.info("Copied \(revComp.count) bases (reverse complement) from annotation '\(annotation.name)' to clipboard")
    }

    /// Returns the complement of a DNA string.
    private func complementString(_ s: String) -> String {
        String(TranslationEngine.reverseComplement(String(s.reversed())))
    }

    /// Returns the reverse complement of a DNA string.
    private func reverseComplementString(_ s: String) -> String {
        TranslationEngine.reverseComplement(s)
    }

    /// Fetches the full sequence bases for an annotation, handling multi-block and bundle-backed sequences.
    private func fetchAnnotationBases(_ annotation: SequenceAnnotation) -> String? {
        if let bundle = currentReferenceBundle {
            // Bundle mode: fetch each interval and concatenate
            let chrom = annotation.chromosome ?? bundle.chromosomeNames.first ?? ""
            var allBases = ""
            for interval in annotation.intervals {
                let start = max(0, interval.start)
                let end = interval.end
                let region = GenomicRegion(chromosome: chrom, start: start, end: end)
                if let bases = try? bundle.fetchSequenceSync(region: region) {
                    allBases += bases
                }
            }
            return allBases.isEmpty ? nil : allBases
        } else if let seq = sequence {
            // Single-sequence mode
            var allBases = ""
            for interval in annotation.intervals {
                let start = max(0, interval.start)
                let end = min(seq.length, interval.end)
                guard start < end else { continue }
                allBases += seq[start..<end]
            }
            return allBases.isEmpty ? nil : allBases
        }
        return nil
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

        // scrollingDeltaY/X give raw physical device direction (up/right = positive).
        // Respect per-axis app settings and fall back to system preference when requested.
        let settings = AppSettings.shared
        let systemSign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let verticalSign: CGFloat = {
            switch settings.verticalScrollDirection {
            case .system: return systemSign
            case .natural: return -1
            case .traditional: return 1
            }
        }()
        let horizontalSign: CGFloat = {
            switch settings.horizontalScrollDirection {
            case .system: return systemSign
            case .natural: return -1
            case .traditional: return 1
            }
        }()

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            // Zoom with Cmd+scroll or Option+scroll
            // Convention: physical scroll/swipe up = zoom in, regardless of natural scrolling.
            if event.scrollingDeltaY > 0 {
                viewController?.zoomIn()
            } else if event.scrollingDeltaY < 0 {
                viewController?.zoomOut()
            }
            invalidateAnnotationTile()
        } else {
            // Check if mouse is in genotype row area for vertical scrolling
            let location = convert(event.locationInWindow, from: nil)
            let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
            let hasLoadedGenotypeRows = {
                guard sampleDisplayState.showGenotypeRows,
                      let data = filteredVisibleGenotypeData() else { return false }
                return !data.sampleNames.isEmpty && !data.sites.isEmpty
            }()
            let inGenotypeArea = showVariants && hasLoadedGenotypeRows
                && location.y >= genotypeTopY && location.y <= bounds.height

            if inGenotypeArea && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                // Vertical scroll in genotype area — scroll through sample rows
                let rowH = sampleDisplayState.rowHeight
                guard rowH > 0 else { return }
                let maxOffset = maxGenotypeScrollOffset(frame: frame)
                let deltaScale: CGFloat = event.hasPreciseScrollingDeltas
                    ? 1.0
                    : max(8, rowH * 0.9)
                let proposedOffset = max(0, min(maxOffset, genotypeScrollOffset + verticalSign * event.scrollingDeltaY * deltaScale))
                guard abs(proposedOffset - genotypeScrollOffset) > 0.1 else { return }
                genotypeScrollOffset = proposedOffset
                setNeedsDisplay(bounds)
                viewController?.updateStatusBar()
                viewController?.scheduleViewStateSave()
                return
            }

            // Check if mouse is in read track area for vertical scrolling
            let rY = lastRenderedReadY
            let readAvailHeight = bounds.height - rY
            let readVisibleHeight = min(readContentHeight, max(readAvailHeight, maxReadTrackHeight))
            let inReadArea = !cachedPackedReads.isEmpty && readContentHeight > readVisibleHeight
                && location.y >= rY && location.y < rY + readVisibleHeight

            if inReadArea && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                // Vertical scroll in read track area — scroll through read rows
                let maxScroll = max(0, readContentHeight - readVisibleHeight)
                let deltaScale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
                let proposedOffset = max(0, min(maxScroll, readScrollOffset + verticalSign * event.scrollingDeltaY * deltaScale))
                guard abs(proposedOffset - readScrollOffset) > 0.1 else { return }
                readScrollOffset = proposedOffset
                setNeedsDisplay(bounds)
                return
            }

            if abs(event.scrollingDeltaX) > 0 || abs(event.scrollingDeltaY) > 0 {
                if hasLoadedGenotypeRows && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                    // Avoid converting pure vertical scroll into horizontal pan in genotype mode.
                    return
                }
            }

            // Horizontal pan — update coordinates immediately, coalesce redraw at 60fps
            let panScale = event.hasPreciseScrollingDeltas ? 1.0 : 2.0
            let panAmount = Double(horizontalSign * event.scrollingDeltaX) * frame.scale * panScale
            frame.pan(by: panAmount)

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

    /// Converts screen X coordinate to base position using the reference frame.
    /// Works in both single-sequence mode and bundle mode.
    private func basePositionAt(x: CGFloat, frame: ReferenceFrame) -> Int {
        let pos = Int(frame.genomicPosition(for: x))
        return max(0, min(frame.sequenceLength - 1, pos))
    }

    /// Selects the entire sequence
    public func selectAll() {
        let length: Int
        if let seq = sequence {
            length = seq.length
        } else if let frame = viewController?.referenceFrame {
            length = frame.sequenceLength
        } else {
            return
        }
        selectionRange = 0..<length
        isUserColumnSelection = true
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Selects the currently visible viewport range.
    ///
    /// Used as a fallback for extraction and copy flows when no explicit range is set.
    public func selectVisibleRegion() {
        guard let frame = viewController?.referenceFrame else { return }
        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        selectionRange = lower..<upper
        selectionStartBase = lower
        isSelecting = false
        isUserColumnSelection = false
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Clears the current selection (column, read, and annotation).
    public func clearSelection() {
        selectionRange = nil
        selectionStartBase = nil
        isUserColumnSelection = false
        columnDragStartBase = nil
        if !selectedReadIDs.isEmpty {
            selectedReadIDs.removeAll()
            NotificationCenter.default.post(name: .readSelected, object: self, userInfo: nil)
        }
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    /// Copies the selected sequence to the clipboard
    public func copySelectionToClipboard() {
        guard let seq = sequence else {
            NSSound.beep()
            return
        }
        if selectionRange == nil {
            selectVisibleRegion()
        }
        guard let range = selectionRange else {
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

    /// Updates the status bar with selection info.
    private func updateSelectionStatus() {
        var parts: [String] = []

        if isUserColumnSelection, let range = selectionRange {
            let length = range.upperBound - range.lowerBound
            parts.append("Selected: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)")
        } else if let range = selectionRange {
            let length = range.upperBound - range.lowerBound
            parts.append("Visible: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)")
        }

        if !selectedReadIDs.isEmpty {
            let count = selectedReadIDs.count
            parts.append("\(count) read\(count == 1 ? "" : "s") selected")
        }

        let selectionText = parts.isEmpty ? nil : parts.joined(separator: " | ")
        viewController?.statusBar.update(
            position: viewController?.statusBar.positionLabel.stringValue,
            selection: selectionText,
            scale: viewController?.referenceFrame?.scale ?? 1.0
        )
    }

    // MARK: - Hover Tooltip (Bundle Mode)

    /// Tracking area for mouse hover detection
    private var viewerTrackingArea: NSTrackingArea?

    /// Custom hover tooltip for fast-appearing tooltips.
    private lazy var hoverTooltip: HoverTooltipView = {
        let tip = HoverTooltipView()
        addSubview(tip)
        return tip
    }()

    /// Currently hovered annotation (to avoid redundant tooltip updates)
    private var hoveredAnnotation: SequenceAnnotation?

    /// Last hovered genotype cell (sampleIndex, siteIndex) for tooltip caching.
    private var lastHoveredGenotypeCell: (sampleIdx: Int, siteIdx: Int)?
    /// Last tooltip text used for hovered genotype cell.
    private var lastHoveredGenotypeTooltipText: String?
    /// Last status text used for hovered genotype cell.
    private var lastHoveredGenotypeStatusText: String?

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

        // --- Gutter edge cursor ---
        if isNearGutterEdge(at: location) {
            NSCursor.resizeLeftRight.set()
            hoverTooltip.hide()
            return
        }

        // --- Sample name gutter hover tooltip ---
        if let sampleName = sampleNameAtGutterPoint(location) {
            let displayName = cachedGenotypeSampleDisplayNames[sampleName] ?? sampleName
            hoverTooltip.show(text: displayName, near: location, in: self)
            NSCursor.arrow.set()
            return
        }

        // --- Genotype cell hit-testing ---
        if let genotypeTooltip = genotypeTooltipAtPoint(location) {
            hoveredAnnotation = nil
            hoverTooltip.show(text: genotypeTooltip.tooltip, near: location, in: self)
            if let controller = viewController {
                controller.statusBar.update(
                    position: controller.statusBar.positionLabel.stringValue,
                    selection: genotypeTooltip.statusText,
                    scale: controller.referenceFrame?.scale ?? 1.0
                )
            }
            NSCursor.crosshair.set()
            return
        }
        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil

        // --- Read hit-testing ---
        if let read = readAtPoint(location) {
            if hoveredRead?.id != read.id {
                hoveredRead = read
                hoveredAnnotation = nil
                let tooltip = readTooltipText(for: read)
                hoverTooltip.show(text: tooltip, near: location, in: self)

                if let controller = viewController {
                    let strandStr = read.isReverse ? "(-)" : "(+)"
                    let hoverSummary = "Read: \(read.name) \(strandStr) • MAPQ \(read.mapq) • \(read.referenceLength) bp"
                    controller.statusBar.update(
                        position: controller.statusBar.positionLabel.stringValue,
                        selection: hoverSummary,
                        scale: controller.referenceFrame?.scale ?? 1.0
                    )
                }
            }
            NSCursor.pointingHand.set()
            return
        }
        hoveredRead = nil

        // --- Coverage hit-testing (coverage tier) ---
        if let coverageHit = coverageDepthAtPoint(location) {
            hoveredAnnotation = nil
            let tooltip = "Depth\n\(coverageHit.chromosome):\(coverageHit.position + 1)\nDepth: \(coverageHit.depth)x"
            hoverTooltip.show(text: tooltip, near: location, in: self)

            if let controller = viewController {
                controller.statusBar.update(
                    position: controller.statusBar.positionLabel.stringValue,
                    selection: "Depth: \(coverageHit.depth)x at \(coverageHit.chromosome):\(coverageHit.position + 1)",
                    scale: controller.referenceFrame?.scale ?? 1.0
                )
            }
            NSCursor.crosshair.set()
            return
        }

        // --- Annotation hit-testing ---
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

                hoverTooltip.show(text: tooltip, near: location, in: self)

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
                hoverTooltip.hide()
                updateSelectionStatus()
            } else {
                hoverTooltip.hide()
            }
            NSCursor.arrow.set()
        }
    }

    // MARK: - Genotype Tooltip

    /// Result of genotype cell hit-testing.
    private struct GenotypeTooltipResult {
        let tooltip: String
        let statusText: String
        let variantSearchResult: AnnotationSearchIndex.SearchResult?
    }

    /// Hit-tests the genotype row area and returns a tooltip if the mouse is over a genotype cell.
    private func genotypeTooltipAtPoint(_ point: NSPoint) -> GenotypeTooltipResult? {
        guard showVariants,
              cachedSampleCount > 0,
              let genotypeData = filteredVisibleGenotypeData(),
              !genotypeData.sampleNames.isEmpty,
              !genotypeData.sites.isEmpty,
              let frame = viewController?.referenceFrame else { return nil }

        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return nil }

        let rowH = sampleDisplayState.rowHeight
        guard rowH > 0 else { return nil }

        // Determine which sample row the mouse is over
        let relativeY = point.y - genotypeTopY + genotypeScrollOffset
        let sampleIdx = Int(relativeY / rowH)
        guard sampleIdx >= 0, sampleIdx < genotypeData.sampleNames.count else { return nil }
        let sampleName = genotypeData.sampleNames[sampleIdx]

        // Determine which variant site the mouse is over
        var bestSiteIdx: Int?
        var sampleMatchedSiteIdx: Int?
        for (idx, site) in genotypeData.sites.enumerated() {
            let siteEnd = site.position + max(1, site.ref.count)
            let startPx = frame.screenPosition(for: Double(site.position))
            let endPx = frame.screenPosition(for: Double(siteEnd))
            let cellWidth = max(1, endPx - startPx)
            if point.x >= startPx && point.x < startPx + cellWidth {
                if site.genotypes[sampleName] != nil {
                    sampleMatchedSiteIdx = idx
                    break
                }
                bestSiteIdx = bestSiteIdx ?? idx
                continue
            }
            // For very zoomed out views where variants are sub-pixel, find closest
            if cellWidth <= 1 && abs(Double(site.position) - frame.genomicPosition(for: point.x)) < frame.scale {
                if site.genotypes[sampleName] != nil {
                    sampleMatchedSiteIdx = idx
                    break
                }
                bestSiteIdx = bestSiteIdx ?? idx
                continue
            }
        }
        if sampleMatchedSiteIdx != nil {
            bestSiteIdx = sampleMatchedSiteIdx
        }

        guard let siteIdx = bestSiteIdx else {
            lastHoveredGenotypeCell = nil
            lastHoveredGenotypeTooltipText = nil
            return nil
        }

        // Avoid recomputing tooltip if we're still on the same cell
        if let last = lastHoveredGenotypeCell, last.sampleIdx == sampleIdx, last.siteIdx == siteIdx {
            if let tooltipText = lastHoveredGenotypeTooltipText {
                return GenotypeTooltipResult(
                    tooltip: tooltipText,
                    statusText: lastHoveredGenotypeStatusText ?? "",
                    variantSearchResult: genotypeVariantSearchResult(for: genotypeData.sites[siteIdx], frame: frame)
                )
            }
        }
        lastHoveredGenotypeCell = (sampleIdx, siteIdx)

        let site = genotypeData.sites[siteIdx]

        // No tooltip for samples without data at this site
        guard let call = site.genotypes[sampleName] else {
            lastHoveredGenotypeTooltipText = nil
            lastHoveredGenotypeStatusText = nil
            return nil
        }

        // Build tooltip
        let callLabel: String
        switch call {
        case .homRef:  callLabel = "0/0 (Hom Ref)"
        case .het:     callLabel = "0/1 (Het)"
        case .homAlt:  callLabel = "1/1 (Hom Alt)"
        case .noCall:  callLabel = "./. (No Call)"
        }

        // Position display (1-based for user)
        let displayPos = site.position + 1
        let chrom = viewController?.referenceFrame?.chromosome ?? "?"
        var tooltip = "\(sampleName)\n\(callLabel)\n\(chrom):\(displayPos.formatted()) \(site.ref) \u{2192} \(site.alt) (\(site.variantType))"

        if let vid = site.variantID, !vid.isEmpty, vid != "." {
            tooltip += "\nID: \(vid)"
        }

        // Show pre-computed impact data from VariantSite (enriched during fetch)
        if let shortAA = site.shortAAChange {
            tooltip += "\nAA: \(shortAA)"
        }
        if let impact = site.impact, impact != .unknown {
            tooltip += "\nImpact: \(impact.rawValue.lowercased())"
        }
        if let gene = site.geneSymbol {
            tooltip += "\nGene: \(gene)"
        }
        if let sampleAF = site.sampleAlleleFractions[sampleName] {
            tooltip += String(format: "\nSample AF: %.3f", sampleAF)
        }
        if let aaChange = site.aminoAcidChange, site.shortAAChange == nil {
            // Only show long form if shortAAChange wasn't populated
            tooltip += "\nAA Change: \(aaChange)"
        }

        var hasExplicitConsequence = false

        // Enrich with additional CSQ/INFO fields from variant database
        if let rowId = site.databaseRowId,
           let handles = viewController?.annotationSearchIndex?.variantDatabaseHandles {
            let db = site.sourceTrackId.flatMap { trackId in
                handles.first(where: { $0.trackId == trackId })?.db
            } ?? handles.first?.db
            let infoDict = db?.infoValues(variantId: rowId) ?? [:]
            if !infoDict.isEmpty {
                // Show CSQ consequence string (more detailed than the impact classification)
                if let consequence = infoDict["CSQ_Consequence"] {
                    tooltip += "\nConsequence: \(consequence)"
                    hasExplicitConsequence = true
                }
                if let codons = infoDict["CSQ_Codons"] {
                    tooltip += "\nCodons: \(codons)"
                }
                if let af = infoDict["AF"] {
                    tooltip += "\nAF: \(af)"
                }
            }
        }

        // Fallback codon-level consequence prediction from CDS annotations when CSQ/ANN
        // annotations are missing or incomplete.
        let predictedImpacts = predictedCDSConsequences(
            for: site,
            sampleName: sampleName,
            genotypeData: genotypeData
        )
        if !predictedImpacts.isEmpty {
            if !hasExplicitConsequence {
                tooltip += "\nConsequence: \(predictedImpacts.joined(separator: "; "))"
            } else {
                tooltip += "\nCDS impact(s): \(predictedImpacts.joined(separator: "; "))"
            }
        }

        let aaStatus = site.shortAAChange.map { " \u{2022} \($0)" } ?? ""
        let statusText = "Genotype: \(sampleName) \u{2022} \(callLabel) \u{2022} \(chrom):\(displayPos.formatted()) \(site.ref)\u{2192}\(site.alt)\(aaStatus)"
        lastHoveredGenotypeTooltipText = tooltip
        lastHoveredGenotypeStatusText = statusText
        return GenotypeTooltipResult(
            tooltip: tooltip,
            statusText: statusText,
            variantSearchResult: genotypeVariantSearchResult(for: site, frame: frame)
        )
    }

    private func genotypeVariantSearchResult(
        for site: VariantSite,
        frame: ReferenceFrame
    ) -> AnnotationSearchIndex.SearchResult? {
        let fallbackName = "\(frame.chromosome)_\(site.position + 1)"
        return AnnotationSearchIndex.SearchResult(
            name: site.variantID?.isEmpty == false ? site.variantID! : fallbackName,
            chromosome: frame.chromosome,
            start: site.position,
            end: site.position + max(1, site.ref.count),
            trackId: site.sourceTrackId ?? "",
            type: site.variantType,
            strand: ".",
            ref: site.ref,
            alt: site.alt,
            quality: nil,
            filter: nil,
            sampleCount: nil,
            variantRowId: site.databaseRowId
        )
    }

    /// Predicts coding consequences from overlapping CDS annotations for a site/sample.
    ///
    /// Used as a fallback when CSQ/ANN consequence fields are unavailable or incomplete.
    /// Includes same-codon compound substitutions by applying all alt-carrying calls from
    /// the current sample within the codon before translating.
    private func predictedCDSConsequences(
        for site: VariantSite,
        sampleName: String,
        genotypeData: GenotypeDisplayData
    ) -> [String] {
        guard let frame = viewController?.referenceFrame else { return [] }
        let chrom = frame.chromosome
        let siteStart = site.position
        let siteEnd = site.position + max(1, site.ref.count)

        let overlappingCDS = cachedBundleAnnotations.filter { annotation in
            annotation.type == .cds
                && (annotation.chromosome ?? chrom) == chrom
                && annotation.overlaps(start: siteStart, end: siteEnd)
        }
        guard !overlappingCDS.isEmpty else { return [] }

        var rendered = Set<String>()
        var details: [String] = []

        for cds in overlappingCDS {
            guard let context = cdsCodingContext(for: cds) else { continue }
            let impactedCodingIndices = context.codingGenomePositions.enumerated().compactMap { pair -> Int? in
                let genomicPos = pair.element
                return (genomicPos >= siteStart && genomicPos < siteEnd) ? pair.offset : nil
            }
            guard let firstCodingIndex = impactedCodingIndices.first else { continue }

            // Indels are classified directly by frame-preservation.
            if site.ref.count != site.alt.count {
                let delta = site.alt.count - site.ref.count
                let effect = (abs(delta) % 3 == 0) ? "inframe_indel" : "frameshift_variant"
                let label = "\(cds.name): \(effect)"
                if rendered.insert(label).inserted {
                    details.append(label)
                }
                continue
            }

            guard firstCodingIndex >= context.phaseOffset else { continue }
            let codonStart = context.phaseOffset + ((firstCodingIndex - context.phaseOffset) / 3) * 3
            guard codonStart + 2 < context.codingBases.count,
                  codonStart + 2 < context.codingGenomePositions.count else { continue }

            let refCodonChars = Array(context.codingBases[codonStart...(codonStart + 2)])
            let codonGenomePositions = Array(context.codingGenomePositions[codonStart...(codonStart + 2)])
            var altCodonChars = refCodonChars

            for (codonOffset, genomicPos) in codonGenomePositions.enumerated() {
                guard let codonVariant = genotypeData.sites.first(where: {
                    $0.position == genomicPos &&
                    ($0.genotypes[sampleName] == .het || $0.genotypes[sampleName] == .homAlt)
                }) else { continue }
                guard codonVariant.ref.count == 1,
                      let firstAltBase = codonVariant.alt.split(separator: ",").first?.first else { continue }
                let orientedBase: Character
                if context.annotation.strand == .reverse {
                    orientedBase = complementDNA(firstAltBase)
                } else {
                    orientedBase = Character(String(firstAltBase).uppercased())
                }
                altCodonChars[codonOffset] = orientedBase
            }

            let refCodon = String(refCodonChars).uppercased()
            let altCodon = String(altCodonChars).uppercased()
            guard refCodon.count == 3, altCodon.count == 3 else { continue }

            let refAA = context.codonTable.translate(refCodon)
            let altAA = context.codonTable.translate(altCodon)
            let aminoIndex = ((codonStart - context.phaseOffset) / 3) + 1

            let effect: String
            if refAA == altAA {
                effect = "synonymous_variant"
            } else if altAA == "*" {
                effect = "stop_gained"
            } else if refAA == "*" {
                effect = "stop_lost"
            } else {
                effect = "missense_variant"
            }

            let label = "\(cds.name): \(effect) \(refAA)\(aminoIndex)\(altAA)"
            if rendered.insert(label).inserted {
                details.append(label)
            }
        }

        return details
    }

    /// Predicts variant consequence/AA-change for table rows when CSQ/ANN INFO is absent.
    ///
    /// This variant-only fallback does not require per-sample genotype context.
    func fallbackConsequenceForTableVariant(
        chromosome: String,
        position: Int,
        ref: String,
        alt: String
    ) -> (consequence: String?, aaChange: String?) {
        let refChromosome = referenceChromosomeName(forVariantDBChromosome: chromosome)
        let siteStart = position
        let siteEnd = position + max(1, ref.count)
        let firstAlt = alt.split(separator: ",").first.map(String.init) ?? alt
        guard !firstAlt.isEmpty else { return (nil, nil) }

        let overlappingCDS = cachedBundleAnnotations.filter { annotation in
            annotation.type == .cds
                && (annotation.chromosome ?? refChromosome) == refChromosome
                && annotation.overlaps(start: siteStart, end: siteEnd)
        }
        guard !overlappingCDS.isEmpty else { return (nil, nil) }

        var consequences: [String] = []
        var aaChanges: [String] = []
        var seenConsequence = Set<String>()
        var seenAA = Set<String>()

        let altChars = Array(firstAlt.uppercased())
        for cds in overlappingCDS {
            guard let context = cdsCodingContext(for: cds) else { continue }
            let impactedCodingIndices = context.codingGenomePositions.enumerated().compactMap { pair -> Int? in
                let genomicPos = pair.element
                return (genomicPos >= siteStart && genomicPos < siteEnd) ? pair.offset : nil
            }
            guard let firstCodingIndex = impactedCodingIndices.first else { continue }

            if ref.count != firstAlt.count {
                let delta = firstAlt.count - ref.count
                let effect = (abs(delta) % 3 == 0) ? "inframe_indel" : "frameshift_variant"
                let label = "\(cds.name): \(effect)"
                if seenConsequence.insert(label).inserted {
                    consequences.append(label)
                }
                continue
            }

            guard firstCodingIndex >= context.phaseOffset else { continue }
            let codonStart = context.phaseOffset + ((firstCodingIndex - context.phaseOffset) / 3) * 3
            guard codonStart + 2 < context.codingBases.count,
                  codonStart + 2 < context.codingGenomePositions.count else { continue }

            let refCodonChars = Array(context.codingBases[codonStart...(codonStart + 2)])
            let codonGenomePositions = Array(context.codingGenomePositions[codonStart...(codonStart + 2)])
            var altCodonChars = refCodonChars

            for (codonOffset, genomicPos) in codonGenomePositions.enumerated() {
                let altIndex = genomicPos - siteStart
                guard altIndex >= 0, altIndex < altChars.count else { continue }
                var replacement = altChars[altIndex]
                if context.annotation.strand == .reverse {
                    replacement = complementDNA(replacement)
                }
                altCodonChars[codonOffset] = replacement
            }

            let refCodon = String(refCodonChars).uppercased()
            let altCodon = String(altCodonChars).uppercased()
            guard refCodon.count == 3, altCodon.count == 3 else { continue }

            let refAA = context.codonTable.translate(refCodon)
            let altAA = context.codonTable.translate(altCodon)
            let aaIndex = ((codonStart - context.phaseOffset) / 3) + 1

            let effect: String
            if refAA == altAA {
                effect = "synonymous_variant"
            } else if altAA == "*" {
                effect = "stop_gained"
            } else if refAA == "*" {
                effect = "stop_lost"
            } else {
                effect = "missense_variant"
            }

            let aaChange = "\(refAA)\(aaIndex)\(altAA)"
            let consequence = "\(cds.name): \(effect) \(aaChange)"
            if seenConsequence.insert(consequence).inserted {
                consequences.append(consequence)
            }
            if seenAA.insert(aaChange).inserted {
                aaChanges.append(aaChange)
            }
        }

        let consequenceText = consequences.isEmpty ? nil : consequences.joined(separator: "; ")
        let aaText = aaChanges.isEmpty ? nil : aaChanges.joined(separator: ", ")
        return (consequenceText, aaText)
    }

    /// Returns a cached CDS coding context, building one from the local sequence cache when needed.
    private func cdsCodingContext(for annotation: SequenceAnnotation) -> CDSCodingContext? {
        if let cached = cachedCDSCodingContexts[annotation.id] {
            return cached
        }
        guard annotation.type == .cds else { return nil }
        let sequenceProvider: (Int, Int) -> String? = { [weak self] start, end in
            guard let self else { return nil }
            guard start < end else { return nil }

            // Fast path: use cached sequence window if it fully covers the request.
            if let sequence = self.cachedBundleSequence, let region = self.cachedSequenceRegion,
               start >= region.start, end <= region.end {
                let offsetStart = start - region.start
                let offsetEnd = end - region.start
                guard offsetStart >= 0, offsetEnd <= sequence.count else { return nil }
                let startIdx = sequence.index(sequence.startIndex, offsetBy: offsetStart)
                let endIdx = sequence.index(sequence.startIndex, offsetBy: offsetEnd)
                return String(sequence[startIdx..<endIdx])
            }

            // Fallback path: pull the exact interval directly from bundle-backed FASTA.
            guard let bundle = self.currentReferenceBundle,
                  let frame = self.viewController?.referenceFrame else { return nil }
            let fetchRegion = GenomicRegion(chromosome: frame.chromosome, start: start, end: end)
            return try? bundle.fetchSequenceSync(region: fetchRegion)
        }

        let sortedIntervals = annotation.intervals.sorted { $0.start < $1.start }
        var exonSequences: [(sequence: String, interval: AnnotationInterval)] = []
        for interval in sortedIntervals {
            guard let seq = sequenceProvider(interval.start, interval.end), !seq.isEmpty else { continue }
            exonSequences.append((seq, interval))
        }
        guard !exonSequences.isEmpty else { return nil }

        let concatenated = exonSequences.map(\.sequence).joined()
        let codingSequence: String
        if annotation.strand == .reverse {
            codingSequence = reverseComplementString(concatenated)
        } else {
            codingSequence = concatenated
        }

        var codingPositions: [Int] = []
        codingPositions.reserveCapacity(codingSequence.count)
        for (seq, interval) in exonSequences {
            for idx in 0..<seq.count {
                codingPositions.append(interval.start + idx)
            }
        }
        if annotation.strand == .reverse {
            codingPositions.reverse()
        }

        let codingBases = Array(codingSequence.uppercased())
        guard codingBases.count == codingPositions.count else { return nil }

        let context = CDSCodingContext(
            annotation: annotation,
            codingBases: codingBases,
            codingGenomePositions: codingPositions,
            phaseOffset: exonSequences.first?.interval.phase ?? 0,
            codonTable: .standard
        )
        cachedCDSCodingContexts[annotation.id] = context
        return context
    }

    /// DNA complement for a nucleotide base.
    private func complementDNA(_ base: Character) -> Character {
        switch Character(String(base).uppercased()) {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default: return Character(String(base).uppercased())
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredAnnotation = nil
        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil
        hoverTooltip.hide()
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

        // Don't hit-test annotations in the variant track area below them
        if showVariants && point.y >= variantTrackY { return nil }

        // Only hit-test in squished and expanded modes (not density histogram)
        guard scale <= annotationDensityThreshold else { return nil }

        // Use the same annotation pool rendered in drawBundleContent (variants are separate track).
        let bundlePool = cachedBundleAnnotations

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
        let regionThresholdSpan = max(visibleSpan, frame.sequenceLength)
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = textFiltered.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        } else {
            let minFeatureBp = max(1, Int(scale))
            displayAnnotations = textFiltered.filter { annot in
                let span = annot.end - annot.start
                guard span >= minFeatureBp else { return false }
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
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

    /// Hit-tests a variant glyph in the variant summary/rows area.
    /// Returns the closest visible variant within a small horizontal tolerance.
    private func variantAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard showVariants,
              let frame = viewController?.referenceFrame,
              !filteredVisibleVariantAnnotations.isEmpty else { return nil }

        let hitTop = variantTrackY
        let hitBottom = max(
            variantTrackY + max(effectiveSummaryBarHeight, sampleDisplayState.rowHeight),
            variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap + sampleDisplayState.rowHeight
        )
        guard point.y >= hitTop, point.y <= hitBottom else { return nil }

        let tolerance: CGFloat = 6
        var best: (annotation: SequenceAnnotation, distance: CGFloat)?
        for annotation in filteredVisibleVariantAnnotations {
            let startX = frame.screenPosition(for: Double(annotation.start))
            let endX = frame.screenPosition(for: Double(max(annotation.start + 1, annotation.end)))
            let minX = min(startX, endX)
            let maxX = max(startX, endX)
            let dx: CGFloat
            if point.x < minX {
                dx = minX - point.x
            } else if point.x > maxX {
                dx = point.x - maxX
            } else {
                dx = 0
            }
            guard dx <= tolerance else { continue }
            if best == nil || dx < best!.distance {
                best = (annotation, dx)
            }
        }
        return best?.annotation
    }

    // MARK: - Read Hit-Testing

    /// Returns the aligned read at the given point, if any, using the cached packed layout.
    ///
    /// Hit-tests against the packed read rows from the most recent draw pass.
    /// Returns nil in coverage tier (individual reads not visible).
    private func readAtPoint(_ point: NSPoint) -> AlignedRead? {
        guard !cachedPackedReads.isEmpty,
              let frame = viewController?.referenceFrame else { return nil }

        let tier = lastRenderedReadTier
        guard tier != .coverage else { return nil }

        let metrics = ReadTrackRenderer.layoutMetrics(verticalCompress: verticallyCompressContigSetting)
        let rowHeight: CGFloat
        switch tier {
        case .coverage: return nil
        case .packed: rowHeight = metrics.packedReadHeight + metrics.rowGap
        case .base: rowHeight = metrics.baseReadHeight + metrics.rowGap
        }

        let rY = lastRenderedReadY

        // Check if point is in the visible read track area
        let availableHeight = bounds.height - rY
        let visibleHeight = min(readContentHeight, max(availableHeight, maxReadTrackHeight))
        guard point.y >= rY && point.y < rY + visibleHeight else { return nil }

        // Account for scroll offset: convert screen Y to content Y
        let contentY = (point.y - rY) + readScrollOffset
        let rowIndex = Int(contentY / rowHeight)

        // Find reads in this row and check horizontal position
        for (row, read) in cachedPackedReads where row == rowIndex {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let readWidth = max(ReadTrackRenderer.minReadPixels, endPx - startPx)

            if point.x >= startPx && point.x <= startPx + readWidth {
                return read
            }
        }

        return nil
    }

    /// Builds a tooltip string for an aligned read.
    private func readTooltipText(for read: AlignedRead) -> String {
        let strandStr = read.isReverse ? "(-)" : "(+)"
        let cigarStr = read.cigarString
        let mapqStr = "MAPQ: \(read.mapq)"
        let posStr = "\(read.chromosome):\(read.position + 1)-\(read.alignmentEnd)"
        let lenStr = "\(read.referenceLength) bp"

        var lines = [
            read.name,
            "\(strandStr) \(posStr) (\(lenStr))",
            "\(mapqStr) • CIGAR: \(cigarStr.prefix(40))\(cigarStr.count > 40 ? "..." : "")",
        ]

        if read.isPaired {
            let pairStatus = read.isProperPair ? "Proper pair" : "Improper pair"
            let mateStr: String
            if let mateChr = read.mateChromosome, let matePos = read.matePosition {
                mateStr = "\(mateChr):\(matePos + 1)"
            } else {
                mateStr = "unmapped"
            }
            lines.append("\(pairStatus) • Mate: \(mateStr)")
            if read.insertSize != 0 {
                lines.append("Insert size: \(read.insertSize)")
            }
        }

        if let rg = read.readGroup {
            lines.append("Read group: \(rg)")
        }

        if read.isSecondary { lines.append("Secondary alignment") }
        if read.isSupplementary { lines.append("Supplementary alignment") }
        if read.isDuplicate { lines.append("PCR/optical duplicate") }

        return lines.joined(separator: "\n")
    }

    /// Returns coverage depth at a point for coverage-tier hover interactions.
    private func coverageDepthAtPoint(_ point: NSPoint) -> (chromosome: String, position: Int, depth: Int)? {
        guard let frame = viewController?.referenceFrame else { return nil }
        guard !cachedDepthPoints.isEmpty else { return nil }

        let rY = lastRenderedCoverageY
        let h = coverageStripHeight
        guard point.y >= rY, point.y <= rY + h else { return nil }

        let pos = Int(frame.genomicPosition(for: point.x))
        let depth = ReadTrackRenderer.depthAt(position: pos, in: cachedDepthPoints)
        return (frame.chromosome, pos, depth)
    }
}

// MARK: - Genotype Classification (free function for background-thread use)

/// Classifies a GenotypeRecord into a display call category.
/// This is a module-level free function (not a method on @MainActor SequenceViewerView)
/// so it can be safely called from GCD background queues.
private func classifyGenotype(_ gt: GenotypeRecord) -> GenotypeDisplayCall {
    GenotypeDisplayCall.classify(genotype: gt.genotype, allele1: gt.allele1, allele2: gt.allele2)
}

/// Returns alt allele fraction from VCF AD string ("ref,alt,...") when available.
private func alleleFraction(from alleleDepths: String?) -> Double? {
    guard let alleleDepths else { return nil }
    let depths = alleleDepths
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard depths.count >= 2 else { return nil }
    let total = depths.reduce(0, +)
    guard total > 0 else { return nil }
    let altDepth = depths.dropFirst().reduce(0, +)
    return min(1.0, max(0.0, Double(altDepth) / Double(total)))
}

/// Returns an allele fraction from common INFO AF keys.
///
/// Supports scalar and comma-delimited values by using the first parsable value.
private func alleleFractionFromINFO(_ info: [String: String]) -> Double? {
    let candidateKeys = ["AF", "af", "VAF", "FREQ", "ALT_FREQ", "MLEAF"]
    for key in candidateKeys {
        guard let raw = info[key], !raw.isEmpty else { continue }
        let first = raw.split(separator: ",", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        if let value = Double(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(1.0, max(0.0, value))
        }
    }
    return nil
}

/// Enriches variant sites with amino acid impact data from CSQ/INFO fields.
/// Called on the background genotype fetch queue — does NOT access @MainActor state.
private func enrichSitesWithCSQImpact(
    _ sites: inout [VariantSite],
    variantDatabasesByTrackId: [String: VariantDatabase]
) {
    guard !sites.isEmpty, !variantDatabasesByTrackId.isEmpty else { return }

    // Group row IDs by source track to avoid cross-database row-id collisions.
    var rowIdsByTrack: [String: [Int64]] = [:]
    for site in sites {
        guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { continue }
        rowIdsByTrack[trackId, default: []].append(rowId)
    }
    guard !rowIdsByTrack.isEmpty else { return }

    // Batch-fetch INFO maps per track/database.
    var infoMapByTrack: [String: [Int64: [String: String]]] = [:]
    for (trackId, rowIds) in rowIdsByTrack {
        guard let db = variantDatabasesByTrackId[trackId], !rowIds.isEmpty else { continue }
        infoMapByTrack[trackId] = db.batchInfoValues(variantIds: rowIds)
    }

    // Enrich each site
    for i in sites.indices {
        guard let trackId = sites[i].sourceTrackId else { continue }
        guard let rowId = sites[i].databaseRowId,
              let info = infoMapByTrack[trackId]?[rowId] else { continue }

        let consequence = info["CSQ_Consequence"] ?? info["ANN_Consequence"] ?? info["Consequence"]
        let csqImpact = info["CSQ_IMPACT"] ?? info["ANN_IMPACT"] ?? info["IMPACT"] ?? info["impact"]
        let symbol = info["CSQ_SYMBOL"] ?? info["CSQ_Gene"] ?? info["ANN_Gene"] ?? info["GENE"] ?? info["Gene"]
        let aminoAcids = info["CSQ_Amino_acids"] ?? info["ANN_AA_pos_len"]
        let proteinPos = info["CSQ_Protein_position"] ?? info["Protein_position"]

        // Classify impact from CSQ fields
        if consequence != nil || csqImpact != nil {
            sites[i].impact = VariantImpact.fromCSQ(impact: csqImpact, consequence: consequence)
            sites[i].geneSymbol = symbol

            // Build amino-acid changes from possibly multi-entry CSQ strings.
            if let aasRaw = aminoAcids {
                let aaEntries = splitMultiInfoValue(aasRaw)
                let posEntries = splitMultiInfoValue(proteinPos ?? "")
                var longChanges: [String] = []
                var shortChanges: [String] = []
                for (idx, aaEntry) in aaEntries.enumerated() {
                    guard aaEntry.contains("/") else { continue }
                    let parts = aaEntry.split(separator: "/", omittingEmptySubsequences: false)
                    guard parts.count == 2 else { continue }
                    let refAA = String(parts[0])
                    let altAA = String(parts[1])
                    let pos = idx < posEntries.count ? posEntries[idx] : (proteinPos ?? "")
                    let normalizedPos = pos.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedPos.isEmpty else { continue }
                    longChanges.append("p.\(refAA)\(normalizedPos)\(altAA)")
                    if refAA.count == 1 && altAA.count == 1 {
                        shortChanges.append("\(refAA)\(normalizedPos)\(altAA)")
                    } else {
                        let refSingle = threeLetterToSingleAA(refAA)
                        let altSingle = threeLetterToSingleAA(altAA)
                        if let r = refSingle, let a = altSingle {
                            shortChanges.append("\(r)\(normalizedPos)\(a)")
                        }
                    }
                }
                let dedupLong = orderedUniqueStrings(longChanges)
                let dedupShort = orderedUniqueStrings(shortChanges)
                if !dedupLong.isEmpty {
                    sites[i].aminoAcidChange = dedupLong.joined(separator: ", ")
                }
                if !dedupShort.isEmpty {
                    sites[i].shortAAChange = dedupShort.joined(separator: ", ")
                }
            }
        } else {
            // No CSQ annotation — classify by variant type heuristic
            if sites[i].variantType == "INS" || sites[i].variantType == "DEL" {
                let refLen = sites[i].ref.count
                let altLen = sites[i].alt.count
                if abs(refLen - altLen) % 3 != 0 {
                    sites[i].impact = .frameshift
                }
            }
        }

        // Haploid/viral callsets often provide AF in INFO without per-sample AD.
        // Fill missing per-sample AF from INFO so genotype row intensity reflects AF.
        if let variantAF = alleleFractionFromINFO(info), !sites[i].genotypes.isEmpty {
            for (sample, call) in sites[i].genotypes where call == .het || call == .homAlt {
                if sites[i].sampleAlleleFractions[sample] == nil {
                    sites[i].sampleAlleleFractions[sample] = variantAF
                }
            }
        }
    }
}

/// Converts a 3-letter amino acid code to its single-letter equivalent.
private func threeLetterToSingleAA(_ code: String) -> String? {
    let map: [String: String] = [
        "Ala": "A", "Arg": "R", "Asn": "N", "Asp": "D", "Cys": "C",
        "Gln": "Q", "Glu": "E", "Gly": "G", "His": "H", "Ile": "I",
        "Leu": "L", "Lys": "K", "Met": "M", "Phe": "F", "Pro": "P",
        "Ser": "S", "Thr": "T", "Trp": "W", "Tyr": "Y", "Val": "V",
        "Sec": "U", "Pyl": "O", "Ter": "*",
    ]
    // Already single-letter?
    if code.count == 1 { return code }
    return map[code]
}

/// Splits an INFO field value containing comma/ampersand-delimited items.
private func splitMultiInfoValue(_ raw: String) -> [String] {
    raw.split(whereSeparator: { $0 == "," || $0 == "&" })
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Returns unique strings preserving first-seen order.
private func orderedUniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    result.reserveCapacity(values.count)
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
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

        let pixelsPerBase = frame.dataPixelWidth / CGFloat(visibleRange)

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
                let x = frame.leadingInset + CGFloat((pos - frame.start)) * pixelsPerBase

                // Draw minor tick at bottom (clip to data area)
                if x >= frame.leadingInset && x <= bounds.width - frame.trailingInset {
                    context.move(to: CGPoint(x: x, y: bounds.maxY - minorTickHeight))
                    context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                    context.strokePath()
                }
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
            let x = frame.leadingInset + CGFloat((pos - frame.start)) * pixelsPerBase

            // Draw major tick at bottom (clip to data area)
            if x >= frame.leadingInset && x <= bounds.width - frame.trailingInset {
                context.move(to: CGPoint(x: x, y: bounds.maxY - majorTickHeight))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                context.strokePath()
            }

            // Draw label centered above tick
            let label = formatPosition(Int(pos))
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let labelX = x - labelSize.width / 2

            // Only draw label if it fits and doesn't overlap with previous label
            let labelPadding: CGFloat = 4
            if labelX > lastLabelEndX + labelPadding &&
               labelX >= frame.leadingInset &&
               labelX + labelSize.width <= bounds.width - frame.trailingInset {
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

    /// Horizontal inset in pixels reserved for sample name gutter.
    /// When > 0, genomic content is rendered to the right of this inset.
    /// All coordinate mapping (screenPosition, genomicPosition, scale) respects this.
    public var leadingInset: CGFloat = 0

    /// Default trailing inset to keep content from touching the right edge.
    public static let defaultTrailingInset: CGFloat = 12

    /// Trailing inset in pixels to keep content from touching the right edge.
    public var trailingInset: CGFloat = 0

    /// Width of the data area in pixels (total width minus leading and trailing insets).
    public var dataPixelWidth: CGFloat {
        max(1, CGFloat(pixelWidth) - leadingInset - trailingInset)
    }

    /// Base pairs per pixel (in the data area, excluding leading inset)
    public var scale: Double {
        (end - start) / Double(dataPixelWidth)
    }

    public init(chromosome: String, start: Double, end: Double, pixelWidth: Int, sequenceLength: Int = Int.max) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.pixelWidth = max(1, pixelWidth)
        self.sequenceLength = sequenceLength
    }

    /// Converts a screen X coordinate to genomic position.
    /// Accounts for leadingInset: screen positions in the inset area map to positions before `start`.
    public func genomicPosition(for screenX: CGFloat) -> Double {
        start + Double(screenX - leadingInset) * scale
    }

    /// Converts a genomic position to screen X coordinate.
    /// Result is offset by leadingInset so genomic data appears after the inset.
    public func screenPosition(for genomicPos: Double) -> CGFloat {
        leadingInset + CGFloat((genomicPos - start) / scale)
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
        case .barcode5p: return "Barcode (5')"
        case .barcode3p: return "Barcode (3')"
        case .adapter5p: return "Adapter (5')"
        case .adapter3p: return "Adapter (3')"
        case .primer5p: return "Primer (5')"
        case .primer3p: return "Primer (3')"
        case .trimQuality: return "Quality Trim"
        case .trimFixed: return "Fixed Trim"
        case .orientMarker: return "Orientation"
        case .umiRegion: return "UMI"
        case .contaminantMatch: return "Contaminant"
        }
    }
}
