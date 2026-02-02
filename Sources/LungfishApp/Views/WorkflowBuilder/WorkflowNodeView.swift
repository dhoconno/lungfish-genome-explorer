// WorkflowNodeView.swift - Visual representation of a workflow node
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import os.log

/// Logger for node view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "WorkflowNodeView")

// MARK: - WorkflowNodeViewDelegate

/// Delegate protocol for node view events.
@MainActor
public protocol WorkflowNodeViewDelegate: AnyObject {
    /// Called when the node view is moved.
    func nodeViewDidMove(_ nodeView: WorkflowNodeView, to position: CGPoint)

    /// Called when the node view is selected.
    func nodeViewDidSelect(_ nodeView: WorkflowNodeView)
}

// MARK: - WorkflowNodeView

/// Visual representation of a workflow node in the canvas.
///
/// Displays:
/// - Rounded rectangle background with category color
/// - Title bar with SF Symbol icon and label
/// - Input ports on the left
/// - Output ports on the right
/// - Selection border when selected
@MainActor
public class WorkflowNodeView: NSView {

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 8
    private static let titleBarHeight: CGFloat = 28
    private static let portRadius: CGFloat = 6
    private static let portSpacing: CGFloat = 24
    private static let minWidth: CGFloat = 160
    private static let padding: CGFloat = 12

    // MARK: - Properties

    /// The workflow node being displayed.
    public private(set) var node: WorkflowNode

    /// Delegate for node events.
    public weak var delegate: WorkflowNodeViewDelegate?

    /// Whether this node is selected.
    public var isSelected: Bool = false {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Port currently being hovered over.
    private var hoveredPortId: String?

    /// Whether the node is being dragged.
    private var isDragging: Bool = false

    /// Starting point for drag operation.
    private var dragStartPoint: CGPoint?
    private var dragStartPosition: CGPoint?

    /// Tracking area for mouse events.
    private var trackingArea: NSTrackingArea?

    // MARK: - Port Geometry Cache

    private struct PortGeometry {
        let portId: String
        let direction: PortDirection
        let center: CGPoint
        let dataType: PortDataType
    }

    private var portGeometries: [PortGeometry] = []

    // MARK: - Initialization

    /// Creates a new node view for the given node.
    public init(node: WorkflowNode) {
        self.node = node
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false

        // Add shadow
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowRadius = 4

        setupAccessibility()
        calculatePortGeometries()
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
        setAccessibilityLabel("\(node.type.displayName) node: \(node.label)")
        setAccessibilityIdentifier("workflow-node-\(node.id)")
    }

    // MARK: - Layout

    public override var intrinsicContentSize: NSSize {
        let portCount = max(node.inputPorts.count, node.outputPorts.count)
        let portHeight = CGFloat(max(1, portCount)) * Self.portSpacing + Self.padding

        return NSSize(
            width: Self.minWidth,
            height: Self.titleBarHeight + portHeight
        )
    }

    private func calculatePortGeometries() {
        portGeometries.removeAll()

        let size = intrinsicContentSize
        let portAreaTop = Self.titleBarHeight + Self.padding / 2

        // Input ports on the left
        for (index, port) in node.inputPorts.enumerated() {
            let y = portAreaTop + CGFloat(index) * Self.portSpacing + Self.portSpacing / 2
            portGeometries.append(PortGeometry(
                portId: port.id,
                direction: .input,
                center: CGPoint(x: Self.portRadius, y: y),
                dataType: port.dataType
            ))
        }

        // Output ports on the right
        for (index, port) in node.outputPorts.enumerated() {
            let y = portAreaTop + CGFloat(index) * Self.portSpacing + Self.portSpacing / 2
            portGeometries.append(PortGeometry(
                portId: port.id,
                direction: .output,
                center: CGPoint(x: size.width - Self.portRadius, y: y),
                dataType: port.dataType
            ))
        }
    }

    /// Returns the position of a port in canvas coordinates.
    public func portPosition(for portId: String, direction: PortDirection) -> CGPoint {
        if let geometry = portGeometries.first(where: { $0.portId == portId && $0.direction == direction }) {
            // Convert to superview coordinates
            let viewPoint = geometry.center
            return convert(viewPoint, to: superview)
        }
        return .zero
    }

    /// Returns the port ID at the given point, or nil if no port is at that point.
    public func portAtPoint(_ point: CGPoint) -> String? {
        for geometry in portGeometries {
            let distance = hypot(point.x - geometry.center.x, point.y - geometry.center.y)
            if distance <= Self.portRadius + 4 { // Slightly larger hit area
                return geometry.portId
            }
        }
        return nil
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        drawBackground(context: context)

        // Title bar
        drawTitleBar(context: context)

        // Ports
        drawPorts(context: context)

        // Selection border
        if isSelected {
            drawSelectionBorder(context: context)
        }
    }

    private func drawBackground(context: CGContext) {
        let rect = bounds.insetBy(dx: Self.portRadius, dy: 0)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )

        // Background fill
        context.addPath(path)
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()

        // Border
        context.addPath(path)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private func drawTitleBar(context: CGContext) {
        let titleRect = NSRect(
            x: Self.portRadius,
            y: 0,
            width: bounds.width - Self.portRadius * 2,
            height: Self.titleBarHeight
        )

        // Title bar background with category color
        let categoryColor = colorForCategory(node.type.category)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: titleRect.minX + Self.cornerRadius, y: titleRect.minY))
        path.addLine(to: CGPoint(x: titleRect.maxX - Self.cornerRadius, y: titleRect.minY))
        path.addArc(
            tangent1End: CGPoint(x: titleRect.maxX, y: titleRect.minY),
            tangent2End: CGPoint(x: titleRect.maxX, y: titleRect.minY + Self.cornerRadius),
            radius: Self.cornerRadius
        )
        path.addLine(to: CGPoint(x: titleRect.maxX, y: titleRect.maxY))
        path.addLine(to: CGPoint(x: titleRect.minX, y: titleRect.maxY))
        path.addLine(to: CGPoint(x: titleRect.minX, y: titleRect.minY + Self.cornerRadius))
        path.addArc(
            tangent1End: CGPoint(x: titleRect.minX, y: titleRect.minY),
            tangent2End: CGPoint(x: titleRect.minX + Self.cornerRadius, y: titleRect.minY),
            radius: Self.cornerRadius
        )
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(categoryColor.cgColor)
        context.fillPath()

