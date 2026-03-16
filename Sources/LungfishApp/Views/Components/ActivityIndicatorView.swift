// ActivityIndicatorView.swift - Reusable activity/progress indicator
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A floating activity indicator that appears above the bottom of its superview.
///
/// Displays as a rounded capsule with a blur background, spinner, and status text.
/// Positioned as a floating overlay to avoid clipping issues with NSSplitView on macOS 26.
///
/// Usage:
/// ```swift
/// let indicator = ActivityIndicatorView()
/// indicator.show(message: "Importing files...", style: .indeterminate)
/// // Later...
/// indicator.hide()
/// ```
@MainActor
public final class ActivityIndicatorView: NSView {

    // MARK: - Types

    /// The style of progress indication
    public enum ProgressStyle {
        /// Spinning indicator for unknown duration
        case indeterminate
        /// Progress bar for known progress (0.0 to 1.0)
        case determinate(progress: Double)
    }

    // MARK: - Properties

    /// Background blur view with rounded corners
    private let backgroundView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The progress indicator (spinner or bar)
    private let progressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    /// The message label
    private let messageLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Optional cancel button
    private let cancelButton: NSButton = {
        let button = NSButton()
        button.bezelStyle = .inline
        button.title = "Cancel"
        button.font = NSFont.systemFont(ofSize: 11)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    /// Callback when cancel is pressed
    public var onCancel: (() -> Void)?

    /// Whether the indicator is currently visible
    public private(set) var isVisible: Bool = false

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        // Drop shadow for floating appearance
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 1

        // Add background
        addSubview(backgroundView)

        // Add subviews to background
        backgroundView.addSubview(progressIndicator)
        backgroundView.addSubview(messageLabel)
        backgroundView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // Background fills entire view
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Fixed height
            heightAnchor.constraint(equalToConstant: 36),

            // Progress indicator on the left
            progressIndicator.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            progressIndicator.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            progressIndicator.heightAnchor.constraint(equalToConstant: 18),

            // Message label after indicator
            messageLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            // Cancel button on the right
            cancelButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
        ])

        // Configure cancel button action
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        // Initially hidden
        isHidden = true
        alphaValue = 0
    }

    // MARK: - Public API

    /// Shows the activity indicator with the given message and style.
    ///
    /// - Parameters:
    ///   - message: The status message to display
    ///   - style: The progress style (indeterminate spinner or determinate bar)
    ///   - cancellable: Whether to show a cancel button
    public func show(message: String, style: ProgressStyle = .indeterminate, cancellable: Bool = false) {
        messageLabel.stringValue = message
        cancelButton.isHidden = !cancellable

        switch style {
        case .indeterminate:
            progressIndicator.style = .spinning
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)

        case .determinate(let progress):
            progressIndicator.style = .bar
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = progress * 100
        }

        // Animate showing
        if !isVisible {
            isVisible = true
            isHidden = false

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                alphaValue = 1
            }
        }
    }

    /// Updates the progress for determinate style.
    ///
    /// - Parameter progress: The progress value (0.0 to 1.0)
    public func updateProgress(_ progress: Double) {
        guard !progressIndicator.isIndeterminate else { return }
        progressIndicator.doubleValue = progress * 100
    }

    /// Updates the message text.
    ///
    /// - Parameter message: The new status message
    public func updateMessage(_ message: String) {
        messageLabel.stringValue = message
    }

    /// Hides the activity indicator.
    public func hide() {
        guard isVisible else { return }

        progressIndicator.stopAnimation(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.isVisible = false
        })
    }

    // MARK: - Actions

    @objc private func cancelPressed() {
        onCancel?()
    }
}
