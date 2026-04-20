// WorkflowCanvasView.swift - Main canvas for workflow visual builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import os.log
import LungfishCore

/// Logger for canvas operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowCanvasView")

// MARK: - WorkflowCanvasViewDelegate

/// Delegate protocol for canvas events.
@MainActor
public protocol WorkflowCanvasViewDelegate: AnyObject {
    /// Called when a node is selected.
    func canvasView(_ canvasView: WorkflowCanvasView, didSelectNode node: WorkflowNode?)

    /// Called when a connection is selected.
    func canvasView(_ canvasView: WorkflowCanvasView, didSelectConnection connection: WorkflowConnection?)

    /// Called when the graph is modified.
    func canvasViewDidModifyGraph(_ canvasView: WorkflowCanvasView)
}

// MARK: - WorkflowCanvasView

/// The main canvas view for the visual workflow builder.
///
/// Displays workflow nodes and connections, supports pan/zoom navigation,
/// drag-and-drop node placement, and connection drawing.
///
/// ## Features
/// - Grid background with configurable spacing
/// - Pan gesture (right-click drag or two-finger scroll)
/// - Zoom gesture (pinch or scroll wheel with modifier)
/// - Node selection and multi-selection
/// - Connection drawing with Bezier curves
/// - Undo/redo support
/// - Snap to grid option
@MainActor
public class WorkflowCanvasView: NSView {

    // MARK: - Properties

    /// The workflow graph being displayed.
    public var graph: WorkflowGraph {
        didSet {
            rebuildNodeViews()
            rebuildConnectionViews()
            setNeedsDisplay(bounds)
        }
    }

    /// Delegate for canvas events.
    public weak var delegate: WorkflowCanvasViewDelegate?

    /// Grid spacing in points.
    public var gridSpacing: CGFloat = 20 {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Whether to show the grid.
    public var showGrid: Bool = true {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Whether to snap nodes to grid.
    public var snapToGrid: Bool = true

    /// Current zoom level (0.25 to 4.0).
    public private(set) var zoomLevel: CGFloat = 1.0

    /// Minimum zoom level.
    public let minZoom: CGFloat = 0.25

    /// Maximum zoom level.
    public let maxZoom: CGFloat = 4.0

    /// Current pan offset.
    public private(set) var panOffset: CGPoint = .zero

    // MARK: - Internal State

    /// Node views keyed by node ID.
    private var nodeViews: [UUID: WorkflowNodeView] = [:]

    /// Connection views keyed by connection ID.
    private var connectionViews: [UUID: WorkflowConnectionView] = [:]

    /// Currently selected node IDs.
    private var selectedNodeIds: Set<UUID> = []

    /// Currently selected connection IDs.
    private var selectedConnectionIds: Set<UUID> = []

    /// Connection being drawn (in progress).
    private var pendingConnection: PendingConnection?

    /// Drag state for panning.
    private var panStartPoint: CGPoint?

    /// Drag state for selection rectangle.
    private var selectionRect: NSRect?
    private var selectionStartPoint: CGPoint?

    /// Undo manager for the canvas.
    private var _undoManager: UndoManager?

    /// Tracking area for mouse events.
    private var trackingArea: NSTrackingArea?

    // MARK: - Pending Connection State

    private struct PendingConnection {
        let sourceEndpoint: ConnectionEndpoint
        var currentPoint: CGPoint
    }

    // MARK: - Initialization

    /// Creates a new canvas view with an empty graph.
    public init() {
        self.graph = WorkflowGraph(name: "New Workflow")
        super.init(frame: .zero)
        commonInit()
    }

    /// Creates a new canvas view with the specified graph.
    public init(graph: WorkflowGraph) {
        self.graph = graph
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.graph = WorkflowGraph(name: "New Workflow")
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        // Register for drag and drop
        registerForDraggedTypes([.workflowNodeType])

        // Set up undo manager
        _undoManager = UndoManager()

        setupAccessibility()

        logger.info("WorkflowCanvasView initialized")
    }

    // MARK: - View Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingArea()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .mouseEnteredAndExited,
            .inVisibleRect
        ]

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )

        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    // MARK: - Accessibility

