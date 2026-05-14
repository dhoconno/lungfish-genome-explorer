// ProjectLockWarningBannerView.swift - Persistent locked-project warning banner
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class ProjectLockWarningBannerView: NSView {
    private let iconLabel: NSTextField = {
        let label = NSTextField(labelWithString: "!")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.55).cgColor
        label.layer?.cornerRadius = 9
        return label
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityIdentifier(MainWindowAccessibilityID.projectLockBannerTitle)
        return label
    }()

    private let detailLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityIdentifier(MainWindowAccessibilityID.projectLockBannerDetail)
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ProjectLockWarningBannerView does not support storyboard initialization")
    }

    func update(with presentation: ProjectLockWarningPresentation) {
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        setAccessibilityLabel(presentation.accessibilityLabel)
        toolTip = presentation.detail
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityIdentifier(MainWindowAccessibilityID.projectLockBanner)
        setAccessibilityRole(.group)

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .horizontal
        textStack.alignment = .firstBaseline
        textStack.spacing = 8
        textStack.distribution = .fill

        addSubview(iconLabel)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 18),
            iconLabel.heightAnchor.constraint(equalToConstant: 18),

            textStack.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
}
