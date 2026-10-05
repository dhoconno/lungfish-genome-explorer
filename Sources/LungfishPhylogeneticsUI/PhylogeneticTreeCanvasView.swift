// PhylogeneticTreeCanvasView.swift - Tree canvas view and node accessibility element
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishIO

struct PhylogeneticTreeCanvasNodeLayout {
    let node: PhylogeneticTreeNormalizedNode
    let point: NSPoint
}

/// A canvas node's accessibility element. Press selects the node.
final class PhylogeneticTreeNodeAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

final class PhylogeneticTreeCanvasView: NSView {
    var onNodeSelected: ((String) -> Void)?
    /// The accessibility custom actions of one node, supplied by the controller.
    var accessibilityActionsProvider: ((String) -> [NSAccessibilityCustomAction])?
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
    var supportLabels: [String] = []
    var supportTextFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) { didSet { needsDisplay = true } }
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
    #if DEBUG
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
    #endif

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
            let element = PhylogeneticTreeNodeAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityIdentifier("phylogenetic-tree-node-\(sanitizedAccessibilityComponent(node.displayLabel))")
            element.setAccessibilityLabel(Self.accessibilityLabel(for: node))
            element.setAccessibilityFrameInParentSpace(rect.insetBy(dx: -6, dy: -6))
            let nodeID = node.id
            element.onPress = { [weak self] in self?.onNodeSelected?(nodeID) }
            element.setAccessibilityCustomActions(accessibilityActionsProvider?(nodeID) ?? [])
            return element
        }
    }

    /// The spoken label of a node: "Homo sapiens, tip, branch length 0.0123" for a tip and
    /// "internal node, 4 tips, SH-aLRT 99.9, UFBoot 100" for an internal node with recorded support labels.
    static func accessibilityLabel(for node: PhylogeneticTreeNormalizedNode) -> String {
        var parts: [String]
        if node.isTip {
            parts = [node.displayLabel, "tip"]
        } else {
            let tips = node.descendantTipCount
            parts = ["internal node", "\(tips) \(tips == 1 ? "tip" : "tips")"]
        }
        if let branchLength = node.branchLength {
            parts.append("branch length \(String(format: "%.6g", branchLength))")
        }
        if !node.supportValues.isEmpty {
            parts += node.supportValues.map { "\($0.label) \($0.rawValue)" }
        } else if let support = node.support {
            parts.append("support \(support.rawValue)")
        }
        return parts.joined(separator: ", ")
    }

    func configure(nodes: [PhylogeneticTreeNormalizedNode], collapsedNodeIDs: Set<String>) {
        #if DEBUG
        configureCount += 1
        #endif
        self.nodes = nodes
        self.collapsedNodeIDs = collapsedNodeIDs
        nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        recomputeLayout()
        needsDisplay = true
    }

    func fit(to visibleSize: NSSize) {
        #if DEBUG
        fitCount += 1
        #endif
        guard baseSize.width > 0, baseSize.height > 0 else { return }
        let horizontal = visibleSize.width > 0 ? visibleSize.width / baseSize.width : 1
        let vertical = visibleSize.height > 0 ? visibleSize.height / baseSize.height : 1
        zoomScale = min(max(min(horizontal, vertical), 0.35), 2.5)
        updateFrameSize()
        needsDisplay = true
    }

    func resetView() {
        #if DEBUG
        resetCount += 1
        #endif
        zoomScale = 1
        updateFrameSize()
        needsDisplay = true
    }

    func zoom(by factor: CGFloat) {
        #if DEBUG
        zoomCount += 1
        #endif
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

    #if DEBUG
    func testingPoint(label: String) -> NSPoint? {
        guard let node = nodes.first(where: { $0.displayLabel == label }),
              let layout = layoutByID[node.id] else {
            return nil
        }
        return scaled(layout.point)
    }
    #endif

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

    /// The canvas takes keyboard focus on a click so the Selection > Tree Node
    /// menu-bar items validate against it.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = nodeID(at: point) else { return }
        onNodeSelected?(nodeID)
    }

    /// A right-click selects the node under the pointer, so the menu's
    /// commands act on it. A node already in the selection keeps the
    /// selection, as in Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let nodeID = nodeID(at: point), !selectedNodeIDs.contains(nodeID) {
            onNodeSelected?(nodeID)
        }
        return super.menu(for: event)
    }

    private func recomputeLayout() {
        #if DEBUG
        recomputeLayoutCount += 1
        #endif
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
            } else if let supportText = PhylogeneticTreeSupportPresentation.supportText(for: node) {
                drawTreeText(
                    supportText,
                    in: PhylogeneticTreeSupportPresentation.canvasTextRect(supportText, font: supportTextFont, nodePoint: point),
                    color: .secondaryLabelColor,
                    font: supportTextFont
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
            return PhylogeneticTreeSupportPresentation.nodeColor(for: node, labels: supportLabels)
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
