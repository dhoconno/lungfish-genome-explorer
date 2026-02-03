// EnhancedCoordinateRulerView.swift - Comprehensive bp ruler with mini-map navigation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)
// Reference: IGV's RulerTrack.java, Ensembl genome browser navigation

import AppKit
import LungfishCore
import os.log

/// Logger for ruler operations
private let rulerLogger = Logger(subsystem: "com.lungfish.browser", category: "EnhancedRuler")

// MARK: - EnhancedCoordinateRulerView

/// Enhanced coordinate ruler view with mini-map navigation.
///
/// This view provides:
/// 1. Current visible range display (e.g., "45,000 - 55,000 bp")
/// 2. Total sequence length context (e.g., "of 500,000 bp total")
/// 3. Interactive mini-map showing view position within full sequence
/// 4. Zoom-to-fit button (Cmd+0) and zoom reset (Cmd+1)
/// 5. Click-to-navigate and drag-to-pan functionality
///
/// ## Layout Structure (56px height)
/// ```
/// +----------------------------------------------------------+
/// | Info Bar: range display, total length, zoom controls     | (20px)
/// +----------------------------------------------------------+
/// | Mini-map: visual position indicator, draggable           | (16px)
/// +----------------------------------------------------------+
/// | Coordinate Ruler: tick marks with base pair labels       | (20px)
/// +----------------------------------------------------------+
/// ```
@MainActor
public class EnhancedCoordinateRulerView: NSView {

    // MARK: - Constants

    /// Height of the info bar section
    private static let infoBarHeight: CGFloat = 20

    /// Height of the mini-map section
    private static let miniMapHeight: CGFloat = 16

    /// Height of the coordinate ruler section
    private static let rulerHeight: CGFloat = 20

    /// Total recommended height for this view
    public static let recommendedHeight: CGFloat = infoBarHeight + miniMapHeight + rulerHeight

    /// Minimum thumb width for mini-map (ensures clickable area)
    private static let minimumThumbWidth: CGFloat = 8

    /// Button width for zoom controls
    private static let buttonWidth: CGFloat = 40

    /// Padding between elements
    private static let horizontalPadding: CGFloat = 8

    /// Minimum pixel spacing between labels to prevent overlap
    private static let minimumLabelSpacing: CGFloat = 10

    // MARK: - Colors

    /// Mini-map track background color
    private var trackBackgroundColor: NSColor {
        NSColor.tertiarySystemFill
    }

    /// Mini-map sequence region color
    private var sequenceRegionColor: NSColor {
        NSColor.systemGray.withAlphaComponent(0.4)
    }

