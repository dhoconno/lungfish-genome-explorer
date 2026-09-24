// ViewportStatusView.swift - Shared empty/no-matches/failed status overlay for result tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Accessible status overlay for result tables and viewports (UX-14).
///
/// Covers the "no matches" case (a filter or column filter narrowed the
/// table to zero rows) and the "empty" case (a classifier run legitimately
/// found nothing, or a viewport has nothing loaded yet). Both states read as
/// a plain blank grid without this view, which can be misread as a bug.
///
/// Kept intentionally small: a title, an optional detail line, and an
/// optional action button. `BatchTableView` uses the `.noMatches` state
/// today; other tables and viewports can adopt the same view as they
/// converge onto shared contracts.
public final class ViewportStatusView: NSView {
    /// Overlay display cases. `.loading` and `.failed` are provided for
    /// future adopters (UX-09) beyond `BatchTableView`'s current `.noMatches` use.
    public enum State {
        case loading(message: String)
        case empty(message: String, actionTitle: String? = nil)
        case noMatches(actionTitle: String = "Clear Filter")
        case failed(title: String, detail: String, actionTitle: String? = nil)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var onAction: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.isHidden = true

        actionButton.bezelStyle = .rounded
        actionButton.isHidden = true
        actionButton.target = self
        actionButton.action = #selector(actionButtonPressed)

        let stack = NSStackView(views: [titleLabel, detailLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    /// Configures the overlay for `state`. `onAction` is invoked when the
    /// optional action button (e.g. "Clear Filter") is pressed.
    public func configure(_ state: State, onAction: (() -> Void)? = nil) {
        self.onAction = onAction
        switch state {
        case .loading(let message):
            titleLabel.stringValue = message
            detailLabel.isHidden = true
            actionButton.isHidden = true
        case .empty(let message, let actionTitle):
            titleLabel.stringValue = message
            detailLabel.isHidden = true
            configureAction(actionTitle)
        case .noMatches(let actionTitle):
            titleLabel.stringValue = "No rows match the current filter"
            detailLabel.isHidden = true
            configureAction(actionTitle)
        case .failed(let title, let detail, let actionTitle):
            titleLabel.stringValue = title
            detailLabel.stringValue = detail
            detailLabel.isHidden = detail.isEmpty
            configureAction(actionTitle)
        }
        setAccessibilityLabel([titleLabel.stringValue, detailLabel.isHidden ? nil : detailLabel.stringValue]
            .compactMap { $0 }
            .joined(separator: ". "))
    }

    private func configureAction(_ title: String?) {
        if let title {
            actionButton.title = title
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func actionButtonPressed() {
        onAction?()
    }
}
