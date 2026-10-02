// TaxaCollectionsDividerView.swift - Drag-to-resize handle at the top of the taxa collections drawer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - TaxaCollectionsDividerView

/// Drag-to-resize handle at the top of the taxa collections drawer.
///
/// Follows the identical divider pattern used by ``DrawerDividerView`` in
/// the annotation drawer and ``FASTQDrawerDividerView`` in the FASTQ drawer.
/// Three subtle horizontal grip lines signal to the user that the divider
/// is draggable.
@MainActor
final class TaxaCollectionsDividerView: NSView {

    /// Called during mouse drag with the vertical delta (positive = dragging up = taller drawer).
    var onDrag: ((CGFloat) -> Void)?

    /// Called when the drag gesture ends.
    var onDragEnd: (() -> Void)?

    private var dragStartY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 1px separator line at the bottom of the divider
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        // Three subtle horizontal grip indicator lines
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 8, y: cy + offset, width: 16, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY  // screen Y increases upward; drag up = positive = taller
        dragStartY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
