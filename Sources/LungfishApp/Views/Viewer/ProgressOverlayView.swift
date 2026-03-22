// ProgressOverlayView.swift - Loading overlay with spinner and timeout
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

// MARK: - ProgressOverlayView

/// A translucent overlay showing a spinner and message during loading.
///
/// Includes a safety timeout that auto-hides the overlay after 30 seconds
/// to prevent indefinitely stuck progress indicators.
public class ProgressOverlayView: NSView {

    private var spinner: NSProgressIndicator!
    private var messageLabel: NSTextField!
    private nonisolated(unsafe) var timeoutTimer: Timer?

    /// Default timeout in seconds before auto-hiding the progress overlay.
    /// This prevents stuck spinners from indefinite operations.
    /// 600s (10 min) because FASTQ import with clumpify + recipe can take several minutes.
    private let defaultTimeout: TimeInterval = 600.0

    public var message: String = "Loading..." {
        didSet {
            messageLabel?.stringValue = message
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor

        // Spinner
        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        addSubview(spinner)

        // Message label
        messageLabel = NSTextField(labelWithString: message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),

            messageLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    /// Starts the spinner animation with an optional timeout.
    ///
    /// If the overlay isn't hidden before the timeout, it will auto-hide as a safety measure.
    /// - Parameter timeout: Optional custom timeout. Defaults to 30 seconds.
    public func startAnimating(timeout: TimeInterval? = nil) {
        spinner.startAnimation(nil)

        // Cancel any existing timeout
        timeoutTimer?.invalidate()

        // Set new timeout as safety net
        let timeoutInterval = timeout ?? defaultTimeout
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stopAnimating()
            self.isHidden = true
        }
    }

    /// Stops the spinner animation and cancels any pending timeout.
    public func stopAnimating() {
        spinner.stopAnimation(nil)
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    deinit {
        timeoutTimer?.invalidate()
    }
}
