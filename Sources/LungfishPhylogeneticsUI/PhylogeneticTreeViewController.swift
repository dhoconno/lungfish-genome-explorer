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

private enum PhylogeneticTreeAccessibilityID {
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

private enum PhylogeneticTreeCanvasMetrics {
    static let marginX: CGFloat = 48
    static let marginY: CGFloat = 32
    static let tipSpacing: CGFloat = 30
    static let nodeRadius: CGFloat = 4
    static let labelGap: CGFloat = 8
    static let minimumWidth: CGFloat = 840
    static let minimumHeight: CGFloat = 360
}

@MainActor
public final class PhylogeneticTreeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var bundleURL: URL?
    public private(set) var bundle: PhylogeneticTreeBundle?
    public var onSelectionStateChanged: ((PhylogeneticTreeSelectionState?) -> Void)?
    public var onTreeBundleOperationRequested: ((TreeBundleOperationRequest) -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
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
    private let colorModeControl = NSSegmentedControl(
        labels: ["None", "Support", "Branch"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tipLabelColumnPopup = NSPopUpButton()
    private let nodeTableView = NSTableView()
    private let treeCanvasView = PhylogeneticTreeCanvasView()
    private let treeScrollView = NSScrollView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let nodeDrawerTitle = NSTextField(labelWithString: "Nodes")
    private let toolbarContainer = NSView()
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
    private var typographyApplicationCount = 0
    private var centerSelectedNodeCount = 0

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
            loaded.manifest.isRooted ? "rooted" : "unrooted",
        ].joined(separator: "   ")
        summaryLabel.toolTip = summaryLabel.stringValue
        summaryLabel.setAccessibilityValue(summaryLabel.stringValue)

        detailLabel.stringValue = defaultDetailText(for: loaded)
        detailLabel.toolTip = detailLabel.stringValue
        detailLabel.setAccessibilityValue(detailLabel.stringValue)
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
            value = node.support?.rawValue ?? ""
        }
        return tableCell(identifier: identifier, value: value)
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
        detailLabel.maximumNumberOfLines = 0
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

    private func applyContentTypography() {
        captureUserColumnWidths()
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        summaryLabel.font = typography.font(for: .emphasizedBody)
        detailLabel.font = typography.font(for: .detail)
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
        typographyApplicationCount += 1
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
        if let support = node.support {
            rows.append(("Support", support.rawValue))
            rows.append(("Support Type", support.interpretation))
        }
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
        centerSelectedNodeCount += 1
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
        if let support = node.support {
            parts.append("support \(support.rawValue) (\(support.interpretation))")
        }
        if !node.metadata.isEmpty {
            let metadata = node.metadata.keys.sorted().prefix(3).map { "\($0)=\(node.metadata[$0] ?? "")" }.joined(separator: ", ")
            parts.append(metadata)
        }
        return parts.joined(separator: "   ")
    }

    private func refreshNodeContextMenu() {
        let menu = nodeContextMenu()
        nodeTableView.menu = menu
        treeCanvasView.menu = menu
    }

    private func nodeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Tree Node")
        let showItem = NSMenuItem(
            title: "Show in Inspector",
            action: #selector(showSelectedNodeInInspector(_:)),
            keyEquivalent: ""
        )
        showItem.target = self
        showItem.isEnabled = selectedNodeID != nil
        menu.addItem(showItem)

        let copyLabelItem = NSMenuItem(
            title: "Copy Node Label",
            action: #selector(copySelectedNodeLabel(_:)),
            keyEquivalent: ""
        )
        copyLabelItem.target = self
        copyLabelItem.isEnabled = selectedNodeID != nil
        menu.addItem(copyLabelItem)

        let copySubtreeItem = NSMenuItem(
            title: "Copy Subtree as Newick",
            action: #selector(copySelectedSubtreeNewick(_:)),
            keyEquivalent: ""
        )
        copySubtreeItem.target = self
        copySubtreeItem.isEnabled = bundle != nil && selectedNodeID != nil
        menu.addItem(copySubtreeItem)

        let rerootItem = NSMenuItem(
            title: "Re-root Here",
            action: #selector(rerootSelectedNode(_:)),
            keyEquivalent: ""
        )
        rerootItem.target = self
        rerootItem.isEnabled = bundleURL != nil && selectedNodeID != nil
        menu.addItem(rerootItem)

        let collapseTitle = selectedNodeID.map { collapsedNodeIDs.contains($0) } == true ? "Expand Clade" : "Collapse Clade"
        let collapseItem = NSMenuItem(
            title: collapseTitle,
            action: #selector(toggleSelectedCladeCollapse(_:)),
            keyEquivalent: ""
        )
        collapseItem.target = self
        collapseItem.isEnabled = selectedNodeID.flatMap { nodesByID[$0] }?.isTip == false
        menu.addItem(collapseItem)

        let extractBundleItem = NSMenuItem(
            title: "Extract Subtree as New Bundle…",
            action: #selector(extractSelectedSubtreeBundle(_:)),
            keyEquivalent: ""
        )
        extractBundleItem.target = self
        extractBundleItem.isEnabled = bundleURL != nil && selectedNodeID != nil
        menu.addItem(extractBundleItem)

        let exportSubtreeItem = NSMenuItem(
            title: "Export Subtree…",
            action: #selector(exportSelectedSubtree(_:)),
            keyEquivalent: ""
        )
        exportSubtreeItem.target = self
        exportSubtreeItem.isEnabled = bundle != nil && selectedNodeID != nil
        menu.addItem(exportSubtreeItem)

        let copySelectedTipsItem = NSMenuItem(
            title: "Copy Selected Tip Names",
            action: #selector(copySelectedTipNames(_:)),
            keyEquivalent: ""
        )
        copySelectedTipsItem.target = self
        copySelectedTipsItem.isEnabled = !selectedTipLabels().isEmpty
        menu.addItem(copySelectedTipsItem)

        let centerItem = NSMenuItem(
            title: "Center Node",
            action: #selector(centerSelectedNodeFromMenu(_:)),
            keyEquivalent: ""
        )
        centerItem.target = self
        centerItem.isEnabled = selectedNodeID != nil
        menu.addItem(centerItem)

        let revealProvenanceItem = NSMenuItem(
            title: "Reveal Provenance",
            action: #selector(revealTreeProvenance(_:)),
            keyEquivalent: ""
        )
        revealProvenanceItem.target = self
        revealProvenanceItem.isEnabled = bundleURL != nil
        menu.addItem(revealProvenanceItem)
        return menu
    }

