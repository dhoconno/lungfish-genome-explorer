// RNASeqEmbeddingPlotView.swift - The plot of an embedding, a raster shown as a layer's contents (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view shows the last raster as `CALayer.contents` (5.5 V1). While a pinch or a scroll runs, the layer's transform
// scales and moves the bitmap it holds, and when the gesture ends the view hands the new window to its controller,
// which draws again off the main actor. Hover asks the raster's grid for the point on top. VoiceOver reads the plot as a
// group whose children are the legend's values, one each, never one for each cell (5.5 V2).

import AppKit
import QuartzCore

@MainActor
public final class RNASeqEmbeddingPlotView: NSView {
    public static let accessibilityID = "rnaseq-cell-map-plot"

    /// The raster on show, nil before the first draw ends.
    public private(set) var raster: RNASeqEmbeddingRaster?
    /// The pixels a point of the view holds when the raster was drawn.
    public private(set) var rasterScale: CGFloat = 1
    /// Called when a pinch, a scroll or a double click ends, with the window the plot should show next, nil for all cells.
    public var onWindowChange: ((RNASeqEmbeddingWindow?) -> Void)?
    /// Called with the cell under the pointer, from 0, or nil when no point is there.
    public var onHover: ((Int?) -> Void)?
    /// Called when the view's size or appearance changes, so the controller draws again.
    public var onNeedsRaster: (() -> Void)?

    private let imageLayer = CALayer()
    private var gestureScale: CGFloat = 1
    private var gestureShift = CGPoint.zero
    private var gestureAnchor = CGPoint.zero
    private var legendChildren: [NSAccessibilityElement] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.anchorPoint = .zero
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        layer?.addSublayer(imageLayer)
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The size of a raster that fills the view, in pixels, and the pixels a point holds.
    public var pixelSize: (width: Int, height: Int, scale: CGFloat) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()), scale)
    }

    /// Whether the view draws in a dark appearance, which picks the dark values of the palette.
    public var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Shows a raster that `image` made from it.
    public func show(_ raster: RNASeqEmbeddingRaster, image: CGImage?, scale: CGFloat) {
        self.raster = raster
        rasterScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(raster.width) / scale, height: CGFloat(raster.height) / scale)
        imageLayer.setAffineTransform(.identity)
        CATransaction.commit()
        gestureScale = 1
        gestureShift = .zero
    }

    /// An image of a raster's pixels, made off the main actor. The words lay out red, green, blue and alpha.
    public nonisolated static func image(of raster: RNASeqEmbeddingRaster) -> CGImage? {
        let data = raster.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The cell, from 0, of the point on top under a point of the view.
    public func cell(at point: NSPoint) -> Int? {
        guard let raster else { return nil }
        let column = Int(point.x * rasterScale), row = Int((bounds.height - point.y) * rasterScale)
        guard column >= 0, row >= 0, column < raster.width, row < raster.height else { return nil }
        return raster.cell(column: column, row: row)
    }

    /// The view point of a cell drawn at a pixel, for tests and VoiceOver.
    public func viewPoint(column: Int, row: Int) -> NSPoint {
        NSPoint(x: (CGFloat(column) + 0.5) / rasterScale, y: bounds.height - (CGFloat(row) + 0.5) / rasterScale)
    }

    // MARK: - Size and appearance

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onNeedsRaster?() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onNeedsRaster?()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onNeedsRaster?()
    }

    // MARK: - Gestures

    public override func magnify(with event: NSEvent) {
        if event.phase == .began || gestureScale == 1 && gestureShift == .zero {
            gestureAnchor = convert(event.locationInWindow, from: nil)
        }
        gestureScale = min(max(gestureScale * (1 + event.magnification), 0.05), 50)
        applyGesture()
        if event.phase == .ended || event.phase == .cancelled { finishGesture() }
    }

    public override func scrollWheel(with event: NSEvent) {
        gestureShift.x += event.scrollingDeltaX
        gestureShift.y -= event.scrollingDeltaY
        applyGesture()
        let ended = event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended
        if ended || (event.phase.isEmpty && event.momentumPhase.isEmpty) { finishGesture() }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onWindowChange?(nil) } else { super.mouseDown(with: event) }
    }

    /// Scales the bitmap about the pinch's point and moves it by the scroll, without drawing it again.
    private func applyGesture() {
        let transform = CGAffineTransform(translationX: gestureAnchor.x + gestureShift.x, y: gestureAnchor.y + gestureShift.y)
            .scaledBy(x: gestureScale, y: gestureScale)
            .translatedBy(x: -gestureAnchor.x, y: -gestureAnchor.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// The window under the view once the gesture's transform is undone, handed to the controller to draw again.
    private func finishGesture() {
        guard let raster, gestureScale != 1 || gestureShift != .zero else { return }
        func plane(_ point: CGPoint) -> (x: Float32, y: Float32) {
            let before = CGPoint(x: (point.x - gestureAnchor.x - gestureShift.x) / gestureScale + gestureAnchor.x,
                                 y: (point.y - gestureAnchor.y - gestureShift.y) / gestureScale + gestureAnchor.y)
            return raster.mapping.point(column: Float32(before.x * rasterScale), row: Float32((bounds.height - before.y) * rasterScale))
        }
        let low = plane(CGPoint(x: 0, y: 0)), high = plane(CGPoint(x: bounds.width, y: bounds.height))
        let window = RNASeqEmbeddingWindow(minX: min(low.x, high.x), minY: min(low.y, high.y), maxX: max(low.x, high.x), maxY: max(low.y, high.y))
        guard window.maxX > window.minX, window.maxY > window.minY else { return }
        onWindowChange?(window)
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        onHover?(cell(at: convert(event.locationInWindow, from: nil)))
    }

    public override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    // MARK: - VoiceOver

    /// One child for each legend value, its frame the value's legend row (UX U-A3).
    public func setLegendChildren(_ labels: [String], frames: [NSRect]) {
        legendChildren = zip(labels, frames).map { label, frame in
            let child = NSAccessibilityElement()
            child.setAccessibilityRole(.staticText)
            child.setAccessibilityLabel(label)
            child.setAccessibilityParent(self)
            child.setAccessibilityFrameInParentSpace(frame)
            return child
        }
        if legendChildren.count < labels.count {
            for label in labels.dropFirst(legendChildren.count) {
                let child = NSAccessibilityElement()
                child.setAccessibilityRole(.staticText)
                child.setAccessibilityLabel(label)
                child.setAccessibilityParent(self)
                legendChildren.append(child)
            }
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    public override func accessibilityChildren() -> [Any]? { legendChildren }
}
