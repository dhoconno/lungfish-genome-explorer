// AIAssistantPanel.swift - AI assistant chat interface components
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "AIAssistantPanel")

// MARK: - Notification

extension Notification.Name {
    /// Posted to request showing the AI assistant panel.
    public static let showAIAssistantRequested = Notification.Name("showAIAssistantRequested")
}

// MARK: - AIAssistantWindowController

/// Manages the floating AI assistant panel window.
@MainActor
public final class AIAssistantWindowController: NSWindowController {

    private let assistantService: AIAssistantService
    private var panelViewController: AIAssistantViewController?

    /// Creates the AI assistant window controller.
    public init(service: AIAssistantService) {
        self.assistantService = service

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "AI Assistant"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 400)
        panel.setFrameAutosaveName("AIAssistantPanel")
        panel.isRestorable = false

        // Set delegate to prevent close from releasing
        let vc = AIAssistantViewController(service: service)

        super.init(window: panel)

        self.panelViewController = vc
        panel.contentViewController = vc
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Toggles the panel visibility.
    public func togglePanel() {
        guard let panel = window else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    /// Shows the panel, positioning near the main window if first show.
    public func showPanel() {
        guard let panel = window else { return }
        if !panel.isVisible {
            // Position near the right edge of the main window
            if let mainWindow = NSApp.mainWindow, panel.frame.origin == .zero || !panel.isVisible {
                let mainFrame = mainWindow.frame
                let panelWidth = panel.frame.width
                let panelHeight = panel.frame.height
                let x = mainFrame.maxX + 8
                let y = mainFrame.maxY - panelHeight
                panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)

                // If panel would be off-screen, position inside the main window
                if let screen = mainWindow.screen {
                    let screenFrame = screen.visibleFrame
                    if x + panelWidth > screenFrame.maxX {
                        let adjustedX = mainFrame.maxX - panelWidth - 20
                        panel.setFrame(NSRect(x: adjustedX, y: y, width: panelWidth, height: panelHeight), display: false)
                    }
                }
            }
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public var isPanelVisible: Bool {
        window?.isVisible ?? false
    }
}

// MARK: - AIAssistantViewController

/// View controller for the AI assistant chat interface.
@MainActor
final class AIAssistantViewController: NSViewController {

    private let service: AIAssistantService
    private let scrollView = NSScrollView()
    private let messagesStackView = NSStackView()
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private let suggestedQueriesContainer = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var thinkingIndicator: NSProgressIndicator?
    private var documentMinHeightConstraint: NSLayoutConstraint?
    private var documentContentHeightConstraint: NSLayoutConstraint?

    init(service: AIAssistantService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        self.view = container
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        restoreConversationFromService()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        performMessageLayoutAndDisplayUpdate(scrollToBottom: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        performMessageLayoutAndDisplayUpdate(scrollToBottom: false)
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Main layout: [header] [suggested queries / messages scroll] [input bar]
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 0
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Header bar
        let headerView = createHeaderView()
        mainStack.addArrangedSubview(headerView)

        // Suggested queries (shown when no messages)
        suggestedQueriesContainer.orientation = .vertical
        suggestedQueriesContainer.spacing = 8
        suggestedQueriesContainer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        // Messages scroll view
        messagesStackView.orientation = .vertical
        messagesStackView.spacing = 12
        messagesStackView.alignment = .leading
        messagesStackView.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        messagesStackView.setContentHuggingPriority(.required, for: .vertical)
        messagesStackView.setContentCompressionResistancePriority(.required, for: .vertical)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        messagesStackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(messagesStackView)

        NSLayoutConstraint.activate([
            messagesStackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            messagesStackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            messagesStackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            messagesStackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            messagesStackView.widthAnchor.constraint(equalTo: documentView.widthAnchor),
        ])

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Keep the document width locked to the viewport width so message bubbles
        // wrap consistently as the assistant window/inspector width changes.
        let clipView = scrollView.contentView
        documentMinHeightConstraint = documentView.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor)
        documentContentHeightConstraint = documentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1)
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
            documentMinHeightConstraint!,
            documentContentHeightConstraint!,
        ])

