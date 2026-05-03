// PhylogeneticTreeViewController.swift - Native tree bundle viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

private enum PhylogeneticTreeAccessibilityID {
    static let root = "phylogenetic-tree-bundle-view"
    static let summary = "phylogenetic-tree-summary"
    static let nodeTable = "phylogenetic-tree-node-table"
    static let canvasView = "phylogenetic-tree-canvas-view"
    static let searchField = "phylogenetic-tree-search-field"
    static let fitButton = "phylogenetic-tree-fit-button"
    static let resetButton = "phylogenetic-tree-reset-button"
    static let colorMode = "phylogenetic-tree-color-mode"
    static let detail = "phylogenetic-tree-detail"
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
final class PhylogeneticTreeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var bundleURL: URL?
    private(set) var bundle: PhylogeneticTreeBundle?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let colorModeControl = NSSegmentedControl(
        labels: ["None", "Support", "Branch"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let nodeTableView = NSTableView()
    private let treeCanvasView = PhylogeneticTreeCanvasView()
    private let treeScrollView = NSScrollView()
    private let detailLabel = NSTextField(labelWithString: "")

    private var nodes: [PhylogeneticTreeNormalizedNode] = []
    private var nodesByID: [String: PhylogeneticTreeNormalizedNode] = [:]
    private var selectedNodeID: String?

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.root)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureLayout()
    }

    func displayBundle(at url: URL) throws {
        _ = view
        let loaded = try PhylogeneticTreeBundle.load(from: url)
        bundleURL = url
        bundle = loaded
        nodes = orderedNodes(loaded.normalizedTree.nodes)
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        selectedNodeID = nil

        summaryLabel.stringValue = [
            loaded.manifest.name,
            "\(loaded.manifest.tipCount) tips",
            "\(loaded.manifest.internalNodeCount) internal nodes",
            loaded.manifest.isRooted ? "rooted" : "unrooted",
        ].joined(separator: "   ")

        detailLabel.stringValue = defaultDetailText(for: loaded)
        treeCanvasView.configure(nodes: nodes)
        nodeTableView.reloadData()
        selectInitialNode()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        nodes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = nodeTableView.selectedRow
        guard nodes.indices.contains(row) else { return }
        selectNode(id: nodes[row].id, center: true)
    }

    private func configureLayout() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.summary)
        root.addArrangedSubview(paddedContainer(summaryLabel, top: 10, bottom: 8, leading: 12, trailing: 12))

        root.addArrangedSubview(configureToolbar())

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        nodeTableView.headerView = NSTableHeaderView()
        nodeTableView.usesAlternatingRowBackgroundColors = true
        nodeTableView.rowHeight = 24
        nodeTableView.dataSource = self
        nodeTableView.delegate = self
        nodeTableView.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.nodeTable)
        addTableColumn(id: "node", title: "Node", width: 180)
        addTableColumn(id: "type", title: "Type", width: 70)
        addTableColumn(id: "tips", title: "Tips", width: 54)
        addTableColumn(id: "length", title: "Branch", width: 72)
        addTableColumn(id: "support", title: "Support", width: 72)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.documentView = nodeTableView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.widthAnchor.constraint(equalToConstant: 420).isActive = true

        treeCanvasView.onNodeSelected = { [weak self] nodeID in
            self?.selectNode(id: nodeID, center: false)
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

        splitView.addArrangedSubview(tableScroll)
        splitView.addArrangedSubview(treeScrollView)
        root.addArrangedSubview(splitView)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.detail)
        root.addArrangedSubview(paddedContainer(detailLabel, top: 8, bottom: 10, leading: 12, trailing: 12))

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.widthAnchor.constraint(equalTo: root.widthAnchor),
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func configureToolbar() -> NSView {
        searchField.placeholderString = "Find tip or node"
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted(_:))
        searchField.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        fitButton.target = self
        fitButton.action = #selector(fitTreeToViewport(_:))
        fitButton.bezelStyle = .rounded
        fitButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.fitButton)

        resetButton.target = self
        resetButton.action = #selector(resetTreeView(_:))
        resetButton.bezelStyle = .rounded
        resetButton.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.resetButton)

        colorModeControl.selectedSegment = 0
        colorModeControl.target = self
        colorModeControl.action = #selector(colorModeChanged(_:))
        colorModeControl.segmentStyle = .rounded
        colorModeControl.setAccessibilityIdentifier(PhylogeneticTreeAccessibilityID.colorMode)

        let toolbar = NSStackView(views: [
            searchField,
            fitButton,
            resetButton,
            colorModeControl,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        return toolbar
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

    private func selectInitialNode() {
        if let firstTip = nodes.first(where: \.isTip) {
            selectNode(id: firstTip.id, center: false)
        } else if let first = nodes.first {
            selectNode(id: first.id, center: false)
        }
    }

    private func selectNode(id: String, center: Bool) {
        guard let node = nodesByID[id] else { return }
        selectedNodeID = id
        treeCanvasView.selectedNodeID = id
        detailLabel.stringValue = detailText(for: node)
        if let row = nodes.firstIndex(where: { $0.id == id }),
           nodeTableView.selectedRow != row {
            nodeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            nodeTableView.scrollRowToVisible(row)
        }
        if center {
            centerSelectedNode()
        }
    }

    private func centerSelectedNode() {
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
        label.font = .systemFont(ofSize: 12)
        return cell
    }

    private func paddedContainer(
        _ content: NSView,
        top: CGFloat,
        bottom: CGFloat,
        leading: CGFloat,
        trailing: CGFloat
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailing),
        ])
        return container
    }
}

