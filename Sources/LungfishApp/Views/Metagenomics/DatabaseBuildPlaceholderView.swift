// DatabaseBuildPlaceholderView.swift — Placeholder shown while a SQLite database is being built
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A centered placeholder view shown in the viewport when a classifier result
/// directory exists but the corresponding SQLite database has not yet been built.
///
/// Displays an icon, title, subtitle, and an optional retry button.
/// Call ``configure(tool:)`` to show the "building" state, or ``showError(_:)``
/// to show an error state with the retry button visible.
@MainActor
final class DatabaseBuildPlaceholderView: NSView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let stackView = NSStackView()

    /// Called when the user taps Retry. Set this before calling ``showError(_:)``.
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Icon
        let image = NSImage(
            systemSymbolName: "gearshape.2",
            accessibilityDescription: "Building database"
        )
        iconView.image = image
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        iconView.contentTintColor = .secondaryLabelColor

        // Title
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        // Subtitle
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.isSelectable = false
        subtitleLabel.isBordered = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping

        // Retry button — hidden in the default "building" state
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        // Stack
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(retryButton)

        // Custom spacing after icon and subtitle
        stackView.setCustomSpacing(16, after: iconView)
        stackView.setCustomSpacing(4, after: titleLabel)
        stackView.setCustomSpacing(16, after: subtitleLabel)

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    /// Configures the view for the "database not yet built" state.
    ///
    /// Shows the tool name, a brief explanation, and the CLI command the user
    /// can run to build the database manually.
    ///
    /// - Parameter tool: Human-readable tool name (e.g. "TaxTriage").
    func configure(tool: String, resultURL: URL) {
        let dirName = resultURL.lastPathComponent
        let cliTool = tool.lowercased()
        titleLabel.stringValue = "No database found for \(tool) results"
        subtitleLabel.stringValue =
            "Run the following command in Terminal to build the database, then re-select this result:\n\n" +
            "lungfish build-db \(cliTool) \"\(dirName)\""
        retryButton.isHidden = true
    }

    /// Switches the view to an error state with a visible Retry button.
    ///
    /// - Parameter message: A brief description of what went wrong.
    func showError(_ message: String) {
        titleLabel.stringValue = "Database build failed"
        subtitleLabel.stringValue = message
        retryButton.isHidden = false
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