        // Content area (suggested queries first, then scroll view)
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.addArrangedSubview(suggestedQueriesContainer)
        contentStack.addArrangedSubview(scrollView)

        mainStack.addArrangedSubview(contentStack)

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        mainStack.addArrangedSubview(separator)

        // Input bar
        let inputBar = createInputBar()
        mainStack.addArrangedSubview(inputBar)

        view.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            headerView.heightAnchor.constraint(equalToConstant: 36),
        ])

        // Set scroll view to expand
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func createHeaderView() -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

        let titleLabel = NSTextField(labelWithString: "AI Assistant")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        clearButton.title = "Clear"
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearConversation)

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(clearButton)

        return header
    }

    private func createInputBar() -> NSView {
        let inputBar = NSStackView()
        inputBar.orientation = .horizontal
        inputBar.spacing = 8
        inputBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        inputField.placeholderString = "Ask about your genome data..."
        inputField.font = .systemFont(ofSize: 13)
        inputField.delegate = self
        inputField.focusRingType = .none
        inputField.bezelStyle = .roundedBezel

        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.bezelStyle = .toolbar
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        inputBar.addArrangedSubview(inputField)
        inputBar.addArrangedSubview(sendButton)

        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        return inputBar
    }

    private func restoreConversationFromService() {
        refreshSuggestedQueries()

        // Clear any existing bubbles.
        for view in messagesStackView.arrangedSubviews {
            messagesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let persisted = service.messages
        guard !persisted.isEmpty else {
            suggestedQueriesContainer.isHidden = false
            addWelcomeMessage()
            return
        }

        suggestedQueriesContainer.isHidden = true
        for message in persisted {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch message.role {
            case .user:
                addMessageView(text: content, isUser: true)
            case .assistant:
                addMessageView(text: content, isUser: false)
            case .system:
                continue
            case .tool:
                break
            }
        }

        if messagesStackView.arrangedSubviews.isEmpty {
            addWelcomeMessage()
        }
        updateMessageDocumentHeight()
        DispatchQueue.main.async { [weak self] in
            self?.scrollMessagesToBottom()
        }
    }

    /// Ensures the scroll document grows with message content so long responses remain visible.
    private func updateMessageDocumentHeight() {
        guard scrollView.documentView != nil else { return }
        scrollView.layoutSubtreeIfNeeded()
        messagesStackView.layoutSubtreeIfNeeded()

        let contentHeight = messagesStackView.fittingSize.height
        let minHeight = scrollView.contentView.bounds.height
        let desiredHeight = max(minHeight, contentHeight)
        documentContentHeightConstraint?.constant = desiredHeight
    }

    private func scrollMessagesToBottom() {
        guard let documentView = scrollView.documentView else { return }
        updateMessageDocumentHeight()
        documentView.layoutSubtreeIfNeeded()
        let contentHeight = max(documentView.fittingSize.height, messagesStackView.fittingSize.height)
        let maxY = max(0, contentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Forces message layout + repaint to avoid stale blank frames until user interaction.
    private func performMessageLayoutAndDisplayUpdate(scrollToBottom: Bool) {
        guard scrollView.documentView != nil else { return }
        updateMessageDocumentHeight()
        view.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        if scrollToBottom {
            scrollMessagesToBottom()
        }
        messagesStackView.needsDisplay = true
        scrollView.contentView.needsDisplay = true
        scrollView.documentView?.needsDisplay = true
        scrollView.needsDisplay = true
    }

    // MARK: - Messages

    private func addWelcomeMessage() {
        let welcome = service.welcomeMessage()
        addMessageView(text: welcome, isUser: false, isWelcome: true)
    }

    private func addMessageView(text: String, isUser: Bool, isWelcome: Bool = false) {
        let messageView = AIMessageBubbleView(text: text, isUser: isUser, isWelcome: isWelcome)
        messagesStackView.addArrangedSubview(messageView)

        // Set width constraints.
        if isUser {
            // User messages should not collapse into a very narrow column for long prompts.
            let maxWidth = messageView.widthAnchor.constraint(lessThanOrEqualTo: messagesStackView.widthAnchor, multiplier: 0.85)
            maxWidth.isActive = true

            if text.count > 80 {
                let minWidth = messageView.widthAnchor.constraint(greaterThanOrEqualTo: messagesStackView.widthAnchor, multiplier: 0.55)
                minWidth.isActive = true
            }
        } else {
            let fullWidth = messageView.widthAnchor.constraint(equalTo: messagesStackView.widthAnchor, constant: -32)
            fullWidth.isActive = true
        }

        // Scroll to bottom
        DispatchQueue.main.async { [weak self] in
            self?.performMessageLayoutAndDisplayUpdate(scrollToBottom: true)
        }
    }

    private func showThinkingIndicator() {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        thinkingIndicator = spinner

        let label = NSTextField(labelWithString: "Analyzing...")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        container.addArrangedSubview(spinner)
        container.addArrangedSubview(label)
        container.identifier = NSUserInterfaceItemIdentifier("thinkingIndicator")

        messagesStackView.addArrangedSubview(container)

        // Scroll to bottom
        DispatchQueue.main.async { [weak self] in
            self?.performMessageLayoutAndDisplayUpdate(scrollToBottom: true)
        }
    }

    private func hideThinkingIndicator() {
        let indicatorId = NSUserInterfaceItemIdentifier("thinkingIndicator")
        for view in messagesStackView.arrangedSubviews {
            if view.identifier == indicatorId {
                messagesStackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        thinkingIndicator?.stopAnimation(nil)
        thinkingIndicator = nil
        updateMessageDocumentHeight()
    }

    /// Updates the label text next to the thinking spinner.
    private func updateThinkingLabel(_ text: String) {
        let indicatorId = NSUserInterfaceItemIdentifier("thinkingIndicator")
        for view in messagesStackView.arrangedSubviews {
            if view.identifier == indicatorId, let stack = view as? NSStackView {
                for subview in stack.arrangedSubviews {
                    if let label = subview as? NSTextField, subview !== thinkingIndicator {
                        label.stringValue = text
                        break
                    }
                }
            }
        }
    }

    // MARK: - Suggested Queries

    private func refreshSuggestedQueries() {
        // Remove existing
        for view in suggestedQueriesContainer.arrangedSubviews {
            suggestedQueriesContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let queries = service.suggestedQueries()
        if queries.isEmpty { return }

        let titleLabel = NSTextField(labelWithString: "Suggested Questions")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        suggestedQueriesContainer.addArrangedSubview(titleLabel)

        for query in queries {
            let button = NSButton()
            button.title = query.title
            button.bezelStyle = .accessoryBarAction
            button.font = .systemFont(ofSize: 12)
            button.target = self
            button.action = #selector(suggestedQueryTapped(_:))
            button.toolTip = query.query
            // Store the full query in the identifier
            button.identifier = NSUserInterfaceItemIdentifier(query.query)

            if let symbolImage = NSImage(systemSymbolName: query.icon, accessibilityDescription: nil) {
                button.image = symbolImage
                button.imagePosition = .imageLeading
            }

            suggestedQueriesContainer.addArrangedSubview(button)
        }
    }

    // MARK: - Actions

    @objc private func sendMessage() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !service.isProcessing else { return }

        inputField.stringValue = ""

        // Hide suggested queries after first message
        suggestedQueriesContainer.isHidden = true

        // Remove welcome message on first real message
        if messagesStackView.arrangedSubviews.count == 1,
           let firstView = messagesStackView.arrangedSubviews.first as? AIMessageBubbleView,
           firstView.isWelcome {
            messagesStackView.removeArrangedSubview(firstView)
            firstView.removeFromSuperview()
        }

        addMessageView(text: text, isUser: true)
        showThinkingIndicator()
        statusLabel.stringValue = "Thinking..."
        sendButton.isEnabled = false
        inputField.isEnabled = false

        // Wire up status updates for tool execution feedback
        service.onStatusUpdate = { [weak self] status in
            self?.statusLabel.stringValue = status
            self?.updateThinkingLabel(status)
        }

        Task { [weak self] in
            guard let self else { return }
            let response = await service.sendMessage(text)
            logger.info("AI panel received response chars=\(response.count)")
            let responseToDisplay: String
            if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let fallback = service.messages.reversed().first(where: {
                   $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               })?.content {
                logger.warning("AI panel response was empty; using last assistant message chars=\(fallback.count)")
                responseToDisplay = fallback
            } else if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let fallback = "The AI request completed without a displayable response. Please retry, narrow the query, or switch providers in Settings > AI Services."
                logger.error("AI panel response was empty with no fallback assistant text")
                responseToDisplay = fallback
            } else {
                responseToDisplay = response
            }

            // Use GCD main queue to ensure UI updates execute reliably;
            // the cooperative executor may not drain during AppKit layout cycles.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.service.onStatusUpdate = nil
                    self.hideThinkingIndicator()
                    self.addMessageView(text: responseToDisplay, isUser: false)
                    self.statusLabel.stringValue = ""
                    self.sendButton.isEnabled = true
                    self.inputField.isEnabled = true
                    self.view.window?.makeFirstResponder(self.inputField)
                    self.performMessageLayoutAndDisplayUpdate(scrollToBottom: true)
                }
            }
        }
    }

    @objc private func clearConversation() {
        service.clearConversation()

        // Remove all message views
        for view in messagesStackView.arrangedSubviews {
            messagesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        addWelcomeMessage()
        performMessageLayoutAndDisplayUpdate(scrollToBottom: true)
        suggestedQueriesContainer.isHidden = false
        refreshSuggestedQueries()
        statusLabel.stringValue = ""
    }

    @objc private func suggestedQueryTapped(_ sender: NSButton) {
        guard let queryId = sender.identifier?.rawValue else { return }
        inputField.stringValue = queryId
        sendMessage()
    }
}

// MARK: - NSTextFieldDelegate

extension AIAssistantViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            sendMessage()
            return true
        }
        return false
    }
}