        // Icon
        if let iconImage = NSImage(systemSymbolName: node.type.iconName, accessibilityDescription: nil) {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(
                x: Self.portRadius + 8,
                y: (Self.titleBarHeight - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )

            let tintedImage = iconImage.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.white])
            )
            tintedImage?.draw(in: iconRect)
        }

        // Title text
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        let titleText = node.label
        let titleSize = (titleText as NSString).size(withAttributes: titleAttributes)
        let titlePoint = CGPoint(
            x: Self.portRadius + 28,
            y: (Self.titleBarHeight - titleSize.height) / 2
        )

        (titleText as NSString).draw(at: titlePoint, withAttributes: titleAttributes)
    }

    private func drawPorts(context: CGContext) {
        for geometry in portGeometries {
            let isHovered = geometry.portId == hoveredPortId

            // Port circle
            let portColor = NSColor(
                red: geometry.dataType.colorComponents.red,
                green: geometry.dataType.colorComponents.green,
                blue: geometry.dataType.colorComponents.blue,
                alpha: 1.0
            )

            let radius = isHovered ? Self.portRadius + 2 : Self.portRadius
            let portRect = NSRect(
                x: geometry.center.x - radius,
                y: geometry.center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            // Fill
            context.setFillColor(portColor.cgColor)
            context.fillEllipse(in: portRect)

            // Border
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(isHovered ? 2 : 1.5)
            context.strokeEllipse(in: portRect)

            // Draw port label
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]

            let port = node.port(withId: geometry.portId)
            let labelText = port?.name ?? geometry.portId
            let labelSize = (labelText as NSString).size(withAttributes: labelAttributes)

            let labelX: CGFloat
            if geometry.direction == .input {
                labelX = geometry.center.x + radius + 4
            } else {
                labelX = geometry.center.x - radius - labelSize.width - 4
            }

            let labelY = geometry.center.y - labelSize.height / 2

            (labelText as NSString).draw(
                at: CGPoint(x: labelX, y: labelY),
                withAttributes: labelAttributes
            )
        }
    }

    private func drawSelectionBorder(context: CGContext) {
        let rect = bounds.insetBy(dx: Self.portRadius - 2, dy: -2)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: Self.cornerRadius + 2,
            cornerHeight: Self.cornerRadius + 2,
            transform: nil
        )

        context.addPath(path)
        context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.strokePath()
    }

    private func colorForCategory(_ category: NodeCategory) -> NSColor {
        switch category {
        case .input:
            return NSColor.systemBlue
        case .preprocessing:
            return NSColor.systemOrange
        case .analysis:
            return NSColor.systemPurple
        case .output:
            return NSColor.systemGreen
        }
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if clicking on a port
        if let portId = portAtPoint(point) {
            // Let the canvas handle port clicks for connection drawing
            super.mouseDown(with: event)
            return
        }

        // Start dragging
        isDragging = true
        dragStartPoint = event.locationInWindow
        dragStartPosition = frame.origin

        delegate?.nodeViewDidSelect(self)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging,
              let startPoint = dragStartPoint,
              let startPosition = dragStartPosition else {
            super.mouseDragged(with: event)
            return
        }

        let currentPoint = event.locationInWindow
        let delta = CGPoint(
            x: currentPoint.x - startPoint.x,
            y: currentPoint.y - startPoint.y
        )

        let newPosition = CGPoint(
            x: startPosition.x + delta.x,
            y: startPosition.y + delta.y
        )

        frame.origin = newPosition
        delegate?.nodeViewDidMove(self, to: newPosition)
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
        dragStartPoint = nil
        dragStartPosition = nil
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHoveredPortId = portAtPoint(point)

        if newHoveredPortId != hoveredPortId {
            hoveredPortId = newHoveredPortId
            setNeedsDisplay(bounds)

            // Update cursor
            if hoveredPortId != nil {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredPortId != nil {
            hoveredPortId = nil
            setNeedsDisplay(bounds)
            NSCursor.arrow.set()
        }
    }

    public override func cursorUpdate(with event: NSEvent) {
        if hoveredPortId != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Update

    /// Updates the view with a new node.
    public func update(with node: WorkflowNode) {
        self.node = node
        calculatePortGeometries()
        invalidateIntrinsicContentSize()
        setNeedsDisplay(bounds)
        setupAccessibility()
    }
}
