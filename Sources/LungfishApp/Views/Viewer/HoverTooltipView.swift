// HoverTooltipView.swift - Readable, pinnable sequence-viewer hover details
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

@MainActor
private final class HoverDetailsPanel: NSPanel {
    var beforeMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            beforeMouseDown?()
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class HoverDetailsBackgroundView: NSVisualEffectView {
    var pointerEntered: (() -> Void)?
    var pointerExited: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        pointerExited?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Document-owned hover details shown by the sequence viewer.
///
/// The `NSView` remains a lightweight facade for compatibility with existing viewer
/// state and test access. Its content is presented in a child panel so it cannot be
/// clipped by the canvas, Inspector, or bottom drawer.
@MainActor
final class HoverTooltipView: NSView {
    private static var defaultShowDelay: TimeInterval { AppSettings.shared.tooltipDelay }
    private static let defaultHideDelay: TimeInterval = 0.3
    private static let headerHeight: CGFloat = 36
    private static let contentHorizontalInset: CGFloat = 10
    private static let contentVerticalInset: CGFloat = 8
    private static let maximumTextWidth: CGFloat = 484

    private let showDelay: TimeInterval
    private let hideDelay: TimeInterval
    private let schedulesAutomatically: Bool

    private let panel: HoverDetailsPanel
    private let backgroundView: HoverDetailsBackgroundView
    private let statusLabel: NSTextField
    private let pinButton: NSButton
    private let copyButton: NSButton
    private let closeButton: NSButton
    private let scrollView: NSScrollView
    private let textView: NSTextView

    private weak var parentView: NSView?
    private weak var parentWindow: NSWindow?
    private weak var priorFirstResponder: NSResponder?
    private var anchorInParent: NSPoint = .zero
    private var anchorInScreen: NSPoint = .zero
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var eventMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var generation = 0
    private var pendingShowGeneration: Int?
    private var pendingShowText: String?
    private var pendingHideGeneration: Int?
    private var suppressedSourceText: String?

    private(set) var currentText: String = ""
    private(set) var isPinned: Bool = false

    override init(frame frameRect: NSRect) {
        self.showDelay = Self.defaultShowDelay
        self.hideDelay = Self.defaultHideDelay
        self.schedulesAutomatically = true
        let components = Self.makePanel()
        self.panel = components.0
        self.backgroundView = components.1
        self.statusLabel = components.2
        self.pinButton = components.3
        self.copyButton = components.4
        self.closeButton = components.5
        self.scrollView = components.6
        self.textView = components.7
        super.init(frame: frameRect)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    init(frame frameRect: NSRect, schedulesAutomatically: Bool) {
        self.showDelay = Self.defaultShowDelay
        self.hideDelay = Self.defaultHideDelay
        self.schedulesAutomatically = schedulesAutomatically
        let components = Self.makePanel()
        self.panel = components.0
        self.backgroundView = components.1
        self.statusLabel = components.2
        self.pinButton = components.3
        self.copyButton = components.4
        self.closeButton = components.5
        self.scrollView = components.6
        self.textView = components.7
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        self.showDelay = Self.defaultShowDelay
        self.hideDelay = Self.defaultHideDelay
        self.schedulesAutomatically = true
        let components = Self.makePanel()
        self.panel = components.0
        self.backgroundView = components.1
        self.statusLabel = components.2
        self.pinButton = components.3
        self.copyButton = components.4
        self.closeButton = components.5
        self.scrollView = components.6
        self.textView = components.7
        super.init(coder: coder)
        setup()
    }

    isolated deinit {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private static func makePanel() -> (
        HoverDetailsPanel,
        HoverDetailsBackgroundView,
        NSTextField,
        NSButton,
        NSButton,
        NSButton,
        NSScrollView,
        NSTextView
    ) {
        let panel = HoverDetailsPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        let background = HoverDetailsBackgroundView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.borderWidth = 0.5

        let status = NSTextField(labelWithString: "Click to keep open")
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pin = Self.headerButton(title: "Pin", symbol: "pin", identifier: "hover-details-pin")
        let copy = Self.headerButton(title: "Copy", symbol: "doc.on.doc", identifier: "hover-details-copy")
        let close = Self.headerButton(title: "Close", symbol: "xmark", identifier: "hover-details-close")

        let header = NSStackView(views: [status, pin, copy, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: Self.contentHorizontalInset, height: Self.contentVerticalInset)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.setAccessibilityIdentifier("hover-details-text")
        text.setAccessibilityLabel("Hover details")
        scroll.documentView = text

        background.addSubview(header)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return (panel, background, status, pin, copy, close, scroll, text)
    }

    private static func headerButton(title: String, symbol: String, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        return button
    }

    private func setup() {
        isHidden = true
        pinButton.target = self
        pinButton.action = #selector(pinAction(_:))
        pinButton.setAccessibilityHelp("Keep these details open while inspecting other features")
        copyButton.target = self
        copyButton.action = #selector(copyAction(_:))
        copyButton.setAccessibilityHelp("Copy all hover details")
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        closeButton.setAccessibilityHelp("Dismiss hover details")

        panel.beforeMouseDown = { [weak self] in self?.pin() }
        backgroundView.pointerEntered = { [weak self] in self?.cancelPendingHide() }
        backgroundView.pointerExited = { [weak self] in self?.requestHide() }
    }

    func show(text: String, near point: NSPoint, in parentView: NSView) {
        guard !text.isEmpty, !isPinned else { return }
        if suppressedSourceText == text { return }
        if suppressedSourceText != nil {
            suppressedSourceText = nil
        }

        let screenAnchor = screenPoint(point, in: parentView)
        if pendingShowText == text, isHidden {
            self.parentView = parentView
            parentWindow = parentView.window
            anchorInParent = point
            if let screenAnchor { anchorInScreen = screenAnchor }
            cancelPendingHide()
            return
        }
        if currentText == text, !isHidden {
            cancelPendingHide()
            return
        }

        generation &+= 1
        let requestedGeneration = generation
        cancelPendingShow()
        cancelPendingHide()
        self.parentView = parentView
        parentWindow = parentView.window
        anchorInParent = point
        if let screenAnchor { anchorInScreen = screenAnchor }
        currentText = text
        pendingShowText = text
        pendingShowGeneration = requestedGeneration
        updateDisplayedText(text)

        if !isHidden {
            completeShow(generation: requestedGeneration, targetText: text)
            return
        }
        guard schedulesAutomatically else { return }
        showTimer = Timer.scheduledTimer(withTimeInterval: showDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeShow(generation: requestedGeneration, targetText: text)
                }
            }
        }
    }

    /// Schedules ordinary pointer-leave dismissal. Pinned snapshots remain open.
    func requestHide() {
        suppressedSourceText = nil
        guard !isPinned, pendingHideGeneration == nil, !currentText.isEmpty else { return }
        let requestedGeneration = generation
        pendingHideGeneration = requestedGeneration
        guard schedulesAutomatically else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeHide(generation: requestedGeneration)
                }
            }
        }
    }

