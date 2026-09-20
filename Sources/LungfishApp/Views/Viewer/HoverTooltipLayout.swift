// HoverTooltipLayout.swift - Screen-space placement for sequence-viewer hover details
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

enum HoverTooltipLayout {
    private static let outerMargin: CGFloat = 8
    private static let pointerOffset: CGFloat = 16
    private static let preferredMinimumWidth: CGFloat = 240
    private static let maximumReadableWidth: CGFloat = 520
    private static let maximumHeightFraction: CGFloat = 0.7
    private static let transitExpansion: CGFloat = 4
    private static let transitRadius: CGFloat = 12

    static func panelFrame(contentSize: NSSize, anchor: NSPoint, available: NSRect) -> NSRect {
        guard available.width > 0, available.height > 0,
              available.width.isFinite, available.height.isFinite,
              anchor.x.isFinite, anchor.y.isFinite else {
            return .zero
        }

        let inset = available.insetBy(dx: outerMargin, dy: outerMargin)
        let bounds = inset.width > 0 && inset.height > 0 ? inset : available
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let preferredMinimum = min(preferredMinimumWidth, bounds.width)
        let maximumWidth = min(maximumReadableWidth, bounds.width)
        let width = min(max(contentSize.width, preferredMinimum), maximumWidth)
        let maximumHeight = min(bounds.height, max(1, bounds.height * maximumHeightFraction))
        let height = min(max(contentSize.height, 1), maximumHeight)

        guard width > 0, height > 0, width.isFinite, height.isFinite else { return .zero }

        var x = anchor.x + pointerOffset
        if x + width > bounds.maxX {
            x = anchor.x - pointerOffset - width
        }

        var y = anchor.y - pointerOffset - height
        if y < bounds.minY {
            y = anchor.y + pointerOffset
        }

        x = min(max(x, bounds.minX), bounds.maxX - width)
        y = min(max(y, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func containsTransitPoint(_ point: NSPoint, anchor: NSPoint, panel: NSRect) -> Bool {
        guard !panel.isEmpty else { return false }
        if panel.insetBy(dx: -transitExpansion, dy: -transitExpansion).contains(point) {
            return true
        }

        let nearest = NSPoint(
            x: min(max(anchor.x, panel.minX), panel.maxX),
            y: min(max(anchor.y, panel.minY), panel.maxY)
        )
        return distance(point, toSegmentFrom: anchor, to: nearest) <= transitRadius
    }

    private static func distance(_ point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
        let t = min(max(projection, 0), 1)
        let projected = NSPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }
}
