// MSABottomPaneView.swift - Tabbed pane under the MSA viewport: annotation table and distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishAlignmentUI
import LungfishIO

/// One bottom pane under the alignment with a segmented control
/// [Annotations | Distances] (ruling U1). The pane owns the single divider,
/// its height, its open state and its last tab, and persists all three.
@MainActor
final class MSABottomPaneView: NSView {
    enum Tab: Int, CaseIterable {
        case annotations = 0
        case distances = 1

        var title: String {
            switch self {
            case .annotations: return "Annotations"
            case .distances: return "Distances"
            }
        }

        var defaultsValue: String {
            switch self {
            case .annotations: return "annotations"
            case .distances: return "distances"
            }
        }

        init?(defaultsValue: String) {
            guard let tab = Tab.allCases.first(where: { $0.defaultsValue == defaultsValue }) else { return nil }
            self = tab
        }
    }

    enum DefaultsKey {
        static let height = "msaBottomPane.height"
        static let tab = "msaBottomPane.tab"
        static let isOpen = "msaBottomPane.isOpen"
    }

    static let minimumHeight: CGFloat = 120
    /// The alignment keeps at least this much height above the pane.
    static let reservedAlignmentHeight: CGFloat = 140
    static let defaultHeight: CGFloat = 260
    static let animationDuration: TimeInterval = 0.25
    static let headerHeight: CGFloat = 28

