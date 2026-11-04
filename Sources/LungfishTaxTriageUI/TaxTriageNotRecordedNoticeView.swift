// TaxTriageNotRecordedNoticeView.swift - The viewer's notice for an import that kept no negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, BIO-IMPORT-BATCH item 5. A result whose record lists
// no samples names no negative control, so its Contamination column reads No for every organism whether or not a
// control held it. This strip sits between the summary bar and the sample filter row and says so. Hidden, it
// takes no height, so a result that knows its controls looks as it did before.

import AppKit

/// A wrapping line of words that is either on show or collapsed to zero height.
@MainActor
final class TaxTriageNotRecordedNoticeView: NSView {
    /// The words BIO-IMPORT-BATCH item 5 sets for a result that kept no record of its samples.
    static let words = "Not recorded by this import: negative controls, run settings and database. "
        + "An organism here may also be in a control. "
        + "If you still have the run's folder, import it again with this version to keep them."

    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 4

    private let label = NSTextField(wrappingLabelWithString: "")
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)
    private lazy var shownBottom = label.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -Self.verticalInset
    )

    /// The words on show, nil while the strip is collapsed.
    private(set) var shownWords: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("taxtriage-not-recorded-notice")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
        ])
        show(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `words` wrapped to the strip's width, or collapses the strip to zero height for nil.
    func show(_ words: String?) {
        shownWords = words
        if let words {
            label.stringValue = words
            collapsedHeight.isActive = false
            shownBottom.isActive = true
            isHidden = false
        } else {
            shownBottom.isActive = false
            collapsedHeight.isActive = true
            isHidden = true
        }
    }

    override func layout() {
        // A wrapping label measures its height at the width it is given, so hand it the strip's width first.
        label.preferredMaxLayoutWidth = max(0, bounds.width - 2 * Self.horizontalInset)
        super.layout()
    }
}
