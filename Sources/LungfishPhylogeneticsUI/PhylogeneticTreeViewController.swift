// PhylogeneticTreeViewController.swift - Native tree bundle viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

@MainActor
private final class PhylogeneticContentTypographyObservation {
    private var token: NSObjectProtocol?

    init(handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func cancel() {
        guard let token else { return }
        self.token = nil
        NotificationCenter.default.removeObserver(token)
    }

    isolated deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

enum PhylogeneticTreeAccessibilityID {
    static let root = "phylogenetic-tree-bundle-view"
    static let summary = "phylogenetic-tree-summary"
    static let nodeTable = "phylogenetic-tree-node-table"
    static let canvasView = "phylogenetic-tree-canvas-view"
    static let searchField = "phylogenetic-tree-search-field"
    static let fitButton = "phylogenetic-tree-fit-button"
    static let resetButton = "phylogenetic-tree-reset-button"
    static let zoomInButton = "phylogenetic-tree-zoom-in-button"
    static let zoomOutButton = "phylogenetic-tree-zoom-out-button"
    static let layoutMode = "phylogenetic-tree-layout-mode"
    static let colorMode = "phylogenetic-tree-color-mode"
    static let tipLabelColumn = "phylogenetic-tree-tip-label-column"
    static let detail = "phylogenetic-tree-detail"
    static let nodeDrawerTitle = "phylogenetic-tree-node-drawer-title"
}

enum PhylogeneticTreeCanvasMetrics {
    static let marginX: CGFloat = 48
    static let marginY: CGFloat = 32
    static let tipSpacing: CGFloat = 30
    static let nodeRadius: CGFloat = 4
    static let labelGap: CGFloat = 8
    static let minimumWidth: CGFloat = 840
    static let minimumHeight: CGFloat = 360
}

@MainActor
public final class PhylogeneticTreeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ResultRowMenuActions {
    /// The pasteboard the copy commands write. Tests substitute a private one.
    var pasteboard: NSPasteboard = .general

    public private(set) var bundleURL: URL?
    public private(set) var bundle: PhylogeneticTreeBundle?
    public var onSelectionStateChanged: ((PhylogeneticTreeSelectionState?) -> Void)?
    public var onTreeBundleOperationRequested: ((TreeBundleOperationRequest) -> Void)?

    let summaryLabel = NSTextField(labelWithString: "")
    let supportLegendLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let fitButton = NSButton(title: "", target: nil, action: nil)
    private let resetButton = NSButton(title: "", target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "", target: nil, action: nil)
    private let layoutModeControl = NSSegmentedControl(
        labels: ["Phylogram", "Cladogram"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let colorModeControl = NSSegmentedControl(
        labels: ["None", "Support", "Branch"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tipLabelColumnPopup = NSPopUpButton()
    let nodeTableView = NSTableView()
    private let treeCanvasView = PhylogeneticTreeCanvasView()
    private let treeScrollView = NSScrollView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let nodeDrawerTitle = NSTextField(labelWithString: "Nodes")
    let toolbarContainer = NSView()
    private var toolbarContentView: NSView?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var nodeDrawerHeightConstraint: NSLayoutConstraint?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var contentTypographyObservation: PhylogeneticContentTypographyObservation?
    private var baselineColumnWidths: [String: CGFloat] = [:]
    private var baselineColumnMinimumWidths: [String: CGFloat] = [:]
    private var lastProgrammaticColumnWidths: [String: CGFloat] = [:]
    private var lastResolvedColumnScale: CGFloat = 1
    #if DEBUG
    private var typographyApplicationCount = 0
    private var centerSelectedNodeCount = 0
    #endif

    private var nodes: [PhylogeneticTreeNormalizedNode] = []
    private var originalNodes: [PhylogeneticTreeNormalizedNode] = []
    private var nodesByID: [String: PhylogeneticTreeNormalizedNode] = [:]
    private var selectedNodeID: String?
    private var selectedNodeIDs: Set<String> = []
    private var collapsedNodeIDs: Set<String> = []
    private var metadataRowsByTipID: [String: [String: String]] = [:]
    private var metadataColumnTitles: [String] = []
    private var isUpdatingTableSelection = false

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.root)
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureLayout()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updatePrimaryContentGeometry()
    }

    isolated deinit {
        contentTypographyObservation?.cancel()
    }

    public func displayBundle(at url: URL) throws {
        _ = view
        let loaded = try PhylogeneticTreeBundle.load(from: url)
        bundleURL = url
        bundle = loaded
        originalNodes = orderedNodes(loaded.normalizedTree.nodes)
        nodes = originalNodes
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        selectedNodeID = nil
        selectedNodeIDs = []
        collapsedNodeIDs = []
        loadTipMetadata(from: url)
        refreshTipLabelColumnPopup()

        summaryLabel.stringValue = [
            loaded.manifest.name,
            "\(loaded.manifest.tipCount) tips",
            "\(loaded.manifest.internalNodeCount) internal nodes",
            PhylogeneticTreeSupportPresentation.rootingText(isRooted: loaded.manifest.isRooted),
        ].joined(separator: "   ")
        summaryLabel.toolTip = summaryLabel.stringValue
        summaryLabel.setAccessibilityValue(summaryLabel.stringValue)

        detailLabel.stringValue = defaultDetailText(for: loaded)
        detailLabel.toolTip = detailLabel.stringValue
        detailLabel.setAccessibilityValue(detailLabel.stringValue)
        configureSupportPresentation()
        treeCanvasView.supportLabels = recordedSupportLabels
        treeCanvasView.configure(nodes: nodes, collapsedNodeIDs: collapsedNodeIDs)
        nodeTableView.reloadData()
        selectInitialNode()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        nodes.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < nodes.count, let identifier = tableColumn?.identifier else { return nil }
        let node = nodes[row]
        let value: String
        switch identifier.rawValue {
        case "node":
            value = node.displayLabel
        case "type":
            value = node.isTip ? "Tip" : "Internal"
        case "tips":
            value = "\(node.descendantTipCount)"
        case "length":
            value = node.branchLength.map { String(format: "%.5g", $0) } ?? ""
        default:
            value = PhylogeneticTreeSupportPresentation.cellValue(for: node, columnID: identifier.rawValue)
        }
        let cell = tableCell(identifier: identifier, value: value)
        AccessibilityCellActions.install(accessibilityActions(forRow: row, cellView: cell), on: cell)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingTableSelection else { return }
        let row = nodeTableView.selectedRow
        guard nodes.indices.contains(row) else { return }
        selectNode(id: nodes[row].id, center: true)
    }

    private func configureLayout() {
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.summary)
        summaryLabel.setAccessibilityLabel("Phylogenetic tree summary")
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        nodeTableView.headerView = NSTableHeaderView()
        nodeTableView.usesAlternatingRowBackgroundColors = true
        nodeTableView.rowHeight = 24
        nodeTableView.dataSource = self
        nodeTableView.delegate = self
        nodeTableView.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.nodeTable)
        nodeTableView.setAccessibilityLabel("Phylogenetic tree nodes")
        addTableColumn(id: "node", title: "Node", width: 180)
        addTableColumn(id: "type", title: "Type", width: 70)
        addTableColumn(id: "tips", title: "Tips", width: 54)
        addTableColumn(id: "length", title: "Branch", width: 72)
        addTableColumn(id: "support", title: "Support", width: 72)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.documentView = nodeTableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        treeCanvasView.onNodeSelected = { [weak self] nodeID in
            let extending = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            self?.selectNode(id: nodeID, center: false, extendingSelection: extending)
        }
        treeCanvasView.accessibilityActionsProvider = { [weak self] nodeID in
            self?.canvasAccessibilityActions(forNodeID: nodeID) ?? []
        }

        treeScrollView.hasVerticalScroller = true
        treeScrollView.hasHorizontalScroller = true
        treeScrollView.autohidesScrollers = false
        treeScrollView.documentView = treeCanvasView
        treeScrollView.drawsBackground = true
        treeScrollView.backgroundColor = .textBackgroundColor
        treeScrollView.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.canvasView)
        treeScrollView.setAccessibilityLabel("Phylogenetic tree canvas")
        treeScrollView.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.detail)
        detailLabel.setAccessibilityLabel("Selected phylogenetic tree node details")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = configureToolbar()
        toolbarContentView = toolbar
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbarContainer.addSubview(summaryLabel)
        toolbarContainer.addSubview(toolbar)
        installSupportLegend()

        let nodeDrawer = NSView()
        nodeDrawer.translatesAutoresizingMaskIntoConstraints = false
        nodeDrawer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        nodeDrawerTitle.textColor = .secondaryLabelColor
        nodeDrawerTitle.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.nodeDrawerTitle)
        nodeDrawerTitle.setAccessibilityRole(.staticText)
        nodeDrawerTitle.setAccessibilityLabel("Nodes")
        nodeDrawerTitle.translatesAutoresizingMaskIntoConstraints = false
        nodeDrawer.addSubview(nodeDrawerTitle)
        nodeDrawer.addSubview(tableScroll)