    let divider = DrawerDividerView()
    let tabControl = NSSegmentedControl(
        labels: Tab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let annotationDrawer: AnnotationTableDrawerView
    let distancePane: MSADistanceMatrixPaneView

    var defaults: UserDefaults {
        didSet { restorePersistedState() }
    }
    /// Injected so tests can assert the Reduce Motion path.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var onTabChanged: ((Tab) -> Void)?
    var onOpenStateChanged: ((Bool) -> Void)?

    private(set) var isOpen = false
    private(set) var selectedTab: Tab = .distances
    private(set) var lastAnimationDuration: TimeInterval = 0
    private(set) lazy var heightConstraint: NSLayoutConstraint = heightAnchor.constraint(equalToConstant: 0)

    /// The Distances tab needs a stored bundle; a read-only alignment has none.
    var isDistancesAvailable = true {
        didSet {
            tabControl.setEnabled(isDistancesAvailable, forSegment: Tab.distances.rawValue)
            showContent()
        }
    }

    /// True while the pane drives the alignment selection, so the alignment
    /// does not echo the change back into the matrix.
    var isDrivingAlignmentSelection = false

    /// Builds the Distances input on demand, so an alignment whose matrix is
    /// never shown is never converted or computed. A thrown error, such as an
    /// unreadable alphabet, shows in the pane instead of a guessed input.
    typealias DistanceInput = () throws -> (records: [MSAAlignedRecord], alphabet: MSASequenceAlphabet)
    private var pendingDistanceInput: DistanceInput?

    /// Replaces the alignment the Distances tab computes from. Nil clears it.
    func setDistanceInput(_ input: DistanceInput?) {
        pendingDistanceInput = input
        if input == nil { distancePane.load(records: [], alphabet: .nucleotide) }
    }

    /// Loads the pending alignment into the Distances pane once.
    func loadPendingDistanceInput() {
        guard let input = pendingDistanceInput else { return }
        pendingDistanceInput = nil
        do {
            let (records, alphabet) = try input()
            distancePane.load(records: records, alphabet: alphabet)
        } catch {
            distancePane.showLoadFailure(error.localizedDescription)
        }
    }

    /// The view the pane follows in the key view loop, set by the host.
    private weak var keyViewAnchor: NSView?

    /// Splices the pane into the key view loop right after `anchor` once the
    /// pane is in a window, where the anchor's own next view is known
    /// (review S3, re-review SF2).
    func insertIntoKeyViewLoop(after anchor: NSView) {
        keyViewAnchor = anchor
        spliceIntoKeyViewLoopIfInWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spliceIntoKeyViewLoopIfInWindow()
    }

    private func spliceIntoKeyViewLoopIfInWindow() {
        guard window != nil, let anchor = keyViewAnchor, anchor.nextKeyView !== divider else { return }
        linkKeyViewLoop(after: anchor, before: anchor.nextKeyView)
    }

    /// Where Tab goes from the pane's last view, set when the pane is linked.
    private weak var keyViewExit: NSView?
    /// The anchor's previous view, kept when the exit is the anchor itself.
    private weak var anchorPreviousKeyView: NSView?

    /// Links `previous` to the divider, the tab control, the visible tab's
    /// content, then `next`. With no `next`, Tab from the pane returns to
    /// `previous`, so the grid and the table are never a dead end
    /// (re-review SF-A). Outside the pane only `next.previousKeyView`
    /// changes, and `previous` keeps its own previous view.
    func linkKeyViewLoop(after previous: NSView, before next: NSView?) {
        let anchorPrevious = previous.previousKeyView
        previous.nextKeyView = divider
        divider.nextKeyView = tabControl
        keyViewExit = next ?? previous
        anchorPreviousKeyView = next == nil ? anchorPrevious : nil
        routeKeyViewLoopToVisibleTab()
    }

    /// Sends the tab control to the visible tab's content. The hidden tab's
    /// last view links to the exit first, so Shift-Tab from the exit returns
    /// to the visible one.
    private func routeKeyViewLoopToVisibleTab() {
        guard let exit = keyViewExit else { return }
        // Annotations: filter field, visible header controls, table (re-review S4).
        let annotations = annotationDrawer.linkEmbeddedKeyViewChain()
        let table = annotations.last
        let grid = distancePane.lastKeyView
        let showsTable = visibleTab == .annotations
        (showsTable ? grid : table).nextKeyView = exit
        (showsTable ? table : grid).nextKeyView = exit
        tabControl.nextKeyView = showsTable ? annotations.first : distancePane.firstKeyView
        if let anchorPrevious = anchorPreviousKeyView, anchorPrevious.nextKeyView === exit {
            // Re-linking gives the exit back its own previous view.
            anchorPrevious.nextKeyView = nil
            anchorPrevious.nextKeyView = exit
        }
    }

    var hasPendingDistanceInput: Bool { pendingDistanceInput != nil }

    private let headerStrip = NSView()
    private let contentView = NSView()

    init(
        annotationDrawer: AnnotationTableDrawerView,
        distancePane: MSADistanceMatrixPaneView? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.annotationDrawer = annotationDrawer
        self.distancePane = distancePane
            ?? MSADistanceMatrixPaneView(model: MSADistanceMatrixPaneModel(defaults: defaults))
        self.defaults = defaults
        super.init(frame: .zero)
        clipsToBounds = true
        build()
        restorePersistedState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Building

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Alignment bottom pane")
        setAccessibilityIdentifier("msa-bottom-pane")

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setAccessibilityLabel("Bottom pane resize handle")
        divider.setAccessibilityIdentifier("msa-bottom-pane-divider")
        divider.setAccessibilityHelp(
            "Drag vertically, or press the Up and Down Arrow keys, to resize the pane under the alignment."
        )
        divider.onResize = { [weak self] delta in self?.resize(by: delta, persist: false) }
        divider.onFinishResize = { [weak self] in self?.persistHeight() }
        divider.currentHeight = { [weak self] in self?.heightConstraint.constant ?? 0 }
        distancePane.onMatrixShown = { [weak self] in self?.growToFitDistances() }

        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.clipsToBounds = true
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.segmentStyle = .rounded
        tabControl.controlSize = .small
        tabControl.target = self
        tabControl.action = #selector(tabControlChanged(_:))
        tabControl.setAccessibilityLabel("Bottom pane content")
        tabControl.setAccessibilityIdentifier("msa-bottom-pane-tabs")
        tabControl.setToolTip("Annotation table", forSegment: Tab.annotations.rawValue)
        tabControl.setToolTip("Pairwise distance matrix (Control-Command-M)", forSegment: Tab.distances.rawValue)
        headerStrip.addSubview(tabControl)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.clipsToBounds = true
        annotationDrawer.translatesAutoresizingMaskIntoConstraints = false
        annotationDrawer.showsDragHandle = false
        annotationDrawer.hidesTabControl = true
        distancePane.translatesAutoresizingMaskIntoConstraints = false
        for content in [annotationDrawer, distancePane] as [NSView] {
            contentView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: contentView.topAnchor),
                content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        addSubview(divider)
        addSubview(headerStrip)
        addSubview(contentView)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: AnnotationDrawerSizing.dividerHeight),

            headerStrip.topAnchor.constraint(equalTo: divider.bottomAnchor),
            headerStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStrip.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            tabControl.leadingAnchor.constraint(equalTo: headerStrip.leadingAnchor, constant: 8),
            tabControl.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            contentView.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Lower than required so a zero height while closed never conflicts
        // with the fixed divider and header heights inside.
        heightConstraint.priority = .defaultHigh + 1
        heightConstraint.isActive = true
    }