    private func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Workflow canvas")
        setAccessibilityIdentifier("workflow-canvas")
    }

    public override func accessibilityChildren() -> [Any]? {
        let nodes = nodeViews.keys
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { nodeViews[$0] }
        let connections = connectionViews.keys
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { connectionViews[$0] }
        return nodes + connections
    }

    // MARK: - Undo Manager

    public override var undoManager: UndoManager? {
        _undoManager
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Apply transform for pan/zoom
        context.saveGState()
        context.translateBy(x: panOffset.x, y: panOffset.y)
        context.scaleBy(x: zoomLevel, y: zoomLevel)

        // Draw grid
        if showGrid {
            drawGrid(context: context, dirtyRect: dirtyRect)
        }

        // Draw selection rectangle if dragging
        if let selRect = selectionRect {
            drawSelectionRect(selRect, context: context)
        }

        // Draw pending connection
        if let pending = pendingConnection {
            drawPendingConnection(pending, context: context)
        }

        context.restoreGState()
    }

    private func drawGrid(context: CGContext, dirtyRect: NSRect) {
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)
        context.setStrokeColor(gridColor.cgColor)
        context.setLineWidth(0.5 / zoomLevel)

        // Calculate visible area in canvas coordinates
        let visibleRect = convertToCanvasCoordinates(dirtyRect)

        let startX = floor(visibleRect.minX / gridSpacing) * gridSpacing
        let startY = floor(visibleRect.minY / gridSpacing) * gridSpacing
        let endX = ceil(visibleRect.maxX / gridSpacing) * gridSpacing
        let endY = ceil(visibleRect.maxY / gridSpacing) * gridSpacing

        // Vertical lines
        var x = startX
        while x <= endX {
            context.move(to: CGPoint(x: x, y: startY))
            context.addLine(to: CGPoint(x: x, y: endY))
            x += gridSpacing
        }

        // Horizontal lines
        var y = startY
        while y <= endY {
            context.move(to: CGPoint(x: startX, y: y))
            context.addLine(to: CGPoint(x: endX, y: y))
            y += gridSpacing
        }

        context.strokePath()
    }

    private func drawSelectionRect(_ rect: NSRect, context: CGContext) {
        // Fill
        context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor)
        context.fill(rect)

        // Stroke
        context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
        context.setLineWidth(1.0 / zoomLevel)
        context.stroke(rect)
    }

    private func drawPendingConnection(_ pending: PendingConnection, context: CGContext) {
        // Get source node view for port position
        guard let sourceNodeView = nodeViews[pending.sourceEndpoint.nodeId] else { return }
        let sourcePoint = sourceNodeView.portPosition(for: pending.sourceEndpoint.portId, direction: .output)

        // Convert current point to canvas coordinates
        let targetPoint = convertToCanvasCoordinates(pending.currentPoint)

        // Draw bezier curve
        let color = NSColor(
            red: pending.sourceEndpoint.dataType.colorComponents.red,
            green: pending.sourceEndpoint.dataType.colorComponents.green,
            blue: pending.sourceEndpoint.dataType.colorComponents.blue,
            alpha: 0.8
        )
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.0 / zoomLevel)
        context.setLineDash(phase: 0, lengths: [6 / zoomLevel, 4 / zoomLevel])

        let path = CGMutablePath()
        path.move(to: sourcePoint)

        let controlOffset = abs(targetPoint.x - sourcePoint.x) / 2
        let cp1 = CGPoint(x: sourcePoint.x + controlOffset, y: sourcePoint.y)
        let cp2 = CGPoint(x: targetPoint.x - controlOffset, y: targetPoint.y)

        path.addCurve(to: targetPoint, control1: cp1, control2: cp2)
        context.addPath(path)
        context.strokePath()
    }

    // MARK: - Node View Management

    private func rebuildNodeViews() {
        // Remove old views
        for (_, view) in nodeViews {
            view.removeFromSuperview()
        }
        nodeViews.removeAll()

        // Create new views
        for node in graph.allNodes {
            let nodeView = WorkflowNodeView(node: node)
            nodeView.delegate = self
            addSubview(nodeView)
            nodeViews[node.id] = nodeView
            updateNodeViewFrame(nodeView, for: node)
        }
    }

    private func rebuildConnectionViews() {
        // Remove old views
        for (_, view) in connectionViews {
            view.removeFromSuperview()
        }
        connectionViews.removeAll()

        // Create new views
        for connection in graph.allConnections {
            if let sourceNodeView = nodeViews[connection.sourceNodeId],
               let targetNodeView = nodeViews[connection.targetNodeId] {
                let connectionView = WorkflowConnectionView(
                    connection: connection,
                    sourceNodeView: sourceNodeView,
                    targetNodeView: targetNodeView
                )
                connectionView.delegate = self
                addSubview(connectionView, positioned: .below, relativeTo: nodeViews.values.first)
                connectionViews[connection.id] = connectionView
            }
        }
    }

    private func updateNodeViewFrame(_ view: WorkflowNodeView, for node: WorkflowNode) {
        let size = view.intrinsicContentSize
        let origin = convertFromCanvasCoordinates(node.position)
        view.frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: size.width * zoomLevel,
            height: size.height * zoomLevel
        )
    }

    // MARK: - Coordinate Conversion

    /// Converts a point from view coordinates to canvas coordinates.
    public func convertToCanvasCoordinates(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - panOffset.x) / zoomLevel,
            y: (point.y - panOffset.y) / zoomLevel
        )
    }

    /// Converts a point from canvas coordinates to view coordinates.
    public func convertFromCanvasCoordinates(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * zoomLevel + panOffset.x,
            y: point.y * zoomLevel + panOffset.y
        )
    }

    /// Converts a rect from view coordinates to canvas coordinates.
    public func convertToCanvasCoordinates(_ rect: NSRect) -> NSRect {
        NSRect(
            x: (rect.origin.x - panOffset.x) / zoomLevel,
            y: (rect.origin.y - panOffset.y) / zoomLevel,
            width: rect.width / zoomLevel,
            height: rect.height / zoomLevel
        )
    }

    // MARK: - Snap to Grid

    private func snapPointToGrid(_ point: CGPoint) -> CGPoint {
        guard snapToGrid else { return point }
        return CGPoint(
            x: round(point.x / gridSpacing) * gridSpacing,
            y: round(point.y / gridSpacing) * gridSpacing
        )
    }

    // MARK: - Pan and Zoom

    /// Sets the zoom level, centered on the given point.
    public func setZoom(_ newZoom: CGFloat, centeredOn point: CGPoint) {
        let clampedZoom = max(minZoom, min(maxZoom, newZoom))

        // Adjust pan to keep the point stationary
        let canvasPoint = convertToCanvasCoordinates(point)

        zoomLevel = clampedZoom

        // Calculate new pan offset to keep canvasPoint at the same view position
        panOffset = CGPoint(
            x: point.x - canvasPoint.x * zoomLevel,
            y: point.y - canvasPoint.y * zoomLevel
        )

        updateAllNodeViewFrames()
        setNeedsDisplay(bounds)

        logger.debug("Zoom set to \(clampedZoom, format: .fixed(precision: 2))")
    }

    /// Zooms in by the specified factor.
    public func zoomIn(factor: CGFloat = 1.25) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        setZoom(zoomLevel * factor, centeredOn: center)
    }

    /// Zooms out by the specified factor.
    public func zoomOut(factor: CGFloat = 1.25) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        setZoom(zoomLevel / factor, centeredOn: center)
    }

    /// Resets zoom to 100% and centers the content.
    public func resetZoom() {
        zoomLevel = 1.0
        centerContent()
    }

    /// Centers the workflow content in the view.
    public func centerContent() {
        guard !graph.allNodes.isEmpty else {
            panOffset = .zero
            setNeedsDisplay(bounds)
            return
        }

        // Calculate bounding box of all nodes
        var minX: CGFloat = .infinity
        var minY: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var maxY: CGFloat = -.infinity

        for node in graph.allNodes {
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + 160) // Approximate node width
            maxY = max(maxY, node.position.y + 100) // Approximate node height
        }

        let contentCenter = CGPoint(
            x: (minX + maxX) / 2 * zoomLevel,
            y: (minY + maxY) / 2 * zoomLevel
        )

        panOffset = CGPoint(
            x: bounds.midX - contentCenter.x,
            y: bounds.midY - contentCenter.y
        )

        updateAllNodeViewFrames()
        setNeedsDisplay(bounds)
    }

    private func updateAllNodeViewFrames() {
        for (nodeId, nodeView) in nodeViews {
            if let node = graph.getNode(nodeId) {
                updateNodeViewFrame(nodeView, for: node)
            }
        }

        // Update connection views
        for (_, connectionView) in connectionViews {
            connectionView.updatePath()
        }
    }

    // MARK: - Selection

    /// Selects a node.
    public func selectNode(_ nodeId: UUID, extendSelection: Bool = false) {
        if !extendSelection {
            deselectAll()
        }

        selectedNodeIds.insert(nodeId)
        nodeViews[nodeId]?.isSelected = true
        delegate?.canvasView(self, didSelectNode: graph.getNode(nodeId))

        logger.debug("Selected node: \(nodeId)")
    }

    /// Selects a connection.
    public func selectConnection(_ connectionId: UUID, extendSelection: Bool = false) {
        if !extendSelection {
            deselectAll()
        }

        selectedConnectionIds.insert(connectionId)
        connectionViews[connectionId]?.isSelected = true
        delegate?.canvasView(self, didSelectConnection: graph.getConnection(connectionId))

        logger.debug("Selected connection: \(connectionId)")
    }

    /// Deselects all nodes and connections.
    public func deselectAll() {
        for nodeId in selectedNodeIds {
            nodeViews[nodeId]?.isSelected = false
        }
        selectedNodeIds.removeAll()

        for connectionId in selectedConnectionIds {
            connectionViews[connectionId]?.isSelected = false
        }
        selectedConnectionIds.removeAll()

        delegate?.canvasView(self, didSelectNode: nil)
        delegate?.canvasView(self, didSelectConnection: nil)
    }

    /// Deletes selected nodes and connections.
    public func deleteSelection() {
        // Capture counts before clearing selection
        let deletedNodeCount = self.selectedNodeIds.count
        let deletedConnectionCount = self.selectedConnectionIds.count

        // Register undo
        let oldGraph = graph
        undoManager?.registerUndo(withTarget: self) { target in
            target.graph = oldGraph
            target.delegate?.canvasViewDidModifyGraph(target)
        }

        // Remove connections first
        for connectionId in selectedConnectionIds {
            _ = graph.removeConnection(connectionId)
        }

        // Remove nodes (this also removes their connections)
        for nodeId in selectedNodeIds {
            _ = graph.removeNode(nodeId)
        }

        rebuildNodeViews()
        rebuildConnectionViews()
        deselectAll()
        delegate?.canvasViewDidModifyGraph(self)

        logger.info("Deleted \(deletedNodeCount) nodes and \(deletedConnectionCount) connections")
    }

    // MARK: - Node Operations

    /// Adds a node at the specified position.
    public func addNode(type: WorkflowNodeType, at position: CGPoint) {
        let canvasPosition = snapPointToGrid(convertToCanvasCoordinates(position))

        // Register undo
        undoManager?.registerUndo(withTarget: self) { [weak self] target in
            guard self != nil else { return }
            // Will be replaced when node is added
        }

        let node = graph.addNode(type: type, position: canvasPosition)

        // Create view
        let nodeView = WorkflowNodeView(node: node)
        nodeView.delegate = self
        addSubview(nodeView)
        nodeViews[node.id] = nodeView
        updateNodeViewFrame(nodeView, for: node)

        // Update undo action
        undoManager?.registerUndo(withTarget: self) { target in
            _ = target.graph.removeNode(node.id)
            target.rebuildNodeViews()
            target.rebuildConnectionViews()
            target.delegate?.canvasViewDidModifyGraph(target)
        }

        delegate?.canvasViewDidModifyGraph(self)

        logger.info("Added node: \(type.displayName) at (\(canvasPosition.x), \(canvasPosition.y))")
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let canvasPoint = convertToCanvasCoordinates(point)

        // Check if clicking on a node
        for (nodeId, nodeView) in nodeViews {
            let nodeRect = convertToCanvasCoordinates(nodeView.frame)
            if nodeRect.contains(canvasPoint) {
                // Check if clicking on a port
                if let portId = nodeView.portAtPoint(convert(point, to: nodeView)),
                   let node = graph.getNode(nodeId),
                   let endpoint = ConnectionEndpoint(node: node, portId: portId) {
                    // Start connection drawing
                    pendingConnection = PendingConnection(
                        sourceEndpoint: endpoint,
                        currentPoint: point
                    )
                    return
                }

                // Select the node
                let extendSelection = event.modifierFlags.contains(.shift)
                selectNode(nodeId, extendSelection: extendSelection)
                return
            }
        }

        // Check if clicking on a connection
        for (connectionId, connectionView) in connectionViews {
            if connectionView.hitTest(point) != nil {
                let extendSelection = event.modifierFlags.contains(.shift)
                selectConnection(connectionId, extendSelection: extendSelection)
                return
            }
        }

        // Start selection rectangle or pan
        if event.modifierFlags.contains(.option) || event.clickCount == 1 {
            selectionStartPoint = canvasPoint
            selectionRect = NSRect(origin: canvasPoint, size: .zero)
        }

        deselectAll()
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Handle pending connection
        if pendingConnection != nil {
            pendingConnection?.currentPoint = point
            setNeedsDisplay(bounds)
            return
        }

        // Handle selection rectangle
        if let startPoint = selectionStartPoint {
            let canvasPoint = convertToCanvasCoordinates(point)
            selectionRect = NSRect(
                x: min(startPoint.x, canvasPoint.x),
                y: min(startPoint.y, canvasPoint.y),
                width: abs(canvasPoint.x - startPoint.x),
                height: abs(canvasPoint.y - startPoint.y)
            )
            setNeedsDisplay(bounds)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Complete pending connection
        if let pending = pendingConnection {
            completePendingConnection(pending, at: point)
            pendingConnection = nil
            setNeedsDisplay(bounds)
            return
        }

        // Complete selection rectangle
        if let rect = selectionRect {
            selectNodesInRect(rect)
            selectionRect = nil
            selectionStartPoint = nil
            setNeedsDisplay(bounds)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        // Start panning
        panStartPoint = convert(event.locationInWindow, from: nil)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard let startPoint = panStartPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)

        panOffset = CGPoint(
            x: panOffset.x + (currentPoint.x - startPoint.x),
            y: panOffset.y + (currentPoint.y - startPoint.y)
        )

        panStartPoint = currentPoint
        updateAllNodeViewFrames()
        setNeedsDisplay(bounds)
    }

    public override func rightMouseUp(with event: NSEvent) {
        panStartPoint = nil
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Zoom
            let zoomDelta = event.scrollingDeltaY * 0.01
            let point = convert(event.locationInWindow, from: nil)
            setZoom(zoomLevel + zoomDelta, centeredOn: point)
        } else {
            // Pan
            panOffset = CGPoint(
                x: panOffset.x + event.scrollingDeltaX,
                y: panOffset.y + event.scrollingDeltaY
            )
            updateAllNodeViewFrames()
            setNeedsDisplay(bounds)
        }
    }

    public override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setZoom(zoomLevel * (1 + event.magnification), centeredOn: point)
    }

    // MARK: - Connection Completion

    private func completePendingConnection(_ pending: PendingConnection, at point: CGPoint) {
        let canvasPoint = convertToCanvasCoordinates(point)

        // Find target port
        for (nodeId, nodeView) in nodeViews {
            let nodeRect = convertToCanvasCoordinates(nodeView.frame)
            if nodeRect.contains(canvasPoint) {
                if let portId = nodeView.portAtPoint(convert(point, to: nodeView)),
                   let node = graph.getNode(nodeId),
                   let targetEndpoint = ConnectionEndpoint(node: node, portId: portId) {
                    // Validate connection direction
                    if pending.sourceEndpoint.direction == .output && targetEndpoint.direction == .input {
                        createConnection(from: pending.sourceEndpoint, to: targetEndpoint)
                    } else if pending.sourceEndpoint.direction == .input && targetEndpoint.direction == .output {
                        createConnection(from: targetEndpoint, to: pending.sourceEndpoint)
                    }
                    return
                }
            }
        }
    }

    private func createConnection(from source: ConnectionEndpoint, to target: ConnectionEndpoint) {
        do {
            let connection = try graph.addConnection(
                sourceNodeId: source.nodeId,
                sourcePortId: source.portId,
                targetNodeId: target.nodeId,
                targetPortId: target.portId
            )

            // Register undo
            undoManager?.registerUndo(withTarget: self) { target in
                _ = target.graph.removeConnection(connection.id)
                target.rebuildConnectionViews()
                target.delegate?.canvasViewDidModifyGraph(target)
            }

            rebuildConnectionViews()
            delegate?.canvasViewDidModifyGraph(self)

            logger.info("Created connection from \(source.nodeId) to \(target.nodeId)")
        } catch {
            logger.error("Failed to create connection: \(error.localizedDescription)")
            // Show error alert
            NSSound.beep()
        }
    }

    private func selectNodesInRect(_ rect: NSRect) {
        for (nodeId, nodeView) in nodeViews {
            if let node = graph.getNode(nodeId) {
                if rect.intersects(NSRect(origin: node.position, size: nodeView.intrinsicContentSize)) {
                    selectNode(nodeId, extendSelection: true)
                }
            }
        }
    }

    // MARK: - Keyboard Events

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            deleteSelection()
        case 123: // Left arrow
            moveSelection(dx: -gridSpacing, dy: 0)
        case 124: // Right arrow
            moveSelection(dx: gridSpacing, dy: 0)
        case 125: // Down arrow
            moveSelection(dx: 0, dy: gridSpacing)
        case 126: // Up arrow
            moveSelection(dx: 0, dy: -gridSpacing)
        case 0: // A (Select All)
            if event.modifierFlags.contains(.command) {
                selectAllNodes()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        for nodeId in selectedNodeIds {
            if var node = graph.getNode(nodeId) {
                node.position = CGPoint(
                    x: node.position.x + dx,
                    y: node.position.y + dy
                )
                try? graph.updateNode(node)
                if let nodeView = nodeViews[nodeId] {
                    updateNodeViewFrame(nodeView, for: node)
                }
            }
        }

        // Update connections
        for (_, connectionView) in connectionViews {
            connectionView.updatePath()
        }

        delegate?.canvasViewDidModifyGraph(self)
    }

    private func selectAllNodes() {
        for nodeId in graph.nodes.keys {
            selectNode(nodeId, extendSelection: true)
        }
    }

    // MARK: - Drag and Drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSString.self], options: [.urlReadingContentsConformToTypes: [NSPasteboard.PasteboardType.workflowNodeType.rawValue]]) {
            return .copy
        }
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.pasteboardItems else { return false }

        for item in items {
            if let typeString = item.string(forType: .workflowNodeType),
               let type = WorkflowNodeType(rawValue: typeString) {
                let point = convert(sender.draggingLocation, from: nil)
                addNode(type: type, at: point)
                return true
            }
        }

        return false
    }
}