// MARK: - AIMessageBubbleView

/// A chat bubble view for displaying a single message.
@MainActor
final class AIMessageBubbleView: NSView {
    let isWelcome: Bool
    private var rawText: String = ""
    private var copyButton: NSButton?
    private weak var textLabel: NSTextField?
    private var lastPreferredTextWidth: CGFloat = 0

    init(text: String, isUser: Bool, isWelcome: Bool = false) {
        self.isWelcome = isWelcome
        self.rawText = text
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        setup(text: text, isUser: isUser, isWelcome: isWelcome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup(text: String, isUser: Bool, isWelcome: Bool) {
        layer?.cornerRadius = 12

        if isUser {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else if isWelcome {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }

        let label = NSTextField(wrappingLabelWithString: "")
        label.isEditable = false
        label.isSelectable = true
        label.drawsBackground = false
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
            cell.usesSingleLineMode = false
            cell.lineBreakMode = .byWordWrapping
        }

        // Apply markdown-like formatting
        let attributedString = formatMessage(text, isUser: isUser)
        label.attributedStringValue = attributedString
        textLabel = label

        addSubview(label)

        // Add copy button for AI responses (not user messages, not welcome)
        if !isUser && !isWelcome {
            let btn = NSButton()
            btn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            btn.bezelStyle = .toolbar
            btn.isBordered = false
            btn.imageScaling = .scaleProportionallyDown
            btn.toolTip = "Copy response"
            btn.target = self
            btn.action = #selector(copyText)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.alphaValue = 0.4
            addSubview(btn)
            copyButton = btn

            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                btn.widthAnchor.constraint(equalToConstant: 20),
                btn.heightAnchor.constraint(equalToConstant: 20),
            ])
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    override func layout() {
        super.layout()
        if let label = textLabel {
            let availableWidth = max(0, bounds.width - 24)
            if availableWidth > 0 && abs(lastPreferredTextWidth - availableWidth) > 0.5 {
                lastPreferredTextWidth = availableWidth
                label.preferredMaxLayoutWidth = availableWidth
                label.invalidateIntrinsicContentSize()
                invalidateIntrinsicContentSize()
            }
        }
    }

    /// Applies basic formatting to message text.
    private func formatMessage(_ text: String, isUser: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let color = NSColor.labelColor

        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 6

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]

        // Simple markdown processing
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            let lineStr = String(line)

            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
            }

            // Headers (## or #)
            if lineStr.hasPrefix("## ") {
                let headerText = String(lineStr.dropFirst(3))
                let headerFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
                result.append(NSAttributedString(string: headerText, attributes: [
                    .font: headerFont,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]))
                continue
            }
            if lineStr.hasPrefix("# ") {
                let headerText = String(lineStr.dropFirst(2))
                let headerFont = NSFont.systemFont(ofSize: 15, weight: .bold)
                result.append(NSAttributedString(string: headerText, attributes: [
                    .font: headerFont,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]))
                continue
            }

            // Bullet points
            if lineStr.hasPrefix("- ") {
                let bulletText = "\u{2022} " + String(lineStr.dropFirst(2))
                result.append(processBoldAndCode(bulletText, defaultAttrs: defaultAttrs, boldFont: boldFont, font: font))
                continue
            }

            // Regular text with bold processing
            result.append(processBoldAndCode(lineStr, defaultAttrs: defaultAttrs, boldFont: boldFont, font: font))
        }

