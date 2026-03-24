// TaxonomySunburstView.swift - CoreGraphics sunburst chart for taxonomy visualization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomySunburstView

/// A CoreGraphics-rendered sunburst chart that visualizes taxonomic classification results.
///
/// The sunburst displays a `TaxonTree` as concentric rings, where each ring
/// represents a taxonomic rank (Domain -> Species) and each arc segment's
/// angular span is proportional to its clade read count.
///
/// ## Features
///
/// - Interactive: click to select, double-click to zoom, right-click for context menu
/// - Mouse tracking with hover highlight and tooltip
/// - Phylum-based coloring with depth tinting
/// - Center label showing zoom root name and read count
/// - Dark mode support via dynamic colors
/// - Keyboard shortcuts: Escape (zoom out), Cmd+0 (zoom to root)
///
/// ## Right-Click Behavior
///
/// Right-click is consolidated into two distinct paths:
/// - **On a segment**: Fires ``onNodeRightClicked`` with the node and window point,
///   so the hosting controller can show a taxon-specific context menu.
/// - **On empty space**: Fires ``onEmptySpaceRightClicked`` with the window point,
///   so the hosting controller can show a chart-level context menu (e.g., Copy Chart as PNG).
///
/// The `menu(for:)` override is intentionally removed to avoid conflicts between
/// AppKit's automatic right-click menu and the explicit `rightMouseDown` handler.
///
/// ## Usage
///
/// ```swift
/// let sunburst = TaxonomySunburstView()
/// sunburst.tree = parsedTaxonTree
/// sunburst.onNodeSelected = { node in
///     print("Selected: \(node.name)")
/// }
/// ```
@MainActor
public class TaxonomySunburstView: NSView {

    // MARK: - Data Properties

    /// The taxonomy tree to render.
    ///
    /// Setting this property triggers a full relayout and redraw.
    public var tree: TaxonTree? {
        didSet {
            invalidateSegmentCache()
            needsDisplay = true
        }
    }

    /// The current zoom center node (`nil` = root).
    ///
    /// When set, only the subtree rooted at this node is shown. The center
    /// circle displays this node's name and read count.
    public var centerNode: TaxonNode? {
        didSet {
            invalidateSegmentCache()
            needsDisplay = true
        }
    }

    // MARK: - Selection State

    /// The currently selected node (highlighted with a thick border).
    public var selectedNode: TaxonNode? {
        didSet { needsDisplay = true }
    }

    /// The currently hovered node (highlighted with an accent border).
    public var hoveredNode: TaxonNode? {
        didSet {
            if hoveredNode !== oldValue {
                needsDisplay = true
                updateTooltip()
            }
        }
    }

    // MARK: - Callbacks

    /// Called when the user single-clicks a segment.
    public var onNodeSelected: ((TaxonNode) -> Void)?

    /// Called when the user double-clicks a segment (zoom in).
    public var onNodeDoubleClicked: ((TaxonNode) -> Void)?

    /// Called when the user right-clicks a segment.
    public var onNodeRightClicked: ((TaxonNode, NSPoint) -> Void)?

    /// Called when the user right-clicks empty space (no segment hit).
    ///
    /// The parameter is the click location in window coordinates, suitable
    /// for positioning a context menu via `NSMenu.popUp(positioning:at:in:)`.
    public var onEmptySpaceRightClicked: ((NSPoint) -> Void)?

    /// Called when the zoom level changes via keyboard or mouse interaction.
    ///
    /// The parameter is the new center node (`nil` = root).
    public var onZoomChanged: ((TaxonNode?) -> Void)?

    // MARK: - Configuration

    /// Maximum number of concentric rings to display.
    public var maxRings: Int = 8 {
        didSet {
            invalidateSegmentCache()
            needsDisplay = true
        }
    }

    /// Minimum clade fraction for a segment to be shown individually.
    /// Segments below this threshold are aggregated into "Other".
    public var minFractionToShow: Double = 0.001 {
        didSet {
            invalidateSegmentCache()
            needsDisplay = true
        }
    }

