// LungfishInfoButton.swift - The info button that opens one help item's general explanation in a popover
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// The info button of place 2, One click away, in the section Where words go of
/// `docs/design/design-system/README.md`.
///
/// Put one beside the control or the data whose general explanation it holds, never one for a whole surface. It shows
/// `info.circle`, since the round `?` button opens the app's help. Its VoiceOver label is "About <subject>", and its help
/// tag and AXHelp are the item's summary. A click, Space or a VoiceOver press opens a transient popover that holds the
/// item's detail as wrapping text, at a fixed width and the height of its text.
///
/// While the popover shows, the button watches the application's key events. Esc or Command-period closes the popover
/// and goes no further, so no keyDown and no `cancelOperation` reaches the window behind, whichever window is key. A
/// cell map that clears its selection on Esc and a dialog that binds Esc to Cancel need no code of their own for it.
///
/// The popover's content controller is built in `init`, so a test with no window reads the words through
/// ``popoverController``. The SwiftUI form is ``LungfishInfoButtonView``, which wraps this button.
@MainActor
public final class LungfishInfoButton: NSButton, NSPopoverDelegate {
    /// The width of every info popover, in points. Its height follows its text.
    public static let popoverWidth: CGFloat = 320

    /// The accessibility identifier of the button that shows `item`. The popover's text carries this identifier with
    /// `-detail` added.
    public nonisolated static func accessibilityIdentifier(for item: LungfishHelpContent.HelpItem) -> String {
        "info-\(item.id)"
    }

    /// Whether `event` is a key that cancels, Esc (key code 53) or Command-period.
    public nonisolated static func isCancelKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == .command && event.charactersIgnoringModifiers == "."
    }

    /// The help item whose summary is the help tag and whose detail the popover shows.
    public private(set) var item: LungfishHelpContent.HelpItem

    /// What the button explains, the "<subject>" of its VoiceOver label "About <subject>".
    public private(set) var subject: String

    /// The popover's content, built before any window exists.
    public let popoverController: LungfishInfoPopoverController

    /// Whether the popover is on screen.
    public var isPopoverShown: Bool { popover.isShown }

    private let popover = NSPopover()
    private var keyMonitor: Any?

    /// Makes an info button for `item`, with the VoiceOver label "About `subject`".
    public init(item: LungfishHelpContent.HelpItem, about subject: String) {
        self.item = item
        self.subject = subject
        popoverController = LungfishInfoPopoverController()
        super.init(frame: .zero)
        title = ""
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        refusesFirstResponder = false
        target = self
        action = #selector(pressed(_:))
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverController
        popoverController.onCancel = { [weak self] in self?.closePopover() }
        applyItem()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("LungfishInfoButton is built in code")
    }

    isolated deinit {
        removeKeyMonitor()
    }

    /// Shows another item or subject, as a SwiftUI update does.
    public func configure(item: LungfishHelpContent.HelpItem, about subject: String) {
        self.item = item
        self.subject = subject
        applyItem()
    }

    /// Opens the popover. With no window the content is still built, and nothing shows.
    public func showPopover() {
        guard window != nil else { return }
        if popover.isShown { return }
        popover.contentSize = popoverController.fittedSize()
        installKeyMonitor()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    /// Closes the popover if it shows, and says whether it did.
    @discardableResult
    public func closePopover() -> Bool {
        removeKeyMonitor()
        guard popover.isShown else { return false }
        popover.close()
        return true
    }

    /// A square the size of the symbol, so AppKit and SwiftUI lay the button out alike.
    public override var intrinsicContentSize: NSSize {
        let side = ceil(max(image?.size.width ?? 16, image?.size.height ?? 16))
        return NSSize(width: side, height: side)
    }

    /// Space opens the popover under either Keyboard navigation setting. Any other key goes on as before.
    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty, event.keyCode == 49 || event.charactersIgnoringModifiers == " " {
            if !event.isARepeat { pressed(self) }
        } else {
            super.keyDown(with: event)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePopover() }
    }

    public func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    @objc private func pressed(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func applyItem() {
        let label = "About \(subject)"
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: label)
        toolTip = item.summary
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        setAccessibilityHelp(item.summary)
        let identifier = Self.accessibilityIdentifier(for: item)
        setAccessibilityIdentifier(identifier)
        // The button's cell is the element accessibility clients reach, and the view does not pass its identifier on.
        cell?.setAccessibilityIdentifier(identifier)
        invalidateIntrinsicContentSize()
        popoverController.update(text: item.detail ?? item.summary, identifier: "\(identifier)-detail")
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard LungfishInfoButton.isCancelKey(event) else { return event }
            return self?.closePopover() == true ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// The content of an info popover, one wrapping, selectable text at ``LungfishInfoButton/popoverWidth``.
@MainActor
public final class LungfishInfoPopoverController: NSViewController {
    /// The space between the text and the popover's edge, in points.
    public static let inset: CGFloat = 12

    /// The text the popover shows, readable before the view loads.
    public let textField: NSTextField

    var onCancel: (() -> Void)?

    init() {
        textField = NSTextField(wrappingLabelWithString: "")
        textField.isSelectable = true
        textField.preferredMaxLayoutWidth = LungfishInfoButton.popoverWidth - 2 * Self.inset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("LungfishInfoPopoverController is built in code")
    }

    /// The words the popover shows.
    public var text: String { textField.stringValue }

    public override func loadView() {
        let container = NSView()
        textField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textField)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: LungfishInfoButton.popoverWidth),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            textField.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        view = container
    }

    /// The popover's size, the fixed width and the height its text needs at that width.
    public func fittedSize() -> NSSize {
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: LungfishInfoButton.popoverWidth, height: ceil(view.fittingSize.height))
        preferredContentSize = size
        return size
    }

    /// Esc that reaches the popover's own window closes it too.
    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func update(text: String, identifier: String) {
        textField.stringValue = text
        textField.setAccessibilityIdentifier(identifier)
    }
}

/// The SwiftUI form of ``LungfishInfoButton``. It wraps the AppKit button, so one popover, one accessibility element and
/// one Esc behaviour serve both forms. It adds no `.help` or `.accessibilityHint`, so the AXHelp is the button's summary.
public struct LungfishInfoButtonView: NSViewRepresentable {
    public let item: LungfishHelpContent.HelpItem
    public let subject: String

    /// An info button for `item`, with the VoiceOver label "About `subject`".
    public init(_ item: LungfishHelpContent.HelpItem, about subject: String) {
        self.item = item
        self.subject = subject
    }

    public func makeNSView(context: Context) -> LungfishInfoButton {
        let button = LungfishInfoButton(item: item, about: subject)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    public func updateNSView(_ button: LungfishInfoButton, context: Context) {
        if button.item != item || button.subject != subject {
            button.configure(item: item, about: subject)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView button: LungfishInfoButton, context: Context) -> CGSize? {
        button.intrinsicContentSize
    }

    public static func dismantleNSView(_ button: LungfishInfoButton, coordinator: ()) {
        button.closePopover()
    }
}
