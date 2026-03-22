// TaxonomyViewController.swift - Complete taxonomy browser combining sunburst and table
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyViewController")

// MARK: - TaxonomyViewController

/// A full-screen taxonomy browser combining a sunburst chart and hierarchical table.
///
/// `TaxonomyViewController` is the primary UI for displaying Kraken2 classification
/// results. It replaces the normal sequence viewer content area following the same
/// child-VC pattern used by ``FASTACollectionViewController``.
///
/// ## Layout
///
/// ```
/// +------------------------------------------+
/// | Summary Bar (48pt)                       |
/// +------------------------------------------+
/// | Breadcrumb Bar (28pt)                    |
/// +------------------------------------------+
/// |  Sunburst Chart  |  Taxonomy Table       |
/// |                  |                       |
/// |    (resizable NSSplitView)               |
/// +------------------------------------------+
/// | Action Bar (36pt)                        |
/// +------------------------------------------+
/// ```
///
/// ## Selection Synchronization
///
/// Clicking a segment in the sunburst selects the corresponding row in the table,
/// and clicking a table row highlights the corresponding sunburst segment. A
/// suppression flag prevents infinite feedback loops (per project conventions).
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class TaxonomyViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - Data

    /// The classification result driving this view.
    private var classificationResult: ClassificationResult?

    /// The taxonomy tree extracted from the result.
    private var tree: TaxonTree?

    // MARK: - Child Views

    private let summaryBar = TaxonomySummaryBar()
    private let breadcrumbBar = TaxonomyBreadcrumbBar()
    private let splitView = NSSplitView()
    private let sunburstView = TaxonomySunburstView()
    private let taxonomyTableView = TaxonomyTableView()
    private let actionBar = TaxonomyActionBar()

    // MARK: - Selection Sync

    /// When true, programmatic selection changes don't trigger cross-view sync.
    /// Prevents infinite loops when syncing between sunburst and table.
    private var suppressSelectionSync = false

    // MARK: - Callbacks

    /// Called when the user requests sequence extraction from a taxon.
    ///
    /// - Parameters:
    ///   - node: The taxon to extract reads for.
    ///   - includeChildren: Whether to include child taxa in the extraction.
    public var onExtractSequences: ((TaxonNode, Bool) -> Void)?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupBreadcrumbBar()
        setupSplitView()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
    }

    // MARK: - Public API

    /// Configures the taxonomy view with a classification result.
    ///
    /// Populates the summary bar, sunburst chart, taxonomy table, and action bar
    /// with data from the classification result.
    ///
    /// - Parameter result: The classification result to display.
    public func configure(result: ClassificationResult) {
        classificationResult = result
        tree = result.tree

        summaryBar.update(tree: result.tree)
        sunburstView.tree = result.tree
        sunburstView.centerNode = nil
        sunburstView.selectedNode = nil
        taxonomyTableView.tree = result.tree
        actionBar.configure(totalReads: result.tree.totalReads)
        actionBar.updateSelection(nil)
        breadcrumbBar.update(zoomNode: nil)

        logger.info("Configured with \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")

    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Breadcrumb Bar

    private func setupBreadcrumbBar() {
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(breadcrumbBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with sunburst (left) and table (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    /// Delegate methods are safe on raw NSSplitView instances.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Sunburst container (left pane)
        let sunburstContainer = NSView()
        sunburstContainer.translatesAutoresizingMaskIntoConstraints = false
        sunburstView.translatesAutoresizingMaskIntoConstraints = false
        sunburstContainer.addSubview(sunburstView)

        NSLayoutConstraint.activate([
            sunburstView.topAnchor.constraint(equalTo: sunburstContainer.topAnchor),
            sunburstView.leadingAnchor.constraint(equalTo: sunburstContainer.leadingAnchor),
            sunburstView.trailingAnchor.constraint(equalTo: sunburstContainer.trailingAnchor),
            sunburstView.bottomAnchor.constraint(equalTo: sunburstContainer.bottomAnchor),
        ])

        // Table container (right pane)
        let tableContainer = NSView()
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        taxonomyTableView.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(taxonomyTableView)

        NSLayoutConstraint.activate([
            taxonomyTableView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            taxonomyTableView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            taxonomyTableView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            taxonomyTableView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
        ])

        splitView.addArrangedSubview(sunburstContainer)
        splitView.addArrangedSubview(tableContainer)

        // Default 60/40 split
        splitView.setPosition(540, ofDividerAt: 0)

        view.addSubview(splitView)
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area to avoid title bar overlap)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Breadcrumb bar (below summary)
            breadcrumbBar.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            breadcrumbBar.heightAnchor.constraint(equalToConstant: 28),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // Split view (fills remaining space between breadcrumb and action bar)
            splitView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Sunburst selection -> table sync
        sunburstView.onNodeSelected = { [weak self] node in
            guard let self, !self.suppressSelectionSync else { return }
            self.suppressSelectionSync = true
            self.taxonomyTableView.selectAndScrollTo(node: node)
            self.actionBar.updateSelection(node)
            self.suppressSelectionSync = false
        }

        // Sunburst double-click -> zoom
        sunburstView.onNodeDoubleClicked = { [weak self] node in
            guard let self else { return }
            self.breadcrumbBar.update(zoomNode: self.sunburstView.centerNode)
        }

        // Sunburst right-click -> context menu
        sunburstView.onNodeRightClicked = { [weak self] node, windowPoint in
            guard let self else { return }
            self.showContextMenu(for: node, at: windowPoint)
        }

        // Table selection -> sunburst sync
        taxonomyTableView.onNodeSelected = { [weak self] node in
            guard let self, !self.suppressSelectionSync else { return }
            self.suppressSelectionSync = true
            self.sunburstView.selectedNode = node
            self.actionBar.updateSelection(node)
            self.suppressSelectionSync = false
        }

        // Breadcrumb navigation -> zoom sunburst
        breadcrumbBar.onNavigateToNode = { [weak self] node in
            guard let self else { return }
            self.sunburstView.centerNode = node
            self.breadcrumbBar.update(zoomNode: node)
        }

        // Action bar extract -> callback
        actionBar.onExtractSequences = { [weak self] node, includeChildren in
            self?.onExtractSequences?(node, includeChildren)
        }
    }

    // MARK: - NSSplitViewDelegate

    /// Enforces minimum widths for sunburst (300px) and table (260px).
    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Minimum left pane (sunburst) width
        max(proposedMinimumPosition, 300)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Ensure right pane (table) has at least 260px
        min(proposedMaximumPosition, splitView.bounds.width - 260)
    }

    // MARK: - Context Menu

    /// Builds and shows a context menu for a taxon node at the given window point.
    ///
    /// Menu items:
    /// - Extract Sequences for [name]...
    /// - Extract Sequences for [name] and Children...
    /// - Copy Taxon Name
    /// - Copy Taxonomy Path
    /// - (separator)
    /// - Zoom to [name]
    /// - Zoom Out to Root
    private func showContextMenu(for node: TaxonNode, at windowPoint: NSPoint) {
        let menu = NSMenu()

        // Extract this node only
        let extractItem = NSMenuItem(
            title: "Extract Sequences for \(node.name)\u{2026}",
            action: #selector(contextExtractNode(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        extractItem.representedObject = node
        menu.addItem(extractItem)

        // Extract with children
        let extractChildrenItem = NSMenuItem(
            title: "Extract Sequences for \(node.name) and Children\u{2026}",
            action: #selector(contextExtractNodeWithChildren(_:)),
            keyEquivalent: ""
        )
        extractChildrenItem.target = self
        extractChildrenItem.representedObject = node
        menu.addItem(extractChildrenItem)

        menu.addItem(.separator())

        // Copy taxon name
        let copyNameItem = NSMenuItem(
            title: "Copy Taxon Name",
            action: #selector(contextCopyName(_:)),
            keyEquivalent: ""
        )
        copyNameItem.target = self
        copyNameItem.representedObject = node
        menu.addItem(copyNameItem)

        // Copy taxonomy path
        let copyPathItem = NSMenuItem(
            title: "Copy Taxonomy Path",
            action: #selector(contextCopyPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = node
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        // Zoom to node (disabled if already the zoom root)
        let zoomItem = NSMenuItem(
            title: "Zoom to \(node.name)",
            action: #selector(contextZoomToNode(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = self
        zoomItem.representedObject = node
        if sunburstView.centerNode === node {
            zoomItem.isEnabled = false
        }
        menu.addItem(zoomItem)

        // Zoom out to root
        let zoomOutItem = NSMenuItem(
            title: "Zoom Out to Root",
            action: #selector(contextZoomToRoot(_:)),
            keyEquivalent: ""
        )
        zoomOutItem.target = self
        zoomOutItem.isEnabled = sunburstView.centerNode != nil
        menu.addItem(zoomOutItem)

        // Convert window point to view coordinates and show
        let viewPoint = view.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: view)
    }

    /// Builds context menu items for the given node (for testing).
    func contextMenuItems(for node: TaxonNode) -> [NSMenuItem] {
        let menu = NSMenu()
        showContextMenuItems(for: node, into: menu)
        return menu.items
    }

    /// Adds context menu items to the given menu without showing it.
    private func showContextMenuItems(for node: TaxonNode, into menu: NSMenu) {
        let extractItem = NSMenuItem(
            title: "Extract Sequences for \(node.name)\u{2026}",
            action: #selector(contextExtractNode(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        extractItem.representedObject = node
        menu.addItem(extractItem)

        let extractChildrenItem = NSMenuItem(
            title: "Extract Sequences for \(node.name) and Children\u{2026}",
            action: #selector(contextExtractNodeWithChildren(_:)),
            keyEquivalent: ""
        )
        extractChildrenItem.target = self
        extractChildrenItem.representedObject = node
        menu.addItem(extractChildrenItem)

        menu.addItem(.separator())

        let copyNameItem = NSMenuItem(
            title: "Copy Taxon Name",
            action: #selector(contextCopyName(_:)),
            keyEquivalent: ""
        )
        copyNameItem.target = self
        copyNameItem.representedObject = node
        menu.addItem(copyNameItem)

        let copyPathItem = NSMenuItem(
            title: "Copy Taxonomy Path",
            action: #selector(contextCopyPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = node
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        let zoomItem = NSMenuItem(
            title: "Zoom to \(node.name)",
            action: #selector(contextZoomToNode(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = self
        zoomItem.representedObject = node
        if sunburstView.centerNode === node {
            zoomItem.isEnabled = false
        }
        menu.addItem(zoomItem)

        let zoomOutItem = NSMenuItem(
            title: "Zoom Out to Root",
            action: #selector(contextZoomToRoot(_:)),
            keyEquivalent: ""
        )
        zoomOutItem.target = self
        zoomOutItem.isEnabled = sunburstView.centerNode != nil
        menu.addItem(zoomOutItem)
    }

    // MARK: - Context Menu Actions

    @objc private func contextExtractNode(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        onExtractSequences?(node, false)
    }

    @objc private func contextExtractNodeWithChildren(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        onExtractSequences?(node, true)
    }

    @objc private func contextCopyName(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.name, forType: .string)
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let path = node.pathFromRoot()
            .filter { $0.rank != .root }
            .map(\.name)
            .joined(separator: " > ")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    @objc private func contextZoomToNode(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        sunburstView.centerNode = node
        breadcrumbBar.update(zoomNode: node)
    }

    @objc private func contextZoomToRoot(_ sender: NSMenuItem) {
        sunburstView.centerNode = nil
        breadcrumbBar.update(zoomNode: nil)
    }

    // MARK: - Testing Accessors

    /// Returns the summary bar for testing.
    var testSummaryBar: TaxonomySummaryBar { summaryBar }

    /// Returns the breadcrumb bar for testing.
    var testBreadcrumbBar: TaxonomyBreadcrumbBar { breadcrumbBar }

    /// Returns the sunburst view for testing.
    var testSunburstView: TaxonomySunburstView { sunburstView }

    /// Returns the taxonomy table view for testing.
    var testTableView: TaxonomyTableView { taxonomyTableView }

    /// Returns the action bar for testing.
    var testActionBar: TaxonomyActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }
}
