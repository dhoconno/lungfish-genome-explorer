// DrawerDividerView.swift - Accessible drag handle that resizes a bottom drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

// MARK: - DrawerDividerView

/// Drag handle at the top of the annotation drawer for resizing.
final class DrawerDividerView: NSView {
    weak var drawerDelegate: AnnotationTableDrawerDelegate?
    var dragStartY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Annotation table drawer resize handle")
        setAccessibilityIdentifier("annotation-table-drawer-divider")
        setAccessibilityHelp("Drag vertically, or press the Up and Down Arrow keys, to resize the annotation table drawer.")
    }

    /// Height change for one keyboard or VoiceOver step.
    static let keyboardStep: CGFloat = 40

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// Up Arrow makes the drawer taller and Down Arrow shorter, one step at a time.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: resize(by: Self.keyboardStep)
        case .downArrow?: resize(by: -Self.keyboardStep)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        resize(by: Self.keyboardStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        resize(by: -Self.keyboardStep)
        return true
    }

    override func accessibilityValue() -> Any? {
        guard let drawer = superview as? AnnotationTableDrawerView else { return nil }
        return "\(Int(drawer.frame.height.rounded())) points tall"
    }

    override func drawFocusRingMask() { NSBezierPath.fill(bounds) }
    override var focusRingMaskBounds: NSRect { bounds }

    /// Resizes through the same path a mouse drag takes, then saves the height.
    func resize(by delta: CGFloat) {
        guard let drawer = superview as? AnnotationTableDrawerView else { return }
        drawer.delegate?.annotationDrawerDidDragDivider(drawer, deltaY: delta)
        drawer.delegate?.annotationDrawerDidFinishDraggingDivider(drawer)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        // Subtle grip indicator
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 10, y: cy + offset, width: 20, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        dragStartY = currentY
        if let drawer = superview as? AnnotationTableDrawerView {
            drawer.delegate?.annotationDrawerDidDragDivider(drawer, deltaY: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drawer = superview as? AnnotationTableDrawerView {
            drawer.delegate?.annotationDrawerDidFinishDraggingDivider(drawer)
        }
    }
}

