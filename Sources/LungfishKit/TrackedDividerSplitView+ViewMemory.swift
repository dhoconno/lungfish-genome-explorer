// TrackedDividerSplitView+ViewMemory.swift - What a split view remembers of its divider positions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The divider positions of one split, as fractions of the split's length along its axis.
///
/// A fraction restores in a window of another size, where a point count would put a divider
/// outside its pane. The orientation travels with the fractions, since a layout preference can
/// turn a side by side split into a stacked one.
public struct SplitPositionMemory: Codable, Sendable, Equatable {
    public var isVertical: Bool
    /// One fraction in `0...1` for each divider, in divider order.
    public var fractions: [Double]

    public init(isVertical: Bool, fractions: [Double]) {
        self.isVertical = isVertical
        self.fractions = fractions
    }
}

extension TrackedDividerSplitView {
    /// The divider positions as fractions, or nil while the split has fewer than two panes or no size yet.
    public func captureViewMemory() -> SplitPositionMemory? {
        let panes = arrangedSubviews
        let extent = isVertical ? bounds.width : bounds.height
        guard panes.count >= 2, extent > 0 else { return nil }
        let fractions = panes.dropLast().map { pane -> Double in
            let edge = isVertical ? pane.frame.maxX : pane.frame.maxY
            return Double(edge / extent)
        }
        return SplitPositionMemory(isVertical: isVertical, fractions: fractions)
    }

    /// Puts the dividers where the person left them, through `setPosition`, so the split tracks
    /// each requested position as it does for any other request.
    ///
    /// Returns false and changes nothing when the split has no size yet, when it turned the
    /// other way, when its pane count changed, or when a fraction is not a position. Call it
    /// after the first layout. AppKit and the split's delegate still clamp each position to
    /// the minimum pane sizes.
    @discardableResult
    public func applyViewMemory(_ memory: SplitPositionMemory) -> Bool {
        let dividerCount = arrangedSubviews.count - 1
        let extent = isVertical ? bounds.width : bounds.height
        guard memory.isVertical == isVertical,
              dividerCount >= 1,
              memory.fractions.count == dividerCount,
              extent > 0,
              memory.fractions.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              zip(memory.fractions, memory.fractions.dropFirst()).allSatisfy({ $0 <= $1 })
        else {
            return false
        }
        for (index, fraction) in memory.fractions.enumerated() {
            setPosition(CGFloat(fraction) * extent, ofDividerAt: index)
        }
        return true
    }
}