    /// Immediately closes the card and suppresses reopening until the pointer leaves its source.
    func dismiss() {
        dismissInternal(suppressCurrentSource: true)
    }

    /// Compatibility alias used by source invalidation paths.
    func hide() {
        dismissInternal(suppressCurrentSource: false)
    }

    /// Makes the currently visible content an immutable snapshot.
    func pin() {
        guard !isHidden, !currentText.isEmpty else { return }
        isPinned = true
        generation &+= 1
        cancelPendingShow()
        cancelPendingHide()
        statusLabel.stringValue = "Pinned details"
        pinButton.title = "Pinned"
        pinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinButton.isEnabled = false
        pinButton.setAccessibilityLabel("Pinned details")
        pinButton.setAccessibilityHelp("These details remain open until closed")
        configureHeader(for: panel.frame.width)
    }

    /// Returns true while the pointer is in the transient card or its narrow transit corridor.
    func retainsHover(at point: NSPoint, in parentView: NSView) -> Bool {
        guard !isPinned, !isHidden, panel.isVisible,
              let screenPoint = screenPoint(point, in: parentView) else { return false }
        let retained = HoverTooltipLayout.containsTransitPoint(
            screenPoint,
            anchor: anchorInScreen,
            panel: panel.frame
        )
        if retained {
            cancelPendingHide()
        }
        return retained
    }

    /// Dismisses state when this viewer leaves its document window.
    func parentWindowDidChange(to window: NSWindow?) {
        guard parentWindow !== window else { return }
        if parentWindow != nil || window == nil {
            dismissInternal(suppressCurrentSource: false)
        }
        parentWindow = window
    }

