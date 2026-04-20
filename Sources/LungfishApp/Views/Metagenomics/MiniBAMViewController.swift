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
/// PCR/optical duplicates are filtered upstream by samtools markdup,
/// so the viewer receives already-deduplicated reads.
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
    private var depthPoints: [DepthPoint] = []
    private var referenceSequence: String?
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

    // MARK: - Read Cache

    /// Pre-computed result stored in the cache for a BAM+contig combination.
    private struct CachedContigResult {
        let reads: [AlignedRead]
        let readCount: Int
    }

    /// Cache keyed by "bamPath|contig". Limited to `maxCachedContigs` entries.
    /// Older entries are evicted when the limit is reached.
    private var contigCache: [String: CachedContigResult] = [:]

    /// Maximum number of BAM+contig entries held in memory.
    private static let maxCachedContigs = 20

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
        statusLabel.stringValue = "\(miniBAMFormatCount(total)) reads · \(zoomText) · ⌘+/⌘- to zoom"
        // Reads are already deduplicated by samtools upstream.
        onReadStatsUpdated?(total, total)
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
            uniqueReadCount = cached.reads.count
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

        // Fetch all reads for this contig.
        // excludeFlags: 0x904 | 0x400 = 0xD04 — exclude unmapped, secondary,
        // supplementary, and PCR/optical duplicates. Duplicate filtering
        // happens upstream in samtools markdup, so the viewer receives
        // already-deduplicated reads.
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let requestedContig = contig
            do {
                let fetchedReads = try await provider.fetchReads(
                    chromosome: contig,
                    start: 0,
                    end: contigLength,
                    excludeFlags: 0x904 | 0x400,
                    maxReads: maxReads
                )
                guard !Task.isCancelled else { return }
                guard self.contigName == requestedContig else { return }

                let visibleReads: [AlignedRead]
                if let readNameAllowlist, !readNameAllowlist.isEmpty {
                    visibleReads = fetchedReads.filter { readNameAllowlist.contains($0.name) }
                } else {
                    visibleReads = fetchedReads
                }

                self.reads = visibleReads
                self.uniqueReadCount = visibleReads.count
                self.updatePileup()

                // Keep the coverage/reference tracks pinned at the top of the viewport.
                self.scrollToTop()
                self.updateZoomStatus()
                self.scheduleDeferredReferenceInferenceIfNeeded(
                    reads: visibleReads,
                    requestedContig: requestedContig,
                    generation: generation
                )

                // Store in cache for instant re-display on repeated selections.
                if readNameAllowlist == nil {
                    let result = CachedContigResult(
                        reads: visibleReads,
                        readCount: visibleReads.count
                    )
                    self.cacheResult(result, key: key)
                }

                logger.info("Loaded \(visibleReads.count) reads for \(contig, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                self.statusLabel.stringValue = "Failed to load reads: \(error.localizedDescription)"
                logger.error("Failed to fetch reads for \(contig, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    @discardableResult
    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        let disallowed: NSEvent.ModifierFlags = [.control, .option, .function]
        guard modifiers.intersection(disallowed).isEmpty else { return false }

        switch event.keyCode {
        case 24, 69:  // =/+ main + keypad
            zoomIn()
            return true
        case 27, 78:  // - main + keypad
            zoomOut()
            return true
        case 29, 82:  // 0 main + keypad
            zoomToFit()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "+", "=":
            zoomIn()
            return true
        case "-", "_":
            zoomOut()
            return true
        case "0":
            zoomToFit()
            return true
        default:
            return false
        }
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
        pendingViewportResizeTask = Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
                self?.scheduleViewportResizeUpdate()
            }
        }
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleViewportResizeUpdate()
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

    private var isVisibleInHierarchy: Bool {
        guard isViewLoaded, view.window != nil else { return false }
        var node: NSView? = view
        while let current = node {
            if current.isHidden || current.alphaValue <= 0.01 {
                return false
            }
            node = current.superview
        }
        return true
    }

    private func shouldHandleLocalZoomShortcut(_ event: NSEvent) -> Bool {
        guard let window = view.window else { return false }
        guard window == event.window, window.isKeyWindow else { return false }
        guard isVisibleInHierarchy else { return false }
        return responderIsWithinMiniBAM(window.firstResponder)
    }

    private func responderIsWithinMiniBAM(_ responder: NSResponder?) -> Bool {
        guard let rootView = viewIfLoaded else { return false }
        var current: NSResponder? = responder
        while let responder = current {
            if let responderView = responder as? NSView, responderView.isDescendant(of: rootView) {
                return true
            }
            current = responder.nextResponder
        }
        return false
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
        let read = reads[idx]
        let qualString = String(read.qualities.map { Character(UnicodeScalar($0 + 33)) })
        let fastq = "@\(read.name)\n\(read.sequence)\n+\n\(qualString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fastq, forType: .string)
    }

    @objc private func copyReadName() {
        guard let idx = selectedReadIndex ?? pileupView.lastClickedReadIndex,
              idx < reads.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reads[idx].name, forType: .string)
    }

    /// Clears the current display.
    public func clear() {
        loadTask?.cancel()
        loadTask = nil
        deferredReferenceTask?.cancel()
        deferredReferenceTask = nil
        loadGeneration &+= 1
        reads = []
        depthPoints = []
        uniqueReadCount = 0
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

            await MainActor.run { [weak self] in
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

// MARK: - MiniPileupView

/// CoreGraphics-based view that renders a compact BAM pileup with base-level detail.
///
/// Renders:
/// - **Coverage depth track** (top 40px): area chart showing per-position depth
/// - **Read pileup** (below): packed reads with colored bases at mismatches,
///   strand arrows, soft-clip indicators, and duplicate highlighting
@MainActor
final class MiniPileupView: NSView {

    // MARK: - Data

    private var reads: [AlignedRead] = []
    private var contigName: String = ""
    private var contigLength: Int = 0
    private var packedRows: [[Int]] = []  // indices into reads array per row
    private(set) var bpPerPixel: Double = 1.0

    /// Callback when a read is clicked.
    var onReadClicked: ((Int) -> Void)?
    var onZoomInRequested: (() -> Void)?
    var onZoomOutRequested: (() -> Void)?
    var onZoomToFitRequested: (() -> Void)?

    /// Index of the last read that was right-clicked (for context menu).
    var lastClickedReadIndex: Int?
    var lastContextClickPoint: NSPoint?

    /// Domain noun used in the empty-state label.
    var subjectNoun: String = "virus"

    // MARK: - Constants

    private let depthTrackHeight: CGFloat = 40
    private let readHeight: CGFloat = 12
    private let readGap: CGFloat = 2
    private let leftMargin: CGFloat = 4
    private let topMargin: CGFloat = 4
    private let referenceTrackHeight: CGFloat = 14
    private let referenceTrackGap: CGFloat = 4

    /// Per-position inferred reference bases from aligned reads and MD tags.
    private var inferredReferenceBases: [Int: Character] = [:]
    private var packInvocationCount: Int = 0

    // MARK: - Configuration

    func configure(
        reads: [AlignedRead],
        contigName: String,
        contigLength: Int,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double = 1.0,
        rebuildReference: Bool = false,
        referenceSequence: String? = nil
    ) {
        self.reads = reads
        self.contigName = contigName
        self.contigLength = contigLength
        if rebuildReference {
            if let referenceSequence, !referenceSequence.isEmpty {
                inferredReferenceBases = Self.referenceBaseMap(from: referenceSequence)
            } else {
                inferredReferenceBases = [:]
            }
        }

        packReads()
        applyViewport(viewportWidth: viewportWidth, viewportHeight: viewportHeight, zoomLevel: zoomLevel)
    }

    func updateViewport(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double = 1.0
    ) {
        applyViewport(viewportWidth: viewportWidth, viewportHeight: viewportHeight, zoomLevel: zoomLevel)
    }

    private func applyViewport(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        zoomLevel: Double
    ) {
        // Compute bp/px: at zoom=1.0, entire contig fits in viewport.
        // Higher zoom = fewer bp/px = more detail.
        let effectiveWidth = max(1, viewportWidth - leftMargin * 2)
        let baseBpPerPx = Double(contigLength) / Double(effectiveWidth)
        bpPerPixel = max(0.1, baseBpPerPx / zoomLevel)  // min 0.1 bp/px (~10 px per base)

        // Set frame size
        let pileupHeight = CGFloat(packedRows.count) * (readHeight + readGap)
            + depthTrackHeight + referenceTrackGap + referenceTrackHeight + topMargin * 2
        let contentWidth = max(viewportWidth, CGFloat(Double(contigLength) / bpPerPixel) + leftMargin * 2)
        let contentHeight = max(200, pileupHeight, viewportHeight)
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        needsDisplay = true
    }

    private static func referenceBaseMap(from sequence: String) -> [Int: Character] {
        var bases: [Int: Character] = [:]
        bases.reserveCapacity(sequence.count)
        for (index, base) in sequence.uppercased().enumerated() {
            bases[index] = base
        }
        return bases
    }

    func clear() {
        reads = []
        packedRows = []
        inferredReferenceBases = [:]
        frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        needsDisplay = true
    }

    func applyInferredReferenceBases(_ bases: [Int: Character]) {
        inferredReferenceBases = bases
        needsDisplay = true
    }

    // MARK: - Read Packing

    private func packReads() {
        packInvocationCount += 1
        packedRows = []
        let sorted = reads.indices.sorted { reads[$0].position < reads[$1].position }

        for idx in sorted {
            let read = reads[idx]

            // Find first row where this read fits
            var placed = false
            for row in 0..<packedRows.count {
                if let lastIdx = packedRows[row].last {
                    let lastEnd = reads[lastIdx].alignmentEnd
                    if read.position > lastEnd + 2 {  // 2bp gap
                        packedRows[row].append(idx)
                        placed = true
                        break
                    }
                }
            }
            if !placed {
                packedRows.append([idx])
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !reads.isEmpty else {
            drawEmptyState()
            return
        }

        drawDepthTrack(in: dirtyRect)
        drawReferenceTrack(in: dirtyRect)
        drawPileup(in: dirtyRect)
    }

    // MARK: - Depth Track

    private func drawDepthTrack(in dirtyRect: NSRect) {
        let trackRect = NSRect(x: leftMargin, y: bounds.height - depthTrackHeight - topMargin,
                               width: bounds.width - leftMargin * 2, height: depthTrackHeight)

        // Compute per-pixel depth
        let pixelCount = Int(trackRect.width)
        guard pixelCount > 0 else { return }

        var depths = [Int](repeating: 0, count: pixelCount)
        for read in reads {
            let startPx = max(0, Int(Double(read.position) / bpPerPixel))
            let endPx = min(pixelCount - 1, Int(Double(read.alignmentEnd) / bpPerPixel))
            guard startPx <= endPx else { continue }
            for px in startPx...endPx {
                depths[px] += 1
            }
        }

        let maxDepth = max(1, depths.max() ?? 1)

        // Draw area chart
        let path = NSBezierPath()
        path.move(to: NSPoint(x: trackRect.minX, y: trackRect.minY))

        for (i, depth) in depths.enumerated() {
            let x = trackRect.minX + CGFloat(i)
            let normalizedDepth = CGFloat(depth) / CGFloat(maxDepth)
            let y = trackRect.minY + trackRect.height * normalizedDepth
            path.line(to: NSPoint(x: x, y: y))
        }

        path.line(to: NSPoint(x: trackRect.maxX, y: trackRect.minY))
        path.close()

        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()

        // Stroke top edge
        let strokePath = NSBezierPath()
        for (i, depth) in depths.enumerated() {
            let x = trackRect.minX + CGFloat(i)
            let normalizedDepth = CGFloat(depth) / CGFloat(maxDepth)
            let y = trackRect.minY + trackRect.height * normalizedDepth
            if i == 0 { strokePath.move(to: NSPoint(x: x, y: y)) }
            else { strokePath.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        strokePath.lineWidth = 1
        strokePath.stroke()

        // Max depth label
        let maxLabel = "\(maxDepth)x" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        maxLabel.draw(at: NSPoint(x: trackRect.minX + 2, y: trackRect.maxY - 12), withAttributes: attrs)
    }

    private func drawReferenceTrack(in dirtyRect: NSRect) {
        let refRect = NSRect(
            x: leftMargin,
            y: bounds.height - depthTrackHeight - topMargin - referenceTrackGap - referenceTrackHeight,
            width: bounds.width - leftMargin * 2,
            height: referenceTrackHeight
        )
        guard refRect.intersects(dirtyRect) else { return }

        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: refRect, xRadius: 3, yRadius: 3).fill()

        guard contigLength > 0 else { return }
        let basePxWidth = CGFloat(1.0 / bpPerPixel)
        guard basePxWidth > 0 else { return }

        let startRef = max(0, Int(floor(Double(dirtyRect.minX - leftMargin) * bpPerPixel)))
        let endRef = min(contigLength - 1, Int(ceil(Double(dirtyRect.maxX - leftMargin) * bpPerPixel)))
        guard endRef >= startRef else { return }

        if basePxWidth >= 5 {
            let font = NSFont.monospacedSystemFont(ofSize: min(10, max(7, basePxWidth * 0.7)), weight: .medium)
            for refPos in startRef...endRef {
                let base = inferredReferenceBases[refPos] ?? "N"
                let x = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                guard x + basePxWidth >= refRect.minX, x <= refRect.maxX else { continue }

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: baseColor(for: base),
                ]
                let str = String(base) as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(
                    at: NSPoint(
                        x: x + (basePxWidth - size.width) / 2,
                        y: refRect.minY + (referenceTrackHeight - size.height) / 2
                    ),
                    withAttributes: attrs
                )
            }
        } else {
            for refPos in startRef...endRef {
                let base = inferredReferenceBases[refPos] ?? "N"
                let x = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                let width = max(1, basePxWidth)
                let rect = NSRect(x: x, y: refRect.minY + 2, width: width, height: referenceTrackHeight - 4)
                baseColor(for: base).withAlphaComponent(0.45).setFill()
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    // MARK: - Read Pileup

    private func drawPileup(in dirtyRect: NSRect) {
        let pileupTop = bounds.height - depthTrackHeight - referenceTrackHeight - referenceTrackGap - topMargin * 2

        for (rowIdx, row) in packedRows.enumerated() {
            let rowY = pileupTop - CGFloat(rowIdx + 1) * (readHeight + readGap)
            guard rowY + readHeight >= dirtyRect.minY && rowY <= dirtyRect.maxY else { continue }

            for readIdx in row {
                let read = reads[readIdx]
                drawRead(read, at: rowY, in: dirtyRect)
            }
        }
    }

    private func drawRead(_ read: AlignedRead, at y: CGFloat, in dirtyRect: NSRect) {
        let startX = leftMargin + CGFloat(Double(read.position) / bpPerPixel)
        let endX = leftMargin + CGFloat(Double(read.alignmentEnd) / bpPerPixel)
        let width = max(2, endX - startX)

        let readRect = NSRect(x: startX, y: y, width: width, height: readHeight)

        // Skip if outside dirty rect
        guard readRect.intersects(dirtyRect) else { return }

        // Read color: forward=blue, reverse=red
        // PCR/optical duplicates are filtered upstream by samtools markdup.
        let baseColor: NSColor
        let fillOpacity: CGFloat
        if read.isReverse {
            baseColor = NSColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1.0)
            fillOpacity = 0.7
        } else {
            baseColor = NSColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 1.0)
            fillOpacity = 0.7
        }

        // Draw read body
        let readPath = NSBezierPath(roundedRect: readRect, xRadius: 2, yRadius: 2)
        baseColor.withAlphaComponent(fillOpacity).setFill()
        readPath.fill()

        // Draw strand arrow at the end
        let arrowSize: CGFloat = 4
        if read.isReverse {
            // Left-pointing arrow
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: startX, y: y + readHeight / 2))
            arrowPath.line(to: NSPoint(x: startX + arrowSize, y: y + readHeight))
            arrowPath.line(to: NSPoint(x: startX + arrowSize, y: y))
            arrowPath.close()
            baseColor.setFill()
            arrowPath.fill()
        } else {
            // Right-pointing arrow
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: endX, y: y + readHeight / 2))
            arrowPath.line(to: NSPoint(x: endX - arrowSize, y: y + readHeight))
            arrowPath.line(to: NSPoint(x: endX - arrowSize, y: y))
            arrowPath.close()
            baseColor.setFill()
            arrowPath.fill()
        }

        // At high zoom: draw individual base letters on the read
        let effectiveBpPerPx = bpPerPixel / max(1, Double(window?.backingScaleFactor ?? 1))
        let hasReferenceBases = !inferredReferenceBases.isEmpty
        if effectiveBpPerPx < 0.5 {
            // Ultra-zoom: draw full sequence bases
            drawBaseLetters(read: read, startX: startX, y: y)
            if hasReferenceBases {
                drawReferenceDifferences(read: read, readRect: readRect, y: y, style: .baseLevel)
            } else if let mdTag = read.mdTag {
                drawMismatchesFromMD(read: read, mdTag: mdTag, readRect: readRect, y: y, style: .outline)
            }
        } else if bpPerPixel < 8 {
            // Medium zoom: draw mismatches as colored ticks.
            if hasReferenceBases {
                drawReferenceDifferences(read: read, readRect: readRect, y: y, style: .compact)
            } else if let mdTag = read.mdTag {
                drawMismatchesFromMD(read: read, mdTag: mdTag, readRect: readRect, y: y, style: .fillTick)
            }
        }

        // Draw soft-clip indicators from CIGAR.
        // Leading clips extend left of alignment start; trailing clips extend
        // right of alignment end.
        let cigar = read.cigar
        if let first = cigar.first, first.op == .softClip {
            let clipWidth = max(2, CGFloat(Double(first.length) / bpPerPixel))
            let clipRect = NSRect(x: startX - clipWidth, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }
        if let last = cigar.last, last.op == .softClip, cigar.count > 1 {
            let clipWidth = max(2, CGFloat(Double(last.length) / bpPerPixel))
            let clipRect = NSRect(x: endX, y: y, width: clipWidth, height: readHeight)
            NSColor.systemYellow.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: clipRect).fill()
        }
    }

    /// Draws individual base letters on the read at high zoom levels.
    ///
    /// Walks the CIGAR string to correctly map query bases to reference
    /// positions.  Soft-clipped bases are skipped (they don't align to
    /// the reference).
    private func drawBaseLetters(read: AlignedRead, startX: CGFloat, y: CGFloat) {
        let basePxWidth = CGFloat(1.0 / bpPerPixel)
        guard basePxWidth >= 4 else { return }  // Too small to render letters

        let fontSize = min(10, max(6, basePxWidth * 0.8))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let readBases = Array(read.sequence)

        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    let q = queryPos + offset
                    guard q < readBases.count else { break }
                    let char = readBases[q]
                    let x = leftMargin + CGFloat(Double(refPos + offset) / bpPerPixel)
                    let color = baseColor(for: char)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: color,
                    ]
                    let str = String(char) as NSString
                    let size = str.size(withAttributes: attrs)
                    str.draw(
                        at: NSPoint(x: x + (basePxWidth - size.width) / 2, y: y + (readHeight - size.height) / 2),
                        withAttributes: attrs
                    )
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }
    }

    /// Draws mismatches parsed from the MD tag as colored ticks on the read.
    ///
    /// The MD tag format: `[0-9]+(([A-Z]|\^[A-Z]+)[0-9]+)*`
    /// Numbers indicate matching bases; letters indicate mismatches;
    /// ^letters indicate deletions from reference.
    private enum MismatchMarkerStyle {
        case fillTick
        case outline
    }

    private enum ReferenceDifferenceStyle {
        case compact
        case baseLevel
    }

    private func drawMismatchesFromMD(
        read: AlignedRead,
        mdTag: String,
        readRect: NSRect,
        y: CGFloat,
        style: MismatchMarkerStyle
    ) {
        var refPos = read.position
        var i = mdTag.startIndex
        let queryByReference = buildReferenceToQueryIndexMap(for: read)

        while i < mdTag.endIndex {
            let ch = mdTag[i]

            if ch.isNumber {
                // Matching bases: skip forward
                var numStr = ""
                while i < mdTag.endIndex && mdTag[i].isNumber {
                    numStr.append(mdTag[i])
                    i = mdTag.index(after: i)
                }
                refPos += Int(numStr) ?? 0
            } else if ch == "^" {
                // Deletion from reference: skip bases
                i = mdTag.index(after: i)
                while i < mdTag.endIndex && mdTag[i].isLetter {
                    refPos += 1
                    i = mdTag.index(after: i)
                }
            } else if ch.isLetter {
                // Mismatch: draw colored tick
                let mismatchX = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
                if mismatchX >= readRect.minX && mismatchX <= readRect.maxX {
                    // Get the read base at this position from the sequence
                    let queryOffset = queryByReference[refPos] ?? (refPos - read.position)
                    let readBase: Character
                    if queryOffset >= 0 && queryOffset < read.sequence.count {
                        let idx = read.sequence.index(read.sequence.startIndex, offsetBy: queryOffset)
                        readBase = read.sequence[idx]
                    } else {
                        readBase = "N"
                    }

                    let color = baseColor(for: readBase)

                    let tickWidth: CGFloat
                    switch style {
                    case .fillTick:
                        tickWidth = max(2, CGFloat(1 / bpPerPixel))
                    case .outline:
                        tickWidth = max(1, CGFloat(1 / bpPerPixel))
                    }
                    let tickRect = NSRect(x: mismatchX, y: y, width: max(1, tickWidth), height: readHeight)
                    switch style {
                    case .fillTick:
                        color.setFill()
                        NSBezierPath(rect: tickRect).fill()
                    case .outline:
                        let outline = NSBezierPath(roundedRect: tickRect.insetBy(dx: -0.5, dy: -0.5), xRadius: 1, yRadius: 1)
                        color.setStroke()
                        outline.lineWidth = 1.2
                        outline.stroke()
                    }
                }

                refPos += 1
                i = mdTag.index(after: i)
            } else {
                i = mdTag.index(after: i)
            }
        }
    }

    private func drawReferenceDifferences(
        read: AlignedRead,
        readRect: NSRect,
        y: CGFloat,
        style: ReferenceDifferenceStyle
    ) {
        let readBases = Array(read.sequence.uppercased())
        guard !readBases.isEmpty else { return }
        let queryByReference = buildReferenceToQueryIndexMap(for: read)
        guard !queryByReference.isEmpty else { return }

        for (refPos, queryOffset) in queryByReference {
            guard queryOffset >= 0, queryOffset < readBases.count else { continue }
            guard let referenceBase = inferredReferenceBases[refPos], referenceBase != "N" else { continue }

            let readBase = readBases[queryOffset]
            guard readBase != "N", readBase != referenceBase else { continue }

            let mismatchX = leftMargin + CGFloat(Double(refPos) / bpPerPixel)
            guard mismatchX >= readRect.minX - 1, mismatchX <= readRect.maxX + 1 else { continue }

            let markerWidth = max(2, CGFloat(1 / bpPerPixel))
            let markerRect = NSRect(x: mismatchX, y: y, width: max(1, markerWidth), height: readHeight)
            let markerColor = baseColor(for: readBase)

            switch style {
            case .compact:
                markerColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(rect: markerRect).fill()
            case .baseLevel:
                NSColor.systemYellow.withAlphaComponent(0.32).setFill()
                NSBezierPath(rect: markerRect).fill()
                let outline = NSBezierPath(
                    roundedRect: markerRect.insetBy(dx: -0.4, dy: -0.4),
                    xRadius: 1,
                    yRadius: 1
                )
                markerColor.setStroke()
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }

    private func baseColor(for base: Character) -> NSColor {
        switch base.uppercased() {
        case "A": return NSColor(red: 0, green: 0.6, blue: 0, alpha: 1)
        case "T": return NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)
        case "G": return NSColor(red: 0.8, green: 0.7, blue: 0, alpha: 1)
        case "C": return NSColor(red: 0, green: 0, blue: 0.8, alpha: 1)
        default: return .systemGray
        }
    }

    private func buildReferenceToQueryIndexMap(for read: AlignedRead) -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    mapping[refPos + offset] = queryPos + offset
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }

        return mapping
    }

    nonisolated static func inferReferenceBases(reads: [AlignedRead], contigLength: Int) -> [Int: Character] {
        guard !reads.isEmpty else { return [:] }

        var baseVotes: [Int: [Character: Int]] = [:]
        for read in reads {
            let inferredForRead = inferReferenceBases(for: read)
            for (refPos, base) in inferredForRead {
                guard refPos >= 0 && refPos < contigLength else { continue }
                baseVotes[refPos, default: [:]][base, default: 0] += 1
            }
        }

        var inferred: [Int: Character] = [:]
        for (refPos, votes) in baseVotes {
            let winner = votes.max { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value < rhs.value
            }?.key ?? "N"
            inferred[refPos] = winner
        }
        return inferred
    }

    private nonisolated static func inferReferenceBases(for read: AlignedRead) -> [Int: Character] {
        let readBases = Array(read.sequence.uppercased())
        guard !readBases.isEmpty else { return [:] }

        var inferred: [Int: Character] = [:]
        var refPos = read.position
        var queryPos = 0

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for offset in 0..<op.length {
                    let q = queryPos + offset
                    if q >= 0, q < readBases.count {
                        inferred[refPos + offset] = readBases[q]
                    }
                }
                refPos += op.length
                queryPos += op.length
            case .insertion, .softClip:
                queryPos += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }

        guard let mdTag = read.mdTag, !mdTag.isEmpty else { return inferred }

        refPos = read.position
        var idx = mdTag.startIndex
        while idx < mdTag.endIndex {
            let ch = mdTag[idx]
            if ch.isNumber {
                var numStr = ""
                while idx < mdTag.endIndex, mdTag[idx].isNumber {
                    numStr.append(mdTag[idx])
                    idx = mdTag.index(after: idx)
                }
                refPos += Int(numStr) ?? 0
            } else if ch == "^" {
                idx = mdTag.index(after: idx)
                while idx < mdTag.endIndex, mdTag[idx].isLetter {
                    inferred[refPos] = Character(String(mdTag[idx]).uppercased())
                    refPos += 1
                    idx = mdTag.index(after: idx)
                }
            } else if ch.isLetter {
                inferred[refPos] = Character(String(ch).uppercased())
                refPos += 1
                idx = mdTag.index(after: idx)
            } else {
                idx = mdTag.index(after: idx)
            }
        }

        return inferred
    }

    private func drawEmptyState() {
        let text = "Select a \(subjectNoun) to view read alignments" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    // MARK: - Hit Testing

    override var acceptsFirstResponder: Bool { true }

    private func handleZoomShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        let disallowed: NSEvent.ModifierFlags = [.control, .option, .function]
        guard modifiers.intersection(disallowed).isEmpty else { return false }

        switch event.keyCode {
        case 24, 69:
            onZoomInRequested?()
            return true
        case 27, 78:
            onZoomOutRequested?()
            return true
        case 29, 82:
            onZoomToFitRequested?()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "+", "=":
            onZoomInRequested?()
            return true
        case "-", "_":
            onZoomOutRequested?()
            return true
        case "0":
            onZoomToFitRequested?()
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleZoomShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleZoomShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Finds the read index at a given point in view coordinates.
    private func readIndex(at point: NSPoint) -> Int? {
        let pileupTop = bounds.height - depthTrackHeight - referenceTrackHeight - referenceTrackGap - topMargin * 2

        for (rowIdx, row) in packedRows.enumerated() {
            let rowY = pileupTop - CGFloat(rowIdx + 1) * (readHeight + readGap)

            for readIdx in row {
                let read = reads[readIdx]
                let startX = leftMargin + CGFloat(Double(read.position) / bpPerPixel)
                let endX = leftMargin + CGFloat(Double(read.alignmentEnd) / bpPerPixel)
                let readRect = NSRect(x: startX, y: rowY, width: max(2, endX - startX), height: readHeight)

                if readRect.contains(point) {
                    return readIdx
                }
            }
        }
        return nil
    }

    private func pointInDocumentCoordinates(from event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = pointInDocumentCoordinates(from: event)
        if let idx = readIndex(at: point) {
            lastClickedReadIndex = idx
            onReadClicked?(idx)
        } else {
            lastClickedReadIndex = nil
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = pointInDocumentCoordinates(from: event)
        lastContextClickPoint = point
        lastClickedReadIndex = readIndex(at: point)
        return super.menu(for: event)
    }

    var testPackInvocationCount: Int { packInvocationCount }
    var testInferredReferenceBaseCount: Int { inferredReferenceBases.count }
}