        view.addSubview(toolbarContainer)
        view.addSubview(treeScrollView)
        view.addSubview(detailLabel)
        view.addSubview(nodeDrawer)

        let toolbarHeightConstraint = toolbarContainer.heightAnchor.constraint(equalToConstant: 76)
        let nodeDrawerHeightConstraint = nodeDrawer.heightAnchor.constraint(equalToConstant: 104)
        self.toolbarHeightConstraint = toolbarHeightConstraint
        self.nodeDrawerHeightConstraint = nodeDrawerHeightConstraint
        NSLayoutConstraint.activate([
            toolbarContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarHeightConstraint,

            summaryLabel.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbarContainer.trailingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: 8),

            toolbar.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 7),
            toolbar.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: toolbarContainer.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(lessThanOrEqualTo: toolbarContainer.bottomAnchor, constant: -7),

            treeScrollView.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor),
            treeScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            treeScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            treeScrollView.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -8),
            treeScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            detailLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: nodeDrawer.topAnchor, constant: -8),

            nodeDrawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nodeDrawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nodeDrawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            nodeDrawerHeightConstraint,

            nodeDrawerTitle.topAnchor.constraint(equalTo: nodeDrawer.topAnchor, constant: 7),
            nodeDrawerTitle.leadingAnchor.constraint(equalTo: nodeDrawer.leadingAnchor, constant: 12),
            tableScroll.topAnchor.constraint(equalTo: nodeDrawerTitle.bottomAnchor, constant: 5),
            tableScroll.leadingAnchor.constraint(equalTo: nodeDrawer.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: nodeDrawer.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: nodeDrawer.bottomAnchor),
        ])

        applyContentTypography()
        contentTypographyObservation = PhylogeneticContentTypographyObservation { [weak self] in
            self?.applyContentTypography()
        }
    }

    func applyContentTypography() {
        captureUserColumnWidths()
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        summaryLabel.font = typography.font(for: .emphasizedBody)
        detailLabel.font = typography.font(for: .detail)
        supportLegendLabel.font = typography.font(for: .detail)
        treeCanvasView.supportTextFont = typography.font(for: .detail)
        nodeDrawerTitle.font = typography.font(for: .tableHeader)
        nodeTableView.rowHeight = typography.tableRowHeight()
        if let headerView = nodeTableView.headerView {
            var frame = headerView.frame
            frame.size.height = typography.tableHeaderHeight()
            headerView.frame = frame
        }
        for column in nodeTableView.tableColumns {
            column.headerCell.font = typography.font(for: .tableHeader)
        }
        applyAdaptiveColumnWidths(typography: typography)
        refreshSupportLegend()

        let selectedRows = nodeTableView.selectedRowIndexes
        let scrollOrigin = nodeTableView.enclosingScrollView?.contentView.bounds.origin
        isUpdatingTableSelection = true
        defer { isUpdatingTableSelection = false }
        nodeTableView.reloadData()
        nodeTableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        if let scrollOrigin, let scrollView = nodeTableView.enclosingScrollView {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        nodeTableView.enclosingScrollView?.tile()
        updatePrimaryContentGeometry()
        view.needsLayout = true
        #if DEBUG
        typographyApplicationCount += 1
        #endif
    }

    private func updatePrimaryContentGeometry() {
        guard isViewLoaded else { return }
        let availableWidth = max(1, view.bounds.width - 24)
        let summaryHeight = measuredTextHeight(
            summaryLabel.stringValue,
            font: summaryLabel.font,
            width: availableWidth
        )
        let toolbarContentHeight = toolbarContentView?.fittingSize.height ?? 0
        let toolbarHeight = max(76, ceil(8 + summaryHeight + 7 + toolbarContentHeight + 7))
        if abs((toolbarHeightConstraint?.constant ?? 0) - toolbarHeight) > 0.5 {
            toolbarHeightConstraint?.constant = toolbarHeight
        }

        let titleHeight = nodeDrawerTitle.font?.boundingRectForFont.height ?? 0
        let headerHeight = nodeTableView.headerView?.frame.height ?? 0
        let drawerHeight = max(
            104,
            ceil(7 + titleHeight + 5 + headerHeight + nodeTableView.rowHeight * 2)
        )
        if abs((nodeDrawerHeightConstraint?.constant ?? 0) - drawerHeight) > 0.5 {
            nodeDrawerHeightConstraint?.constant = drawerHeight
        }
    }

    private func measuredTextHeight(_ text: String, font: NSFont?, width: CGFloat) -> CGFloat {
        guard let font else { return 0 }
        return ceil((text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height)
    }

    private func captureUserColumnWidths() {
        for column in nodeTableView.tableColumns {
            let identifier = column.identifier.rawValue
            if baselineColumnWidths[identifier] == nil {
                baselineColumnWidths[identifier] = column.width
                baselineColumnMinimumWidths[identifier] = column.minWidth
            } else if let lastWidth = lastProgrammaticColumnWidths[identifier],
                      abs(lastWidth - column.width) > 0.5 {
                baselineColumnWidths[identifier] = column.width / max(lastResolvedColumnScale, 0.01)
            }
        }
    }

    private func applyAdaptiveColumnWidths(typography: ContentTypography) {
        let scale = typography.font(for: .body).pointSize
            / max(preferredFontProvider.canonicalUnscaledPointSize(for: .body), 1)
        for column in nodeTableView.tableColumns {
            let identifier = column.identifier.rawValue
            let baselineWidth = baselineColumnWidths[identifier] ?? column.width
            let baselineMinimum = baselineColumnMinimumWidths[identifier] ?? column.minWidth
            let headerWidth = ceil(column.headerCell.cellSize.width + 20)
            column.minWidth = scale > 1.01 ? max(baselineMinimum, headerWidth) : baselineMinimum
            column.width = max(
                column.minWidth,
                max(baselineWidth * scale, scale > 1.01 ? headerWidth : 0)
            )
            lastProgrammaticColumnWidths[identifier] = column.width
        }
        lastResolvedColumnScale = scale
    }

    private func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        guard isViewLoaded else { return }
        applyContentTypography()
    }

    private func configureToolbar() -> NSView {
        searchField.placeholderString = "Find tip or node"
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted(_:))
        LungfishKitControlStyle.applyInspectorMetrics(to: searchField)
        searchField.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchIdealWidth = searchField.widthAnchor.constraint(equalToConstant: 180)
        searchIdealWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            searchIdealWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])

        fitButton.target = self
        fitButton.action = #selector(fitTreeToViewport(_:))
        configureIconButton(
            fitButton,
            symbolName: "arrow.up.left.and.arrow.down.right",
            fallbackTitle: "Fit",
            accessibilityLabel: "Fit tree"
        )
        fitButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.fitButton)

        resetButton.target = self
        resetButton.action = #selector(resetTreeView(_:))
        configureIconButton(
            resetButton,
            symbolName: "arrow.counterclockwise",
            fallbackTitle: "Reset",
            accessibilityLabel: "Reset tree"
        )
        resetButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.resetButton)

        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTree(_:))
        configureIconButton(
            zoomOutButton,
            symbolName: "minus.magnifyingglass",
            fallbackTitle: "-",
            accessibilityLabel: "Zoom out"
        )
        zoomOutButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.zoomOutButton)

        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTree(_:))
        configureIconButton(
            zoomInButton,
            symbolName: "plus.magnifyingglass",
            fallbackTitle: "+",
            accessibilityLabel: "Zoom in"
        )
        zoomInButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.zoomInButton)

        layoutModeControl.selectedSegment = 0
        layoutModeControl.target = self
        layoutModeControl.action = #selector(layoutModeChanged(_:))
        LungfishKitControlStyle.applyInspectorMetrics(to: layoutModeControl)
        layoutModeControl.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.layoutMode)

        colorModeControl.selectedSegment = 0
        colorModeControl.target = self
        colorModeControl.action = #selector(colorModeChanged(_:))
        LungfishKitControlStyle.applyInspectorMetrics(to: colorModeControl)
        colorModeControl.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.colorMode)

        tipLabelColumnPopup.target = self
        tipLabelColumnPopup.action = #selector(tipLabelColumnChanged(_:))
        tipLabelColumnPopup.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.tipLabelColumn)
        LungfishKitControlStyle.applyInspectorMetrics(to: tipLabelColumnPopup)
        tipLabelColumnPopup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tipLabelColumnPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            tipLabelColumnPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])

        let toolbar = NSStackView(views: [
            searchField,
            zoomOutButton,
            zoomInButton,
            fitButton,
            resetButton,
            layoutModeControl,
            colorModeControl,
            tipLabelColumnPopup,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        return toolbar
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        fallbackTitle: String,
        accessibilityLabel: String
    ) {
        LungfishKitControlStyle.configureInspectorIconButton(
            button,
            symbolName: symbolName,
            fallbackTitle: fallbackTitle,
            accessibilityLabel: accessibilityLabel
        )
    }

    @objc private func searchFieldSubmitted(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return }
        if let node = nodes.first(where: {
            $0.displayLabel.lowercased().contains(query) ||
                ($0.rawLabel?.lowercased().contains(query) ?? false) ||
                $0.metadata.values.contains { $0.lowercased().contains(query) }
        }) {
            selectNode(id: node.id, center: true)
        }
    }

    @objc private func fitTreeToViewport(_ sender: Any?) {
        treeCanvasView.fit(to: treeScrollView.contentView.bounds.size)
        centerSelectedNode()
    }

    @objc private func resetTreeView(_ sender: Any?) {
        treeCanvasView.resetView()
        centerSelectedNode()
    }

    @objc private func zoomOutTree(_ sender: Any?) {
        treeCanvasView.zoom(by: 0.8)
        centerSelectedNode()
    }

    @objc private func zoomInTree(_ sender: Any?) {
        treeCanvasView.zoom(by: 1.25)
        centerSelectedNode()
    }

    @objc private func layoutModeChanged(_ sender: NSSegmentedControl) {
        treeCanvasView.layoutMode = sender.selectedSegment == 1 ? .cladogram : .phylogram
        centerSelectedNode()
    }

    @objc private func colorModeChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1:
            treeCanvasView.colorMode = .support
        case 2:
            treeCanvasView.colorMode = .branchLength
        default:
            treeCanvasView.colorMode = .none
        }
        refreshSupportLegend()
    }

    @objc private func tipLabelColumnChanged(_ sender: NSPopUpButton) {
        applyTipLabelColumn(sender.titleOfSelectedItem ?? "Original")
    }

    private func loadTipMetadata(from bundleURL: URL) {
        metadataRowsByTipID = [:]
        metadataColumnTitles = []
        let metadataURL = bundleURL.appendingPathComponent("metadata.tsv")
        guard let text = try? String(contentsOf: metadataURL, encoding: .utf8) else { return }
        let rows = text.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        guard let header = rows.first, !header.isEmpty else { return }
        let idColumn = header.firstIndex { ["id", "sample", "sample_id", "name", "tip"].contains($0.lowercased()) } ?? 0
        metadataColumnTitles = header.enumerated().compactMap { index, title in
            index == idColumn ? nil : title
        }
        for row in rows.dropFirst() {
            guard row.indices.contains(idColumn), !row[idColumn].isEmpty else { continue }
            var values: [String: String] = [:]
            for (index, column) in header.enumerated() where row.indices.contains(index) {
                values[column] = row[index]
            }
            metadataRowsByTipID[row[idColumn]] = values
        }
    }

    private func refreshTipLabelColumnPopup() {
        tipLabelColumnPopup.removeAllItems()
        tipLabelColumnPopup.addItem(withTitle: "Original")
        tipLabelColumnPopup.addItems(withTitles: metadataColumnTitles)
        tipLabelColumnPopup.selectItem(withTitle: "Original")
        tipLabelColumnPopup.isEnabled = !metadataColumnTitles.isEmpty
    }

    private func applyTipLabelColumn(_ column: String) {
        let selectedLabel = selectedNodeID.flatMap { nodesByID[$0]?.displayLabel }
        if column == "Original" {
            nodes = originalNodes
        } else {
            nodes = originalNodes.map { node in
                guard node.isTip,
                      let row = metadataRowsByTipID[node.displayLabel] ?? node.rawLabel.flatMap({ metadataRowsByTipID[$0] }),
                      let label = row[column],
                      !label.isEmpty else {
                    return node
                }
                return node.replacingDisplayLabel(label)
            }
        }
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        treeCanvasView.configure(nodes: nodes, collapsedNodeIDs: collapsedNodeIDs)
        nodeTableView.reloadData()
        if let selectedLabel,
           let selected = nodes.first(where: { $0.displayLabel == selectedLabel }) {
            selectNode(id: selected.id, center: false)
        } else if let selectedNodeID, nodesByID[selectedNodeID] != nil {
            selectNode(id: selectedNodeID, center: false)
        }
    }

    private func selectInitialNode() {
        if let firstTip = nodes.first(where: \.isTip) {
            selectNode(id: firstTip.id, center: false)
        } else if let first = nodes.first {
            selectNode(id: first.id, center: false)
        }
    }

    private func selectNode(id: String, center: Bool, extendingSelection: Bool = false) {
        guard let node = nodesByID[id] else { return }
        selectedNodeID = id
        if extendingSelection, node.isTip {
            selectedNodeIDs.insert(id)
        } else {
            selectedNodeIDs = [id]
        }
        treeCanvasView.selectedNodeIDs = selectedNodeIDs
        detailLabel.stringValue = detailText(for: node)
        detailLabel.toolTip = detailLabel.stringValue
        detailLabel.setAccessibilityValue(detailLabel.stringValue)
        if let row = nodes.firstIndex(where: { $0.id == id }),
           nodeTableView.selectedRow != row {
            isUpdatingTableSelection = true
            nodeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isUpdatingTableSelection = false
            nodeTableView.scrollRowToVisible(row)
        }
        if center {
            centerSelectedNode()
        }
        refreshNodeContextMenu()
        notifySelectionStateIfAvailable()
    }

    public func notifySelectionStateIfAvailable() {
        onSelectionStateChanged?(selectionState())
    }

    private func selectionState() -> PhylogeneticTreeSelectionState? {
        guard let selectedNodeID,
              let node = nodesByID[selectedNodeID] else {
            return nil
        }
        var rows: [(String, String)] = [
            ("Node", node.displayLabel),
            ("Type", node.isTip ? "Tip" : "Internal"),
            ("Descendant Tips", "\(node.descendantTipCount)"),
        ]
        if let branchLength = node.branchLength {
            rows.append(("Branch Length", String(format: "%.6g", branchLength)))
        }
        if let cumulativeDivergence = node.cumulativeDivergence {
            rows.append(("Cumulative Divergence", String(format: "%.6g", cumulativeDivergence)))
        }
        rows.append(contentsOf: PhylogeneticTreeSupportPresentation.detailRows(for: node))
        for key in node.metadata.keys.sorted() {
            rows.append((key, node.metadata[key] ?? ""))
        }
        return PhylogeneticTreeSelectionState(
            title: node.displayLabel,
            subtitle: node.isTip ? "tip" : "internal node",
            detailRows: rows
        )
    }

    private func centerSelectedNode() {
        #if DEBUG
        centerSelectedNodeCount += 1
        #endif
        guard let selectedNodeID,
              let rect = treeCanvasView.rectForNode(id: selectedNodeID) else { return }
        treeCanvasView.scrollToVisible(rect.insetBy(dx: -80, dy: -36))
    }

    private func defaultDetailText(for bundle: PhylogeneticTreeBundle) -> String {
        [
            "Format: \(bundle.manifest.sourceFormat)",
            "Primary tree: \(bundle.manifest.primaryTreeID)",
            "Warnings: \(bundle.manifest.warnings.isEmpty ? "none" : "\(bundle.manifest.warnings.count)")",
        ].joined(separator: "   ")
    }

    private func detailText(for node: PhylogeneticTreeNormalizedNode) -> String {
        var parts = [
            node.displayLabel,
            node.isTip ? "tip" : "internal",
            "\(node.descendantTipCount) descendant tips",
        ]
        if let branchLength = node.branchLength {
            parts.append("branch \(String(format: "%.5g", branchLength))")
        }
        PhylogeneticTreeSupportPresentation.detailSummary(for: node).map { parts.append($0) }
        if !node.metadata.isEmpty {
            let metadata = node.metadata.keys.sorted().prefix(3).map { "\($0)=\(node.metadata[$0] ?? "")" }.joined(separator: ", ")
            parts.append(metadata)
        }
        return parts.joined(separator: "   ")
    }

    private func refreshNodeContextMenu() {
        // Each view owns its menu. A shared instance would let a canvas
        // command read the node table's stale clickedRow.
        nodeTableView.menu = nodeContextMenu()
        treeCanvasView.menu = nodeContextMenu()
    }

    // MARK: - Node Commands

    /// One command of the tree node menus: a shared ``ResultRowCommand`` or one
    /// of the tree's own. The context menu, Selection > Table Row validation
    /// and each node row's accessibility actions all read
    /// ``availableNodeActions(forNodeID:selectedTipCount:)``, so they list the
    /// same commands under the same titles.
    enum NodeAction: Hashable {
        case command(ResultRowCommand)
        case copySubtreeNewick
        case rootOnSelectedBranch
        case toggleClade(collapsed: Bool)
        case extractSubtree
        case exportSubtree
        case copySelectedTipNames
        case centerNode
        case revealProvenance

        var title: String {
            switch self {
            case .command(let command): return command.title
            case .copySubtreeNewick: return "Copy Subtree as Newick"
            case .rootOnSelectedBranch: return "Root on Selected Branch"
            case .toggleClade(let collapsed): return collapsed ? "Expand Clade" : "Collapse Clade"
            case .extractSubtree: return "Extract Subtree as New Bundle\u{2026}"
            case .exportSubtree: return "Export Subtree\u{2026}"
            case .copySelectedTipNames: return "Copy Selected Tip Names"
            case .centerNode: return "Center Node"
            case .revealProvenance: return "Reveal Provenance"
            }
        }

        var selector: Selector {
            switch self {
            case .command(let command): return command.menuSelector
            case .copySubtreeNewick: return #selector(PhylogeneticTreeViewController.copySelectedSubtreeNewick(_:))
            case .rootOnSelectedBranch: return #selector(PhylogeneticTreeViewController.rerootSelectedNode(_:))
            case .toggleClade: return #selector(PhylogeneticTreeViewController.toggleSelectedCladeCollapse(_:))
            case .extractSubtree: return #selector(PhylogeneticTreeViewController.extractSelectedSubtreeBundle(_:))
            case .exportSubtree: return #selector(PhylogeneticTreeViewController.exportSelectedSubtree(_:))
            case .copySelectedTipNames: return #selector(PhylogeneticTreeViewController.copySelectedTipNames(_:))
            case .centerNode: return #selector(PhylogeneticTreeViewController.centerSelectedNodeFromMenu(_:))
            case .revealProvenance: return #selector(PhylogeneticTreeViewController.revealTreeProvenance(_:))
            }
        }

        /// True for the same command whatever the clade's collapsed state.
        func matches(_ other: NodeAction) -> Bool {
            if case .toggleClade = self, case .toggleClade = other { return true }
            return self == other
        }

        static func action(for selector: Selector?) -> NodeAction? {
            guard let selector else { return nil }
            if let command = ResultRowCommand.command(for: selector) { return .command(command) }
            return [
                NodeAction.copySubtreeNewick, .rootOnSelectedBranch, .toggleClade(collapsed: false), .extractSubtree,
                .exportSubtree, .copySelectedTipNames, .centerNode, .revealProvenance,
            ].first { $0.selector == selector }
        }
    }

    /// The context menu's commands, in display order.
    private static let nodeMenuOrder: [NodeAction] = [
        .command(.showInInspector), .command(.copyName), .copySubtreeNewick, .rootOnSelectedBranch,
        .toggleClade(collapsed: false), .extractSubtree, .exportSubtree, .copySelectedTipNames, .centerNode,
        .revealProvenance,
    ]

    /// The commands that apply with node `nodeID` selected and
    /// `selectedTipCount` tips in the selection. Reveal Provenance needs only
    /// the bundle.
    func availableNodeActions(forNodeID nodeID: String?, selectedTipCount: Int) -> [NodeAction] {
        var actions: [NodeAction] = []
        let node = nodeID.flatMap { nodesByID[$0] }
        if node != nil {
            actions.append(.command(.showInInspector))
            actions.append(.command(.copyName))
            if bundle != nil { actions.append(.copySubtreeNewick) }
            if bundleURL != nil, node?.parentID != nil { actions.append(.rootOnSelectedBranch) }
            if let node, !node.isTip { actions.append(.toggleClade(collapsed: collapsedNodeIDs.contains(node.id))) }
            if bundleURL != nil, let node, !node.isTip { actions.append(.extractSubtree) }
            if bundle != nil { actions.append(.exportSubtree) }
        }
        if selectedTipCount > 0 { actions.append(.copySelectedTipNames) }
        if node != nil { actions.append(.centerNode) }
        if bundleURL != nil { actions.append(.revealProvenance) }
        return actions
    }

    /// The node a menu command acts on. A context-menu command from the node
    /// table acts on the clicked row; every other command acts on the
    /// selected node, because `clickedRow` outlives the click that set it.
    private func targetNodeID(sender: Any?) -> String? {
        if let menuItem = sender as? NSMenuItem,
           ResultRowMenuValidation.isContextMenuItem(menuItem, in: [nodeTableView.menu]),
           nodeTableView.clickedRow >= 0, nodes.indices.contains(nodeTableView.clickedRow),
           !selectedNodeIDs.contains(nodes[nodeTableView.clickedRow].id) {
            return nodes[nodeTableView.clickedRow].id
        }
        return selectedNodeID
    }

    /// Makes the clicked table row the selected node when a context-menu
    /// command was aimed at it, so the selection-based handlers act on it.
    private func adoptContextTarget(sender: Any?) {
        guard let id = targetNodeID(sender: sender), id != selectedNodeID else { return }
        selectNode(id: id, center: false)
    }

    private func nodeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Tree Node")
        let collapsedSelected = selectedNodeID.map { collapsedNodeIDs.contains($0) } ?? false
        for action in Self.nodeMenuOrder {
            let resolved: NodeAction = {
                if case .toggleClade = action { return .toggleClade(collapsed: collapsedSelected) }
                return action
            }()
            let item = NSMenuItem(title: resolved.title, action: resolved.selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// One item of Selection > Tree Node: the title and responder-chain selector the
    /// menu bar uses, shared with the context menu and the accessibility actions.
    public struct NodeMenuBarCommand {
        public let title: String
        public let selector: Selector
        public let identifierSlug: String
    }

    /// The Selection > Tree Node items in display order, one array per section.
    /// Collapse Clade becomes Expand Clade through validation when the selected
    /// clade is collapsed.
    public static var nodeMenuBarSections: [[NodeMenuBarCommand]] {
        func command(_ action: NodeAction, _ slug: String) -> NodeMenuBarCommand {
            NodeMenuBarCommand(title: action.title, selector: action.selector, identifierSlug: slug)
        }
        return [
            [command(.command(.showInInspector), "show-in-inspector")],
            [command(.command(.copyName), "copy-name"), command(.copySubtreeNewick, "copy-subtree-newick"),
             command(.copySelectedTipNames, "copy-selected-tip-names")],
            [command(.rootOnSelectedBranch, "root-on-selected-branch"),
             command(.toggleClade(collapsed: false), "toggle-clade"),
             command(.centerNode, "center-node")],
            [command(.extractSubtree, "extract-subtree"), command(.exportSubtree, "export-subtree")],
            [command(.revealProvenance, "reveal-provenance")],
        ]
    }

    private var canvasHasKeyboardFocus: Bool {
        guard let responder = treeCanvasView.window?.firstResponder as? NSView else { return false }
        return responder === treeCanvasView || responder.isDescendant(of: treeCanvasView)
    }

    /// The context menu follows the selected node (or the clicked node row).
    /// The menu-bar items under Selection > Table Row and Tree Node are enabled
    /// only while the node table or the canvas has keyboard focus, and the Tree
    /// Node items also need a selected node.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = NodeAction.action(for: menuItem.action) else { return true }
        if case .command(let command) = action, ![.showInInspector, .copyName].contains(command) { return false }
        let inContextMenu = ResultRowMenuValidation.isContextMenuItem(
            menuItem, in: [nodeTableView.menu, treeCanvasView.menu]
        )
        guard inContextMenu
                || ResultRowMenuValidation.tableHasKeyboardFocus(nodeTableView)
                || canvasHasKeyboardFocus else { return false }
        let id = targetNodeID(sender: menuItem)
        if !inContextMenu, id == nil { return false }
        let tipCount = id == selectedNodeID ? selectedTipLabels().count : (id.flatMap { nodesByID[$0]?.isTip } == true ? 1 : 0)
        let available = availableNodeActions(forNodeID: id, selectedTipCount: tipCount)
        if case .toggleClade = action, let available = available.first(where: { $0.matches(action) }) {
            menuItem.title = available.title
            return true
        }
        return available.contains { $0.matches(action) }
    }

    /// The accessibility custom actions of the node row at `row`: every
    /// command the context menu offers with that node selected, named the
    /// same. The handlers resolve the row from `cellView` when they run and
    /// select its node first.
    private func accessibilityActions(forRow row: Int, cellView: NSView) -> [NSAccessibilityCustomAction] {
        guard nodes.indices.contains(row) else { return [] }
        let node = nodes[row]
        return availableNodeActions(forNodeID: node.id, selectedTipCount: node.isTip ? 1 : 0).map { action in
            AccessibilityCellActions.makeAction(name: action.title) { [weak self, weak cellView] in
                guard let self, let cellView,
                      let current = AccessibilityCellActions.currentRow(of: cellView),
                      self.nodes.indices.contains(current) else { return }
                self.selectNode(id: self.nodes[current].id, center: false)
                _ = NSApp.sendAction(action.selector, to: self, from: nil)
            }
        }
    }

    /// The accessibility custom actions of a canvas node: the same commands and
    /// titles as its row in the node table. Each handler selects the node first.
    private func canvasAccessibilityActions(forNodeID nodeID: String) -> [NSAccessibilityCustomAction] {
        guard let node = nodesByID[nodeID] else { return [] }
        return availableNodeActions(forNodeID: nodeID, selectedTipCount: node.isTip ? 1 : 0).map { action in
            AccessibilityCellActions.makeAction(name: action.title) { [weak self] in
                guard let self else { return }
                self.selectNode(id: nodeID, center: false)
                _ = NSApp.sendAction(action.selector, to: self, from: nil)
            }
        }
    }

    @objc public func showSelectedRowInInspector(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        notifySelectionStateIfAvailable()
    }

    @objc public func copySelectedRowName(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        guard let selectedNodeID,
              let node = nodesByID[selectedNodeID] else { return }
        pasteboard.clearContents()
        pasteboard.setString(node.displayLabel, forType: .string)
    }

    @objc func copySelectedSubtreeNewick(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        guard let selectedNodeID,
              let newick = try? bundle?.subtreeNewick(nodeID: selectedNodeID) else { return }
        pasteboard.clearContents()
        pasteboard.setString(newick, forType: .string)
    }

    @objc func rerootSelectedNode(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        requestTreeBundleOperation(.reroot)
    }

    @objc func extractSelectedSubtreeBundle(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        requestTreeBundleOperation(.extractSubtree)
    }

    @objc func toggleSelectedCladeCollapse(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        guard let selectedNodeID,
              let node = nodesByID[selectedNodeID],
              !node.isTip else { return }
        if collapsedNodeIDs.contains(selectedNodeID) {
            collapsedNodeIDs.remove(selectedNodeID)
        } else {
            collapsedNodeIDs.insert(selectedNodeID)
        }
        treeCanvasView.collapsedNodeIDs = collapsedNodeIDs
        refreshNodeContextMenu()
        // The row's Collapse Clade / Expand Clade action name follows the state.
        if let row = nodes.firstIndex(where: { $0.id == selectedNodeID }) {
            nodeTableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(0..<nodeTableView.numberOfColumns)
            )
        }
    }

    @objc func copySelectedTipNames(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        let labels = selectedTipLabels()
        guard !labels.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(labels.joined(separator: "\n"), forType: .string)
    }

    private func requestTreeBundleOperation(_ operation: TreeBundleOperation) {
        guard let bundleURL,
              let selectedNodeID,
              let node = nodesByID[selectedNodeID] else { return }
        onTreeBundleOperationRequested?(
            TreeBundleOperationRequest(
                operation: operation,
                bundleURL: bundleURL,
                nodeID: selectedNodeID,
                nodeLabel: node.displayLabel,
                tipLabels: descendantTipLabels(of: node)
            )
        )
    }

    /// Tip display labels under `node` in tree (child) order; a tip returns itself.
    private func descendantTipLabels(of node: PhylogeneticTreeNormalizedNode) -> [String] {
        if node.isTip {
            return [node.displayLabel]
        }
        return node.childIDs.flatMap { childID -> [String] in
            guard let child = nodesByID[childID] else { return [] }
            return descendantTipLabels(of: child)
        }
    }

    private func selectedTipLabels() -> [String] {
        selectedNodeIDs
            .compactMap { nodesByID[$0] }
            .filter(\.isTip)
            .map(\.displayLabel)
            .sorted()
    }

    @objc func exportSelectedSubtree(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        guard let selectedNodeID,
              let bundle else { return }
        do {
            let export = try bundle.subtreeExport(nodeID: selectedNodeID)
            let panel = Self.makeSubtreeExportPanel(
                suggestedName: Self.subtreeExportSuggestedName(label: export.selectedLabel)
            )
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Self.writeSubtreeExport(
                        export,
                        sourceBundleURL: bundle.url,
                        to: url,
                        startedAt: Date()
                    )
                } catch {
                    self?.presentSubtreeExportFailure(error)
                }
            }
            if let window = view.window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        } catch {
            presentSubtreeExportFailure(error)
        }
    }

    private static func makeSubtreeExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    @discardableResult
    static func writeSubtreeExport(
        _ export: PhylogeneticTreeSubtreeExport,
        sourceBundleURL: URL?,
        to outputURL: URL,
        startedAt: Date = Date()
    ) throws -> URL {
        let sourceURLs = sourceBundleURL.map { [$0] } ?? []
        var argv = ["Lungfish Genome Explorer", "export-tree-subtree"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--node", export.selectedNodeID, "--output", outputURL.path])

        do {
            return try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app phylogenetic subtree export",
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .text,
                argv: argv,
                explicitOptions: [
                    "sourceBundlePath": sourceBundleURL.map(ParameterValue.file) ?? .string("none"),
                    "outputPath": .file(outputURL),
                    "selectedNodeID": .string(export.selectedNodeID),
                    "selectedLabel": .string(export.selectedLabel),
                ],
                defaults: [
                    "outputFormat": .string("newick"),
                ],
                resolved: [
                    "descendantTipCount": .integer(export.descendantTipCount),
                    "outputByteCount": .integer(export.newick.utf8.count),
                ],
                startedAt: startedAt,
                completedAt: Date()
            )) { staged in
                try Data(export.newick.utf8).write(to: staged, options: .atomic)
            }
        } catch {
            throw error
        }
    }

    @objc func centerSelectedNodeFromMenu(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        centerSelectedNode()
    }

    @objc func revealTreeProvenance(_ sender: Any?) {
        adoptContextTarget(sender: sender)
        guard let provenanceURL = bundleURL?.appendingPathComponent(".lungfish-provenance.json") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([provenanceURL])
    }

    private func orderedNodes(_ input: [PhylogeneticTreeNormalizedNode]) -> [PhylogeneticTreeNormalizedNode] {
        let byID = Dictionary(uniqueKeysWithValues: input.map { ($0.id, $0) })
        guard let root = input.first(where: { $0.parentID == nil }) else {
            return input.sorted { $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending }
        }
        var ordered: [PhylogeneticTreeNormalizedNode] = []
        func walk(_ node: PhylogeneticTreeNormalizedNode) {
            ordered.append(node)
            for childID in node.childIDs {
                if let child = byID[childID] {
                    walk(child)
                }
            }
        }
        walk(root)
        return ordered
    }

    func addTableColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        nodeTableView.addTableColumn(column)
    }

    private func tableCell(identifier: NSUserInterfaceItemIdentifier, value: String) -> NSTableCellView {
        let cell = nodeTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        label.stringValue = value
        label.font = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        ).font(for: .body)
        label.toolTip = value
        let columnTitle = nodeTableView.tableColumns
            .first(where: { $0.identifier == identifier })?.title ?? "Node value"
        label.setAccessibilityLabel("\(columnTitle): \(value)")
        label.setAccessibilityValue(value)
        return cell
    }
}

