// MiniBAMViewController.swift - Compact BAM alignment viewer for EsViritu detail pane
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "MiniBAM")

private func miniBAMFormatCount(_ count: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}

/// Drag handle used to resize the embedded mini-BAM viewport vertically.
private final class MiniBAMResizeHandleView: NSView {
    var onDragDeltaY: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastWindowPoint: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastWindowPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastWindowPoint else { return }
        let next = event.locationInWindow
        // Bottom-edge resize handle semantics: dragging down increases height.
        let deltaY = lastWindowPoint.y - next.y
        onDragDeltaY?(deltaY)
        self.lastWindowPoint = next
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowPoint = nil
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Match other app divider visuals: 1px separator + subtle grip.
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))

        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }
}

// MARK: - MiniBAMViewController

/// A compact BAM alignment viewer that shows base-level read pileup for a viral contig.
///
/// Designed to be embedded in the EsViritu detail pane. Unlike the full
/// `SequenceViewerView`, this controller is lightweight:
/// - Creates its own `AlignmentDataProvider` from a BAM path
/// - Renders reads using CoreGraphics directly (no tile cache)
/// - Shows the entire viral contig in a scrollable view
///
/// PCR/optical duplicate flags are retained in the viewer so users can inspect
/// all reported alignments; unique-read stats are computed from read fingerprints.
///
/// ## Layout
///
/// ```
/// +--------------------------------------------------+
/// | Coverage depth track (40px)                      |
/// | [area chart showing depth across contig]         |
/// +--------------------------------------------------+
/// | Read pileup (scrollable, variable height)        |
/// | [packed reads with mismatch coloring, arrows]    |
/// +--------------------------------------------------+
/// | Status: "42 reads"                               |
/// +--------------------------------------------------+
/// ```
@MainActor
public final class MiniBAMViewController: NSViewController {

    // MARK: - Properties

    private var bamURL: URL?
    private var indexURL: URL?
    private var contigName: String = ""
    private var contigLength: Int = 0
    private var reads: [AlignedRead] = []
    private var referenceSequence: String?
    private var displayedReadSetIsSketch = false
    private var estimatedTotalReadCount: Int?
    private var fullReadSetLoadPending = false
    public private(set) var uniqueReadCount: Int = 0

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let pileupView = MiniPileupView()
    private let resizeHandleView = MiniBAMResizeHandleView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var resizeHandleHeightConstraint: NSLayoutConstraint?

    private var lastKnownViewportSize: CGSize = .zero
    private var keyMonitorToken: Any?
    private var clipBoundsObserver: NSObjectProtocol?
    private var clipFrameObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var pendingViewportResizeTask: Task<Void, Never>?
    private var deferredReferenceTask: Task<Void, Never>?
    private var loadGeneration: Int = 0
    private lazy var zoomShortcutHandler = ZoomShortcutHandler(
        zoomIn: { [weak self] in self?.zoomIn() },
        zoomOut: { [weak self] in self?.zoomOut() },
        zoomToFit: { [weak self] in self?.zoomToFit() }
    )

    // MARK: - Read Cache

    /// Pre-computed result stored in the cache for a BAM+contig combination.
    private struct CachedContigResult {
        let reads: [AlignedRead]
        let uniqueReadCount: Int
    }

    struct DisplayReadStats {
        let reads: [AlignedRead]
        let uniqueReadCount: Int
    }

    /// Cache keyed by "bamPath|contig". Limited to `maxCachedContigs` entries.
    /// Older entries are evicted when the limit is reached.
    private var contigCache: [String: CachedContigResult] = [:]

    /// Maximum number of BAM+contig entries held in memory.
    private static let maxCachedContigs = 20

    /// First-pass read sketch size for large TaxTriage/EsViritu contig selections.
    private nonisolated static let initialReadSketchTarget = 2_500

    /// Upper bound for automatically replacing the first-pass sketch with all reads.
    ///
    /// Larger contigs stay in sketch mode unless a caller explicitly requests a
    /// bounded `maxReads`; rendering tens of thousands of reads synchronously on
    /// the main actor makes unrelated AppKit interactions feel frozen.
    private nonisolated static let automaticFullReadLoadLimit = 10_000

    /// Ordered insertion keys so we can evict the oldest entry on overflow.
    private var cacheInsertionOrder: [String] = []