    // MARK: State

    /// Reads the open state, tab and height from the defaults, without animation.
    func restorePersistedState() {
        let storedTab = defaults.string(forKey: DefaultsKey.tab).flatMap(Tab.init(defaultsValue:))
        // With no stored choice the pane opens on the Distances tab.
        selectedTab = storedTab ?? .distances
        tabControl.selectedSegment = selectedTab.rawValue
        showContent()
        // With no stored choice the pane starts open. An explicit hide or tab
        // pick is stored and wins on later opens.
        let storedOpen = defaults.object(forKey: DefaultsKey.isOpen) as? Bool
        applyOpen(storedOpen ?? true, animated: false, persist: false)
    }

    /// The height the pane opens to, from the defaults.
    var preferredOpenHeight: CGFloat {
        let stored = CGFloat(defaults.double(forKey: DefaultsKey.height))
        return stored >= Self.minimumHeight ? stored : Self.defaultHeight
    }

    /// Matrix rows the Distances tab shows on first open, before the user
    /// has chosen a height.
    static let firstOpenDistanceRows = 6
    /// Matrix rows the Distances tab always shows, even at a stored height.
    static let minimumDistanceRows = 2

    private var hasStoredHeight: Bool {
        CGFloat(defaults.double(forKey: DefaultsKey.height)) >= Self.minimumHeight
    }

    /// The open height the Distances tab needs to show its column header and
    /// enough rows: six before the user picks a height, two after. Nil while
    /// no matrix is on screen. Not clamped.
    var distancesFittingHeight: CGFloat? {
        let rows = hasStoredHeight ? Self.minimumDistanceRows : Self.firstOpenDistanceRows
        guard let fit = distancePane.fittingHeight(rows: rows) else { return nil }
        return AnnotationDrawerSizing.dividerHeight + Self.headerHeight + fit
    }

    /// True from an open or a switch to the Distances tab until the tab has
    /// grown once to fit. A recompute never grows the pane again, so a
    /// height the user dragged stays (re-review S2).
    private(set) var isDistancesGrowPending = false
    /// True while the open animation runs. A grow waits for it to land,
    /// since the running animator would end on its own target (re-review S1).
    private(set) var isAnimatingOpen = false
    private var openAnimationGeneration = 0

    /// Grows an open Distances tab that is too short for its column header
    /// and rows, once per open and per switch to the tab. A taller height,
    /// stored or dragged, stays. The grown height is not stored, so it never
    /// overrides the user's own choice.
    func growToFitDistances() {
        guard isDistancesGrowPending, !isAnimatingOpen, isOpen, visibleTab == .distances,
              let fit = distancesFittingHeight else { return }
        isDistancesGrowPending = false
        let target = Self.clampedHeight(fit, hostHeight: hostHeight)
        guard heightConstraint.constant < target else { return }
        heightConstraint.constant = target
        superview?.layoutSubtreeIfNeeded()
    }