extension PhylogeneticTreeViewController {
    public enum TreeBundleOperation: Equatable {
        case reroot
        case extractSubtree
        case collapse
    }

    public struct TreeBundleOperationRequest: Equatable {
        public let operation: TreeBundleOperation
        public let bundleURL: URL
        public let nodeID: String
        public let nodeLabel: String
        /// Display labels of the tips under the selected node, in tree order. A tip lists itself.
        public let tipLabels: [String]

        public init(
            operation: TreeBundleOperation,
            bundleURL: URL,
            nodeID: String,
            nodeLabel: String,
            tipLabels: [String] = []
        ) {
            self.operation = operation
            self.bundleURL = bundleURL
            self.nodeID = nodeID
            self.nodeLabel = nodeLabel
            self.tipLabels = tipLabels
        }
    }
}

#if DEBUG
public extension PhylogeneticTreeViewController {
    struct TestingPrimaryContentMetrics: Equatable {
        public let summaryFontPointSize: CGFloat
        public let detailFontPointSize: CGFloat
        public let searchFontPointSize: CGFloat
        public let nodeCellFontPointSize: CGFloat
        public let rowHeight: CGFloat
        public let headerHeight: CGFloat
        public let toolbarHeight: CGFloat
        public let nodeDrawerHeight: CGFloat
        public let typographyApplicationCount: Int
    }

