// HoverTooltipView.swift - Fast-appearing custom tooltip overlay
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// A lightweight floating tooltip that appears much faster than the system tooltip.
///
/// Positioned near the cursor as a child view of the viewer.
/// Uses a visual effect background with rounded corners.
@MainActor
final class HoverTooltipView: NSView {

    // MARK: - Constants

    /// Delay before showing the tooltip. Much faster than AppKit's ~800ms.
    private static var showDelay: TimeInterval { AppSettings.shared.tooltipDelay }

    /// Maximum width before text wraps.
    private static let maxWidth: CGFloat = 320

    /// Padding around the text content.
    private static let padding: CGFloat = 8

    // MARK: - Properties

    private let backgroundView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.blendingMode = .withinWindow
        v.material = .toolTip
        v.state = .active
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        v.layer?.borderWidth = 0.5
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let textField: NSTextField = {
        let tf = NSTextField(wrappingLabelWithString: "")
        tf.font = .systemFont(ofSize: 11)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 0
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    private var showTimer: Timer?

    /// The text currently displayed.
    private(set) var currentText: String = ""

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.2).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 1

        addSubview(backgroundView)
        backgroundView.addSubview(textField)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            textField.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: Self.padding),
            textField.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -Self.padding),
            textField.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: Self.padding - 2),
            textField.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -(Self.padding - 2)),
        ])

        isHidden = true
        alphaValue = 0
    }

    // MARK: - Public API

    /// Shows the tooltip near the given point with the specified text.
    /// If the text matches what's already shown, just repositions.
    func show(text: String, near point: NSPoint, in parentView: NSView) {
        if text == currentText && !isHidden {
            // Same content — just reposition
            repositionNear(point, in: parentView)
            return
        }

        currentText = text
        textField.stringValue = text

        // Calculate required size
        let constrainedWidth = Self.maxWidth - 2 * Self.padding
        let textSize = textField.sizeThatFits(NSSize(width: constrainedWidth, height: 10_000))
        let tooltipWidth = min(Self.maxWidth, textSize.width + 2 * Self.padding + 4)
        let tooltipHeight = textSize.height + 2 * (Self.padding - 2) + 2

        frame.size = NSSize(width: tooltipWidth, height: tooltipHeight)
        repositionNear(point, in: parentView)

        // Show with brief delay (cancel any pending show)
        showTimer?.invalidate()
        if isHidden {
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
                guard let self, !self.currentText.isEmpty else { return }
                self.isHidden = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.1
                    ctx.allowsImplicitAnimation = true
                    self.alphaValue = 1
                }
            }
        }
    }

    /// Hides the tooltip immediately.
    func hide() {
        showTimer?.invalidate()
        showTimer = nil
        currentText = ""

        guard !isHidden else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            ctx.allowsImplicitAnimation = true
            alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }

    // MARK: - Private

    private func repositionNear(_ point: NSPoint, in parentView: NSView) {
        let offset: CGFloat = 16  // cursor offset
        var x = point.x + offset
        var y = point.y + offset

        // Keep within parent bounds
        let parentBounds = parentView.bounds
        if x + frame.width > parentBounds.maxX - 4 {
            x = point.x - frame.width - 4
        }
        if y + frame.height > parentBounds.maxY - 4 {
            y = point.y - frame.height - 4
        }
        x = max(4, x)
        y = max(4, y)

        frame.origin = NSPoint(x: x, y: y)
    }

    /// Prevents the tooltip from intercepting mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
