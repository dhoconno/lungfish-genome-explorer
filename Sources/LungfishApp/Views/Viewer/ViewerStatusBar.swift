// ViewerStatusBar.swift - Status bar for the sequence viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

// MARK: - ViewerStatusBar

/// Status bar showing current position and selection info.
public class ViewerStatusBar: NSView {

    public private(set) var positionLabel: NSTextField!
    public private(set) var selectionLabel: NSTextField!
    private var scaleLabel: NSTextField!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {

        positionLabel = createLabel()
        positionLabel.stringValue = "No sequence loaded"
        addSubview(positionLabel)

        selectionLabel = createLabel()
        selectionLabel.stringValue = ""
        addSubview(selectionLabel)

        scaleLabel = createLabel()
        scaleLabel.stringValue = ""
        scaleLabel.alignment = .right
        addSubview(scaleLabel)

        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),

            selectionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scaleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scaleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            scaleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        // Accessibility
        positionLabel.setAccessibilityIdentifier("position-label")
        selectionLabel.setAccessibilityIdentifier("selection-label")
        scaleLabel.setAccessibilityIdentifier("scale-label")
    }

    private func createLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        // Top border
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: 0.5))
        context.strokePath()
    }

    public func update(position: String?, selection: String?, scale: Double) {
        positionLabel.stringValue = position ?? "No sequence loaded"
        selectionLabel.stringValue = selection ?? ""
        scaleLabel.stringValue = String(format: "%.1f bp/px", scale)
    }
}
