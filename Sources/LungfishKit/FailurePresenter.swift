// FailurePresenter.swift - One failure alert in plain words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The words of one failure alert (ALERT-PRESENTER, Phase 3.1).
///
/// A site that catches an error builds a report and hands it to
/// `FailurePresenter`. The alert title names the step that failed, the body
/// says what happened and the next thing to try, and the error's own text goes
/// only into a collapsed details area, so a person never reads raw error text
/// as the explanation (`docs/contracts/SCOPE-AND-DELIVERY.md`, Words and
/// outcomes).
public struct FailureReport: Sendable, Equatable {
    public let failedStep: String     // the step, e.g. "Import the Kraken2 database"
    public let whatHappened: String   // plain words, never raw error text. A sentence an app-owned error already
                                      // words for the person may stand here, by a typed case or an exact prefix
                                      // (ALERT review R1, SF1)
    public let nextStep: String       // the next thing to try
    public let details: String?       // the underlying error, kept for the details area

    /// - Parameters:
    ///   - failedStep: The step that failed, starting with a verb, such as
    ///     "Import the Kraken2 database". The alert title reads
    ///     "Could not import the Kraken2 database".
    ///   - whatHappened: What went wrong, in plain words.
    ///   - nextStep: The next thing the person can try.
    ///   - underlying: The caught error. Its description, domain and code go
    ///     only into the collapsed details area.
    public init(failedStep: String, whatHappened: String, nextStep: String, underlying: (any Error)?) {
        self.failedStep = failedStep
        self.whatHappened = whatHappened
        self.nextStep = nextStep
        self.details = underlying.map(FailureReport.detailsText(for:))
    }

    /// A report for a step that failed on several items, one error each. The
    /// details area lists each item's name with its error.
    public init(failedStep: String, whatHappened: String, nextStep: String, itemErrors: [(name: String, error: any Error)]) {
        self.failedStep = failedStep
        self.whatHappened = whatHappened
        self.nextStep = nextStep
        self.details = itemErrors.isEmpty
            ? nil
            : itemErrors.map { "\($0.name)\n\(FailureReport.detailsText(for: $0.error))" }.joined(separator: "\n\n")
    }

    /// The details area text for an error, its description and then its
    /// domain and code.
    public static func detailsText(for error: any Error) -> String {
        let bridged = error as NSError
        return "\(error.localizedDescription)\n\nError domain \(bridged.domain), code \(bridged.code)"
    }

    /// The alert title, "Could not" and the step. The first letter of the step
    /// is lowered unless its first word is an all-capitals name such as BLAST.
    public var title: String {
        guard let first = failedStep.first else { return "Could not finish the step" }
        let firstWord = failedStep.prefix { $0 != " " }
        let keepsCase = firstWord.count > 1 && firstWord.dropFirst().allSatisfy { !$0.isLowercase }
        let step = keepsCase ? failedStep : first.lowercased() + failedStep.dropFirst()
        return "Could not \(step)"
    }

    /// The alert body, what happened and the next step as two paragraphs.
    public var body: String {
        "\(whatHappened)\n\n\(nextStep)"
    }
}

/// The one presenter for failure alerts. `WarningPresenter.present` forwards
/// its presentation here.
@MainActor
public enum FailurePresenter {
    /// Builds the alert for a report without showing it, so a test or a site
    /// that adds its own buttons can check or extend the words. With no button
    /// added, AppKit gives the alert one OK button.
    public static func alert(for report: FailureReport) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = report.title
        alert.informativeText = report.body
        alert.alertStyle = .warning
        // The Lungfish icon, as `NSAlert.applyLungfishBranding()` in the App sets it.
        if let icon = NSApplication.shared.applicationIconImage {
            alert.icon = icon
        }
        if let details = report.details {
            let detailsView = FailureDetailsView(details: details)
            detailsView.alert = alert
            alert.accessoryView = detailsView
        }
        return alert
    }

    /// Shows the report as a sheet on `window`, or on the key window, or as a
    /// modal alert when no window is open.
    public static func present(_ report: FailureReport, in window: NSWindow?, completion: (() -> Void)? = nil) {
        show(alert(for: report), in: window, completion: completion)
    }

    /// The one presentation path both presenters share.
    static func show(_ alert: NSAlert, in window: NSWindow?, completion: (() -> Void)?) {
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in completion?() }
        } else {
            _ = alert.runModal()
            completion?()
        }
    }
}

/// The collapsed, selectable details area under a failure alert's words.
/// It holds the underlying error's text for a person who wants to copy it
/// into a support message.
public final class FailureDetailsView: NSView {
    static let width: CGFloat = 320
    static let buttonHeight: CGFloat = 24
    static let gap: CGFloat = 6
    static let textHeight: CGFloat = 110

    public let toggleButton: NSButton
    public let scrollView: NSScrollView
    public let textView: NSTextView
    weak var alert: NSAlert?

    public var isExpanded: Bool { !scrollView.isHidden }

    init(details: String) {
        toggleButton = NSButton(title: "Show Details", target: nil, action: nil)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.textHeight))
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.textHeight))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.buttonHeight))

        toggleButton.bezelStyle = .push
        toggleButton.controlSize = .small
        toggleButton.target = self
        toggleButton.action = #selector(toggleDetails(_:))
        toggleButton.setAccessibilityLabel("Show or hide the error details")

        textView.string = details
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Error details")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.isHidden = true

        addSubview(toggleButton)
        addSubview(scrollView)
        layoutParts()
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override var isFlipped: Bool { true }

    @objc public func toggleDetails(_ sender: Any?) {
        setExpanded(!isExpanded)
    }

    /// Opens or closes the details area and asks the alert to lay itself out
    /// again for the new height.
    public func setExpanded(_ expanded: Bool) {
        scrollView.isHidden = !expanded
        toggleButton.title = expanded ? "Hide Details" : "Show Details"
        layoutParts()
        alert?.layout()
    }

    private func layoutParts() {
        toggleButton.sizeToFit()
        toggleButton.frame.origin = .zero
        scrollView.frame = NSRect(
            x: 0, y: Self.buttonHeight + Self.gap, width: Self.width, height: Self.textHeight
        )
        let height = isExpanded ? Self.buttonHeight + Self.gap + Self.textHeight : Self.buttonHeight
        setFrameSize(NSSize(width: Self.width, height: height))
    }
}