extension PhylogeneticTreeViewController {
    var testingCanvasNodeCount: Int {
        treeCanvasView.testingNodeCount
    }

    var testingRenderedTipLabels: [String] {
        nodes.filter(\.isTip).map(\.displayLabel).sorted()
    }

    var testingCanvasCommandTitles: [String] {
        [fitButton.title, resetButton.title]
    }

    var testingCanvasViewportFrame: NSRect {
        treeScrollView.frame
    }

    var testingTreeLayoutFrames: [String: NSRect] {
        [
            "rootView": view.frame,
            "treeScrollView": treeScrollView.frame,
            "treeCanvasView": treeCanvasView.frame,
        ]
    }

    var testingSelectedNodeLabel: String? {
        selectedNodeID.flatMap { nodesByID[$0]?.displayLabel }
    }

    var testingDetailText: String {
        detailLabel.stringValue
    }

    func testingSelectNode(label: String) {
        guard let node = nodes.first(where: { $0.displayLabel == label }) else { return }
        selectNode(id: node.id, center: true)
    }
}

private enum PhylogeneticTreeCanvasColorMode {
    case none
    case support
    case branchLength
}

private struct PhylogeneticTreeCanvasNodeLayout {
    let node: PhylogeneticTreeNormalizedNode
    let point: NSPoint
}

private final class PhylogeneticTreeCanvasView: NSView {
    var onNodeSelected: ((String) -> Void)?
    var selectedNodeID: String? {
        didSet { needsDisplay = true }
    }
    var colorMode: PhylogeneticTreeCanvasColorMode = .none {
        didSet { needsDisplay = true }
    }

    private var nodes: [PhylogeneticTreeNormalizedNode] = []
    private var nodesByID: [String: PhylogeneticTreeNormalizedNode] = [:]
    private var layoutByID: [String: PhylogeneticTreeCanvasNodeLayout] = [:]
    private var zoomScale: CGFloat = 1
    private var baseSize = NSSize(width: PhylogeneticTreeCanvasMetrics.minimumWidth, height: PhylogeneticTreeCanvasMetrics.minimumHeight)

    var testingNodeCount: Int { nodes.count }

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
        wantsLayer = true
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

    func configure(nodes: [PhylogeneticTreeNormalizedNode]) {
        self.nodes = nodes
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        recomputeLayout()
        needsDisplay = true
    }

    func fit(to visibleSize: NSSize) {
        guard baseSize.width > 0, baseSize.height > 0 else { return }
        let horizontal = visibleSize.width > 0 ? visibleSize.width / baseSize.width : 1
        let vertical = visibleSize.height > 0 ? visibleSize.height / baseSize.height : 1
        zoomScale = min(max(min(horizontal, vertical), 0.35), 2.5)
        updateFrameSize()
        needsDisplay = true
    }

    func resetView() {
        zoomScale = 1
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard !nodes.isEmpty else {
            drawTreeText("No tree nodes loaded.", in: bounds.insetBy(dx: 16, dy: 16), color: .secondaryLabelColor)
            return
        }

        drawEdges()
        drawNodesAndLabels()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = nodeID(at: point) else { return }
        onNodeSelected?(nodeID)
    }

    private func recomputeLayout() {
        guard !nodes.isEmpty else {
            layoutByID = [:]
            baseSize = NSSize(width: PhylogeneticTreeCanvasMetrics.minimumWidth, height: PhylogeneticTreeCanvasMetrics.minimumHeight)
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
            if let divergence = node.cumulativeDivergence, divergence > 0 {
                rawXByID[node.id] = CGFloat(divergence)
            } else {
                rawXByID[node.id] = CGFloat(depthByID[node.id] ?? 0)
            }
        }
        let maxRawX = max(rawXByID.values.max() ?? 1, 1)
        let tipCount = max(nodes.filter(\.isTip).count, 1)
        baseSize = NSSize(
            width: max(PhylogeneticTreeCanvasMetrics.minimumWidth, CGFloat(nodes.count) * 72),
            height: max(PhylogeneticTreeCanvasMetrics.minimumHeight, CGFloat(tipCount) * PhylogeneticTreeCanvasMetrics.tipSpacing + 80)
        )
        let drawableWidth = max(320, baseSize.width - PhylogeneticTreeCanvasMetrics.marginX * 2 - 180)
        let xScale = drawableWidth / maxRawX

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
            if selectedNodeID == node.id {
                NSColor.controlAccentColor.setStroke()
                let highlight = NSBezierPath(ovalIn: NSRect(x: point.x - radius - 4, y: point.y - radius - 4, width: radius * 2 + 8, height: radius * 2 + 8))
                highlight.lineWidth = 2
                highlight.stroke()
            }
            if node.isTip {
                drawTreeText(
                    node.displayLabel,
                    in: NSRect(
                        x: point.x + PhylogeneticTreeCanvasMetrics.labelGap,
                        y: point.y - 8,
                        width: 180,
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