// MARK: - WorkflowNodeViewDelegate

extension WorkflowCanvasView: WorkflowNodeViewDelegate {

    public func nodeViewDidMove(_ nodeView: WorkflowNodeView, to position: CGPoint) {
        guard let nodeId = nodeViews.first(where: { $0.value === nodeView })?.key,
              var node = graph.getNode(nodeId) else { return }

        let canvasPosition = snapPointToGrid(convertToCanvasCoordinates(position))
        node.position = canvasPosition
        try? graph.updateNode(node)

        // Update connections
        for (_, connectionView) in connectionViews {
            if connectionView.connection.sourceNodeId == nodeId ||
               connectionView.connection.targetNodeId == nodeId {
                connectionView.updatePath()
            }
        }

        delegate?.canvasViewDidModifyGraph(self)
    }

    public func nodeViewDidSelect(_ nodeView: WorkflowNodeView) {
        if let nodeId = nodeViews.first(where: { $0.value === nodeView })?.key {
            selectNode(nodeId)
        }
    }
}

// MARK: - WorkflowConnectionViewDelegate

extension WorkflowCanvasView: WorkflowConnectionViewDelegate {

    public func connectionViewDidSelect(_ connectionView: WorkflowConnectionView) {
        if let connectionId = connectionViews.first(where: { $0.value === connectionView })?.key {
            selectConnection(connectionId)
        }
    }
}

// MARK: - Pasteboard Type

public extension NSPasteboard.PasteboardType {
    /// Pasteboard type for workflow node drag and drop.
    static let workflowNodeType = NSPasteboard.PasteboardType("com.lungfish.workflow.nodetype")
}