    /// Returns a cache key for the given BAM path and contig name.
    private func cacheKey(bamPath: String, contig: String) -> String {
        "\(bamPath)|\(contig)"
    }

    /// Stores a result in the cache, evicting the oldest entry if necessary.
    private func cacheResult(_ result: CachedContigResult, key: String) {
        if contigCache[key] != nil { return }  // already cached
        if cacheInsertionOrder.count >= Self.maxCachedContigs,
           let oldest = cacheInsertionOrder.first {
            contigCache.removeValue(forKey: oldest)
            cacheInsertionOrder.removeFirst()
        }
        contigCache[key] = result
        cacheInsertionOrder.append(key)
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.setAccessibilityElement(true)
        container.setAccessibilityIdentifier("mini-bam-view")
        container.setAccessibilityLabel("Mini BAM Viewer")
        view = container

        setupScrollView()
        setupStatusLabel()

        resizeHandleView.onDragDeltaY = { [weak self] deltaY in
            self?.onResizeBy?(deltaY)
        }
        resizeHandleView.onDragEnded = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.pileupView)
        }

        // Context menu for the pileup view
        let menu = NSMenu()
        menu.addItem(withTitle: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.items.last?.target = self
        menu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.items.last?.target = self
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFitAction), keyEquivalent: "0")
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.items.last?.target = self
        menu.addItem(withTitle: "Center View Here", action: #selector(centerViewHereAction), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Read Sequence (FASTQ)", action: #selector(copyReadFASTQ), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(withTitle: "Copy Read Sequence (FASTA)", action: #selector(copyReadFASTA), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(withTitle: "Copy Read Name", action: #selector(copyReadName), keyEquivalent: "")
        menu.items.last?.target = self
        pileupView.menu = menu

        // Wire the pileup view's click handler for read selection
        pileupView.onReadClicked = { [weak self] readIndex in
            self?.selectedReadIndex = readIndex
        }
        pileupView.onZoomInRequested = { [weak self] in self?.zoomIn() }
        pileupView.onZoomOutRequested = { [weak self] in self?.zoomOut() }
        pileupView.onZoomToFitRequested = { [weak self] in self?.zoomToFit() }
        pileupView.onMagnification = { [weak self] magnification in
            self?.applyMagnification(magnification)
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        installClipViewObserversIfNeeded()
        if keyboardShortcutsEnabled {
            installLocalKeyMonitorIfNeeded()
        }
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        removeLocalKeyMonitor()
        removeClipViewObservers()
        pendingViewportResizeTask?.cancel()
        pendingViewportResizeTask = nil
        deferredReferenceTask?.cancel()
        deferredReferenceTask = nil
    }

    deinit {
        loadTask?.cancel()
        pendingViewportResizeTask?.cancel()
        deferredReferenceTask?.cancel()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        scheduleViewportResizeUpdate()
    }

    /// Index of the currently selected read (for context menu operations).
    private var selectedReadIndex: Int?

    /// Domain noun for empty-state/status text ("virus" or "organism").
    public var subjectNoun: String = "virus" {
        didSet {
            pileupView.subjectNoun = subjectNoun
            if reads.isEmpty {
                statusLabel.stringValue = emptyStatusText
                pileupView.needsDisplay = true
            }
        }
    }

    private var emptyStatusText: String {
        "Select a \(subjectNoun) to view alignments"
    }

    /// Optional callback used by host views to resize this mini-BAM vertically.
    public var onResizeBy: ((CGFloat) -> Void)? {
        didSet {
            updateResizeHandleVisibility()
        }
    }

    /// Whether this panel should register local keyboard zoom shortcuts.
    ///
    /// Disable when many miniBAM panels are visible to avoid overlapping
    /// keyboard monitors across embedded viewers.
    public var keyboardShortcutsEnabled: Bool = true {
        didSet {
            if keyboardShortcutsEnabled {
                installLocalKeyMonitorIfNeeded()
            } else {
                removeLocalKeyMonitor()
            }
        }
    }

    /// Emits `(totalReads, uniqueReads)` whenever read stats change.
    public var onReadStatsUpdated: ((Int, Int) -> Void)?

    /// Current zoom level (1.0 = fit entire contig in viewport width).
    private var zoomLevel: Double = 1.0

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("mini-bam-scroll-view")
        scrollView.setAccessibilityLabel("Mini BAM Scroll View")
        // Do NOT use allowsMagnification — it just scales pixels.
        // We implement semantic zoom by changing bpPerPixel and re-rendering.
        scrollView.allowsMagnification = false
        scrollView.documentView = pileupView
        view.addSubview(scrollView)
        installClipViewObserversIfNeeded()

        resizeHandleView.translatesAutoresizingMaskIntoConstraints = false
        resizeHandleView.isHidden = true
        resizeHandleView.setAccessibilityIdentifier("mini-bam-resize-handle")
        resizeHandleView.setAccessibilityLabel("Mini BAM Resize Handle")
        view.addSubview(resizeHandleView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.setAccessibilityIdentifier("mini-bam-status-label")
        statusLabel.setAccessibilityLabel("Mini BAM Status")
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: resizeHandleView.topAnchor),

            resizeHandleView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resizeHandleView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resizeHandleView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            statusLabel.heightAnchor.constraint(equalToConstant: 14),
        ])

        let handleHeight = resizeHandleView.heightAnchor.constraint(equalToConstant: 0)
        handleHeight.isActive = true
        resizeHandleHeightConstraint = handleHeight
        updateResizeHandleVisibility()
    }

    private func setupStatusLabel() {
        pileupView.subjectNoun = subjectNoun
        statusLabel.stringValue = emptyStatusText
    }

    private var currentViewportWidth: CGFloat {
        max(scrollView.contentView.bounds.width, scrollView.bounds.width, 1)
    }

    private var currentViewportHeight: CGFloat {
        max(scrollView.contentView.bounds.height, scrollView.bounds.height, 1)
    }

    private var topAlignedVerticalOffset: CGFloat {
        let clipView = scrollView.contentView
        let maxY = max(0, pileupView.frame.height - clipView.bounds.height)
        return clipView.isFlipped ? 0 : maxY
    }

    private func updateResizeHandleVisibility() {
        let showsHandle = (onResizeBy != nil)
        resizeHandleView.isHidden = !showsHandle
        resizeHandleHeightConstraint?.constant = showsHandle ? 8 : 0
    }

    // MARK: - Public API

    /// Zoom in: doubles the zoom level (halves bp/px), re-renders at higher detail.
    ///
    /// Preserves the scroll position by centering on the current viewport midpoint.
    public func zoomIn() {
        let maxZoom = Double(contigLength) / 2.0  // Min 2bp visible
        let newZoom = min(maxZoom, zoomLevel * 2)
        applyZoom(newZoom)
    }

    /// Zoom out: halves the zoom level (doubles bp/px).
    public func zoomOut() {
        let newZoom = max(1.0, zoomLevel / 2)
        applyZoom(newZoom)
    }

    /// Zoom to fit the entire contig in the viewport.
    public func zoomToFit() {
        applyZoom(1.0)
    }

    public override func magnify(with event: NSEvent) {
        applyMagnification(event.magnification)
    }

    private func applyMagnification(_ magnification: CGFloat) {
        let newZoom = Self.zoomLevel(
            afterMagnification: magnification,
            currentZoom: zoomLevel,
            contigLength: contigLength
        )
        guard abs(newZoom - zoomLevel) > 0.001 else { return }
        applyZoom(newZoom)
    }

    /// Applies a new zoom level and re-renders the pileup.
    private func applyZoom(_ newZoom: Double) {
        // Remember viewport center position in bp coordinates
        let viewportWidth = currentViewportWidth
        let viewportHeight = currentViewportHeight
        let scrollX = scrollView.contentView.bounds.origin.x
        let oldBpPerPx = pileupView.bpPerPixel
        let centerBp = (Double(scrollX) + Double(viewportWidth) / 2) * oldBpPerPx

        zoomLevel = newZoom

        // Re-render with new zoom level
        pileupView.updateViewport(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            zoomLevel: zoomLevel
        )
        lastKnownViewportSize = CGSize(width: viewportWidth, height: viewportHeight)

        // Scroll to keep the same bp position centered
        let newBpPerPx = pileupView.bpPerPixel
        let newScrollX = CGFloat(centerBp / newBpPerPx) - viewportWidth / 2
        let clampedX = max(0, min(newScrollX, pileupView.frame.width - viewportWidth))
        let topY = topAlignedVerticalOffset
        scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        updateZoomStatus()
    }

    private static func zoomLevel(
        afterMagnification magnification: CGFloat,
        currentZoom: Double,
        contigLength: Int
    ) -> Double {
        let factor = PinchZoom.factor(magnification: magnification)
        let maxZoom = max(1, Double(contigLength) / 2.0)
        return min(maxZoom, max(1.0, currentZoom * factor))
    }

    private func updatePileupForViewportResizeIfNeeded() {
        let viewportWidth = currentViewportWidth
        let viewportHeight = currentViewportHeight
        let widthChanged = abs(viewportWidth - lastKnownViewportSize.width) > 0.5
        let heightChanged = abs(viewportHeight - lastKnownViewportSize.height) > 0.5
        guard widthChanged || heightChanged else { return }
        let oldBpPerPx = pileupView.bpPerPixel
        let currentScrollX = scrollView.contentView.bounds.origin.x
        let centerBp = (Double(currentScrollX) + Double(viewportWidth) / 2) * oldBpPerPx
        lastKnownViewportSize = CGSize(width: viewportWidth, height: viewportHeight)

        guard !reads.isEmpty else { return }

        pileupView.updateViewport(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            zoomLevel: zoomLevel
        )

        let newBpPerPx = pileupView.bpPerPixel
        let newScrollX = CGFloat(centerBp / newBpPerPx) - viewportWidth / 2
        let clampedX = max(0, min(newScrollX, pileupView.frame.width - viewportWidth))
        let topY = topAlignedVerticalOffset
        scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateZoomStatus()
    }

    private func updateZoomStatus() {
        let bpPerPx = pileupView.bpPerPixel
        let zoomText: String
        if bpPerPx < 1 {
            zoomText = String(format: "%.1f px/bp", 1.0 / bpPerPx)
        } else {
            zoomText = String(format: "%.0f bp/px", bpPerPx)
        }

        let total = reads.count
        if displayedReadSetIsSketch {
            let estimatedTotal = estimatedTotalReadCount.map(miniBAMFormatCount) ?? "many"
            let suffix = fullReadSetLoadPending ? " · loading full alignments" : " · sampled overview"
            statusLabel.stringValue = "\(miniBAMFormatCount(total)) of \(estimatedTotal) reads · sketch · \(zoomText)\(suffix)"
            return
        }

        statusLabel.stringValue = "\(miniBAMFormatCount(total)) reads · \(zoomText) · ⌘+/⌘- to zoom"
        onReadStatsUpdated?(total, uniqueReadCount)
    }

    private nonisolated static func displayReadsAndUniqueCount(
        from fetchedReads: [AlignedRead],
        readNameAllowlist: Set<String>?
    ) -> DisplayReadStats {
        let visibleReads: [AlignedRead]
        if let readNameAllowlist, !readNameAllowlist.isEmpty {
            visibleReads = fetchedReads.filter { readNameAllowlist.contains($0.name) }
        } else {
            visibleReads = fetchedReads
        }

        return DisplayReadStats(
            reads: visibleReads,
            uniqueReadCount: AlignedRead.deduplicatedReadCount(from: visibleReads)
        )
    }

    /// Loads and displays reads for a specific viral contig from the BAM file.
    ///
    /// - Parameters:
    ///   - bamURL: Path to the sorted, indexed BAM file.
    ///   - contig: The viral contig accession to display.
    ///   - contigLength: Length of the reference contig in base pairs.
    ///   - indexURL: Optional explicit index path (.bai/.csi).
    ///   - referenceSequence: Optional reference sequence for this contig.
    ///   - maxReads: Maximum reads to load for this panel.
    public func displayContig(
        bamURL: URL,
        contig: String,
        contigLength: Int,
        indexURL: URL? = nil,
        referenceSequence: String? = nil,
        maxReads: Int = .max,
        readNameAllowlist: Set<String>? = nil
    ) {
        loadTask?.cancel()
        deferredReferenceTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        self.bamURL = bamURL
        self.contigName = contig
        self.contigLength = contigLength
        self.referenceSequence = referenceSequence
        statusLabel.stringValue = "Loading alignments…"

        let fm = FileManager.default
        let resolvedIndexPath: String? = {
            if let indexURL, fm.fileExists(atPath: indexURL.path) {
                return indexURL.path
            }
            let baiPath = bamURL.path + ".bai"
            if fm.fileExists(atPath: baiPath) {
                return baiPath
            }
            let csiPath = bamURL.path + ".csi"
            if fm.fileExists(atPath: csiPath) {
                return csiPath
            }
            return nil
        }()

        guard let indexPath = resolvedIndexPath else {
            statusLabel.stringValue = "BAM index not found"
            logger.warning("BAM index not found for \(bamURL.lastPathComponent, privacy: .public)")
            return
        }
        self.indexURL = URL(fileURLWithPath: indexPath)

        // Check the read cache first — avoids spawning a samtools subprocess on repeated
        // selections of the same organism row.
        let key = cacheKey(bamPath: bamURL.path, contig: contig)
        if readNameAllowlist == nil, let cached = contigCache[key] {
            reads = cached.reads
            uniqueReadCount = cached.uniqueReadCount
            displayedReadSetIsSketch = false
            estimatedTotalReadCount = nil
            fullReadSetLoadPending = false
            updatePileup()
            scrollToTop()
            updateZoomStatus()
            scheduleDeferredReferenceInferenceIfNeeded(
                reads: cached.reads,
                requestedContig: contig,
                generation: generation
            )
            logger.info("Cache hit: \(cached.reads.count) reads for \(contig, privacy: .public)")
            return
        }

        let provider = AlignmentDataProvider(
            alignmentPath: bamURL.path,
            indexPath: indexPath
        )

        // Fetch all primary/supplement-compatible reads for this contig. Keep
        // duplicate-flagged reads visible and deduplicate only for unique stats.
        let sketchTarget = Self.initialReadSketchTarget

        // Fetch and parse SAM off the main actor. `Task {}` created here would
        // inherit this @MainActor controller and stall AppKit while samtools
        // output is parsed or a large full-read display is prepared.
        loadTask = Task.detached(priority: .userInitiated) { [weak self, provider, readNameAllowlist] in
            let requestedContig = contig
            func applyOnMain(_ update: @escaping @MainActor (MiniBAMViewController) -> Void) {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        update(self)
                    }
                }
            }

            do {
                if maxReads == .max, readNameAllowlist == nil {
                    let sketch = try await provider.fetchReadSketch(
                        chromosome: contig,
                        start: 0,
                        end: contigLength,
                        excludeFlags: 0x904,
                        targetReads: sketchTarget
                    )
                    guard !Task.isCancelled else { return }

                    if sketch.isSubsampled {
                        let shouldLoadFullReadSet = Self.shouldAutoLoadFullReadSet(
                            estimatedTotalReads: sketch.estimatedTotalReads,
                            targetReads: sketchTarget
                        )
                        let display = Self.displayReadsAndUniqueCount(
                            from: sketch.reads,
                            readNameAllowlist: nil
                        )
                        guard !Task.isCancelled else { return }
                        applyOnMain { controller in
                            guard controller.loadGeneration == generation else { return }
                            guard controller.contigName == requestedContig else { return }
                            controller.reads = display.reads
                            controller.uniqueReadCount = display.uniqueReadCount
                            controller.displayedReadSetIsSketch = true
                            controller.estimatedTotalReadCount = sketch.estimatedTotalReads
                            controller.fullReadSetLoadPending = shouldLoadFullReadSet
                            controller.updatePileup()
                            controller.scrollToTop()
                            controller.updateZoomStatus()
                            controller.scheduleDeferredReferenceInferenceIfNeeded(
                                reads: display.reads,
                                requestedContig: requestedContig,
                                generation: generation
                            )
                        }

                        guard shouldLoadFullReadSet else {
                            logger.info("Using sketch-only MiniBAM display: \(display.reads.count) of \(sketch.estimatedTotalReads) reads for \(contig, privacy: .public)")
                            return
                        }
                    } else {
                        let display = Self.displayReadsAndUniqueCount(
                            from: sketch.reads,
                            readNameAllowlist: nil
                        )
                        guard !Task.isCancelled else { return }
                        applyOnMain { controller in
                            guard controller.loadGeneration == generation else { return }
                            guard controller.contigName == requestedContig else { return }
                            controller.reads = display.reads
                            controller.uniqueReadCount = display.uniqueReadCount
                            controller.displayedReadSetIsSketch = false
                            controller.estimatedTotalReadCount = nil
                            controller.fullReadSetLoadPending = false
                            controller.updatePileup()
                            controller.scrollToTop()
                            controller.updateZoomStatus()
                            controller.scheduleDeferredReferenceInferenceIfNeeded(
                                reads: display.reads,
                                requestedContig: requestedContig,
                                generation: generation
                            )

                            let result = CachedContigResult(
                                reads: display.reads,
                                uniqueReadCount: display.uniqueReadCount
                            )
                            controller.cacheResult(result, key: key)
                        }
                        logger.info("Loaded \(display.reads.count) reads for \(contig, privacy: .public)")
                        return
                    }
                }

                let fetchedReads = try await provider.fetchReads(
                    chromosome: contig,
                    start: 0,
                    end: contigLength,
                    excludeFlags: 0x904,
                    maxReads: maxReads
                )
                guard !Task.isCancelled else { return }

                let display = Self.displayReadsAndUniqueCount(
                    from: fetchedReads,
                    readNameAllowlist: readNameAllowlist
                )

                applyOnMain { controller in
                    guard controller.loadGeneration == generation else { return }
                    guard controller.contigName == requestedContig else { return }
                    controller.reads = display.reads
                    controller.uniqueReadCount = display.uniqueReadCount
                    controller.displayedReadSetIsSketch = false
                    controller.estimatedTotalReadCount = nil
                    controller.fullReadSetLoadPending = false
                    controller.updatePileup()

                    // Keep the coverage/reference tracks pinned at the top of the viewport.
                    controller.scrollToTop()
                    controller.updateZoomStatus()
                    controller.scheduleDeferredReferenceInferenceIfNeeded(
                        reads: display.reads,
                        requestedContig: requestedContig,
                        generation: generation
                    )

                    // Store in cache for instant re-display on repeated selections.
                    if readNameAllowlist == nil {
                        let result = CachedContigResult(
                            reads: display.reads,
                            uniqueReadCount: display.uniqueReadCount
                        )
                        controller.cacheResult(result, key: key)
                    }
                }

                logger.info("Loaded \(display.reads.count) reads for \(contig, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                applyOnMain { controller in
                    guard controller.loadGeneration == generation else { return }
                    guard controller.contigName == requestedContig else { return }
                    controller.statusLabel.stringValue = "Failed to load reads: \(message)"
                }
                logger.error("Failed to fetch reads for \(contig, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Testing Hooks

    static func testingDisplayReadsAndUniqueCount(
        from fetchedReads: [AlignedRead],
        readNameAllowlist: Set<String>?
    ) -> DisplayReadStats {
        displayReadsAndUniqueCount(from: fetchedReads, readNameAllowlist: readNameAllowlist)
    }

    static func testingReadFASTA(_ read: AlignedRead) -> String {
        readFASTA(read)
    }

    static func testingZoomLevel(
        afterMagnification magnification: CGFloat,
        currentZoom: Double,
        contigLength: Int
    ) -> Double {
        zoomLevel(
            afterMagnification: magnification,
            currentZoom: currentZoom,
            contigLength: contigLength
        )
    }

    static func testingShouldAutoLoadFullReadSet(
        estimatedTotalReads: Int,
        targetReads: Int
    ) -> Bool {
        shouldAutoLoadFullReadSet(
            estimatedTotalReads: estimatedTotalReads,
            targetReads: targetReads
        )
    }

    private nonisolated static func shouldAutoLoadFullReadSet(
        estimatedTotalReads: Int,
        targetReads: Int
    ) -> Bool {
        estimatedTotalReads <= max(targetReads, automaticFullReadLoadLimit)
    }

    // MARK: - Keyboard Shortcuts

    @discardableResult
    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        zoomShortcutHandler.handleZoomShortcut(event)
    }

    public override func keyDown(with event: NSEvent) {
        if handleZoomShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleZoomShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Make sure we can become first responder for keyboard events
    public override var acceptsFirstResponder: Bool { true }

    private func installLocalKeyMonitorIfNeeded() {
        guard keyMonitorToken == nil else { return }
        keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldHandleLocalZoomShortcut(event) else { return event }
            if self.handleZoomShortcut(event) {
                return nil
            }
            return event
        }
    }

    private func removeLocalKeyMonitor() {
        guard let keyMonitorToken else { return }
        NSEvent.removeMonitor(keyMonitorToken)
        self.keyMonitorToken = nil
    }

    private func scheduleViewportResizeUpdate() {
        pendingViewportResizeTask?.cancel()
        pendingViewportResizeTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.pendingViewportResizeTask = nil
            self?.updatePileupForViewportResizeIfNeeded()
        }
    }

    private func installClipViewObserversIfNeeded() {
        guard clipBoundsObserver == nil, clipFrameObserver == nil else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduleViewportResizeUpdate()
                }
            }
        }
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduleViewportResizeUpdate()
                }
            }
        }
    }

    private func removeClipViewObservers() {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
            self.clipBoundsObserver = nil
        }
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
    }

    private func shouldHandleLocalZoomShortcut(_ event: NSEvent) -> Bool {
        ZoomShortcutHandler.shouldHandleLocalZoomShortcut(
            event,
            window: view.window,
            rootView: view,
            responder: view.window?.firstResponder
        )
    }

    // MARK: - Context Menu Actions

    @objc private func zoomInAction() { zoomIn() }
    @objc private func zoomOutAction() { zoomOut() }
    @objc private func zoomToFitAction() { zoomToFit() }

    @objc private func centerViewHereAction() {
        guard let clickPoint = pileupView.lastContextClickPoint else { return }
        let viewportWidth = currentViewportWidth
        let targetX = clickPoint.x - viewportWidth / 2
        let clampedX = max(0, min(targetX, pileupView.frame.width - viewportWidth))
        scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func copyReadFASTQ() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.readFASTQ(reads[idx]), forType: .string)
    }

    @objc private func copyReadFASTA() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.readFASTA(reads[idx]), forType: .string)
    }

    @objc private func copyReadName() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reads[idx].name, forType: .string)
    }

    private static func readFASTQ(_ read: AlignedRead) -> String {
        let qualString = String(read.qualities.map { Character(UnicodeScalar($0 + 33)) })
        return "@\(read.name)\n\(read.sequence)\n+\n\(qualString)"
    }

    private static func readFASTA(_ read: AlignedRead) -> String {
        ">\(read.name)\n\(read.sequence)"
    }

    /// Clears the current display.
    public func clear() {
        loadTask?.cancel()
        loadTask = nil
        deferredReferenceTask?.cancel()
        deferredReferenceTask = nil
        loadGeneration &+= 1
        reads = []
        uniqueReadCount = 0
        displayedReadSetIsSketch = false
        estimatedTotalReadCount = nil
        fullReadSetLoadPending = false
        referenceSequence = nil
        pileupView.clear()
        statusLabel.stringValue = emptyStatusText
        onReadStatsUpdated?(0, 0)
        lastKnownViewportSize = CGSize(width: currentViewportWidth, height: currentViewportHeight)
    }

    private func scrollToTop() {
        let topY = topAlignedVerticalOffset
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Pileup Update

    private func updatePileup() {
        let viewportWidth = currentViewportWidth
        let viewportHeight = currentViewportHeight
        pileupView.configure(
            reads: reads,
            contigName: contigName,
            contigLength: contigLength,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            zoomLevel: zoomLevel,
            rebuildReference: true,
            referenceSequence: referenceSequence
        )
        lastKnownViewportSize = CGSize(width: viewportWidth, height: viewportHeight)
    }

    private func scheduleDeferredReferenceInferenceIfNeeded(
        reads: [AlignedRead],
        requestedContig: String,
        generation: Int
    ) {
        deferredReferenceTask?.cancel()
        deferredReferenceTask = nil

        guard referenceSequence == nil, !reads.isEmpty else { return }
        let contigLength = self.contigLength

        deferredReferenceTask = Task.detached(priority: .utility) { [reads] in
            let inferredBases = MiniPileupView.inferReferenceBases(reads: reads, contigLength: contigLength)
            guard !Task.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.loadGeneration == generation else { return }
                    guard self.contigName == requestedContig else { return }
                    guard self.referenceSequence == nil else { return }

                    self.pileupView.applyInferredReferenceBases(inferredBases)
                    self.deferredReferenceTask = nil
                }
            }
        }
    }

}