    @objc private func showSelectedNodeInInspector(_ sender: Any?) {
        notifySelectionStateIfAvailable()
    }

    @objc private func copySelectedNodeLabel(_ sender: Any?) {
        guard let selectedNodeID,
              let node = nodesByID[selectedNodeID] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.displayLabel, forType: .string)
    }

    @objc private func copySelectedSubtreeNewick(_ sender: Any?) {
        guard let selectedNodeID,
              let newick = try? bundle?.subtreeNewick(nodeID: selectedNodeID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(newick, forType: .string)
    }

    @objc private func rerootSelectedNode(_ sender: Any?) {
        requestTreeBundleOperation(.reroot)
    }

    @objc private func extractSelectedSubtreeBundle(_ sender: Any?) {
        requestTreeBundleOperation(.extractSubtree)
    }

    @objc private func toggleSelectedCladeCollapse(_ sender: Any?) {
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
    }

    @objc private func copySelectedTipNames(_ sender: Any?) {
        let labels = selectedTipLabels()
        guard !labels.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(labels.joined(separator: "\n"), forType: .string)
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
                nodeLabel: node.displayLabel
            )
        )
    }

    private func selectedTipLabels() -> [String] {
        selectedNodeIDs
            .compactMap { nodesByID[$0] }
            .filter(\.isTip)
            .map(\.displayLabel)
            .sorted()
    }

    @objc private func exportSelectedSubtree(_ sender: Any?) {
        guard let selectedNodeID,
              let bundle else { return }
        do {
            let export = try bundle.subtreeExport(nodeID: selectedNodeID)
            let panel = Self.makeSubtreeExportPanel(
                suggestedName: "\(export.selectedLabel).nwk"
            )
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Self.writeSubtreeExport(
                        export,
                        sourceBundleURL: bundle.url,
                        to: url,
                        startedAt: Date()
                    )
                } catch {
                    NSSound.beep()
                }
            }
            if let window = view.window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        } catch {
            NSSound.beep()
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
        try Data(export.newick.utf8).write(to: outputURL, options: .atomic)
        let sourceURLs = sourceBundleURL.map { [$0] } ?? []
        var argv = ["Lungfish Genome Explorer", "export-tree-subtree"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--node", export.selectedNodeID, "--output", outputURL.path])

        do {
            return try ScientificFileExportProvenance.write(.init(
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
            ))
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    @objc private func centerSelectedNodeFromMenu(_ sender: Any?) {
        centerSelectedNode()
    }

    @objc private func revealTreeProvenance(_ sender: Any?) {
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

    private func addTableColumn(id: String, title: String, width: CGFloat) {
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

        public init(operation: TreeBundleOperation, bundleURL: URL, nodeID: String, nodeLabel: String) {
            self.operation = operation
            self.bundleURL = bundleURL
            self.nodeID = nodeID
            self.nodeLabel = nodeLabel
        }
    }
}

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

public enum PhylogeneticTreeCanvasColorMode {
    case none
    case support
    case branchLength
}

public enum PhylogeneticTreeCanvasLayoutMode {
    case phylogram
    case cladogram
}

private struct PhylogeneticTreeCanvasNodeLayout {
    let node: PhylogeneticTreeNormalizedNode
    let point: NSPoint
}

private final class PhylogeneticTreeCanvasView: NSView {
    var onNodeSelected: ((String) -> Void)?
    var selectedNodeID: String? {
        get { selectedNodeIDs.first }
        set {
            selectedNodeIDs = newValue.map { [$0] } ?? []
        }
    }
    var selectedNodeIDs: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var collapsedNodeIDs: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var colorMode: PhylogeneticTreeCanvasColorMode = .none {
        didSet { needsDisplay = true }
    }
    var layoutMode: PhylogeneticTreeCanvasLayoutMode = .phylogram {
        didSet {
            recomputeLayout()
            needsDisplay = true
        }
    }

    private var nodes: [PhylogeneticTreeNormalizedNode] = []
    private var nodesByID: [String: PhylogeneticTreeNormalizedNode] = [:]
    private var layoutByID: [String: PhylogeneticTreeCanvasNodeLayout] = [:]
    private var zoomScale: CGFloat = 1
    private var baseSize = NSSize(width: PhylogeneticTreeCanvasMetrics.minimumWidth, height: PhylogeneticTreeCanvasMetrics.minimumHeight)
    private var labelWidth: CGFloat = 180
    private var pointsPerBranchLengthUnit: CGFloat?
    private var maxBranchLengthUnits: CGFloat = 0
    private var configureCount = 0
    private var recomputeLayoutCount = 0
    private var fitCount = 0
    private var resetCount = 0
    private var zoomCount = 0

    var testingNodeCount: Int { nodes.count }
    var testingConfigureCount: Int { configureCount }
    var testingRecomputeLayoutCount: Int { recomputeLayoutCount }
    var testingFitCount: Int { fitCount }
    var testingResetCount: Int { resetCount }
    var testingZoomCount: Int { zoomCount }
    var testingZoomScale: CGFloat { zoomScale }
    var testingLayoutMode: String {
        switch layoutMode {
        case .phylogram:
            return "phylogram"
        case .cladogram:
            return "cladogram"
        }
    }
    var testingColorMode: String {
        switch colorMode {
        case .none:
            return "none"
        case .support:
            return "support"
        case .branchLength:
            return "branchLength"
        }
    }
    var testingScaleBarLabel: String {
        guard layoutMode == .phylogram,
              let pointsPerBranchLengthUnit,
              pointsPerBranchLengthUnit > 0,
              maxBranchLengthUnits > 0 else {
            return ""
        }
        let targetPixels = min(max(bounds.width * 0.18, 72), 150)
        let targetUnits = targetPixels / (pointsPerBranchLengthUnit * zoomScale)
        let scaleUnits = niceScaleLength(near: targetUnits)
        return String(format: "%.3g substitutions/site", Double(scaleUnits))
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.canvasView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Phylogenetic tree canvas")
    }

    override func accessibilityChildren() -> [Any]? {
        nodes.compactMap { node in
            guard let rect = rectForNode(id: node.id) else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.group)
            element.setAccessibilityIdentifier("phylogenetic-tree-node-\(sanitizedAccessibilityComponent(node.displayLabel))")
            element.setAccessibilityLabel("\(node.displayLabel), \(node.isTip ? "tip" : "internal node")")
            element.setAccessibilityFrameInParentSpace(rect.insetBy(dx: -6, dy: -6))
            return element
        }
    }

    func configure(nodes: [PhylogeneticTreeNormalizedNode], collapsedNodeIDs: Set<String>) {
        configureCount += 1
        self.nodes = nodes
        self.collapsedNodeIDs = collapsedNodeIDs
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        recomputeLayout()
        needsDisplay = true
    }

    func fit(to visibleSize: NSSize) {
        fitCount += 1
        guard baseSize.width > 0, baseSize.height > 0 else { return }
        let horizontal = visibleSize.width > 0 ? visibleSize.width / baseSize.width : 1
        let vertical = visibleSize.height > 0 ? visibleSize.height / baseSize.height : 1
        zoomScale = min(max(min(horizontal, vertical), 0.35), 2.5)
        updateFrameSize()
        needsDisplay = true
    }

    func resetView() {
        resetCount += 1
        zoomScale = 1
        updateFrameSize()
        needsDisplay = true
    }

    func zoom(by factor: CGFloat) {
        zoomCount += 1
        zoomScale = min(4, max(0.25, zoomScale * factor))
        updateFrameSize()
        needsDisplay = true
    }

    func rectForNode(id: String) -> NSRect? {
        guard let layout = layoutByID[id] else { return nil }
        let point = scaled(layout.point)
        return NSRect(
            x: point.x - PhylogeneticTreeCanvasMetrics.nodeRadius - 2,
            y: point.y - PhylogeneticTreeCanvasMetrics.nodeRadius - 2,
            width: (PhylogeneticTreeCanvasMetrics.nodeRadius + 2) * 2,
            height: (PhylogeneticTreeCanvasMetrics.nodeRadius + 2) * 2
        )
    }

    func testingPoint(label: String) -> NSPoint? {
        guard let node = nodes.first(where: { $0.displayLabel == label }),
              let layout = layoutByID[node.id] else {
            return nil
        }
        return scaled(layout.point)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard !nodes.isEmpty else {
            drawTreeText("No tree nodes loaded.", in: bounds.insetBy(dx: 16, dy: 16), color: .secondaryLabelColor)
            return
        }

        drawEdges()
        drawNodesAndLabels()
        drawScaleBar()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = nodeID(at: point) else { return }
        onNodeSelected?(nodeID)
    }

    private func recomputeLayout() {
        recomputeLayoutCount += 1
        guard !nodes.isEmpty else {
            layoutByID = [:]
            baseSize = NSSize(width: PhylogeneticTreeCanvasMetrics.minimumWidth, height: PhylogeneticTreeCanvasMetrics.minimumHeight)
            pointsPerBranchLengthUnit = nil
            maxBranchLengthUnits = 0
            updateFrameSize()
            return
        }

        let childIDsByNodeID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.childIDs) })
        let rootID = nodes.first(where: { $0.parentID == nil })?.id ?? nodes[0].id
        var depthByID: [String: Int] = [:]
        func assignDepth(_ nodeID: String, depth: Int) {
            depthByID[nodeID] = depth
            for childID in childIDsByNodeID[nodeID] ?? [] {
                assignDepth(childID, depth: depth + 1)
            }
        }
        assignDepth(rootID, depth: 0)

        var rawXByID: [String: CGFloat] = [:]
        for node in nodes {
            if layoutMode == .phylogram, let divergence = node.cumulativeDivergence, divergence > 0 {
                rawXByID[node.id] = CGFloat(divergence)
            } else {
                rawXByID[node.id] = CGFloat(depthByID[node.id] ?? 0)
            }
        }
        let observedMaxRawX = rawXByID.values.max() ?? 0
        let maxRawX = observedMaxRawX > 0 ? observedMaxRawX : 1
        let tipCount = max(nodes.filter(\.isTip).count, 1)
        labelWidth = min(
            320,
            max(
                180,
                nodes.filter(\.isTip).map {
                    (($0.displayLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 18
                }.max() ?? 180
            )
        )
        baseSize = NSSize(
            width: max(PhylogeneticTreeCanvasMetrics.minimumWidth, CGFloat(nodes.count) * 72 + labelWidth),
            height: max(PhylogeneticTreeCanvasMetrics.minimumHeight, CGFloat(tipCount) * PhylogeneticTreeCanvasMetrics.tipSpacing + 80)
        )
        let drawableWidth = max(320, baseSize.width - PhylogeneticTreeCanvasMetrics.marginX * 2 - labelWidth)
        let xScale = drawableWidth / maxRawX
        pointsPerBranchLengthUnit = layoutMode == .phylogram ? xScale : nil
        maxBranchLengthUnits = maxRawX

        var nextTipY = PhylogeneticTreeCanvasMetrics.marginY
        var pointByID: [String: NSPoint] = [:]
        func assignPoint(_ nodeID: String) -> NSPoint {
            let children = childIDsByNodeID[nodeID] ?? []
            let y: CGFloat
            if children.isEmpty {
                y = nextTipY
                nextTipY += PhylogeneticTreeCanvasMetrics.tipSpacing
            } else {
                let childPoints = children.map(assignPoint)
                y = childPoints.map(\.y).reduce(0, +) / CGFloat(max(childPoints.count, 1))
            }
            let x = PhylogeneticTreeCanvasMetrics.marginX + (rawXByID[nodeID] ?? 0) * xScale
            let point = NSPoint(x: x, y: y)
            pointByID[nodeID] = point
            return point
        }
        _ = assignPoint(rootID)

        layoutByID = Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
            guard let point = pointByID[node.id] else { return nil }
            return (node.id, PhylogeneticTreeCanvasNodeLayout(node: node, point: point))
        })
        updateFrameSize()
    }

    private func updateFrameSize() {
        setFrameSize(NSSize(width: baseSize.width * zoomScale, height: baseSize.height * zoomScale))
    }

    private func drawEdges() {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        for node in nodes {
            guard let parentID = node.parentID,
                  let parentLayout = layoutByID[parentID],
                  let childLayout = layoutByID[node.id] else { continue }
            let parent = scaled(parentLayout.point)
            let child = scaled(childLayout.point)
            path.move(to: parent)
            path.line(to: NSPoint(x: parent.x, y: child.y))
            path.line(to: child)
        }
        path.stroke()
    }

    private func drawNodesAndLabels() {
        for node in nodes {
            guard let layout = layoutByID[node.id] else { continue }
            let point = scaled(layout.point)
            let radius = PhylogeneticTreeCanvasMetrics.nodeRadius
            nodeColor(for: node).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            if selectedNodeIDs.contains(node.id) {
                NSColor.controlAccentColor.setStroke()
                let highlight = NSBezierPath(ovalIn: NSRect(x: point.x - radius - 4, y: point.y - radius - 4, width: radius * 2 + 8, height: radius * 2 + 8))
                highlight.lineWidth = 2
                highlight.stroke()
            }
            if collapsedNodeIDs.contains(node.id), !node.isTip {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - radius - 7, y: point.y - radius - 7, width: radius * 2 + 14, height: radius * 2 + 14)).fill()
            }
            if node.isTip {
                drawTreeText(
                    node.displayLabel,
                    in: NSRect(
                        x: point.x + PhylogeneticTreeCanvasMetrics.labelGap,
                        y: point.y - 8,
                        width: labelWidth,
                        height: 18
                    ),
                    color: .labelColor,
                    font: .systemFont(ofSize: 11)
                )
            } else if let support = node.support {
                drawTreeText(
                    support.rawValue,
                    in: NSRect(x: point.x + 5, y: point.y - 18, width: 52, height: 15),
                    color: .secondaryLabelColor,
                    font: .systemFont(ofSize: 9)
                )
            }
        }
    }

    private func drawScaleBar() {
        guard layoutMode == .phylogram,
              let pointsPerBranchLengthUnit,
              pointsPerBranchLengthUnit > 0,
              maxBranchLengthUnits > 0 else {
            return
        }
        let targetPixels = min(max(bounds.width * 0.18, 72), 150)
        let targetUnits = targetPixels / (pointsPerBranchLengthUnit * zoomScale)
        let scaleUnits = niceScaleLength(near: targetUnits)
        let pixelLength = scaleUnits * pointsPerBranchLengthUnit * zoomScale
        guard pixelLength.isFinite, pixelLength > 12 else { return }

        let origin = NSPoint(
            x: PhylogeneticTreeCanvasMetrics.marginX * zoomScale,
            y: max(24, bounds.height - 30)
        )
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: origin)
        path.line(to: NSPoint(x: origin.x + pixelLength, y: origin.y))
        path.move(to: NSPoint(x: origin.x, y: origin.y - 4))
        path.line(to: NSPoint(x: origin.x, y: origin.y + 4))
        path.move(to: NSPoint(x: origin.x + pixelLength, y: origin.y - 4))
        path.line(to: NSPoint(x: origin.x + pixelLength, y: origin.y + 4))
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()

        drawTreeText(
            String(format: "%.3g substitutions/site", Double(scaleUnits)),
            in: NSRect(x: origin.x, y: origin.y + 6, width: 180, height: 16),
            color: .secondaryLabelColor,
            font: .systemFont(ofSize: 9)
        )
    }

    private func niceScaleLength(near value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0.1 }
        let exponent = floor(log10(Double(value)))
        let base = CGFloat(pow(10.0, exponent))
        let fraction = value / base
        let niceFraction: CGFloat
        if fraction <= 1 {
            niceFraction = 1
        } else if fraction <= 2 {
            niceFraction = 2
        } else if fraction <= 5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }
        return niceFraction * base
    }

    private func nodeColor(for node: PhylogeneticTreeNormalizedNode) -> NSColor {
        switch colorMode {
        case .none:
            return node.isTip ? .labelColor : .secondaryLabelColor
        case .support:
            guard let value = node.support?.rawValue,
                  let numeric = Double(value) else {
                return .tertiaryLabelColor
            }
            let normalized = max(0, min(1, numeric > 1 ? numeric / 100 : numeric))
            return NSColor.systemBlue.blended(withFraction: 1 - normalized, of: .systemGray) ?? .systemBlue
        case .branchLength:
            let length = max(0, min(1, node.branchLength ?? 0))
            return NSColor.systemGreen.blended(withFraction: 1 - CGFloat(length), of: .systemGray) ?? .systemGreen
        }
    }

    private func nodeID(at point: NSPoint) -> String? {
        layoutByID.min { lhs, rhs in
            distance(from: point, to: scaled(lhs.value.point)) < distance(from: point, to: scaled(rhs.value.point))
        }.flatMap { candidate in
            distance(from: point, to: scaled(candidate.value.point)) <= 10 ? candidate.key : nil
        }
    }

    private func distance(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func scaled(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x * zoomScale, y: point.y * zoomScale)
    }

    private func sanitizedAccessibilityComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "node" : sanitized
    }
}

private func drawTreeText(
    _ text: String,
    in rect: NSRect,
    color: NSColor,
    font: NSFont = .systemFont(ofSize: 12),
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    )
}
