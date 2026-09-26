import AppKit
import LungfishKit

/// A persistent reader: paused readers retain their snapshot, selection and viewport,
/// even when the operation's bounded log rotates underneath them.
@MainActor
final class OperationsLogInspector: NSView, NSTextViewDelegate {
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
    private let detailsToggle = NSButton(checkboxWithTitle: "Details", target: nil, action: nil)
    private let detailsScroll = NSScrollView()
    private let detailsText = NSTextView()
    private let followButton = NSButton(checkboxWithTitle: "Follow latest", target: nil, action: nil)
    private let jumpButton = NSButton(title: "Jump to latest", target: nil, action: nil)
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

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityIdentifier("operations-inspector-title")
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        detailsToggle.setAccessibilityIdentifier("operations-inspector-details-toggle")
        let titleRow = NSStackView(views: [titleField, detailsToggle])
        titleRow.distribution = .fill
        stack.addArrangedSubview(titleRow)

        latestField.font = .systemFont(ofSize: 11)
        latestField.textColor = .secondaryLabelColor
        latestField.lineBreakMode = .byTruncatingTail
        latestField.setAccessibilityIdentifier("operations-inspector-latest")
        stack.addArrangedSubview(latestField)
        failureField.font = .systemFont(ofSize: 12)
        failureField.textColor = .lungfishDanger
        failureField.maximumNumberOfLines = 2
        failureField.isSelectable = true
        failureField.isHidden = true
        failureField.setAccessibilityIdentifier("operations-inspector-failure")
        stack.addArrangedSubview(failureField)

        configureText(detailsText, in: detailsScroll, identifier: "operations-inspector-details-text")
        detailsScroll.isHidden = true
        stack.addArrangedSubview(detailsScroll)
        detailsScroll.heightAnchor.constraint(equalToConstant: 85).isActive = true

        followButton.target = self
        followButton.action = #selector(toggleFollowing)
        followButton.state = .on
        followButton.setAccessibilityIdentifier("operations-inspector-follow-latest")
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatest)
        jumpButton.bezelStyle = .rounded
        jumpButton.setAccessibilityIdentifier("operations-inspector-jump-latest")
        actionsButton.setAccessibilityIdentifier("operations-inspector-actions")
        actionsButton.setAccessibilityLabel("Operation actions")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [followButton, jumpButton, spacer, actionsButton])
        toolbar.spacing = 8
        stack.addArrangedSubview(toolbar)

        configureText(logText, in: logScroll, identifier: "operations-inspector-log-text")
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
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        let retention = NSTextField(labelWithString: "Captured preview · up to 2,000 entries. View Log exports this retained diagnostic snapshot.")
        retention.font = .systemFont(ofSize: 10)
        retention.textColor = .secondaryLabelColor
        retention.lineBreakMode = .byTruncatingTail
        retention.toolTip = retention.stringValue
        stack.addArrangedSubview(retention)
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

    private func configureText(_ text: NSTextView, in scroll: NSScrollView, identifier: String) {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 5)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityIdentifier(identifier)
        text.setAccessibilityLabel(identifier == "operations-inspector-log-text" ? "Operation log preview" : "Operation diagnostics and command")
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
        let diagnosticText = newItem.map(Self.diagnostics) ?? ""
        if detailsText.string != diagnosticText { detailsText.string = diagnosticText }
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
        let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
        let age = max(0, now.timeIntervalSince(entry.timestamp))
        let silence = item.state.isActive && age >= 10 ? " · no new output for \(formatElapsedTime(age))" : ""
        return "\(timestamp)\(silence) · \(entry.message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))"
    }

    private func renderLatest(_ item: OperationCenter.Item) {
        guard reading.renderedCount != item.logEntryCount || logText.string != reading.text else {
            // A newly selected operation can have the same empty snapshot/count.
            scrollToEnd()
            return
        }
        reading.text = item.logEntries.map { entry in
            let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
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
        // Resizing the window, opening Details, and text layout also change
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
        detailsToggle.isEnabled = enabled
        actionsButton.isEnabled = enabled
        followButton.state = reading.followsLatest ? .on : .off
        let pending = max(0, (item?.logEntryCount ?? 0) - max(0, reading.renderedCount))
        jumpButton.title = !reading.followsLatest && pending > 0
            ? "Jump to latest (\(pending) new)" : "Jump to latest"
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

    @objc private func toggleDetails() {
        changingView = true
        detailsScroll.isHidden = detailsToggle.state != .on
        layoutSubtreeIfNeeded()
        if reading.followsLatest { scrollToEnd() }
        changingView = false
    }

    private static func diagnostics(_ item: OperationCenter.Item) -> String {
        var lines = [item.detail]
        if let command = item.cliCommand { lines += ["", "CLI Command", command] }
        let outputs = item.outputURLs + item.bundleURLs
        if !outputs.isEmpty { lines += ["", "Output Files"] + outputs.map(\.path) }
        if let message = item.errorMessage { lines += ["", "Error", message] }
        if let detail = item.errorDetail { lines += ["", "Error Detail", detail] }
        if let report = item.failureReportURL { lines += ["", "Failure Report", report.path] }
        return lines.joined(separator: "\n")
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
