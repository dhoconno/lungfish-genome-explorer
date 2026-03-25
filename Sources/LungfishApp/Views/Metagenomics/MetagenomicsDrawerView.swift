// MetagenomicsDrawerView.swift - Unified bottom drawer for metagenomics result views
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "MetagenomicsDrawer")

// MARK: - MetagenomicsDrawerDelegate

/// Delegate protocol for the unified metagenomics drawer.
@MainActor
public protocol MetagenomicsDrawerDelegate: AnyObject {
    /// Called when the user drags the divider to resize the drawer.
    func metagenomicsDrawerDidDragDivider(_ drawer: MetagenomicsDrawerView, deltaY: CGFloat)

    /// Called when the user finishes dragging the divider.
    func metagenomicsDrawerDidFinishDraggingDivider(_ drawer: MetagenomicsDrawerView)

    /// Called when the user clicks "Extract" on a collection.
    func metagenomicsDrawer(_ drawer: MetagenomicsDrawerView, didRequestExtractFor collection: TaxaCollection)
}

// MARK: - MetagenomicsDrawerTab

/// Tab identifiers for the unified metagenomics drawer.
enum MetagenomicsDrawerTab: Int, CaseIterable {
    case samples = 0
    case collections = 1
    case blastResults = 2

    var title: String {
        switch self {
        case .samples: return "Samples"
        case .collections: return "Collections"
        case .blastResults: return "BLAST Results"
        }
    }
}

// MARK: - MetagenomicsDividerView

/// Drag-to-resize handle at the top of the metagenomics drawer.
///
/// Reuses the same divider visual pattern as ``TaxaCollectionsDividerView``
/// and ``DrawerDividerView``.
@MainActor
final class MetagenomicsDividerView: NSView {

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        dragStartY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

// MARK: - MetagenomicsDrawerView

/// Unified bottom drawer for metagenomics result views.
///
/// Hosts three tabs: Samples, Collections, and BLAST Results.
/// The Samples tab provides metadata display and sample filtering for
/// batch analyses. Collections and BLAST Results are carried over from
/// the existing `TaxaCollectionsDrawerView`.
///
/// ## Layout
///
/// ```
/// +------------------------------------------------------------------+
/// | [===== Drag Handle =====]                                         |
/// +------------------------------------------------------------------+
/// | [Samples] [Collections] [BLAST Results]          [Filter: ____]   |
/// +------------------------------------------------------------------+
/// |  (tab content)                                                    |
/// +------------------------------------------------------------------+
/// ```
@MainActor
public final class MetagenomicsDrawerView: NSView {

    // MARK: - Delegate

    weak var delegate: MetagenomicsDrawerDelegate?

    // MARK: - Child Views

    let dividerView = MetagenomicsDividerView()
    let tabControl = NSSegmentedControl()
    let samplesTab = SampleFilterDrawerTab()
    let collectionsTab: TaxaCollectionsDrawerView
    let blastResultsTab = BlastResultsDrawerTab()

    // MARK: - State

    private(set) var selectedTab: MetagenomicsDrawerTab = .samples

    /// Returns the set of currently visible (checked) sample IDs.
    var visibleSampleIds: Set<String> {
        samplesTab.visibleSampleIds
    }

    /// Called when the user changes sample visibility.
    var onSampleFilterChanged: ((Set<String>) -> Void)? {
        get { samplesTab.onFilterChanged }
        set { samplesTab.onFilterChanged = newValue }
    }

    // MARK: - Init

    init(collectionsDrawer: TaxaCollectionsDrawerView? = nil) {
        self.collectionsTab = collectionsDrawer ?? TaxaCollectionsDrawerView()
        super.init(frame: .zero)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupLayout() {
        // Divider
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        dividerView.onDrag = { [weak self] delta in
            guard let self else { return }
            delegate?.metagenomicsDrawerDidDragDivider(self, deltaY: delta)
        }
        dividerView.onDragEnd = { [weak self] in
            guard let self else { return }
            delegate?.metagenomicsDrawerDidFinishDraggingDivider(self)
        }

        // Tab control
        tabControl.segmentCount = MetagenomicsDrawerTab.allCases.count
        for tab in MetagenomicsDrawerTab.allCases {
            tabControl.setLabel(tab.title, forSegment: tab.rawValue)
            tabControl.setWidth(0, forSegment: tab.rawValue) // auto-size
        }
        tabControl.selectedSegment = MetagenomicsDrawerTab.samples.rawValue
        tabControl.segmentStyle = .rounded
        tabControl.controlSize = .small
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabControl)

        // Tab content views
        samplesTab.translatesAutoresizingMaskIntoConstraints = false
        collectionsTab.translatesAutoresizingMaskIntoConstraints = false
        blastResultsTab.translatesAutoresizingMaskIntoConstraints = false

        addSubview(samplesTab)
        addSubview(collectionsTab)
        addSubview(blastResultsTab)

        // Layout constraints
        NSLayoutConstraint.activate([
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 8),

            tabControl.topAnchor.constraint(equalTo: dividerView.bottomAnchor, constant: 4),
            tabControl.centerXAnchor.constraint(equalTo: centerXAnchor),

            samplesTab.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            samplesTab.leadingAnchor.constraint(equalTo: leadingAnchor),
            samplesTab.trailingAnchor.constraint(equalTo: trailingAnchor),
            samplesTab.bottomAnchor.constraint(equalTo: bottomAnchor),

            collectionsTab.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            collectionsTab.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionsTab.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionsTab.bottomAnchor.constraint(equalTo: bottomAnchor),

            blastResultsTab.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            blastResultsTab.leadingAnchor.constraint(equalTo: leadingAnchor),
            blastResultsTab.trailingAnchor.constraint(equalTo: trailingAnchor),
            blastResultsTab.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Show initial tab
        updateTabVisibility()
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = MetagenomicsDrawerTab(rawValue: sender.selectedSegment) else { return }
        switchToTab(tab)
    }

    func switchToTab(_ tab: MetagenomicsDrawerTab) {
        selectedTab = tab
        tabControl.selectedSegment = tab.rawValue
        updateTabVisibility()
    }

    private func updateTabVisibility() {
        samplesTab.isHidden = selectedTab != .samples
        collectionsTab.isHidden = selectedTab != .collections
        blastResultsTab.isHidden = selectedTab != .blastResults
    }

    // MARK: - BLAST Results

    /// Switches to the BLAST Results tab and populates it.
    func showBlastResults(_ result: BlastVerificationResult) {
        blastResultsTab.showResults(result)
        switchToTab(.blastResults)
    }

    // MARK: - Sample Configuration

    /// Configures the Samples tab with batch sample data.
    func configureSamples(sampleIds: [String], metadata: [String: FASTQSampleMetadata]) {
        samplesTab.configure(sampleIds: sampleIds, metadata: metadata)
    }
}
