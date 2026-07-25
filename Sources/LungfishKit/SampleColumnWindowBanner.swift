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
    private var contentTypographyObservation: ContentTypographyNotificationObservation?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var isWindowActive = false

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
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.cell?.wraps = true
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            messageLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: showAllButton.leadingAnchor, constant: -8),
            showAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            showAllButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let notifications = NotificationCenterContentTypographyNotifications(
            notificationCenter: .default
        )
        contentTypographyObservation = notifications.observe(
            .contentTextSizeDidChange
        ) { [weak self] in
            self?.applyContentTypography()
        }
        applyContentTypography()
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
        self.isWindowActive = isWindowActive
        isHidden = !isWindowActive
        needsDisplay = true
        updatePreferredHeight()
        guard isWindowActive else { return }
        let samples = totalCount == 1 ? "sample" : "samples"
        messageLabel.stringValue = "Showing \(shownCount) of \(totalCount) \(samples)"
        messageLabel.toolTip = messageLabel.stringValue
        messageLabel.setAccessibilityValue(messageLabel.stringValue)
        toolTip = "Only the first \(shownCount) sample columns are shown. Click Show all to reveal the remaining columns."
        updatePreferredHeight()
    }

    @objc private func showAllClicked(_ sender: NSButton) {
        onShowAll?()
    }

    public override func layout() {
        super.layout()
        updatePreferredHeight()
    }

    /// Re-resolves the message using an injected semantic System-font source.
    public func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        applyContentTypography()
    }

    private func applyContentTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        let canonicalBody = max(
            preferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
        let scale = typography.font(for: .body).pointSize / canonicalBody
        let pointSize = max(ContentTypography.minimumPointSize, 11 * scale)
        messageLabel.font = .systemFont(ofSize: pointSize)
        updatePreferredHeight()
        needsLayout = true
    }

    private func updatePreferredHeight() {
        guard isWindowActive else {
            heightConstraint?.constant = 0
            return
        }
        let availableWidth = max(
            40,
            bounds.width - showAllButton.fittingSize.width - 30
        )
        let measured = messageLabel.attributedStringValue.boundingRect(
            with: NSSize(width: availableWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        heightConstraint?.constant = max(
            24,
            ceil(measured + 12),
            ceil(showAllButton.fittingSize.height + 8)
        )
    }
}

#if DEBUG
public extension SampleColumnWindowBanner {
    var testingMessagePointSize: CGFloat { messageLabel.font?.pointSize ?? 0 }
    var testingPreferredHeight: CGFloat { heightConstraint?.constant ?? 0 }
    var testingMessageWraps: Bool {
        messageLabel.maximumNumberOfLines == 0
            && messageLabel.lineBreakMode == .byWordWrapping
    }
}
#endif
