// MissingSourceNoticeView.swift - Non-blocking viewport strip for a copied result's missing sources
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// A one-line strip shown above a result view when the result was copied
/// from another project and some of its source data is not available here.
/// The result itself still renders. The strip only says what is missing and
/// the full list stays in the Inspector.
@MainActor
final class MissingSourceNoticeView: NSView {
    static let preferredHeight: CGFloat = 26

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

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
        setAccessibilityIdentifier("viewport.missingSourceNotice")
        setAccessibilityRole(.group)

        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Missing source data")
        iconView.contentTintColor = .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Fills the strip from a copy record. Returns false when there is
    /// nothing to say, in which case the caller keeps the strip hidden.
    @discardableResult
    func update(with record: ProjectItemCopyRecord?) -> Bool {
        guard let record, record.hasMissingSources else {
            label.stringValue = ""
            toolTip = nil
            return false
        }
        let names = record.unresolvedLinks.map(\.displayName)
        let shown = names.prefix(2).joined(separator: ", ")
        let more = names.count > 2 ? " and \(names.count - 2) more" : ""
        let origin = record.sourceProjectName.map { " Copied from project \($0)." } ?? ""
        label.stringValue = "Source data not in this project: \(shown)\(more).\(origin) See the Inspector for details."
        toolTip = record.missingSourceSummaryLines.joined(separator: "\n")
        setAccessibilityLabel(label.stringValue)
        return true
    }
}
