import AppKit
import LungfishKit

/// A persistent reader: paused readers retain their snapshot, selection and viewport,
/// even when the operation's bounded log rotates underneath them.
@MainActor
final class OperationsLogInspector: NSView, NSTextViewDelegate {
    private static let logFontSizeDefaultsKey = "OperationsCenter.logFontSize"
    private static let minimumLogFontSize: CGFloat = 10
    private static let maximumLogFontSize: CGFloat = 18

    var onClose: (() -> Void)?

    private struct ReadingState {
        var followsLatest = true
        var renderedCount = -1
        var text = ""
        var selection = NSRange(location: 0, length: 0)
        var origin = NSPoint.zero
    }

    private var readingStates: [UUID: ReadingState] = [:]
    private var retainedOperationIDs: Set<UUID> = []
    private var reading = ReadingState()
    private var item: OperationCenter.Item?
    private var changingView = false
    private var layingOut = false
    private nonisolated(unsafe) var boundsObserver: NSObjectProtocol?
    private nonisolated(unsafe) var liveScrollObserver: NSObjectProtocol?
    private let titleField = NSTextField(labelWithString: "Select an operation to read its log")
    private let latestField = NSTextField(labelWithString: "No operation selected")
    private let failureField = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let commandLabel = NSTextField(labelWithString: "Command")
    private let commandScroll = NSScrollView()
    private let commandText = NSTextView()
    private let followButton = NSButton(checkboxWithTitle: "Follow latest", target: nil, action: nil)
    private let jumpButton = NSButton(title: "Jump to latest", target: nil, action: nil)
    private let smallerTextButton = NSButton(title: "A−", target: nil, action: nil)
    private let largerTextButton = NSButton(title: "A+", target: nil, action: nil)
    private let actionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let logScroll = OperationsLogScrollView()
    private let logText = OperationsLogTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("operations-log-inspector")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        titleField.font = .systemFont(ofSize: 13, weight: .regular)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityIdentifier("operations-inspector-title")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close details")
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(closeInspector)
        closeButton.toolTip = "Close operation details"
        closeButton.setAccessibilityIdentifier("operations-inspector-close")
        closeButton.setAccessibilityLabel("Close operation details")
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleField, titleSpacer, closeButton])
        titleRow.distribution = .fill
        stack.addArrangedSubview(titleRow)

        latestField.font = .systemFont(ofSize: 13, weight: .regular)
        latestField.textColor = .secondaryLabelColor
        latestField.lineBreakMode = .byTruncatingTail
        latestField.setAccessibilityIdentifier("operations-inspector-latest")
        stack.addArrangedSubview(latestField)
        failureField.font = .systemFont(ofSize: 13, weight: .regular)
        failureField.textColor = .lungfishDanger
        failureField.maximumNumberOfLines = 2
        failureField.isSelectable = true
        failureField.isHidden = true
        failureField.setAccessibilityIdentifier("operations-inspector-failure")
        stack.addArrangedSubview(failureField)

        commandLabel.font = .systemFont(ofSize: 13, weight: .regular)
        commandLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(commandLabel)
        configureText(commandText, in: commandScroll, identifier: "operations-inspector-command-text", fontSize: 11)
        commandText.setAccessibilityLabel("Actual command")
        stack.addArrangedSubview(commandScroll)
        commandScroll.heightAnchor.constraint(equalToConstant: 52).isActive = true

        followButton.target = self
        followButton.action = #selector(toggleFollowing)
        followButton.state = .on
        followButton.setAccessibilityIdentifier("operations-inspector-follow-latest")
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatest)
        jumpButton.bezelStyle = .rounded
        jumpButton.setAccessibilityIdentifier("operations-inspector-jump-latest")
        smallerTextButton.target = self
        smallerTextButton.action = #selector(makeLogTextSmaller)
        smallerTextButton.bezelStyle = .rounded
        smallerTextButton.toolTip = "Decrease log text size"
        smallerTextButton.setAccessibilityIdentifier("operations-inspector-smaller-text")
        smallerTextButton.setAccessibilityLabel("Decrease log text size")
        largerTextButton.target = self
        largerTextButton.action = #selector(makeLogTextLarger)
        largerTextButton.bezelStyle = .rounded
        largerTextButton.toolTip = "Increase log text size"
        largerTextButton.setAccessibilityIdentifier("operations-inspector-larger-text")
        largerTextButton.setAccessibilityLabel("Increase log text size")
        actionsButton.setAccessibilityIdentifier("operations-inspector-actions")
        actionsButton.setAccessibilityLabel("Operation actions")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [followButton, jumpButton, smallerTextButton, largerTextButton, spacer, actionsButton])
        toolbar.spacing = 8
        stack.addArrangedSubview(toolbar)

        configureText(logText, in: logScroll, identifier: "operations-inspector-log-text", fontSize: Self.savedLogFontSize)
        logText.delegate = self
        logScroll.onUserScroll = { [weak self] in self?.userScrolled() }
        logText.onUserNavigation = { [weak self] in self?.userScrolled() }
        logScroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: logScroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveViewportAfterBoundsChange() }
        }
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: logScroll, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        }
        stack.addArrangedSubview(logScroll)
        // The log is the only region that may give up height. With a
        // required minimum here, a drawer shorter than the header plus 70pt
        // of log (a failed row adds two lines of failure text) could not be
        // satisfied, Auto Layout broke the stack's top pin, and the title
        // was drawn above the inspector and clipped. The header rows now
        // always stay pinned to the top and the log shrinks instead.
        let logMinimumHeight = logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70)
        logMinimumHeight.priority = .defaultHigh
        logMinimumHeight.isActive = true
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for header in [titleField, closeButton, latestField, failureField, commandLabel, commandScroll, followButton, jumpButton, smallerTextButton, largerTextButton, actionsButton] as [NSView] {
            header.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(999), for: .vertical)
        }
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    }

    private static var savedLogFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: logFontSizeDefaultsKey)
        return stored == 0 ? 11 : min(maximumLogFontSize, max(minimumLogFontSize, stored))
    }

    private func configureText(_ text: NSTextView, in scroll: NSScrollView, identifier: String, fontSize: CGFloat) {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 5)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityIdentifier(identifier)
        text.setAccessibilityLabel(identifier == "operations-inspector-log-text" ? "Operation log" : "Actual command")
        scroll.documentView = text
    }

    func display(_ newItem: OperationCenter.Item?, actions: NSMenu? = nil, at now: Date = Date()) {
        let switched = item?.id != newItem?.id
        let actionsChanged = switched || item?.state != newItem?.state
            || item?.cliCommand != newItem?.cliCommand
            || item?.outputURLs != newItem?.outputURLs || item?.bundleURLs != newItem?.bundleURLs
            || item?.failureReportURL != newItem?.failureReportURL
            || item?.logEntries.isEmpty != newItem?.logEntries.isEmpty
        if switched {
            saveReadingPosition()
            if let item, retainedOperationIDs.contains(item.id) { readingStates[item.id] = reading }
            reading = newItem.flatMap { readingStates[$0.id] } ?? ReadingState()
        }
        item = newItem
        changingView = true
        defer { changingView = false }
        if actionsChanged || actionsButton.menu == nil { actionsButton.menu = actions }
        titleField.stringValue = newItem.map { "\($0.title) · \($0.displayStateLabel)" }
            ?? "Select an operation to read its log"
        titleField.toolTip = titleField.stringValue
        updateLatest(at: now)
        failureField.stringValue = newItem?.state == .failed
            ? (newItem?.errorMessage ?? newItem?.detail ?? "Operation failed") : ""
        failureField.toolTip = newItem?.errorDetail ?? failureField.stringValue
        failureField.isHidden = failureField.stringValue.isEmpty
        let command = newItem?.cliCommand ?? "No command recorded for this operation."
        if commandText.string != command { commandText.string = command }
        if let newItem {
            if reading.followsLatest {
                renderLatest(newItem)
            } else if switched {
                logText.string = reading.text
                restoreReadingPosition()
            }
        } else {
            logText.string = ""
        }
        updateControls()
    }

    func retainOperations(_ ids: Set<UUID>) {
        retainedOperationIDs = ids
        readingStates = readingStates.filter { ids.contains($0.key) }
    }

    func updateLatest(at now: Date) {
        guard let item else { latestField.stringValue = "No operation selected"; return }
        latestField.stringValue = Self.latestLine(for: item, at: now)
        latestField.toolTip = item.latestLogEntry?.message ?? "No captured log output yet"
    }

    static func latestLine(for item: OperationCenter.Item, at now: Date = Date()) -> String {
        guard let entry = item.latestLogEntry else { return "No captured log output yet" }
        let timestamp = timestamp(for: entry.timestamp, at: now)
        let age = max(0, now.timeIntervalSince(entry.timestamp))
        let silence = item.state.isActive && age >= 10 ? " · no new output for \(formatElapsedTime(age))" : ""
        return "\(timestamp)\(silence) · \(entry.message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))"
    }

    static func timestamp(for date: Date, at now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(date))
        return date.formatted(date: age > 24 * 60 * 60 ? .abbreviated : .omitted, time: .standard)
    }

    private func renderLatest(_ item: OperationCenter.Item) {
        guard reading.renderedCount != item.logEntryCount || logText.string != reading.text else {
            // A newly selected operation can have the same empty snapshot/count.
            scrollToEnd()
            return
        }
        reading.text = item.logEntries.map { entry in
            let timestamp = Self.timestamp(for: entry.timestamp)
            return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
        reading.renderedCount = item.logEntryCount
        logText.string = reading.text
        logText.setSelectedRange(NSRange(location: (reading.text as NSString).length, length: 0))
        scrollToEnd()
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        let wasChangingView = changingView
        changingView = true
        layingOut = true
        super.layout()
        // First display can precede the split view's initial layout. Follow only
        // after the parent supplies a real viewport; never lay out a zero-sized
        // inspector just to find the last text line.
        if reading.followsLatest, item != nil { scrollToEnd() }
        layingOut = false
        changingView = wasChangingView
    }

    private func scrollToEnd() {
        guard bounds.width > 0, bounds.height >= 70 else { return }
        if !layingOut { layoutSubtreeIfNeeded() }
        guard logScroll.contentSize.width > 0, logScroll.contentSize.height > 0 else { return }
        logText.frame.size.width = logScroll.contentSize.width
        if let container = logText.textContainer { logText.layoutManager?.ensureLayout(for: container) }
        logText.sizeToFit()
        logText.scrollRangeToVisible(NSRange(location: (logText.string as NSString).length, length: 0))
    }

    private func saveReadingPosition() {
        reading.selection = logText.selectedRange()
        reading.origin = logScroll.contentView.bounds.origin
    }

    private func restoreReadingPosition() {
        guard bounds.width > 0, bounds.height >= 70 else { return }
        layoutSubtreeIfNeeded()
        logText.frame.size.width = logScroll.contentSize.width
        if let container = logText.textContainer { logText.layoutManager?.ensureLayout(for: container) }
        logText.sizeToFit()
        let length = (logText.string as NSString).length
        let location = min(reading.selection.location, length)
        logText.setSelectedRange(NSRange(location: location, length: min(reading.selection.length, length - location)))
        logScroll.contentView.scroll(to: reading.origin)
        logScroll.reflectScrolledClipView(logScroll.contentView)
    }

    private func saveViewportAfterBoundsChange() {
        guard !changingView, item != nil else { return }
        // Resizing the window and text layout also change
        // bounds. Those changes are not evidence of a user's intent to pause.
        saveReadingPosition()
    }

    private func userScrolled() {
        guard !changingView, item != nil else { return }
        let atBottom = logScroll.contentView.bounds.maxY >= logText.bounds.maxY - 3
        if !atBottom { pauseFollowing() }
        saveReadingPosition()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !changingView, logText.selectedRange().length > 0 else { return }
        pauseFollowing()
        saveReadingPosition()
    }

    private func pauseFollowing() {
        reading.followsLatest = false
        updateControls()
    }

    private func updateControls() {
        let enabled = item != nil
        followButton.isEnabled = enabled
        jumpButton.isEnabled = enabled
        closeButton.isEnabled = true
        actionsButton.isEnabled = enabled
        smallerTextButton.isEnabled = enabled && (logText.font?.pointSize ?? 11) > Self.minimumLogFontSize
        largerTextButton.isEnabled = enabled && (logText.font?.pointSize ?? 11) < Self.maximumLogFontSize
        followButton.state = reading.followsLatest ? .on : .off
        followButton.title = reading.followsLatest ? "Follow latest" : "Reviewing log history"
        followButton.toolTip = reading.followsLatest
            ? "The log follows new output as it arrives"
            : "Reviewing earlier log output. Processing and log capture continue independently. Select to resume live log output."
        followButton.setAccessibilityLabel("Follow latest log output")
        followButton.setAccessibilityHelp(followButton.toolTip)
        let pending = max(0, (item?.logEntryCount ?? 0) - max(0, reading.renderedCount))
        jumpButton.title = !reading.followsLatest && pending > 0
            ? "Resume live log (\(pending) new)" : (reading.followsLatest ? "Jump to latest" : "Resume live log")
        jumpButton.setAccessibilityLabel(jumpButton.title)
    }

    @objc private func toggleFollowing() {
        if followButton.state == .on { jumpToLatest() } else { pauseFollowing() }
    }

    @objc private func jumpToLatest() {
        guard let item else { return }
        changingView = true
        reading.followsLatest = true
        // Clear a historical selection even if no new lines have arrived.
        logText.setSelectedRange(NSRange(location: (logText.string as NSString).length, length: 0))
        renderLatest(item)
        saveReadingPosition()
        updateControls()
        changingView = false
    }

    @objc private func closeInspector() {
        onClose?()
    }

    @objc private func makeLogTextSmaller() {
        setLogFontSize((logText.font?.pointSize ?? Self.savedLogFontSize) - 1)
    }

    @objc private func makeLogTextLarger() {
        setLogFontSize((logText.font?.pointSize ?? Self.savedLogFontSize) + 1)
    }

    private func setLogFontSize(_ requestedSize: CGFloat) {
        let size = min(Self.maximumLogFontSize, max(Self.minimumLogFontSize, requestedSize))
        changingView = true
        saveReadingPosition()
        let pausedAnchor = reading.followsLatest ? nil : visibleTextAnchor()
        logText.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        UserDefaults.standard.set(Double(size), forKey: Self.logFontSizeDefaultsKey)
        layoutSubtreeIfNeeded()
        if reading.followsLatest {
            scrollToEnd()
        } else if let pausedAnchor {
            restoreVisibleTextAnchor(pausedAnchor)
        } else {
            restoreReadingPosition()
        }
        changingView = false
        updateControls()
    }

    private struct VisibleTextAnchor {
        let characterIndex: Int
        let offsetFromLineTop: CGFloat
        let horizontalOrigin: CGFloat
    }

    private func visibleTextAnchor() -> VisibleTextAnchor? {
        guard let layoutManager = logText.layoutManager,
              let textContainer = logText.textContainer,
              !logText.string.isEmpty else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let origin = logScroll.contentView.bounds.origin
        let point = logText.convert(origin, from: logScroll.contentView)
        let glyph = min(
            layoutManager.glyphIndex(for: point, in: textContainer),
            max(0, layoutManager.numberOfGlyphs - 1)
        )
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return VisibleTextAnchor(
            characterIndex: character,
            offsetFromLineTop: point.y - line.minY,
            horizontalOrigin: origin.x
        )
    }

    private func restoreVisibleTextAnchor(_ anchor: VisibleTextAnchor) {
        guard let layoutManager = logText.layoutManager,
              let textContainer = logText.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }
        logText.frame.size.width = logScroll.contentSize.width
        layoutManager.ensureLayout(for: textContainer)
        logText.sizeToFit()
        let character = min(anchor.characterIndex, max(0, (logText.string as NSString).length - 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        logScroll.contentView.scroll(to: NSPoint(
            x: anchor.horizontalOrigin,
            y: max(0, line.minY + anchor.offsetFromLineTop)
        ))
        logScroll.reflectScrolledClipView(logScroll.contentView)
        saveReadingPosition()
    }
}

@MainActor
private final class OperationsLogScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}

@MainActor
private final class OperationsLogTextView: NSTextView {
    var onUserNavigation: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        onUserNavigation?()
    }
}