    struct TestingScientificMutationCounts: Equatable {
        public let configure: Int
        public let recomputeLayout: Int
        public let fit: Int
        public let reset: Int
        public let zoom: Int
        public let center: Int
    }

    struct TestingToolbarTextControlMetric: Equatable {
        public let controlSize: NSControl.ControlSize
        public let fontPointSize: CGFloat

        public init(controlSize: NSControl.ControlSize, fontPointSize: CGFloat) {
            self.controlSize = controlSize
            self.fontPointSize = fontPointSize
        }
    }

    var testingCanvasNodeCount: Int {
        treeCanvasView.testingNodeCount
    }

    var testingPrimaryContentMetrics: TestingPrimaryContentMetrics {
        let cell = nodeTableView.view(
            atColumn: 0,
            row: max(0, min(nodeTableView.numberOfRows - 1, nodeTableView.selectedRow)),
            makeIfNecessary: true
        ) as? NSTableCellView
        return TestingPrimaryContentMetrics(
            summaryFontPointSize: summaryLabel.font?.pointSize ?? 0,
            detailFontPointSize: detailLabel.font?.pointSize ?? 0,
            searchFontPointSize: searchField.font?.pointSize ?? 0,
            nodeCellFontPointSize: cell?.textField?.font?.pointSize ?? 0,
            rowHeight: nodeTableView.rowHeight,
            headerHeight: nodeTableView.headerView?.frame.height ?? 0,
            toolbarHeight: toolbarHeightConstraint?.constant ?? 0,
            nodeDrawerHeight: nodeDrawerHeightConstraint?.constant ?? 0,
            typographyApplicationCount: typographyApplicationCount
        )
    }

