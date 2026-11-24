// ViewMemoryFilterLine.swift - The one in-view line for a restored filter or sample subset (word 5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The three forms of the line that a viewport shows while a restored filter or sample subset
/// hides rows or changes values and the viewport itself shows nothing of it (VS B5, B6).
///
/// The words are word 5 as the copy edit left them. Each line is one line of at most 20 words, and none
/// runs a count that needs a long load. A table that counts its rows cheaply uses `counted`.
public enum ViewMemoryFilterLineForm: Sendable, Equatable {
    /// Rows or reads are hidden and no cheap count exists. `kind` starts a sentence ("Read")
    /// and `noun` is plural ("reads").
    case hiddenWithoutCount(kind: String, noun: String)
    /// A table that counts its rows cheaply.
    case counted(shown: Int, total: Int)
    /// Settings that change values, such as genotype denominators, rather than which rows show.
    case changesValues

    /// The words on screen. VoiceOver reads the same words.
    public var text: String {
        switch self {
        case .hiddenWithoutCount(let kind, let noun):
            return "\(kind) filters from your last visit hide some \(noun). Change filters in the Inspector."
        case .counted(let shown, let total):
            return "With filters from your last visit, you can see \(shown.formatted()) of \(total.formatted()) rows. Change filters in the Inspector."
        case .changesValues:
            return "Settings from your last visit change these values. Change the settings in the Inspector."
        }
    }

    /// The VoiceOver announcement, which says the same words as the line.
    public var announcement: String { text }
}

/// When the line shows. A restore shows it only while the restored value differs from its
/// default, and it is gone once the person changes the value or runs Reset View.
public struct ViewMemoryFilterLineModel: Sendable, Equatable {
    public private(set) var form: ViewMemoryFilterLineForm?

    public init() {}

    public var isVisible: Bool { form != nil }
    public var text: String? { form?.text }

    /// A restore. Pass nil when the restored value equals its default, so no line shows.
    /// Returns true when the line should be announced, which is once for each new form.
    @discardableResult
    public mutating func restore(_ form: ViewMemoryFilterLineForm?) -> Bool {
        let isNew = self.form != form
        self.form = form
        return isNew && form != nil
    }

    /// The person changed the filter or the subset, so the line goes.
    public mutating func personChangedIt() {
        form = nil
    }

    /// Reset View ran, so the line goes.
    public mutating func resetView() {
        form = nil
    }
}

/// A one-line view for ``ViewMemoryFilterLineModel``. A viewport places it in its own layout, and
/// it is hidden while it has nothing to say.
@MainActor
public final class ViewMemoryFilterLineView: NSView {
    private var model = ViewMemoryFilterLineModel()
    private let announcer: any AccessibilityAnnouncementPosting
    private let label = NSTextField(labelWithString: "")
    private var contentTypographyObservation: ContentTypographyNotificationObservation?

    /// The form on show, nil while the line is hidden.
    public var currentForm: ViewMemoryFilterLineForm? { model.form }
    /// The words on screen.
    public var displayedText: String { label.stringValue }

    public init(announcer: any AccessibilityAnnouncementPosting = AccessibilityAnnouncementPoster()) {
        self.announcer = announcer
        super.init(frame: .zero)
        build()
    }

    public required init?(coder: NSCoder) {
        self.announcer = AccessibilityAnnouncementPoster()
        super.init(coder: coder)
        build()
    }

    /// Shows the line for a restored value and announces it once. Pass nil when the restored
    /// value equals its default.
    public func showRestored(_ form: ViewMemoryFilterLineForm?) {
        let shouldAnnounce = model.restore(form)
        refresh()
        if shouldAnnounce, let form {
            announcer.post(form.announcement, priority: .medium)
        }
    }

    /// The person changed the value, or Reset View ran.
    public func clear() {
        model.personChangedIt()
        refresh()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityIdentifier("view-memory-filter-line")

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.textColor = .lungfishSecondaryText
        label.setAccessibilityIdentifier("view-memory-filter-line-label")
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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

    private func applyContentTypography() {
        label.font = ContentTypography.current().font(for: .caption)
    }

    private func refresh() {
        if let text = model.text {
            label.stringValue = text
            label.toolTip = text
            isHidden = false
        } else {
            label.stringValue = ""
            label.toolTip = nil
            isHidden = true
        }
    }
}
