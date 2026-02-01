// CoverageTrack.swift - Signal/coverage visualization track
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Track Rendering Engineer (Role 04)
// Reference: IGV's DataTrack

import Foundation
import AppKit
import LungfishCore

/// Track for displaying coverage/signal data.
///
/// Renders continuous signal data (like from BigWig files) as:
/// - Histogram bars
/// - Line graph
/// - Heatmap
///
/// Supports automatic Y-axis scaling and customizable colors.
@MainActor
public final class CoverageTrack: Track {

    // MARK: - Track Identity

    public let id: UUID
    public var name: String
    public var height: CGFloat
    public var isVisible: Bool = true
    public var displayMode: DisplayMode = .auto
    public var isSelected: Bool = false
    public var order: Int = 0

    // MARK: - Data Source

    public var dataSource: (any TrackDataSource)?

    /// Cached coverage values for the current view
    private var cachedValues: [Float] = []
    private var cachedFrame: ReferenceFrame?

    // MARK: - Rendering Configuration

    /// How to render the coverage data
    public enum RenderMode: String, CaseIterable, Sendable {
        case histogram
        case line
        case heatmap
    }

    /// Y-axis scaling mode
    public enum YAxisScale: Sendable {
        case auto           // Scale to data range
        case fixed(min: Float, max: Float)  // Fixed range
        case autoFloor      // Auto with floor at 0
    }

    /// Current render mode
    public var renderMode: RenderMode = .histogram

    /// Y-axis scaling
    public var yAxisScale: YAxisScale = .autoFloor

    /// Primary color for rendering
    public var color: NSColor = NSColor.systemBlue

    /// Whether to show Y-axis labels
    public var showYAxis: Bool = true

    /// Y-axis label width
    public var yAxisWidth: CGFloat = 40

    /// Line width for line mode
    public var lineWidth: CGFloat = 1.5

    /// Whether to fill under the line
    public var fillUnderLine: Bool = true

    // MARK: - Data

    /// Direct data setter (for programmatic use)
    private var directData: [Float]?

    // MARK: - Initialization

    /// Creates a coverage track.
    ///
    /// - Parameters:
    ///   - name: Display name for the track
    ///   - height: Track height in points
    public init(name: String = "Coverage", height: CGFloat = 80) {
        self.id = UUID()
        self.name = name
        self.height = height
    }

    /// Sets coverage data directly.
    public func setData(_ values: [Float]) {
        self.directData = values
        invalidateCache()
    }

    private func invalidateCache() {
        cachedValues = []
        cachedFrame = nil
    }

    // MARK: - Track Protocol

    public func isReady(for frame: ReferenceFrame) -> Bool {
        if let lastFrame = cachedFrame {
            return lastFrame == frame && !cachedValues.isEmpty
        }
        return false
    }

    public func load(for frame: ReferenceFrame) async throws {
        // If we have direct data, compute bins from it
        if let data = directData {
            let binCount = frame.widthInPixels
            cachedValues = computeBins(from: data, binCount: binCount, frame: frame)
        } else {
            // Would normally load from BigWig data source
            // For now, just use empty array
            cachedValues = []
        }
        cachedFrame = frame
    }

    public func render(context: RenderContext, rect: CGRect) {
        let frame = context.frame

        // Background
        context.fill(rect, with: .textBackgroundColor)

        // Recompute if needed
        if cachedFrame != frame {
            if let data = directData {
                let binCount = frame.widthInPixels
                cachedValues = computeBins(from: data, binCount: binCount, frame: frame)
                cachedFrame = frame
            }
        }

        guard !cachedValues.isEmpty else {
            drawPlaceholder(context: context, rect: rect, message: "No coverage data")
            return
        }

        // Calculate data area (accounting for Y-axis)
        let dataRect: CGRect
        if showYAxis {
            dataRect = CGRect(
                x: rect.minX + yAxisWidth,
                y: rect.minY,
                width: rect.width - yAxisWidth,
                height: rect.height
            )
        } else {
            dataRect = rect
        }

        // Compute Y scale
        let (minVal, maxVal) = computeYRange()

        // Render based on mode
        switch renderMode {
        case .histogram:
            renderHistogram(context: context, rect: dataRect, minVal: minVal, maxVal: maxVal)
        case .line:
            renderLine(context: context, rect: dataRect, minVal: minVal, maxVal: maxVal)
        case .heatmap:
            renderHeatmap(context: context, rect: dataRect, minVal: minVal, maxVal: maxVal)
        }

        // Draw Y-axis
        if showYAxis {
            drawYAxis(context: context, rect: rect, minVal: minVal, maxVal: maxVal)
        }

        // Draw track label
        drawTrackLabel(context: context, rect: rect)
    }