    /// Mini-map visible window thumb color
    private var thumbColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.7)
    }

    /// Mini-map visible window thumb border color
    private var thumbBorderColor: NSColor {
        NSColor.controlAccentColor
    }

    /// Text color for primary labels
    private var primaryTextColor: NSColor {
        NSColor.labelColor
    }

    /// Text color for secondary labels
    private var secondaryTextColor: NSColor {
        NSColor.secondaryLabelColor
    }

    /// Text color for ruler position labels
    private var rulerLabelColor: NSColor {
        NSColor.labelColor
    }

    /// Button background color (normal state)
    private var buttonBackgroundColor: NSColor {
        NSColor.quaternarySystemFill
    }

    /// Button background color (hover state)
    private var buttonHoverColor: NSColor {
        NSColor.tertiarySystemFill
    }

    // MARK: - State

    /// Reference frame for coordinate mapping
    public var referenceFrame: ReferenceFrame? {
        didSet {
            needsDisplay = true
        }
    }

    /// Delegate for navigation callbacks
    public weak var delegate: EnhancedCoordinateRulerDelegate?

    /// Currently dragging the mini-map thumb
    private var isDraggingThumb = false

    /// Drag start position in genomic coordinates
    private var dragStartPosition: Double = 0

    /// Drag start origin of the window
    private var dragStartOrigin: Double = 0

    /// Mouse is hovering over zoom-to-fit button
    private var isHoveringFitButton = false

    /// Mouse is hovering over zoom-reset button
    private var isHoveringResetButton = false

    /// Tracking area for mouse events
    private var trackingArea: NSTrackingArea?

    // MARK: - Computed Properties

    /// Rectangle for the info bar section
    private var infoBarRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.infoBarHeight)
    }

    /// Rectangle for the mini-map section
    private var miniMapRect: NSRect {
        NSRect(x: Self.horizontalPadding,
               y: Self.infoBarHeight,
               width: bounds.width - Self.horizontalPadding * 2,
               height: Self.miniMapHeight)
    }

    /// Rectangle for the coordinate ruler section
    private var rulerRect: NSRect {
        NSRect(x: 0,
               y: Self.infoBarHeight + Self.miniMapHeight,
               width: bounds.width,
               height: Self.rulerHeight)
    }

    /// Rectangle for the zoom-to-fit button
    private var fitButtonRect: NSRect {
        NSRect(x: bounds.width - Self.buttonWidth * 2 - Self.horizontalPadding * 2,
               y: 2,
               width: Self.buttonWidth,
               height: Self.infoBarHeight - 4)
    }

    /// Rectangle for the zoom-reset button
    private var resetButtonRect: NSRect {
        NSRect(x: bounds.width - Self.buttonWidth - Self.horizontalPadding,
               y: 2,
               width: Self.buttonWidth,
               height: Self.infoBarHeight - 4)
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        setupAccessibility()
    }

    private func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Coordinate ruler and navigation")
        setAccessibilityIdentifier("enhanced-coordinate-ruler")

        // Accessibility for keyboard navigation
        setAccessibilityHelp("Shows current viewing position within the sequence. Use Command+0 to fit entire sequence, Command+1 to reset zoom to 100%.")
    }

    // MARK: - View Configuration

    public override var isFlipped: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )

        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Draw sections
        drawInfoBar(context: context)
        drawMiniMap(context: context)
        drawCoordinateRuler(context: context)

        // Bottom border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: bounds.maxY - 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        context.strokePath()
    }

    // MARK: - Info Bar Drawing

    private func drawInfoBar(context: CGContext) {
        guard let frame = referenceFrame else {
            drawPlaceholderInfoBar(context: context)
            return
        }

        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        let totalLength = frame.sequenceLength

        // Format range text
        let rangeText = "\(formatNumber(visibleStart + 1)) - \(formatNumber(visibleEnd)) bp"
        let totalText = "of \(formatNumber(totalLength)) bp total"

        // Primary font for range
        let primaryFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .font: primaryFont,
            .foregroundColor: primaryTextColor
        ]

        // Secondary font for total
        let secondaryFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: secondaryFont,
            .foregroundColor: secondaryTextColor
        ]

        // Draw range text
        let rangeSize = (rangeText as NSString).size(withAttributes: primaryAttributes)
        let rangeY = (Self.infoBarHeight - rangeSize.height) / 2
        (rangeText as NSString).draw(at: CGPoint(x: Self.horizontalPadding, y: rangeY),
                                      withAttributes: primaryAttributes)

        // Draw total text
        let totalX = Self.horizontalPadding + rangeSize.width + 8
        let totalSize = (totalText as NSString).size(withAttributes: secondaryAttributes)
        let totalY = (Self.infoBarHeight - totalSize.height) / 2
        (totalText as NSString).draw(at: CGPoint(x: totalX, y: totalY),
                                      withAttributes: secondaryAttributes)

        // Draw zoom buttons
        drawZoomButtons(context: context)
    }

    private func drawPlaceholderInfoBar(context: CGContext) {
        let placeholderText = "No sequence loaded"
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: secondaryTextColor
        ]

        let size = (placeholderText as NSString).size(withAttributes: attributes)
        let y = (Self.infoBarHeight - size.height) / 2
        (placeholderText as NSString).draw(at: CGPoint(x: Self.horizontalPadding, y: y),
                                            withAttributes: attributes)
    }

    private func drawZoomButtons(context: CGContext) {
        // Zoom-to-fit button
        drawButton(
            context: context,
            rect: fitButtonRect,
            title: "Fit",
            shortcut: "0",
            isHovering: isHoveringFitButton
        )

        // Zoom reset button - show current zoom percentage
        let zoomPercent = calculateZoomPercent()
        let zoomTitle = "\(Int(zoomPercent))%"
        drawButton(
            context: context,
            rect: resetButtonRect,
            title: zoomTitle,
            shortcut: "1",
            isHovering: isHoveringResetButton
        )
    }

    private func drawButton(context: CGContext, rect: NSRect, title: String, shortcut: String, isHovering: Bool) {
        // Button background
        let bgColor = isHovering ? buttonHoverColor : buttonBackgroundColor
        context.setFillColor(bgColor.cgColor)

        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()

        // Button border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.addPath(path)
        context.strokePath()

        // Button text
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: primaryTextColor
        ]

        let textSize = (title as NSString).size(withAttributes: attributes)
        let textX = rect.midX - textSize.width / 2
        let textY = rect.midY - textSize.height / 2
        (title as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    // MARK: - Mini-Map Drawing

    private func drawMiniMap(context: CGContext) {
        let mapRect = miniMapRect

        // Track background (rounded rectangle)
        context.setFillColor(trackBackgroundColor.cgColor)
        let trackPath = CGPath(roundedRect: mapRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(trackPath)
        context.fillPath()

        guard let frame = referenceFrame, frame.sequenceLength > 0 else {
            return
        }

        // Sequence region (the full sequence)
        let sequenceRect = NSRect(
            x: mapRect.minX + 2,
            y: mapRect.minY + 2,
            width: mapRect.width - 4,
            height: mapRect.height - 4
        )
        context.setFillColor(sequenceRegionColor.cgColor)
        let seqPath = CGPath(roundedRect: sequenceRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.addPath(seqPath)
        context.fillPath()

        // Calculate thumb position and size
        let thumbRect = calculateThumbRect(in: mapRect, frame: frame)

        // Draw thumb (visible window indicator)
        context.setFillColor(thumbColor.cgColor)
        let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(thumbPath)
        context.fillPath()

        // Thumb border
        context.setStrokeColor(thumbBorderColor.cgColor)
        context.setLineWidth(1.5)
        context.addPath(thumbPath)
        context.strokePath()

        // Draw grip lines on thumb if wide enough
        if thumbRect.width > 20 {
            drawThumbGrip(context: context, in: thumbRect)
        }
    }

    private func calculateThumbRect(in mapRect: NSRect, frame: ReferenceFrame) -> NSRect {
        let totalLength = Double(frame.sequenceLength)
        let usableWidth = mapRect.width - 4

        // Calculate proportional position and width
        let startRatio = frame.start / totalLength
        let endRatio = frame.end / totalLength

        var thumbX = mapRect.minX + 2 + CGFloat(startRatio) * usableWidth
        var thumbWidth = CGFloat(endRatio - startRatio) * usableWidth

        // Enforce minimum thumb width
        if thumbWidth < Self.minimumThumbWidth {
            thumbWidth = Self.minimumThumbWidth
            // Center the minimum-width thumb on the actual position
            let centerRatio = (startRatio + endRatio) / 2
            thumbX = mapRect.minX + 2 + CGFloat(centerRatio) * usableWidth - thumbWidth / 2
        }

        // Clamp to bounds
        thumbX = max(mapRect.minX + 2, min(mapRect.maxX - 2 - thumbWidth, thumbX))

        return NSRect(
            x: thumbX,
            y: mapRect.minY + 3,
            width: thumbWidth,
            height: mapRect.height - 6
        )
    }

    private func drawThumbGrip(context: CGContext, in rect: NSRect) {
        // Draw three vertical grip lines
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)

        let centerX = rect.midX
        let lineSpacing: CGFloat = 3
        let lineHeight = rect.height - 6
        let lineY = rect.minY + 3

        for offset in [-lineSpacing, 0, lineSpacing] {
            context.move(to: CGPoint(x: centerX + offset, y: lineY))
            context.addLine(to: CGPoint(x: centerX + offset, y: lineY + lineHeight))
        }
        context.strokePath()
    }

    // MARK: - Coordinate Ruler Drawing

    private func drawCoordinateRuler(context: CGContext) {
        guard let frame = referenceFrame else {
            drawPlaceholderRuler(context: context)
            return
        }

        let visibleRange = frame.end - frame.start
        guard visibleRange > 0 else { return }

        let rulerY = Self.infoBarHeight + Self.miniMapHeight
        let pixelsPerBase = bounds.width / CGFloat(visibleRange)

        // Calculate tick interval based on zoom level
        let tickInterval = calculateTickInterval(visibleRange: visibleRange, pixelWidth: bounds.width)
        let minorTickInterval = tickInterval / 5

        // Font for position labels - use a slightly larger, bolder font for visibility
        let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: rulerLabelColor
        ]

        // Calculate label dimensions for positioning
        let sampleLabel = formatPosition(Int(tickInterval))
        let sampleSize = (sampleLabel as NSString).size(withAttributes: labelAttributes)
        let labelHeight = sampleSize.height

        // Position labels in the upper portion of the ruler, tick marks below
        // Layout: [label area ~12px] [tick marks ~8px]
        let labelY = rulerY + 1  // Small padding from top of ruler section
        let majorTickTop = rulerY + labelHeight + 2  // Ticks start below labels
        let majorTickBottom = rulerY + Self.rulerHeight  // Ticks extend to bottom
        let minorTickTop = rulerY + Self.rulerHeight - 4  // Minor ticks are shorter

        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)

        // Draw minor ticks
        context.setLineWidth(0.5)
        var minorPos = (frame.start / minorTickInterval).rounded(.up) * minorTickInterval
        while minorPos <= frame.end {
            // Skip positions that will have major ticks
            if minorPos.truncatingRemainder(dividingBy: tickInterval) != 0 {
                let x = CGFloat((minorPos - frame.start) * Double(pixelsPerBase))
                if x >= 0 && x <= bounds.width {
                    context.move(to: CGPoint(x: x, y: minorTickTop))
                    context.addLine(to: CGPoint(x: x, y: majorTickBottom))
                    context.strokePath()
                }
            }
            minorPos += minorTickInterval
        }

        // Draw major ticks and labels
        // Track the right edge of the last drawn label to prevent overlap
        var lastLabelRightEdge: CGFloat = -CGFloat.greatestFiniteMagnitude

        context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        context.setLineWidth(1)
        var majorPos = (frame.start / tickInterval).rounded(.up) * tickInterval
        while majorPos <= frame.end {
            let x = CGFloat((majorPos - frame.start) * Double(pixelsPerBase))

            if x >= 0 && x <= bounds.width {
                // Major tick mark
                context.move(to: CGPoint(x: x, y: majorTickTop))
                context.addLine(to: CGPoint(x: x, y: majorTickBottom))
                context.strokePath()

                // Position label
                let label = formatPosition(Int(majorPos))
                let labelSize = (label as NSString).size(withAttributes: labelAttributes)
                let labelX = x - labelSize.width / 2

                // Check if label fits within bounds and does not overlap with previous label
                let labelLeftEdge = labelX
                let labelRightEdge = labelX + labelSize.width

                let hasRoomOnLeft = labelLeftEdge >= Self.horizontalPadding
                let hasRoomOnRight = labelRightEdge <= bounds.width - Self.horizontalPadding
                let noOverlap = labelLeftEdge >= lastLabelRightEdge + Self.minimumLabelSpacing

                if hasRoomOnLeft && hasRoomOnRight && noOverlap {
                    (label as NSString).draw(
                        at: CGPoint(x: labelX, y: labelY),
                        withAttributes: labelAttributes
                    )
                    lastLabelRightEdge = labelRightEdge
                }
            }

            majorPos += tickInterval
        }

        // Draw a baseline at the bottom of the ruler section
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 0, y: majorTickBottom - 0.5))
        context.addLine(to: CGPoint(x: bounds.width, y: majorTickBottom - 0.5))
        context.strokePath()
    }

    private func drawPlaceholderRuler(context: CGContext) {
        let rulerY = Self.infoBarHeight + Self.miniMapHeight
        let tickInterval: CGFloat = 100

        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(0.5)

        for x in stride(from: CGFloat(0), to: bounds.width, by: tickInterval) {
            context.move(to: CGPoint(x: x, y: rulerY + Self.rulerHeight - 6))
            context.addLine(to: CGPoint(x: x, y: rulerY + Self.rulerHeight))
            context.strokePath()
        }
    }

    // MARK: - Utility Methods

    /// Calculates appropriate tick interval based on visible range
    private func calculateTickInterval(visibleRange: Double, pixelWidth: CGFloat) -> Double {
        // Target approximately one label every 80 pixels for better density
        let targetLabelCount = max(1, pixelWidth / 80)
        let rawInterval = visibleRange / Double(targetLabelCount)

        // Round to a nice number (1, 2, 5, 10, 20, 50, 100, etc.)
        let magnitude = pow(10, floor(log10(rawInterval)))
        let normalized = rawInterval / magnitude

        let niceNormalized: Double
        if normalized <= 1.5 {
            niceNormalized = 1
        } else if normalized <= 3 {
            niceNormalized = 2
        } else if normalized <= 7 {
            niceNormalized = 5
        } else {
            niceNormalized = 10
        }

        return niceNormalized * magnitude
    }

    /// Formats a number with thousands separators
    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Formats a position with appropriate units (bp, K, M)
    private func formatPosition(_ pos: Int) -> String {
        if pos >= 1_000_000 {
            let millions = Double(pos) / 1_000_000
            // Use integer format if it's a round number
            if millions == Double(Int(millions)) {
                return "\(Int(millions))M"
            }
            return String(format: "%.1fM", millions)
        } else if pos >= 1_000 {
            let thousands = Double(pos) / 1_000
            // Use integer format if it's a round number
            if thousands == Double(Int(thousands)) {
                return "\(Int(thousands))K"
            }
            return String(format: "%.1fK", thousands)
        } else {
            return "\(pos)"
        }
    }

    /// Calculates current zoom percentage (100% = entire sequence visible)
    private func calculateZoomPercent() -> Double {
        guard let frame = referenceFrame, frame.sequenceLength > 0 else {
            return 100
        }

        let visibleFraction = (frame.end - frame.start) / Double(frame.sequenceLength)
        return min(100, visibleFraction * 100)
    }

    // MARK: - Mouse Event Handling

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Check button clicks
        if fitButtonRect.contains(location) {
            handleZoomToFit()
            return
        }

        if resetButtonRect.contains(location) {
            handleZoomReset()
            return
        }

        // Check mini-map interaction
        if miniMapRect.contains(location) {
            handleMiniMapMouseDown(location: location)
            return
        }

        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb, let frame = referenceFrame else {
            super.mouseDragged(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        handleMiniMapDrag(location: location, frame: frame)
    }

    public override func mouseUp(with event: NSEvent) {
        if isDraggingThumb {
            isDraggingThumb = false
            rulerLogger.debug("Mini-map drag ended")
        }
        super.mouseUp(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        let wasHoveringFit = isHoveringFitButton
        let wasHoveringReset = isHoveringResetButton

        isHoveringFitButton = fitButtonRect.contains(location)
        isHoveringResetButton = resetButtonRect.contains(location)

        // Update cursor for mini-map thumb
        if let frame = referenceFrame {
            let thumbRect = calculateThumbRect(in: miniMapRect, frame: frame)
            if thumbRect.contains(location) {
                NSCursor.openHand.set()
            } else if miniMapRect.contains(location) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        if wasHoveringFit != isHoveringFitButton || wasHoveringReset != isHoveringResetButton {
            needsDisplay = true
        }
    }

    public override func mouseExited(with event: NSEvent) {
        isHoveringFitButton = false
        isHoveringResetButton = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    // MARK: - Mini-Map Interaction

    private func handleMiniMapMouseDown(location: NSPoint) {
        guard let frame = referenceFrame else { return }

        let thumbRect = calculateThumbRect(in: miniMapRect, frame: frame)

        if thumbRect.contains(location) {
            // Start dragging the thumb
            isDraggingThumb = true
            dragStartPosition = genomicPositionForMiniMap(x: location.x)
            dragStartOrigin = frame.start
            NSCursor.closedHand.set()
            rulerLogger.debug("Started mini-map drag at position \(self.dragStartPosition)")
        } else {
            // Click to navigate - center view on clicked position
            let targetPosition = genomicPositionForMiniMap(x: location.x)
            navigateToCenter(position: targetPosition)
            rulerLogger.debug("Mini-map click navigation to \(targetPosition)")
        }
    }

    private func handleMiniMapDrag(location: NSPoint, frame: ReferenceFrame) {
        let currentPosition = genomicPositionForMiniMap(x: location.x)
        let delta = currentPosition - dragStartPosition

        let newStart = dragStartOrigin + delta
        let windowLength = frame.end - frame.start

        // Clamp to bounds
        let clampedStart = max(0, min(Double(frame.sequenceLength) - windowLength, newStart))
        let clampedEnd = clampedStart + windowLength

        // Update frame through delegate
        delegate?.ruler(self, didRequestNavigation: clampedStart, end: clampedEnd)
    }

    /// Converts a screen X position in the mini-map to a genomic position
    private func genomicPositionForMiniMap(x: CGFloat) -> Double {
        guard let frame = referenceFrame else { return 0 }

        let mapRect = miniMapRect
        let usableWidth = mapRect.width - 4
        let relativeX = x - mapRect.minX - 2
        let ratio = max(0, min(1, Double(relativeX / usableWidth)))

        return ratio * Double(frame.sequenceLength)
    }

    /// Navigates to center the view on a specific position
    private func navigateToCenter(position: Double) {
        guard let frame = referenceFrame else { return }

        let windowLength = frame.end - frame.start
        let halfWindow = windowLength / 2

        var newStart = position - halfWindow
        var newEnd = position + halfWindow

        // Clamp to bounds
        if newStart < 0 {
            newStart = 0
            newEnd = windowLength
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - windowLength)
        }

        delegate?.ruler(self, didRequestNavigation: newStart, end: newEnd)
    }

    // MARK: - Zoom Actions

    /// Handles zoom-to-fit button press or Cmd+0 shortcut
    public func handleZoomToFit() {
        rulerLogger.info("Zoom to fit requested")
        delegate?.rulerDidRequestZoomToFit(self)
        needsDisplay = true
    }

    /// Handles zoom-reset button press or Cmd+1 shortcut
    public func handleZoomReset() {
        rulerLogger.info("Zoom reset requested")
        delegate?.rulerDidRequestZoomReset(self)
        needsDisplay = true
    }

    // MARK: - Keyboard Shortcuts

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Handle keyboard shortcuts
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "0":
                handleZoomToFit()
                return
            case "1":
                handleZoomReset()
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for EnhancedCoordinateRulerView navigation callbacks.
@MainActor
public protocol EnhancedCoordinateRulerDelegate: AnyObject {

    /// Called when the user requests navigation to a specific range.
    ///
    /// - Parameters:
    ///   - ruler: The ruler view making the request
    ///   - start: Start position in base pairs
    ///   - end: End position in base pairs
    func ruler(_ ruler: EnhancedCoordinateRulerView, didRequestNavigation start: Double, end: Double)

    /// Called when the user requests zoom-to-fit (Cmd+0).
    ///
    /// - Parameter ruler: The ruler view making the request
    func rulerDidRequestZoomToFit(_ ruler: EnhancedCoordinateRulerView)

    /// Called when the user requests zoom reset (Cmd+1).
    ///
    /// - Parameter ruler: The ruler view making the request
    func rulerDidRequestZoomReset(_ ruler: EnhancedCoordinateRulerView)
}

// MARK: - Integration Extension for ViewerViewController

/// Extension to integrate EnhancedCoordinateRulerView with ViewerViewController.
///
/// Add this conformance to ViewerViewController to handle ruler navigation events.
extension ViewerViewController: EnhancedCoordinateRulerDelegate {

    public func ruler(_ ruler: EnhancedCoordinateRulerView, didRequestNavigation start: Double, end: Double) {
        referenceFrame?.start = start
        referenceFrame?.end = end

        viewerView.setNeedsDisplay(viewerView.bounds)
        ruler.needsDisplay = true
        updateStatusBar()
    }

    public func rulerDidRequestZoomToFit(_ ruler: EnhancedCoordinateRulerView) {
        zoomToFit()
    }

    public func rulerDidRequestZoomReset(_ ruler: EnhancedCoordinateRulerView) {
        // Reset to 100% zoom (show ~10,000 bp window centered on current view)
        guard let frame = referenceFrame else { return }

        let center = (frame.start + frame.end) / 2
        let defaultWindow: Double = 10000

        var newStart = center - defaultWindow / 2
        var newEnd = center + defaultWindow / 2

        // Clamp to bounds
        if newStart < 0 {
            newStart = 0
            newEnd = min(Double(frame.sequenceLength), defaultWindow)
        }
        if newEnd > Double(frame.sequenceLength) {
            newEnd = Double(frame.sequenceLength)
            newStart = max(0, newEnd - defaultWindow)
        }

        frame.start = newStart
        frame.end = newEnd

        viewerView.setNeedsDisplay(viewerView.bounds)
        ruler.needsDisplay = true
        updateStatusBar()
    }
}

// MARK: - TrackHeaderViewDelegate Integration

/// Extension to integrate TrackHeaderView with ViewerViewController.
///
/// Handles user interactions with track header controls, including
/// toggling annotation visibility for individual sequences.
extension ViewerViewController: TrackHeaderViewDelegate {

    public func trackHeaderView(_ headerView: TrackHeaderView, didToggleAnnotationsForTrackAt index: Int) {
        guard let state = viewerView.multiSequenceState else { return }

        // Toggle annotation visibility for this sequence
        state.toggleAnnotationVisibility(at: index)

        // Update header with new stacked sequence state
        headerView.setStackedSequences(state.stackedSequences)

        // Trigger redraw
        viewerView.needsDisplay = true
        headerView.needsDisplay = true

        rulerLogger.info("TrackHeaderViewDelegate: Toggled annotations for track \(index)")

        // Post notification for other observers
        NotificationCenter.default.post(
            name: .annotationVisibilityChanged,
            object: self,
            userInfo: [
                NotificationUserInfoKey.activeSequenceIndex: index,
                NotificationUserInfoKey.annotationVisible: state.stackedSequences[index].showAnnotations
            ]
        )
    }
}
