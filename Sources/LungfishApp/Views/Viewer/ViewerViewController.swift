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

// QuickLookItem extracted to QuickLookItem.swift
// BaseColors extracted to BaseColors.swift
// Variant chromosome helpers extracted to VariantChromosomeHelpers.swift

// MARK: - Logging

/// Logger for viewer operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

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

    /// FASTA collection browser (shown in place of sequence viewer for multi-sequence FASTA files)
    private var fastaCollectionController: FASTACollectionViewController?

    /// Taxonomy classification browser (shown in place of sequence viewer for kreport results)
    var taxonomyViewController: TaxonomyViewController?

    /// EsViritu viral detection browser (shown in place of sequence viewer for EsViritu results)
    var esVirituViewController: EsVirituResultViewController?

    /// TaxTriage clinical triage browser (shown in place of sequence viewer for TaxTriage results)
    var taxTriageViewController: TaxTriageResultViewController?

    /// Assembly result browser (shown in place of the sequence viewer for assembly analyses)
    var assemblyResultController: AssemblyResultViewController?

    // MARK: - State

    /// The current viewport content mode (genomics, FASTQ, metagenomics, or empty).
    ///
    /// Updated automatically when display methods are called. Posts
    /// `.viewportContentModeDidChange` so the inspector and toolbar can adapt.
    public var contentMode: ViewportContentMode = .empty {
        didSet {
            guard contentMode != oldValue else { return }
            NotificationCenter.default.post(
                name: .viewportContentModeDidChange,
                object: self,
                userInfo: [NotificationUserInfoKey.contentMode: contentMode.rawValue]
            )
        }
    }

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

    // MARK: - Bundle Display State (moved from associated objects)

    /// The chromosome navigator panel shown in the left drawer.
    var chromosomeNavigatorView: ChromosomeNavigatorView?

    /// Layout constraints for the chromosome navigator panel.
    var chromosomeNavigatorConstraints: [NSLayoutConstraint]?

    /// Data provider for the currently displayed reference bundle.
    public var currentBundleDataProvider: BundleDataProvider?

    /// Whether the chromosome drawer is currently open.
    var isChromosomeDrawerOpen: Bool = false

    /// The current bundle's persisted view state.
    public var currentBundleViewState: BundleViewState?

    /// URL of the currently displayed bundle (needed for save-back).
    public var currentBundleURL: URL?

    /// Debounce work item for saving view state.
    var viewStateSaveWorkItem: DispatchWorkItem?

    // MARK: - FASTQ Drawer State (moved from associated objects)

    /// FASTQ metadata drawer view.
    var fastqMetadataDrawerView: FASTQMetadataDrawerView?

    /// Bottom constraint for the FASTQ metadata drawer (animated on toggle).
    var fastqMetadataDrawerBottomConstraint: NSLayoutConstraint?

    /// Height constraint for the FASTQ metadata drawer (resizable via drag).
    var fastqMetadataDrawerHeightConstraint: NSLayoutConstraint?

    /// Whether the FASTQ metadata drawer is currently open.
    var isFASTQMetadataDrawerOpen: Bool = false

    /// FASTQ dashboard view (shown in place of sequence viewer for FASTQ files).
    var fastqDashboardView: NSView?

    /// Bottom constraint for the FASTQ dashboard view.
    var fastqDashboardBottomConstraint: NSLayoutConstraint?

    /// URL of the currently displayed FASTQ dataset.
    var currentFASTQDatasetURL: URL?

    /// Debounce work item for saving FASTQ drawer height.
    var _fastqDrawerHeightSaveWorkItem: DispatchWorkItem?

    // MARK: - Annotation Drawer State (moved from associated objects)

    /// The annotation table drawer view.
    var annotationDrawerView: AnnotationTableDrawerView?

    /// Bottom constraint for the annotation drawer (animated on toggle).
    var annotationDrawerBottomConstraint: NSLayoutConstraint?

    /// Height constraint for the annotation drawer (resizable via drag).
    var annotationDrawerHeightConstraint: NSLayoutConstraint?

    /// Whether the annotation drawer is currently open.
    var isAnnotationDrawerOpen: Bool = false

    /// Search index for annotations and variants.
    public var annotationSearchIndex: AnnotationSearchIndex? {
        didSet {
            if let index = annotationSearchIndex {
                // Apply haploid AF shading immediately on index attach so first render
                // after import uses the correct AF color ramp without requiring redraw.
                viewerView?.sampleDisplayState.useHaploidAFShading = index.isLikelyHaploidOrganism
            }
            // If the drawer exists and index is ready, populate it
            if let index = annotationSearchIndex, !index.isBuilding, let drawer = annotationDrawerView {
                drawer.setSearchIndex(index)
            }
        }
    }

    /// Last selected gene tab navigation state (name, chromosome, start, end).
    var lastSelectedGeneTabSelection: (name: String, chromosome: String, start: Int, end: Int)?


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
        viewerView?.suppressPlaceholder = true
        viewerView?.needsDisplay = true
    }

    /// Hides the progress overlay
    public func hideProgress() {
        logger.info("hideProgress: Hiding progress overlay")
        progressOverlay.stopAnimating()
        progressOverlay.isHidden = true
        viewerView?.suppressPlaceholder = false
        viewerView?.needsDisplay = true
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
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()
        contentMode = .fastq

        let controller = FASTQDatasetViewController()
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        let dashBottomConstraint = dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        controller.onLaunchFASTQOperationCategory = { category in
            let preferredInputURLs = [fastqSourceURL ?? fastqURL].compactMap { $0 }
            AppDelegate.shared?.showFASTQOperationsDialog(
                nil,
                initialCategory: category,
                preferredInputURLs: preferredInputURLs
            )
        }
        controller.onOpenDemuxDrawer = { [weak self] in
            self?.openDemuxSetupDrawer()
        }
        controller.onOpenPrimerTrimDrawer = { [weak self] in
            self?.openPrimerTrimDrawer()
        }
        controller.onOpenDedupDrawer = { [weak self] in
            self?.openDedupDrawer()
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
        // Include the bundle URL so the inspector can load sample metadata
        if let fastqURL {
            let parentDir = fastqURL.deletingLastPathComponent()
            if parentDir.pathExtension == "lungfishfastq" {
                userInfo["bundleURL"] = parentDir
            }
        }
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
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()

        let controller = VCFDatasetViewController()
        controller.onDownloadReferenceRequested = onDownloadReference
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    // MARK: - FASTA Collection Display

    /// Displays the multi-sequence FASTA collection browser in place of the
    /// normal sequence viewer.
    ///
    /// - Parameters:
    ///   - sequences: All sequences from the FASTA file.
    ///   - annotations: Associated annotations (grouped by chromosome internally).
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation]
    ) {
        displayFASTACollection(
            sequences: sequences,
            annotations: annotations,
            sourceNames: [:]
        )
    }

    /// Displays a FASTA collection view with sequences from multiple source documents.
    ///
    /// When `sourceNames` is non-empty, the collection table shows a "Source" column
    /// indicating which file each sequence came from. The summary bar also reflects
    /// the number of source files.
    ///
    /// - Parameters:
    ///   - sequences: Combined sequences from all selected documents.
    ///   - annotations: Combined annotations from all selected documents.
    ///   - sourceNames: Maps sequence IDs to source file names. Pass empty for
    ///                  single-document display.
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String]
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()

        let controller = FASTACollectionViewController()
        addChild(controller)

        // Hide annotation drawer so it doesn't overlap the collection view
        annotationDrawerView?.isHidden = true

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(
            sequences: sequences,
            annotations: annotations,
            sourceNames: sourceNames
        )
        // Store collection data so we can return to it via the back button
        let allSequences = sequences
        let allAnnotations = annotations
        let allSourceNames = sourceNames

        controller.onOpenSequence = { [weak self] sequence, sequenceAnnotations in
            guard let self else { return }
            self.hideFASTACollectionView()
            self.clearBundleDisplay()

            // Set up the viewer directly with the selected sequence
            self.view.layoutSubtreeIfNeeded()
            let effectiveWidth = max(800, Int(self.viewerView.bounds.width))

            self.referenceFrame = ReferenceFrame(
                chromosome: sequence.name,
                start: 0,
                end: Double(min(sequence.length, 10000)),
                pixelWidth: effectiveWidth,
                sequenceLength: sequence.length
            )

            self.viewerView.setSequence(sequence)
            self.viewerView.setAnnotations(sequenceAnnotations)

            let trackNames = [sequence.name]
                + (sequenceAnnotations.isEmpty ? [] : ["Annotations"])
            self.headerView.setTrackNames(trackNames)
            self.enhancedRulerView.referenceFrame = self.referenceFrame

            // Restore viewer components
            self.enhancedRulerView.isHidden = false
            self.viewerView.isHidden = false
            self.headerView.isHidden = false
            self.statusBar.isHidden = false
            self.geneTabBarView.isHidden = true

            // Add "Back to Collection" button above the viewer
            self.showCollectionBackButton(
                sequences: allSequences,
                annotations: allAnnotations,
                sourceNames: allSourceNames
            )

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
            self.updateStatusBar()
            self.scheduleDeferredRedraw()
        }

        fastaCollectionController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        logger.info("displayFASTACollection: Showing browser with \(sequences.count) sequences")
    }

    /// Removes the FASTA collection browser and restores normal viewer components.
    public func hideFASTACollectionView() {
        guard let controller = fastaCollectionController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        fastaCollectionController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
        annotationDrawerView?.isHidden = false
    }

    // MARK: - Collection Back Button

    private var collectionBackButton: NSButton?

    /// Shows a navigation bar with "Back to Collection" above the viewer content.
    private func showCollectionBackButton(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String] = [:]
    ) {
        hideCollectionBackButton()

        // Create a thin navigation bar that sits above the viewer content
        let navBar = NSView()
        navBar.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        button.imagePosition = .imageLeading
        button.title = "All Sequences (\(sequences.count))"
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(collectionBackButtonTapped(_:))

        // Separator line at bottom of nav bar
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        navBar.addSubview(button)
        navBar.addSubview(separator)
        view.addSubview(navBar)

        // Position nav bar at the very top of the safe area, pushing content down
        // by adjusting the enhanced ruler's top constraint
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 28),

            button.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 6),
            button.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
        ])

        // Store the collection data so we can return to it
        collectionBackSequences = sequences
        collectionBackAnnotations = annotations
        collectionBackSourceNames = sourceNames
        collectionBackButton = button
        collectionNavBar = navBar
    }

    public func hideCollectionBackButton() {
        collectionNavBar?.removeFromSuperview()
        collectionNavBar = nil
        collectionBackButton = nil
        collectionBackSequences = nil
        collectionBackAnnotations = nil
        collectionBackSourceNames = nil
    }

    private var collectionNavBar: NSView?
    private var collectionBackSequences: [LungfishCore.Sequence]?
    private var collectionBackAnnotations: [SequenceAnnotation]?
    private var collectionBackSourceNames: [UUID: String]?

    @objc private func collectionBackButtonTapped(_ sender: Any?) {
        guard let sequences = collectionBackSequences,
              let annotations = collectionBackAnnotations else { return }
        let sourceNames = collectionBackSourceNames ?? [:]
        hideCollectionBackButton()
        displayFASTACollection(
            sequences: sequences,
            annotations: annotations,
            sourceNames: sourceNames
        )
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
        clearViewport(statusMessage: "No sequence loaded")
        logger.info("clearViewer: Viewer cleared")
    }

    /// Shows the "No sequence selected" state.
    ///
    /// Call this when a project is open but has no sequences, or when no sequence is selected.
    /// This differs from clearViewer() in the message shown - this indicates an active project
    /// context where the user hasn't selected a sequence yet.
    public func showNoSequenceSelected() {
        logger.info("showNoSequenceSelected: Setting empty state with 'No sequence selected'")
        clearViewport(statusMessage: "No sequence selected")
        logger.info("showNoSequenceSelected: Empty state set")
    }

    /// Unified viewport clearing that removes ALL overlay views and resets to empty state.
    ///
    /// This method is the single point of cleanup when the viewport needs to show nothing.
    /// It hides every overlay (QuickLook, FASTQ, VCF, FASTA collection, taxonomy, EsViritu,
    /// TaxTriage), clears bundle display state, cancels deferred redraws, and resets the
    /// genomics viewer to a blank state.
    ///
    /// - Parameter statusMessage: The message to show in the status bar (e.g. "No sequence loaded")
    public func clearViewport(statusMessage: String = "No sequence loaded") {
        logger.info("clearViewport: Clearing all viewport state")
        contentMode = .empty

        // Hide progress overlay
        hideProgress()

        // Hide all overlay views that may be showing non-genomics content
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()

        // Clear bundle display state (chromosome navigator, data provider)
        clearBundleDisplay()

        // Clear back button from collection drill-down
        hideCollectionBackButton()

        // Cancel deferred redraws to prevent stale renders
        layoutSettleWorkItem?.cancel()
        deferredRedrawWorkItem?.cancel()

        // Clear genomics viewer state
        currentDocument = nil
        referenceFrame = nil

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

        // Clear search index
        annotationSearchIndex = nil

        // Update status bar
        statusBar.update(position: statusMessage, selection: nil, scale: 1.0)

        // Ensure genomics viewer components are visible (in case QuickLook hid them)
        showGenomicsViewer()

        // Trigger redraw
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        headerView.needsDisplay = true

        logger.info("clearViewport: All viewport state cleared")
    }

    // MARK: - Document Display

    /// Displays a loaded document in the viewer.
    public func displayDocument(_ document: LoadedDocument) {
        logger.info("displayDocument: Starting to display '\(document.name, privacy: .public)'")
        contentMode = .genomics

        // Hide any non-document views when showing a genomics document
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()

        // Clear any stale reference bundle state so the viewer uses
        // the document's sequences instead of trying to fetch from a bundle
        clearBundleDisplay()

        logger.info("displayDocument: Document has \(document.sequences.count) sequences, \(document.annotations.count) annotations")

        // Clear any back button from a previous collection drill-down
        hideCollectionBackButton()

        // Multi-sequence FASTA: show collection view instead of genome browser
        if document.sequences.count > 1 {
            logger.info("displayDocument: Multi-sequence document (\(document.sequences.count) seqs), showing collection view")
            displayFASTACollection(
                sequences: document.sequences,
                annotations: document.annotations
            )
            return
        }

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
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()

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

// ProgressOverlayView extracted to ProgressOverlayView.swift


// SequenceViewerView extracted to SequenceViewerView.swift

// Genotype classification helpers extracted to VariantChromosomeHelpers.swift

// TrackHeaderView extracted to TrackHeaderView.swift


// CoordinateRulerView extracted to CoordinateRulerView.swift


// ViewerStatusBar extracted to ViewerStatusBar.swift

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

// AnnotationPopoverView extracted to AnnotationPopoverView.swift
