// SampleColumnWindowBanner.swift - In-view "Show all" reveal affordance for windowed sample columns
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A small, unobtrusive banner that surfaces the display-only sample-column
/// window (``SampleColumnWindow``) to the user and offers a "Show all" button to
/// instantiate the hidden columns.
///
/// AppKit does not virtualize table columns, so cohorts larger than
/// ``SampleColumnWindow/defaultLimit`` only instantiate the leading columns. This
/// banner is the user-facing affordance that reveals columns 61+: without it the
/// hidden columns are unreachable in the GUI.
///
/// ## Usage
///
/// Host the banner in a matrix/heatmap view's header area, then keep it in sync:
///
/// ```swift
/// banner.onShowAll = { [weak self] in self?.showAllSampleColumns() }
/// // after any column rebuild:
/// banner.update(isWindowActive: isColumnWindowActive,
///               shownCount: SampleColumnWindow.defaultLimit,
///               totalCount: fullSampleCount)
/// ```
///
/// The banner hides itself whenever the window is inactive (small cohort, or the
/// user already revealed everything), so callers can drive it purely from
/// ``SampleColumnWindow/caps(_:)``.
@MainActor
public final class SampleColumnWindowBanner: NSView {

    private let messageLabel = NSTextField(labelWithString: "")
    private let showAllButton = NSButton()
    private var heightConstraint: NSLayoutConstraint?

    /// Invoked when the user clicks "Show all". Wire this to the host view's
    /// `showAllSampleColumns()` reveal method.
    public var onShowAll: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityIdentifier("sample-column-window-banner")

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .lungfishSecondaryText
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setAccessibilityIdentifier("sample-column-window-banner-label")
        addSubview(messageLabel)

        showAllButton.translatesAutoresizingMaskIntoConstraints = false
        showAllButton.title = "Show all"
        showAllButton.bezelStyle = .rounded
        showAllButton.controlSize = .small
        showAllButton.font = .systemFont(ofSize: 11)
        showAllButton.target = self
        showAllButton.action = #selector(showAllClicked(_:))
        showAllButton.setAccessibilityIdentifier("sample-column-window-banner-show-all")
        addSubview(showAllButton)

        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: showAllButton.leadingAnchor, constant: -8),
            showAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            showAllButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.lungfishMutedFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }

    /// Synchronize the banner with the current window state.
    ///
    /// - Parameters:
    ///   - isWindowActive: Whether the column window is currently capping columns
    ///     (typically the host's `isColumnWindowActive`). When `false`, the banner
    ///     hides.
    ///   - shownCount: The number of currently-instantiated sample columns.
    ///   - totalCount: The full logical sample count.
    public func update(isWindowActive: Bool, shownCount: Int, totalCount: Int) {
        isHidden = !isWindowActive
        needsDisplay = true
        // Collapse the reserved 24pt row when hidden so the host layout closes the
        // gap; expand it back when the affordance is shown.
        heightConstraint?.constant = isWindowActive ? 24 : 0
        guard isWindowActive else { return }
        let samples = totalCount == 1 ? "sample" : "samples"
        messageLabel.stringValue = "Showing \(shownCount) of \(totalCount) \(samples)"
        toolTip = "Only the first \(shownCount) sample columns are shown. Click Show all to reveal the remaining columns."
    }

    @objc private func showAllClicked(_ sender: NSButton) {
        onShowAll?()
    }
}