    // MARK: - Filter State

    /// Set of taxId values currently passing the table search filter.
    ///
    /// When non-nil, segments whose taxId is NOT in this set are drawn
    /// with reduced opacity (dimmed) so matched taxa stand out visually.
    /// When `nil`, all segments are drawn at full opacity (no filter active).
    public var filteredNodeIds: Set<Int>? {
        didSet { needsDisplay = true }
    }

    // MARK: - Cached Geometry

    /// Cached segment geometries, recomputed on tree/bounds changes.
    private var cachedSegments: [SunburstSegment] = []

    /// The bounds size used to compute the cached segments.
    private var cachedBoundsSize: CGSize = .zero

    /// The zoom root used to compute the cached segments.
    private weak var cachedZoomRoot: TaxonNode?

    /// Tooltip popover window.
    private var tooltipView: TaxonomyTooltipView?
    private var tooltipWindow: NSWindow?

    /// Tracking area for mouse move events.
    private var trackingArea: NSTrackingArea?

    // MARK: - Initialization

    public override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        updateTrackingArea()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Taxonomy Sunburst Chart")
    }

    // MARK: - View Configuration

    public override var isFlipped: Bool { true }

    public override var acceptsFirstResponder: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidateSegmentCache()
        needsDisplay = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        // Invalidate if bounds changed
        if cachedBoundsSize != bounds.size {
            invalidateSegmentCache()
        }
    }

    // MARK: - Segment Cache

    private func invalidateSegmentCache() {
        cachedSegments = []
        cachedBoundsSize = .zero
        cachedZoomRoot = nil
    }

    private func ensureSegmentCache() {
        guard let tree else {
            cachedSegments = []
            return
        }
        let currentZoomRoot = centerNode
        if cachedBoundsSize == bounds.size, cachedZoomRoot === currentZoomRoot {
            return  // cache is valid
        }

        let layout = SunburstLayout(
            tree: tree,
            zoomRoot: currentZoomRoot,
            bounds: bounds,
            maxRings: maxRings,
            minFractionToShow: minFractionToShow
        )
        cachedSegments = layout.computeSegments()
        cachedBoundsSize = bounds.size
        cachedZoomRoot = currentZoomRoot
    }

    /// Returns the current layout used for geometry calculations.
    private var currentLayout: SunburstLayout? {
        guard let tree else { return nil }
        return SunburstLayout(
            tree: tree,
            zoomRoot: centerNode,
            bounds: bounds,
            maxRings: maxRings,
            minFractionToShow: minFractionToShow
        )
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Transparent background -- parent view's background shows through.
        // Use controlBackgroundColor which adapts to light/dark mode automatically.
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        guard let tree else {
            drawEmptyState(ctx)
            return
        }

        guard tree.root.readsClade > 0 else {
            drawEmptyState(ctx)
            return
        }

        ensureSegmentCache()

        guard let layout = currentLayout else { return }

        // Draw segments
        for segment in cachedSegments {
            drawSegment(segment, layout: layout, ctx: ctx)
        }

        // Draw center circle
        drawCenterCircle(layout: layout, ctx: ctx)
    }

    /// Draws a single arc segment.
    ///
    /// When ``filteredNodeIds`` is active, segments whose taxId is not in the
    /// filter set are drawn with reduced saturation and opacity so that matching
    /// taxa visually stand out.
    private func drawSegment(_ segment: SunburstSegment, layout: SunburstLayout, ctx: CGContext) {
        let path = segment.bezierPath(center: layout.center)

        // Determine whether this segment is dimmed by the active filter.
        let isDimmed: Bool = {
            guard let filtered = filteredNodeIds else { return false }
            return !filtered.contains(segment.node.taxId)
        }()

        // Fill
        var fillColor = segment.color
        if isDimmed {
            fillColor = desaturatedColor(fillColor, saturationFactor: 0.25, alphaFactor: 0.25)
        } else if segment.node === hoveredNode, !segment.isOther {
            // Brighten hovered segment by 10%
            fillColor = brightenedColor(fillColor, by: 0.10)
        }
        fillColor.setFill()
        path.fill()

        // Stroke
        let isSelected = !segment.isOther && segment.node === selectedNode
        let isHovered = !segment.isOther && segment.node === hoveredNode

        if isDimmed {
            NSColor.separatorColor.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if isSelected {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 3.0
            path.stroke()
        } else if isHovered {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.0
            path.stroke()
        } else {
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        // Label (only for segments wide enough and not dimmed)
        if !segment.isOther, !isDimmed {
            drawSegmentLabel(segment, layout: layout, ctx: ctx)
        }
    }

    /// Draws a label inside a segment when there is enough space.
    private func drawSegmentLabel(_ segment: SunburstSegment, layout: SunburstLayout, ctx: CGContext) {
        let arcLength = segment.arcLengthAtMid
        let thickness = segment.ringThickness

        // Only draw label if there's enough space
        guard arcLength > 40, thickness > 14 else { return }

        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let textColor = PhylumPalette.contrastingTextColor(for: segment.color)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        let name = segment.node.name
        let attrStr = NSAttributedString(string: name, attributes: attrs)
        let textSize = attrStr.size()

        // Truncate if needed
        let maxWidth = min(arcLength - 4, thickness * 2)
        let displayStr: NSAttributedString
        if textSize.width > maxWidth {
            let truncated = truncateToFit(name, maxWidth: maxWidth, font: font)
            displayStr = NSAttributedString(string: truncated, attributes: attrs)
        } else {
            displayStr = attrStr
        }

        let displaySize = displayStr.size()

        // Position at mid-radius, mid-angle
        let midR = segment.midRadius
        let midA = segment.midAngle

        // Convert polar to Cartesian (flipped coords)
        let x = layout.center.x + midR * sin(midA)
        let y = layout.center.y - midR * cos(midA)

        // Rotate label to follow arc tangent
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)

        // Rotation: tangent to the arc at midAngle
        // In our coordinate system, tangent direction at angle A is (cos(A), sin(A))
        var rotation = midA

        // Flip text if it would be upside down (bottom half of chart)
        if rotation > .pi / 2 && rotation < 3 * .pi / 2 {
            rotation += .pi
        }

        ctx.rotate(by: -rotation)
        displayStr.draw(at: CGPoint(
            x: -displaySize.width / 2,
            y: -displaySize.height / 2
        ))
        ctx.restoreGState()
    }

    /// Truncates a string to fit within a maximum width with ellipsis.
    private func truncateToFit(_ string: String, maxWidth: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var s = string
        while s.count > 1 {
            let candidate = s + "\u{2026}"  // ellipsis
            let size = (candidate as NSString).size(withAttributes: attrs)
            if size.width <= maxWidth {
                return candidate
            }
            s = String(s.dropLast())
        }
        return "\u{2026}"
    }

    /// Draws the center circle with the zoom root's name and stats.
    private func drawCenterCircle(layout: SunburstLayout, ctx: CGContext) {
        let center = layout.center
        let radius = layout.centerRadius
        guard radius > 5 else { return }

        // Circle background -- uses system color for dark mode compatibility
        let circlePath = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        NSColor.controlBackgroundColor.setFill()
        circlePath.fill()
        NSColor.separatorColor.setStroke()
        circlePath.lineWidth = 1.0
        circlePath.stroke()

        // Center label
        let root = layout.effectiveRoot
        let name = centerNode != nil ? root.name : "All Taxa"
        let count = root.readsClade
        let percentage: String
        if let tree {
            let pct = tree.totalReads > 0
                ? Double(count) / Double(tree.totalReads) * 100
                : 0
            percentage = String(format: "(%.1f%%)", pct)
        } else {
            percentage = ""
        }

        // Name
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(13, radius / 3), weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let nameStr = NSAttributedString(string: name, attributes: nameAttrs)
        let nameSize = nameStr.size()

        // Count
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: min(11, radius / 4), weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let countStr = NSAttributedString(
            string: formatCount(count),
            attributes: countAttrs
        )
        let countSize = countStr.size()

        // Percentage
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(10, radius / 5)),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let pctStr = NSAttributedString(string: percentage, attributes: pctAttrs)
        let pctSize = pctStr.size()

        // Layout vertically centered
        let totalHeight = nameSize.height + countSize.height + pctSize.height + 4
        var y = center.y - totalHeight / 2

        nameStr.draw(at: CGPoint(x: center.x - nameSize.width / 2, y: y))
        y += nameSize.height + 2

        countStr.draw(at: CGPoint(x: center.x - countSize.width / 2, y: y))
        y += countSize.height + 2

        pctStr.draw(at: CGPoint(x: center.x - pctSize.width / 2, y: y))
    }

    /// Draws the empty state message when no tree is available.
    private func drawEmptyState(_ ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: "No classification data", attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }

    /// Brightens a color by the given factor.
    private func brightenedColor(_ color: NSColor, by factor: CGFloat) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(1.0, b + factor),
            alpha: a
        )
    }

    /// Returns a desaturated and faded variant of a color for dimmed segments.
    ///
    /// - Parameters:
    ///   - color: The original segment color.
    ///   - saturationFactor: Multiplier for saturation (0 = fully grey, 1 = unchanged).
    ///   - alphaFactor: Multiplier for alpha (0 = invisible, 1 = unchanged).
    /// - Returns: The desaturated color.
    private func desaturatedColor(
        _ color: NSColor,
        saturationFactor: CGFloat,
        alphaFactor: CGFloat
    ) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s * saturationFactor,
            brightness: b,
            alpha: a * alphaFactor
        )
    }

    /// Formats a count with K/M suffixes.
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    // MARK: - Mouse Interaction

    public override func mouseDown(with event: NSEvent) {
        // Take first responder for keyboard shortcuts
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)

        guard let layout = currentLayout else { return }
        ensureSegmentCache()

        if event.clickCount == 2 {
            // Double-click: zoom
            if layout.isInCenter(point: point) {
                // Zoom out
                if let current = centerNode {
                    let newCenter = current.parent
                    centerNode = newCenter
                    onZoomChanged?(newCenter)
                    onNodeDoubleClicked?(current)
                }
            } else if let segment = layout.hitTest(point: point, segments: cachedSegments),
                      !segment.isOther {
                centerNode = segment.node
                onZoomChanged?(segment.node)
                onNodeDoubleClicked?(segment.node)
            }
            return
        }

        // Single click
        if layout.isInCenter(point: point) {
            // Click center: zoom out one level
            if let current = centerNode {
                let newCenter = current.parent
                centerNode = newCenter
                onZoomChanged?(newCenter)
            }
            selectedNode = nil
            onNodeSelected?(layout.effectiveRoot)
        } else if let segment = layout.hitTest(point: point, segments: cachedSegments),
                  !segment.isOther {
            selectedNode = segment.node
            onNodeSelected?(segment.node)
        } else {
            // Click empty space: deselect
            selectedNode = nil
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard let layout = currentLayout else {
            hoveredNode = nil
            return
        }
        ensureSegmentCache()

        if let segment = layout.hitTest(point: point, segments: cachedSegments),
           !segment.isOther {
            hoveredNode = segment.node
        } else {
            hoveredNode = nil
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredNode = nil
        hideTooltip()
    }

    /// Handles right-click events with consolidated behavior.
    ///
    /// - **On a segment**: Fires ``onNodeRightClicked`` so the hosting controller
    ///   can show a taxon-specific context menu (extract, copy, zoom).
    /// - **On empty space**: Fires ``onEmptySpaceRightClicked`` so the hosting
    ///   controller can show a chart-level context menu (Copy Chart as PNG).
    ///
    /// This replaces the previous dual-path approach where `rightMouseDown` handled
    /// segments and `menu(for:)` handled empty space. The two paths conflicted
    /// because AppKit calls `menu(for:)` after `rightMouseDown`, causing both
    /// menus to appear.
    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let windowPoint = event.locationInWindow

        guard let layout = currentLayout else {
            onEmptySpaceRightClicked?(windowPoint)
            return
        }
        ensureSegmentCache()

        if let segment = layout.hitTest(point: point, segments: cachedSegments),
           !segment.isOther {
            onNodeRightClicked?(segment.node, windowPoint)
        } else {
            onEmptySpaceRightClicked?(windowPoint)
        }
    }

    // MARK: - Keyboard Interaction

    /// Handles keyboard shortcuts for zoom navigation.
    ///
    /// - **Escape**: Zoom out one level (or deselect if already at root).
    /// - **Cmd+0**: Zoom to root.
    public override func keyDown(with event: NSEvent) {
        guard tree != nil else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // Escape
            if centerNode != nil {
                // Zoom out one level
                let newCenter = centerNode?.parent
                centerNode = newCenter
                onZoomChanged?(newCenter)
            } else {
                // Already at root -- deselect
                selectedNode = nil
            }

        case 29 where modifiers == .command: // Cmd+0
            zoomToRoot()

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Zoom Actions

    /// Zooms out one level toward the root.
    ///
    /// If already at root, this is a no-op.
    public func zoomOut() {
        guard let current = centerNode else { return }
        let newCenter = current.parent
        centerNode = newCenter
        onZoomChanged?(newCenter)
    }

    /// Zooms all the way to the root of the taxonomy tree.
    public func zoomToRoot() {
        guard centerNode != nil else { return }
        centerNode = nil
        onZoomChanged?(nil)
    }

    // MARK: - Copy to Clipboard

    /// Copies the sunburst chart as a 2x PNG image to the system pasteboard.
    ///
    /// This method is exposed as `@objc` so it can be invoked from an `NSMenuItem`
    /// in the empty-space context menu built by the hosting controller.
    @objc public func copyChartToPasteboard(_ sender: Any) {
        let scale: CGFloat = 2.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        bitmapRep.size = bounds.size

        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    // MARK: - Tooltip

    private func updateTooltip() {
        guard let node = hoveredNode else {
            hideTooltip()
            return
        }
        showTooltip(for: node)
    }

    private func showTooltip(for node: TaxonNode) {
        let tooltip: TaxonomyTooltipView
        if let existing = tooltipView {
            tooltip = existing
        } else {
            tooltip = TaxonomyTooltipView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
            tooltipView = tooltip
        }

        tooltip.update(with: node, totalReads: tree?.totalReads ?? 0)

        // Position tooltip near the mouse
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let tooltipSize = tooltip.preferredSize

        // Position to the right of the cursor, adjust for screen edges
        var origin = NSPoint(
            x: mouseLocation.x + 16,
            y: mouseLocation.y - tooltipSize.height / 2
        )

        if let screen = window.screen {
            let screenFrame = screen.visibleFrame
            if origin.x + tooltipSize.width > screenFrame.maxX {
                origin.x = mouseLocation.x - tooltipSize.width - 16
            }
            if origin.y < screenFrame.minY {
                origin.y = screenFrame.minY
            }
            if origin.y + tooltipSize.height > screenFrame.maxY {
                origin.y = screenFrame.maxY - tooltipSize.height
            }
        }

        if let tooltipWin = tooltipWindow {
            tooltipWin.setFrame(NSRect(origin: origin, size: tooltipSize), display: true)
        } else {
            let win = NSWindow(
                contentRect: NSRect(origin: origin, size: tooltipSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = NSColor.clear
            win.level = NSWindow.Level.floating
            win.contentView = tooltip
            win.ignoresMouseEvents = true
            window.addChildWindow(win, ordered: .above)
            tooltipWindow = win
        }

        tooltipWindow?.orderFront(nil)
    }

    private func hideTooltip() {
        if let win = tooltipWindow {
            win.parent?.removeChildWindow(win)
            win.orderOut(nil)
        }
        tooltipWindow = nil
        tooltipView = nil
    }
}