    func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(currentText, forType: .string)
    }

    static func attributedText(for text: String) -> NSAttributedString {
        let regular = NSFont.systemFont(ofSize: 12)
        let semibold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: regular,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let fullRange = NSRange(location: 0, length: result.length)
        let nsText = text as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 2
        result.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        var lineIndex = 0
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .byLines) { _, lineRange, _, _ in
            let line = nsText.substring(with: lineRange)
            if lineIndex == 0, lineRange.length > 0 {
                result.addAttribute(.font, value: semibold, range: lineRange)
            }
            let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let searchable = (line as NSString).substring(from: leadingWhitespace) as NSString
            let delimiter = searchable.range(of: ": ")
            if delimiter.location != NSNotFound {
                let labelLength = leadingWhitespace + delimiter.location + 1
                result.addAttribute(
                    .font,
                    value: semibold,
                    range: NSRange(location: lineRange.location + leadingWhitespace, length: labelLength - leadingWhitespace)
                )
            }
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("Sample:") {
                result.addAttribute(.font, value: semibold, range: lineRange)
                let sampleParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                sampleParagraph.paragraphSpacingBefore = 7
                result.addAttribute(.paragraphStyle, value: sampleParagraph, range: lineRange)
            }
            lineIndex += 1
        }
        return result
    }

    private func updateDisplayedText(_ text: String) {
        textView.textStorage?.setAttributedString(Self.attributedText(for: text))
    }

    private func completeShow(generation requestedGeneration: Int, targetText: String) {
        guard generation == requestedGeneration,
              pendingShowGeneration == requestedGeneration,
              pendingShowText == targetText,
              currentText == targetText,
              !isPinned else { return }
        cancelPendingShow()
        guard let parentView, let parentWindow = parentView.window,
              let available = availableScreenRect(anchor: anchorInScreen, window: parentWindow) else { return }

        self.parentWindow = parentWindow
        let targetFrame = targetPanelFrame(available: available)
        guard !targetFrame.isEmpty else { return }

        installPanelIfNeeded(in: parentWindow)
        panel.setFrame(targetFrame, display: false)
        configureHeader(for: targetFrame.width)
        backgroundView.frame = NSRect(origin: .zero, size: targetFrame.size)
        backgroundView.layoutSubtreeIfNeeded()
        let refinedFrame = refinedPanelFrame(width: targetFrame.width, available: available)
        panel.setFrame(refinedFrame, display: false)
        configureHeader(for: refinedFrame.width)
        backgroundView.layoutSubtreeIfNeeded()
        sizeTextDocumentToPanel()
        panel.orderFront(nil)
        isHidden = false
        installPresentationObservers()
    }

    private func installPanelIfNeeded(in window: NSWindow) {
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
    }

    private func measuredPanelSize(text: NSAttributedString, width: CGFloat) -> NSSize {
        let textRect = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalWidth = min(width, ceil(textRect.width)) + 2 * Self.contentHorizontalInset
        let measuredHeight = measuredTextHeight(width: max(1, naturalWidth))
        return NSSize(
            width: naturalWidth,
            height: Self.headerHeight + measuredHeight + 2 * Self.contentVerticalInset
        )
    }

    private func targetPanelFrame(available: NSRect) -> NSRect {
        let naturalSize = measuredPanelSize(text: textView.attributedString(), width: Self.maximumTextWidth)
        let provisional = HoverTooltipLayout.panelFrame(
            contentSize: naturalSize,
            anchor: anchorInScreen,
            available: available
        )
        guard !provisional.isEmpty else { return .zero }

        let constrainedHeight = Self.headerHeight
            + measuredTextHeight(width: provisional.width)
            + 2 * Self.contentVerticalInset
        return HoverTooltipLayout.panelFrame(
            contentSize: NSSize(width: provisional.width, height: constrainedHeight),
            anchor: anchorInScreen,
            available: available
        )
    }

    private func measuredTextHeight(width: CGFloat) -> CGFloat {
        let usableWidth = max(1, width - 2 * Self.contentHorizontalInset)
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: usableWidth, height: .greatestFiniteMagnitude)
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 1 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    private func refinedPanelFrame(width: CGFloat, available: NSRect) -> NSRect {
        let viewportWidth = max(1, scrollView.contentSize.width)
        let refinedHeight = Self.headerHeight
            + measuredTextHeight(width: viewportWidth)
            + 2 * Self.contentVerticalInset
        return HoverTooltipLayout.panelFrame(
            contentSize: NSSize(width: width, height: refinedHeight),
            anchor: anchorInScreen,
            available: available
        )
    }

    private func sizeTextDocumentToPanel() {
        backgroundView.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize
        let documentWidth = max(1, viewport.width)
        let contentHeight = measuredTextHeight(width: documentWidth)
        let documentHeight = max(viewport.height, contentHeight + 2 * Self.contentVerticalInset)
        textView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)
        textView.minSize = NSSize(width: 0, height: viewport.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func repositionPresentedPanel() {
        if let parentView, let movedAnchor = screenPoint(anchorInParent, in: parentView) {
            anchorInScreen = movedAnchor
        }
        guard !isHidden, let parentWindow,
              let available = availableScreenRect(anchor: anchorInScreen, window: parentWindow) else {
            if !isHidden { dismissInternal(suppressCurrentSource: false) }
            return
        }
        let targetFrame = targetPanelFrame(available: available)
        guard !targetFrame.isEmpty else {
            dismissInternal(suppressCurrentSource: false)
            return
        }
        panel.setFrame(targetFrame, display: true)
        configureHeader(for: targetFrame.width)
        backgroundView.layoutSubtreeIfNeeded()
        let refinedFrame = refinedPanelFrame(width: targetFrame.width, available: available)
        panel.setFrame(refinedFrame, display: true)
        configureHeader(for: refinedFrame.width)
        sizeTextDocumentToPanel()
    }

    private func configureHeader(for width: CGFloat) {
        let compact = width < 340
        let veryNarrow = width < 150
        pinButton.title = compact ? "" : (isPinned ? "Pinned" : "Pin")
        copyButton.title = compact ? "" : "Copy"
        closeButton.title = compact ? "" : "Close"
        statusLabel.isHidden = veryNarrow
        let controlSize: NSControl.ControlSize = veryNarrow ? .mini : .small
        pinButton.controlSize = controlSize
        copyButton.controlSize = controlSize
        closeButton.controlSize = controlSize
        if width < 220 {
            statusLabel.stringValue = isPinned ? "Pinned" : "Details"
        } else {
            statusLabel.stringValue = isPinned ? "Pinned details" : "Click to keep open"
        }
    }

    private func screenPoint(_ point: NSPoint, in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        return window.convertPoint(toScreen: view.convert(point, to: nil))
    }

    private func availableScreenRect(anchor: NSPoint, window: NSWindow) -> NSRect? {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(anchor) }) ?? window.screen
        guard let screen, let contentView = window.contentView else { return nil }
        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        let contentRectInScreen = window.convertToScreen(contentRectInWindow)
        let available = screen.visibleFrame.intersection(contentRectInScreen)
        guard !available.isNull, available.width > 0, available.height > 0 else { return nil }
        return available
    }

    private func dismissInternal(suppressCurrentSource: Bool) {
        if suppressCurrentSource, !currentText.isEmpty {
            suppressedSourceText = currentText
        } else if !suppressCurrentSource {
            suppressedSourceText = nil
        }
        generation &+= 1
        cancelPendingShow()
        cancelPendingHide()
        removePresentationObservers()

        if panel.isKeyWindow, let parentWindow, let priorFirstResponder {
            parentWindow.makeFirstResponder(priorFirstResponder)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        priorFirstResponder = nil
        currentText = ""
        textView.string = ""
        isPinned = false
        isHidden = true
        statusLabel.stringValue = "Click to keep open"
        pinButton.title = "Pin"
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        pinButton.isEnabled = true
        pinButton.setAccessibilityLabel("Pin details")
        pinButton.setAccessibilityHelp("Keep these details open while inspecting other features")
    }

    private func cancelPendingShow() {
        showTimer?.invalidate()
        showTimer = nil
        pendingShowGeneration = nil
        pendingShowText = nil
    }

    private func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
        pendingHideGeneration = nil
    }

    private func completeHide(generation requestedGeneration: Int) {
        guard pendingHideGeneration == requestedGeneration,
              generation == requestedGeneration,
              !isPinned else { return }
        dismissInternal(suppressCurrentSource: false)
    }

    private func installPresentationObservers() {
        guard eventMonitor == nil, let parentWindow else { return }
        priorFirstResponder = parentWindow.firstResponder
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.window === self.panel || event.window === self.parentWindow else { return event }
            self.dismiss()
            return nil
        }

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissInternal(suppressCurrentSource: false) }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionPresentedPanel() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionPresentedPanel() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissInternal(suppressCurrentSource: false) }
            },
        ]
    }

    private func removePresentationObservers() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    @objc private func pinAction(_ sender: NSButton) {
        pin()
    }

    @objc private func copyAction(_ sender: NSButton) {
        copy(to: .general)
    }

    @objc private func closeAction(_ sender: NSButton) {
        dismiss()
    }

    // MARK: - Deterministic test access

    var testGeneration: Int { generation }
    var testStatusText: String { statusLabel.stringValue }
    var testAttributedText: NSAttributedString { textView.attributedString() }
    var testTextView: NSTextView { textView }
    var testScrollView: NSScrollView { scrollView }
    var testPanelWindow: NSWindow { panel }
    var testTextDocumentHeight: CGFloat { textView.frame.height }

    func testFirePendingShow() {
        guard let pendingShowGeneration, let pendingShowText else { return }
        completeShow(generation: pendingShowGeneration, targetText: pendingShowText)
    }

    func testCompleteShow(generation: Int, targetText: String) {
        completeShow(generation: generation, targetText: targetText)
    }

    func testFirePendingHide() {
        guard let pendingHideGeneration else { return }
        completeHide(generation: pendingHideGeneration)
    }
}
