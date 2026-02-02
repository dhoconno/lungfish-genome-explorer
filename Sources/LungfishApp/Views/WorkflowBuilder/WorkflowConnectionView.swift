// WorkflowConnectionView.swift - Visual representation of a workflow connection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import os.log

/// Logger for connection view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "WorkflowConnectionView")

// MARK: - WorkflowConnectionViewDelegate

/// Delegate protocol for connection view events.
@MainActor
public protocol WorkflowConnectionViewDelegate: AnyObject {
    /// Called when the connection view is selected.
    func connectionViewDidSelect(_ connectionView: WorkflowConnectionView)
}

// MARK: - WorkflowConnectionView

/// Visual representation of a connection between workflow nodes.
///
/// Displays:
/// - Bezier curve from source to target port
/// - Color coding based on data type
/// - Arrow head at target
/// - Selection highlighting
@MainActor
public class WorkflowConnectionView: NSView {

    // MARK: - Constants

    private static let lineWidth: CGFloat = 2
    private static let selectedLineWidth: CGFloat = 3
    private static let hitTestTolerance: CGFloat = 8
    private static let arrowSize: CGFloat = 8

    // MARK: - Properties

    /// The connection being displayed.
    public let connection: WorkflowConnection

    /// Reference to the source node view.
    public weak var sourceNodeView: WorkflowNodeView?

    /// Reference to the target node view.
    public weak var targetNodeView: WorkflowNodeView?

    /// Delegate for connection events.
    public weak var delegate: WorkflowConnectionViewDelegate?

    /// Whether this connection is selected.
    public var isSelected: Bool = false {
        didSet { setNeedsDisplay(bounds) }
    }

    /// The bezier path for the connection.
    private var connectionPath: CGPath?

    /// Color for the connection based on data type.
    private var connectionColor: NSColor

    // MARK: - Initialization

    /// Creates a new connection view.
    public init(
        connection: WorkflowConnection,
        sourceNodeView: WorkflowNodeView,
        targetNodeView: WorkflowNodeView
    ) {
        self.connection = connection
        self.sourceNodeView = sourceNodeView
        self.targetNodeView = targetNodeView

        // Get color from source port data type
        let dataType = sourceNodeView.node.outputPort(withId: connection.sourcePortId)?.dataType ?? .any
        self.connectionColor = NSColor(
            red: dataType.colorComponents.red,
            green: dataType.colorComponents.green,
            blue: dataType.colorComponents.blue,
            alpha: 1.0
        )

        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setupAccessibility()
        updatePath()
    }

    // MARK: - Accessibility

