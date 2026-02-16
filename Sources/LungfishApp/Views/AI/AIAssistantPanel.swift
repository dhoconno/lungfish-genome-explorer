// AIAssistantPanel.swift - Floating AI assistant panel with chat interface
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os

private let logger = Logger(subsystem: "com.lungfish", category: "AIAssistantPanel")

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
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "AI Assistant"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 400)
        panel.setFrameAutosaveName("AIAssistantPanel")

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
        refreshSuggestedQueries()
        addWelcomeMessage()
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

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        messagesStackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(messagesStackView)

        NSLayoutConstraint.activate([
            messagesStackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            messagesStackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            messagesStackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            messagesStackView.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            messagesStackView.widthAnchor.constraint(equalTo: documentView.widthAnchor),
        ])

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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

    // MARK: - Messages

    private func addWelcomeMessage() {
        let welcome = """
        Welcome! I can help you explore your genomic data. Try asking questions like:

        - "What genes are in my data?"
        - "Show me a summary of the variants"
        - "What does the gene BRCA1 do?"
        - "Are there any variants in immune-related genes?"

        Configure your API key in **Settings > AI Services** to get started.
        """
        addMessageView(text: welcome, isUser: false, isWelcome: true)
    }

    private func addMessageView(text: String, isUser: Bool, isWelcome: Bool = false) {
        let messageView = AIMessageBubbleView(text: text, isUser: isUser, isWelcome: isWelcome)
        messagesStackView.addArrangedSubview(messageView)

        // Set width constraint
        let widthAnchor: NSLayoutConstraint
        if isUser {
            widthAnchor = messageView.widthAnchor.constraint(lessThanOrEqualTo: messagesStackView.widthAnchor, multiplier: 0.85)
            messageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            widthAnchor = messageView.widthAnchor.constraint(equalTo: messagesStackView.widthAnchor, constant: -32)
        }
        widthAnchor.isActive = true

        // Scroll to bottom
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.scrollView,
                  let documentView = scrollView.documentView else { return }
            let maxY = documentView.frame.maxY - scrollView.contentView.bounds.height
            if maxY > 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            }
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
            guard let scrollView = self?.scrollView,
                  let documentView = scrollView.documentView else { return }
            let maxY = documentView.frame.maxY - scrollView.contentView.bounds.height
            if maxY > 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            }
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

        Task { [weak self] in
            guard let self else { return }
            let response = await service.sendMessage(text)

            hideThinkingIndicator()
            addMessageView(text: response, isUser: false)
            statusLabel.stringValue = ""
            sendButton.isEnabled = true
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

    init(text: String, isUser: Bool, isWelcome: Bool = false) {
        self.isWelcome = isWelcome
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        setup(text: text, isUser: isUser, isWelcome: isWelcome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup(text: String, isUser: Bool, isWelcome: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 12

        if isUser {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else if isWelcome {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false

        // Apply markdown-like formatting
        let attributedString = formatMessage(text, isUser: isUser)
        textView.textStorage?.setAttributedString(attributedString)

        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
}