    /// The visible tab: Distances falls back to Annotations while unavailable.
    var visibleTab: Tab {
        selectedTab == .distances && !isDistancesAvailable ? .annotations : selectedTab
    }

    /// Clamps a height to at least 120pt and at most the host height minus 140pt.
    static func clampedHeight(_ proposed: CGFloat, hostHeight: CGFloat) -> CGFloat {
        let maximum = max(minimumHeight, hostHeight - reservedAlignmentHeight)
        return min(max(proposed, minimumHeight), maximum)
    }

    private var hostHeight: CGFloat {
        let height = superview?.bounds.height ?? 0
        return height > 0 ? height : .greatestFiniteMagnitude
    }

    func setOpen(_ open: Bool, animated: Bool = true) {
        applyOpen(open, animated: animated, persist: true)
    }

    func select(_ tab: Tab) {
        defer { growToFitDistances() }
        guard tab != selectedTab else {
            showContent()
            return
        }
        if tab == .distances { isDistancesGrowPending = true }
        selectedTab = tab
        tabControl.selectedSegment = tab.rawValue
        defaults.set(tab.defaultsValue, forKey: DefaultsKey.tab)
        showContent()
        onTabChanged?(tab)
    }

    /// Changes the open height by `delta`, clamped. Backs the divider drag,
    /// its arrow keys and View > Make Drawer Taller / Shorter.
    func resize(by delta: CGFloat, persist: Bool = true) {
        guard isOpen else { return }
        heightConstraint.constant = Self.clampedHeight(heightConstraint.constant + delta, hostHeight: hostHeight)
        superview?.layoutSubtreeIfNeeded()
        if persist { persistHeight() }
    }

    private func persistHeight() {
        guard isOpen else { return }
        defaults.set(Double(heightConstraint.constant), forKey: DefaultsKey.height)
    }

    private func applyOpen(_ open: Bool, animated: Bool, persist: Bool) {
        let changed = open != isOpen
        isOpen = open
        if open && changed { isDistancesGrowPending = true }
        openAnimationGeneration += 1
        let generation = openAnimationGeneration
        if persist { defaults.set(open, forKey: DefaultsKey.isOpen) }
        var openHeight = preferredOpenHeight
        if visibleTab == .distances, let fit = distancesFittingHeight { openHeight = max(openHeight, fit) }
        let target = open ? Self.clampedHeight(openHeight, hostHeight: hostHeight) : 0
        if open { isHidden = false }
        let duration = animated && !reduceMotion() ? Self.animationDuration : 0
        lastAnimationDuration = duration
        if duration == 0 || window == nil {
            isAnimatingOpen = false
            heightConstraint.constant = target
            superview?.layoutSubtreeIfNeeded()
            isHidden = !open
            if open { growToFitDistances() }
        } else {
            isAnimatingOpen = open
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                heightConstraint.animator().constant = target
                superview?.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.openAnimationGeneration else { return }
                    self.isAnimatingOpen = false
                    if self.isOpen {
                        // A matrix that arrived mid-animation grows the pane now.
                        self.growToFitDistances()
                    } else {
                        self.isHidden = true
                    }
                }
            }
        }
        if changed { onOpenStateChanged?(open) }
    }

    private func showContent() {
        let tab = visibleTab
        annotationDrawer.isHidden = tab != .annotations
        distancePane.isHidden = tab != .distances
        if tabControl.selectedSegment != tab.rawValue {
            tabControl.selectedSegment = tab.rawValue
        }
        routeKeyViewLoopToVisibleTab()
    }

    @objc private func tabControlChanged(_ sender: NSSegmentedControl) {
        guard let tab = Tab(rawValue: sender.selectedSegment) else { return }
        select(tab)
    }
}