    private func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Connection from \(sourceNodeView?.node.label ?? "unknown") to \(targetNodeView?.node.label ?? "unknown")")
        setAccessibilityIdentifier("workflow-connection-\(connection.id)")
    }

    // MARK: - Path Calculation

    /// Updates the connection path based on current node positions.
    public func updatePath() {
        guard let sourceView = sourceNodeView,
              let targetView = targetNodeView else {
            connectionPath = nil
            return
        }

        // Get port positions in superview coordinates
        let sourcePoint = sourceView.portPosition(for: connection.sourcePortId, direction: .output)
        let targetPoint = targetView.portPosition(for: connection.targetPortId, direction: .input)

        // Calculate bounding rect with padding
        let padding: CGFloat = 50
        let minX = min(sourcePoint.x, targetPoint.x) - padding
        let minY = min(sourcePoint.y, targetPoint.y) - padding
        let maxX = max(sourcePoint.x, targetPoint.x) + padding
        let maxY = max(sourcePoint.y, targetPoint.y) + padding

        frame = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Convert points to local coordinates
        let localSource = convert(sourcePoint, from: superview)
        let localTarget = convert(targetPoint, from: superview)

        // Create bezier path with smooth curves
        let path = CGMutablePath()
        path.move(to: localSource)

        // Calculate control points for smooth S-curve
        let horizontalDistance = abs(localTarget.x - localSource.x)
        let controlOffset = max(horizontalDistance / 2, 50)

        let cp1 = CGPoint(x: localSource.x + controlOffset, y: localSource.y)
        let cp2 = CGPoint(x: localTarget.x - controlOffset, y: localTarget.y)

        path.addCurve(to: localTarget, control1: cp1, control2: cp2)

        connectionPath = path

        setNeedsDisplay(bounds)
    }

    // MARK: - Drawing

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext,
              let path = connectionPath else { return }

        // Set line style
        let lineWidth = isSelected ? Self.selectedLineWidth : Self.lineWidth
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw shadow for selected connections
        if isSelected {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: 2),
                blur: 4,
                color: connectionColor.withAlphaComponent(0.5).cgColor
            )
        }

        // Draw the path
        context.addPath(path)
        context.setStrokeColor(connectionColor.cgColor)
        context.strokePath()

        if isSelected {
            context.restoreGState()
        }

        // Draw arrow head at target
        drawArrowHead(context: context)

        // Draw selection indicator
        if isSelected {
            drawSelectionIndicator(context: context)
        }
    }

    private func drawArrowHead(context: CGContext) {
        guard let sourceView = sourceNodeView,
              let targetView = targetNodeView else { return }

        let sourcePoint = sourceView.portPosition(for: connection.sourcePortId, direction: .output)
        let targetPoint = targetView.portPosition(for: connection.targetPortId, direction: .input)

        let localTarget = convert(targetPoint, from: superview)
        let localSource = convert(sourcePoint, from: superview)

        // Calculate direction vector at target
        let horizontalDistance = abs(localTarget.x - localSource.x)
        let controlOffset = max(horizontalDistance / 2, 50)
        let cp2 = CGPoint(x: localTarget.x - controlOffset, y: localTarget.y)

        // Direction from control point to target
        let dx = localTarget.x - cp2.x
        let dy = localTarget.y - cp2.y
        let length = hypot(dx, dy)

        guard length > 0 else { return }

        let unitX = dx / length
        let unitY = dy / length

        // Arrow head points
        let arrowSize = Self.arrowSize
        let arrowAngle: CGFloat = .pi / 6 // 30 degrees

        let point1 = CGPoint(
            x: localTarget.x - arrowSize * (unitX * cos(arrowAngle) - unitY * sin(arrowAngle)),
            y: localTarget.y - arrowSize * (unitY * cos(arrowAngle) + unitX * sin(arrowAngle))
        )

        let point2 = CGPoint(
            x: localTarget.x - arrowSize * (unitX * cos(arrowAngle) + unitY * sin(arrowAngle)),
            y: localTarget.y - arrowSize * (unitY * cos(arrowAngle) - unitX * sin(arrowAngle))
        )

        // Draw arrow
        let arrowPath = CGMutablePath()
        arrowPath.move(to: localTarget)
        arrowPath.addLine(to: point1)
        arrowPath.move(to: localTarget)
        arrowPath.addLine(to: point2)

        context.addPath(arrowPath)
        context.setStrokeColor(connectionColor.cgColor)
        context.setLineWidth(isSelected ? Self.selectedLineWidth : Self.lineWidth)
        context.strokePath()
    }

    private func drawSelectionIndicator(context: CGContext) {
        // Draw a subtle glow effect
        guard let path = connectionPath else { return }

        context.saveGState()
        context.setLineWidth(8)
        context.setStrokeColor(connectionColor.withAlphaComponent(0.2).cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Hit Testing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let path = connectionPath else { return nil }

        // Convert point to local coordinates
        let localPoint = convert(point, from: superview)

        // Check if point is near the path
        let testPath = path.copy(strokingWithWidth: Self.hitTestTolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)

        if testPath.contains(localPoint) {
            return self
        }

        return nil
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        delegate?.connectionViewDidSelect(self)
    }
}

// MARK: - Animated Connection View

/// Extension for connection animation support.
extension WorkflowConnectionView {

    /// Animates the connection being drawn.
    public func animateDrawing(duration: TimeInterval = 0.3) {
        guard let layer = layer,
              let path = connectionPath else { return }

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0.0
        animation.toValue = 1.0
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path
        shapeLayer.strokeColor = connectionColor.cgColor
        shapeLayer.fillColor = nil
        shapeLayer.lineWidth = Self.lineWidth

        layer.addSublayer(shapeLayer)
        shapeLayer.add(animation, forKey: "drawAnimation")

        // Remove shape layer after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            shapeLayer.removeFromSuperlayer()
        }
    }

    /// Pulses the connection to indicate data flow.
    public func pulseDataFlow() {
        guard let layer = layer else { return }

        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 0.5
        pulseAnimation.duration = 0.3
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = 2

        layer.add(pulseAnimation, forKey: "pulseAnimation")
    }
}