    var testingScientificMutationCounts: TestingScientificMutationCounts {
        TestingScientificMutationCounts(
            configure: treeCanvasView.testingConfigureCount,
            recomputeLayout: treeCanvasView.testingRecomputeLayoutCount,
            fit: treeCanvasView.testingFitCount,
            reset: treeCanvasView.testingResetCount,
            zoom: treeCanvasView.testingZoomCount,
            center: centerSelectedNodeCount
        )
    }

    var testingNodeColumnWidths: [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: nodeTableView.tableColumns.map {
            ($0.identifier.rawValue, $0.width)
        })
    }

    func testingSetNodeColumnWidth(identifier: String, width: CGFloat) {
        nodeTableView.tableColumns.first {
            $0.identifier.rawValue == identifier
        }?.width = width
    }

    var testingSearchField: NSSearchField { searchField }

    func testingSetSearchText(_ text: String) {
        searchField.stringValue = text
    }

    var testingCanvasScrollOrigin: NSPoint {
        treeScrollView.contentView.bounds.origin
    }

    func testingSetCanvasScrollOrigin(_ origin: NSPoint) {
        treeScrollView.contentView.scroll(to: origin)
        treeScrollView.reflectScrolledClipView(treeScrollView.contentView)
    }

    var testingNodeTableScrollOrigin: NSPoint {
        nodeTableView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    func testingSetNodeTableScrollOrigin(_ origin: NSPoint) {
        guard let scrollView = nodeTableView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var testingNodeTableSelectedRow: Int { nodeTableView.selectedRow }

    var testingSelectedNodeRow: Int {
        selectedNodeID.flatMap { id in nodes.firstIndex(where: { $0.id == id }) } ?? -1
    }

    var testingNodeTableAccessibilityLabel: String {
        nodeTableView.accessibilityLabel() ?? ""
    }

    func testingNodeCellAccessibilityValue(column: String, row: Int) -> String {
        guard let columnIndex = nodeTableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == column
        }), row >= 0 else { return "" }
        let cell = nodeTableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true)
            as? NSTableCellView
        return cell?.textField?.accessibilityValue() ?? ""
    }

    var testingHasAmbiguousPrimaryLayout: Bool {
        view.hasAmbiguousLayout
            || toolbarContainer.hasAmbiguousLayout
            || summaryLabel.hasAmbiguousLayout
            || detailLabel.hasAmbiguousLayout
            || nodeDrawerTitle.hasAmbiguousLayout
            || nodeTableView.hasAmbiguousLayout
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    var testingRenderedTipLabels: [String] {
        nodes.filter(\.isTip).map(\.displayLabel).sorted()
    }

    /// The canvas node accessibility elements, for tests.
    var testingCanvasAccessibilityElements: [NSAccessibilityElement] {
        (treeCanvasView.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
    }

    var testingCanvasView: NSView { treeCanvasView }

    var testingCanvasCommandTitles: [String] {
        [fitButton.title, resetButton.title]
    }

    var testingCanvasCommandAccessibilityLabels: [String] {
        [fitButton, resetButton, zoomOutButton, zoomInButton].compactMap { $0.accessibilityLabel() }
    }

    var testingToolbarControlFrames: [String: NSRect] {
        [
            "search": searchField,
            "zoomOut": zoomOutButton,
            "zoomIn": zoomInButton,
            "fit": fitButton,
            "reset": resetButton,
            "layout": layoutModeControl,
            "color": colorModeControl,
            "tipLabelColumn": tipLabelColumnPopup,
        ].reduce(into: [String: NSRect]()) { result, pair in
            result[pair.key] = view.convert(pair.value.bounds, from: pair.value)
        }
    }

    var testingToolbarTextControlMetrics: [String: TestingToolbarTextControlMetric] {
        [
            "search": TestingToolbarTextControlMetric(
                controlSize: searchField.controlSize,
                fontPointSize: searchField.font?.pointSize ?? 0
            ),
            "layout": TestingToolbarTextControlMetric(
                controlSize: layoutModeControl.controlSize,
                fontPointSize: layoutModeControl.font?.pointSize ?? 0
            ),
            "color": TestingToolbarTextControlMetric(
                controlSize: colorModeControl.controlSize,
                fontPointSize: colorModeControl.font?.pointSize ?? 0
            ),
            "tipLabelColumn": TestingToolbarTextControlMetric(
                controlSize: tipLabelColumnPopup.controlSize,
                fontPointSize: tipLabelColumnPopup.font?.pointSize ?? 0
            ),
        ]
    }

    var testingCanvasViewportFrame: NSRect {
        treeScrollView.frame
    }

    var testingTreeLayoutFrames: [String: NSRect] {
        [
            "rootView": view.frame,
            "toolbar": toolbarContainer.frame,
            "treeScrollView": treeScrollView.frame,
            "treeCanvasView": treeCanvasView.frame,
            "detailLabel": detailLabel.frame,
        ]
    }

    var testingCanvasZoomScale: CGFloat {
        treeCanvasView.testingZoomScale
    }

    var testingCanvasLayoutMode: String {
        treeCanvasView.testingLayoutMode
    }

    var testingCanvasColorMode: String {
        treeCanvasView.testingColorMode
    }

    var testingCanvasScaleBarLabel: String {
        treeCanvasView.testingScaleBarLabel
    }

    func testingCanvasPoint(label: String) -> NSPoint? {
        treeCanvasView.testingPoint(label: label)
    }

    var testingSelectedNodeLabel: String? {
        selectedNodeID.flatMap { nodesByID[$0]?.displayLabel }
    }

    var testingDetailText: String {
        detailLabel.stringValue
    }

    func testingSetDetailText(_ text: String) {
        detailLabel.stringValue = text
        detailLabel.toolTip = text
        detailLabel.setAccessibilityValue(text)
        view.needsLayout = true
    }

    var testingDetailAccessibilityValue: String {
        detailLabel.accessibilityValue() ?? ""
    }

    var testingDetailToolTip: String {
        detailLabel.toolTip ?? ""
    }

    var testingNodeTableView: NSTableView { nodeTableView }

    var testingNodeTableContextMenu: NSMenu? { nodeTableView.menu }

    var testingTreeCanvasView: NSView { treeCanvasView }

    var testingNodeContextMenuTitles: [String] {
        nodeContextMenu().items.map(\.title)
    }

    func testingSelectNode(label: String) {
        testingSelectNode(label: label, extendingSelection: false)
    }

    func testingSelectNode(label: String, extendingSelection: Bool) {
        guard let node = nodes.first(where: { $0.displayLabel == label }) else { return }
        selectNode(id: node.id, center: true, extendingSelection: extendingSelection)
    }

    var testingSelectedNodeTransformAvailability: [String: Bool] {
        let selectedNode = selectedNodeID.flatMap { nodesByID[$0] }
        return [
            "reroot": bundleURL != nil && selectedNode != nil,
            "collapse": selectedNode?.isTip == false,
            "extractSubtree": bundleURL != nil && selectedNode != nil,
        ]
    }

    func testingPerformSelectedNodeOperation(_ operation: TreeBundleOperation) {
        switch operation {
        case .reroot:
            rerootSelectedNode(nil)
        case .extractSubtree:
            extractSelectedSubtreeBundle(nil)
        case .collapse:
            toggleSelectedCladeCollapse(nil)
        }
    }

    var testingCollapsedNodeLabels: [String] {
        collapsedNodeIDs.compactMap { nodesByID[$0]?.displayLabel }.sorted()
    }

    var testingSelectedTipLabels: [String] {
        selectedTipLabels()
    }

    func testingCopySelectedTipNames() {
        copySelectedTipNames(nil)
    }

    var testingTipLabelColumnTitles: [String] {
        (0..<tipLabelColumnPopup.numberOfItems).compactMap { tipLabelColumnPopup.item(at: $0)?.title }
    }

    func testingApplyTipLabelColumn(_ column: String) {
        tipLabelColumnPopup.selectItem(withTitle: column)
        applyTipLabelColumn(column)
    }

    func testingPerformZoomIn() {
        zoomInTree(nil)
    }

    func testingPerformZoomOut() {
        zoomOutTree(nil)
    }

    func testingSetTreeLayoutMode(_ mode: PhylogeneticTreeCanvasLayoutMode) {
        layoutModeControl.selectedSegment = mode == .cladogram ? 1 : 0
        layoutModeChanged(layoutModeControl)
    }

    func testingSetTreeColorMode(_ mode: PhylogeneticTreeCanvasColorMode) {
        switch mode {
        case .none:
            colorModeControl.selectedSegment = 0
        case .support:
            colorModeControl.selectedSegment = 1
        case .branchLength:
            colorModeControl.selectedSegment = 2
        }
        colorModeChanged(colorModeControl)
    }
}
#endif

public enum PhylogeneticTreeCanvasColorMode {
    case none
    case support
    case branchLength
}

public enum PhylogeneticTreeCanvasLayoutMode {
    case phylogram
    case cladogram
}
