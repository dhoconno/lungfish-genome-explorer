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
    private var labelStack: NSStackView!

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
        positionLabel.alignment = .left

        selectionLabel = createLabel()
        selectionLabel.stringValue = ""
        selectionLabel.alignment = .center

        scaleLabel = createLabel()
        scaleLabel.stringValue = ""
        scaleLabel.alignment = .right
        labelStack = NSStackView(views: [positionLabel, selectionLabel, scaleLabel])
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.orientation = .horizontal
        labelStack.alignment = .centerY
        labelStack.distribution = .fillEqually
        labelStack.spacing = 12
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labelStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        // VoiceOver reads the value, so it must track the text on every update
        // rather than the label's value from an earlier layout pass.
        positionLabel.setAccessibilityValue(positionLabel.stringValue)
        selectionLabel.setAccessibilityValue(selectionLabel.stringValue)
        scaleLabel.setAccessibilityValue(scaleLabel.stringValue)
    }
}