        return result
    }

    /// Processes **bold** and `code` markers within a line.
    private func processBoldAndCode(
        _ text: String,
        defaultAttrs: [NSAttributedString.Key: Any],
        boldFont: NSFont,
        font: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Look for **bold**
            if let boldStart = remaining.range(of: "**") {
                // Add text before bold
                let before = String(remaining[remaining.startIndex..<boldStart.lowerBound])
                if !before.isEmpty {
                    result.append(NSAttributedString(string: before, attributes: defaultAttrs))
                }

                let afterBold = remaining[boldStart.upperBound...]
                if let boldEnd = afterBold.range(of: "**") {
                    let boldText = String(afterBold[afterBold.startIndex..<boldEnd.lowerBound])
                    var attrs = defaultAttrs
                    attrs[.font] = boldFont
                    result.append(NSAttributedString(string: boldText, attributes: attrs))
                    remaining = afterBold[boldEnd.upperBound...]
                } else {
                    // No closing **, treat as regular text
                    result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                    break
                }
            } else if let codeStart = remaining.range(of: "`") {
                // Add text before code
                let before = String(remaining[remaining.startIndex..<codeStart.lowerBound])
                if !before.isEmpty {
                    result.append(NSAttributedString(string: before, attributes: defaultAttrs))
                }

                let afterCode = remaining[codeStart.upperBound...]
                if let codeEnd = afterCode.range(of: "`") {
                    let codeText = String(afterCode[afterCode.startIndex..<codeEnd.lowerBound])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    var attrs = defaultAttrs
                    attrs[.font] = codeFont
                    attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                    result.append(NSAttributedString(string: codeText, attributes: attrs))
                    remaining = afterCode[codeEnd.upperBound...]
                } else {
                    result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                    break
                }
            } else {
                result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                break
            }
        }

        return result
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)

        // Briefly show checkmark icon for feedback
        copyButton?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        if copyButton != nil {
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            )
            addTrackingArea(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        copyButton?.animator().alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        copyButton?.animator().alphaValue = 0.4
    }
}