    // MARK: - Rendering Methods

    private func renderHistogram(context: RenderContext, rect: CGRect, minVal: Float, maxVal: Float) {
        let graphics = context.graphics
        let range = maxVal - minVal
        guard range > 0 else { return }

        let barWidth = rect.width / CGFloat(cachedValues.count)

        graphics.setFillColor(color.cgColor)

        for (index, value) in cachedValues.enumerated() {
            let normalizedValue = (value - minVal) / range
            let barHeight = CGFloat(normalizedValue) * rect.height

            let barRect = CGRect(
                x: rect.minX + CGFloat(index) * barWidth,
                y: rect.maxY - barHeight,
                width: max(1, barWidth - 0.5),
                height: barHeight
            )

            graphics.fill(barRect)
        }
    }

    private func renderLine(context: RenderContext, rect: CGRect, minVal: Float, maxVal: Float) {
        let graphics = context.graphics
        let range = maxVal - minVal
        guard range > 0 && !cachedValues.isEmpty else { return }

        let stepWidth = rect.width / CGFloat(cachedValues.count - 1)

        // Build path
        let path = CGMutablePath()
        var isFirst = true

        for (index, value) in cachedValues.enumerated() {
            let normalizedValue = (value - minVal) / range
            let x = rect.minX + CGFloat(index) * stepWidth
            let y = rect.maxY - CGFloat(normalizedValue) * rect.height

            if isFirst {
                path.move(to: CGPoint(x: x, y: y))
                isFirst = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        // Fill under line if enabled
        if fillUnderLine {
            let fillPath = path.mutableCopy()!
            fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fillPath.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            fillPath.closeSubpath()

            graphics.setFillColor(color.withAlphaComponent(0.3).cgColor)
            graphics.addPath(fillPath)
            graphics.fillPath()
        }

        // Draw line
        graphics.setStrokeColor(color.cgColor)
        graphics.setLineWidth(lineWidth)
        graphics.addPath(path)
        graphics.strokePath()
    }

    private func renderHeatmap(context: RenderContext, rect: CGRect, minVal: Float, maxVal: Float) {
        let graphics = context.graphics
        let range = maxVal - minVal
        guard range > 0 else { return }

        let cellWidth = rect.width / CGFloat(cachedValues.count)

        for (index, value) in cachedValues.enumerated() {
            let normalizedValue = (value - minVal) / range
            let intensity = CGFloat(max(0, min(1, normalizedValue)))

            // Color gradient: white -> color
            let cellColor = NSColor(
                calibratedRed: 1.0 - intensity * (1.0 - color.redComponent),
                green: 1.0 - intensity * (1.0 - color.greenComponent),
                blue: 1.0 - intensity * (1.0 - color.blueComponent),
                alpha: 1.0
            )

            let cellRect = CGRect(
                x: rect.minX + CGFloat(index) * cellWidth,
                y: rect.minY,
                width: max(1, cellWidth),
                height: rect.height
            )

            graphics.setFillColor(cellColor.cgColor)
            graphics.fill(cellRect)
        }
    }

    private func drawYAxis(context: RenderContext, rect: CGRect, minVal: Float, maxVal: Float) {
        let graphics = context.graphics

        let axisRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: yAxisWidth - 4,
            height: rect.height
        )

        // Draw axis line
        graphics.setStrokeColor(NSColor.separatorColor.cgColor)
        graphics.setLineWidth(1)
        graphics.move(to: CGPoint(x: axisRect.maxX, y: axisRect.minY))
        graphics.addLine(to: CGPoint(x: axisRect.maxX, y: axisRect.maxY))
        graphics.strokePath()

        // Draw labels
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        // Max value
        let maxStr = formatAxisValue(maxVal)
        let maxSize = maxStr.size(withAttributes: attributes)
        maxStr.draw(at: CGPoint(x: axisRect.maxX - maxSize.width - 2, y: axisRect.minY), withAttributes: attributes)

        // Min value
        let minStr = formatAxisValue(minVal)
        let minSize = minStr.size(withAttributes: attributes)
        minStr.draw(at: CGPoint(x: axisRect.maxX - minSize.width - 2, y: axisRect.maxY - minSize.height), withAttributes: attributes)
    }

    private func drawTrackLabel(context: RenderContext, rect: CGRect) {
        let label = name
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let x = showYAxis ? rect.minX + yAxisWidth + 4 : rect.minX + 4
        label.draw(at: CGPoint(x: x, y: rect.minY + 2), withAttributes: attributes)
    }

    private func drawPlaceholder(context: RenderContext, rect: CGRect, message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = message.size(withAttributes: attributes)
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        message.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    // MARK: - Helpers

    private func computeYRange() -> (Float, Float) {
        switch yAxisScale {
        case .auto:
            let min = cachedValues.min() ?? 0
            let max = cachedValues.max() ?? 1
            return (min, max)
        case .fixed(let min, let max):
            return (min, max)
        case .autoFloor:
            let max = cachedValues.max() ?? 1
            return (0, max)
        }
    }

    private func computeBins(from data: [Float], binCount: Int, frame: ReferenceFrame) -> [Float] {
        guard binCount > 0 && !data.isEmpty else { return [] }

        let dataLength = data.count
        let startIndex = Int(max(0, frame.origin))
        let endIndex = Int(min(Double(dataLength), frame.end))

        guard startIndex < endIndex else { return [] }

        let regionLength = endIndex - startIndex
        let binSize = max(1, regionLength / binCount)

        var result: [Float] = []
        result.reserveCapacity(binCount)

        for i in 0..<binCount {
            let binStart = startIndex + i * binSize
            let binEnd = min(binStart + binSize, endIndex)

            if binStart < dataLength {
                var sum: Float = 0
                var count = 0
                for j in binStart..<min(binEnd, dataLength) {
                    sum += data[j]
                    count += 1
                }
                result.append(count > 0 ? sum / Float(count) : 0)
            } else {
                result.append(0)
            }
        }

        return result
    }

    private func formatAxisValue(_ value: Float) -> String {
        if abs(value) >= 1000 {
            return String(format: "%.1fK", value / 1000)
        } else if abs(value) >= 1 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    // MARK: - Interaction

    public func tooltipText(at position: Double, y: CGFloat) -> String? {
        guard !cachedValues.isEmpty, let frame = cachedFrame else { return nil }

        let binIndex = Int((position - frame.origin) / frame.scale)
        guard binIndex >= 0 && binIndex < cachedValues.count else { return nil }

        let value = cachedValues[binIndex]
        return String(format: "Position: %.0f\nValue: %.2f", position, value)
    }

    public func handleClick(at position: Double, y: CGFloat, modifiers: NSEvent.ModifierFlags) -> Bool {
        return false
    }

    public func contextMenu(at position: Double, y: CGFloat) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Render Mode", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        for mode in RenderMode.allCases {
            let item = NSMenuItem(title: mode.rawValue.capitalized, action: nil, keyEquivalent: "")
            item.state = mode == renderMode ? .on : .off
            menu.addItem(item)
        }

        return menu
    }
}
