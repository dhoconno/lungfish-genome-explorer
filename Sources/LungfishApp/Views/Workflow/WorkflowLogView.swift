// WorkflowLogView.swift - Log viewer for workflow output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import os.log
import LungfishCore

/// Logger for workflow log view operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowLogView")

// MARK: - WorkflowLogView

/// A text view optimized for displaying workflow log output.
///
/// `WorkflowLogView` provides a terminal-like log display with:
/// - Monospace font (SF Mono, 11pt)
/// - ANSI color code parsing
/// - Auto-scroll to bottom (toggleable)
/// - Optional timestamp prefixes
/// - Dark/Light mode support
/// - Copy selection support
///
/// ## Example
///
/// ```swift
/// let logView = WorkflowLogView()
/// scrollView.documentView = logView
///
/// // Append log messages
/// logView.appendLog("Starting workflow...", level: .info)
/// logView.appendLog("Warning: Low disk space", level: .warning)
/// logView.appendLog("Error: File not found", level: .error)
///
/// // Get log content
/// let content = logView.string
/// ```
@MainActor
public class WorkflowLogView: NSTextView {

    // MARK: - Properties

    /// Whether to automatically scroll to the bottom when new content is added
    public var autoScrollEnabled: Bool = true

    /// Whether to prefix each log line with a timestamp
    public var showTimestamps: Bool = false

    /// Date formatter for timestamps
    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// ANSI color code parser
    private let ansiParser = ANSIColorParser()

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    // MARK: - Setup

    private func setupView() {
        // Font: SF Mono, 11pt
        font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Text container configuration
        textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer?.widthTracksTextView = false
        isHorizontallyResizable = true

        // Appearance
        isEditable = false
        isSelectable = true
        allowsUndo = false
        isRichText = true
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false

        // Colors
        updateColors()

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Workflow output log")
        setAccessibilityIdentifier("workflow-log-view")

        // Register for appearance changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange(_:)),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        logger.info("setupView: WorkflowLogView setup complete")
    }

    private func updateColors() {
        // Use appropriate colors for current appearance
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1.0)
            insertionPointColor = .white
        } else {
            backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1.0)
            insertionPointColor = .black
        }
    }

    @objc private func appearanceDidChange(_ notification: Notification) {
        updateColors()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Appends a log message with the specified level.
    ///
    /// - Parameters:
    ///   - message: The log message to append
    ///   - level: The log level (affects coloring)
    public func appendLog(_ message: String, level: LogLevel = .info) {
        let attributedMessage = formatLogMessage(message, level: level)
        appendAttributedString(attributedMessage)
    }

    /// Appends raw text with ANSI color code parsing.
    ///
    /// - Parameter text: The text to append (may contain ANSI codes)
    public func appendRawOutput(_ text: String) {
        let attributedText = ansiParser.parse(text, defaultColor: defaultTextColor)
        appendAttributedString(attributedText)
    }

    /// Clears all log content.
    public func clear() {
        textStorage?.setAttributedString(NSAttributedString())
        logger.debug("clear: Log cleared")
    }

    /// Scrolls to the bottom of the log.
    public func scrollToBottom() {
        guard let textStorage = textStorage else { return }
        let endRange = NSRange(location: textStorage.length, length: 0)
        scrollRangeToVisible(endRange)
    }

    /// Scrolls to the top of the log.
    public func scrollToTop() {
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Copies the current selection to the clipboard.
    public func copySelection() {
        if selectedRange().length > 0 {
            copy(nil)
        }
    }

    /// Copies all log content to the clipboard.
    public func copyAll() {
        selectAll(nil)
        copy(nil)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: - Private Helpers

    private var defaultTextColor: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.9, alpha: 1.0)
            : NSColor(calibratedWhite: 0.1, alpha: 1.0)
    }

    private func formatLogMessage(_ message: String, level: LogLevel) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Timestamp prefix
        if showTimestamps {
            let timestamp = "[\(timestampFormatter.string(from: Date()))] "
            let timestampAttrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            result.append(NSAttributedString(string: timestamp, attributes: timestampAttrs))
        }

        // Level indicator (colored)
        let levelPrefix: String
        switch level {
        case .debug:
            levelPrefix = "[DEBUG] "
        case .info:
            levelPrefix = ""
        case .warning:
            levelPrefix = "[WARN] "
        case .error:
            levelPrefix = "[ERROR] "
        }

        if !levelPrefix.isEmpty {
            let levelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: level.color,
            ]
            result.append(NSAttributedString(string: levelPrefix, attributes: levelAttrs))
        }

        // Message text (with ANSI parsing)
        let parsedMessage = ansiParser.parse(message, defaultColor: level == .info ? defaultTextColor : level.color)
        result.append(parsedMessage)

        // Newline
        let newlineAttrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: defaultTextColor,
        ]
        result.append(NSAttributedString(string: "\n", attributes: newlineAttrs))

        return result
    }

    private func appendAttributedString(_ attrString: NSAttributedString) {
        guard let textStorage = textStorage else { return }

        // Append the string
        textStorage.append(attrString)

        // Auto-scroll if enabled
        if autoScrollEnabled {
            scrollToBottom()
        }
    }

    // MARK: - Context Menu

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(copyItem)

        let copyAllItem = NSMenuItem(title: "Copy All", action: #selector(copyAllAction(_:)), keyEquivalent: "")
        menu.addItem(copyAllItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        menu.addItem(selectAllItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearAction(_:)), keyEquivalent: "")
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let autoScrollItem = NSMenuItem(
            title: "Auto-Scroll",
            action: #selector(toggleAutoScroll(_:)),
            keyEquivalent: ""
        )
        autoScrollItem.state = autoScrollEnabled ? .on : .off
        menu.addItem(autoScrollItem)

        let timestampItem = NSMenuItem(
            title: "Show Timestamps",
            action: #selector(toggleTimestamps(_:)),
            keyEquivalent: ""
        )
        timestampItem.state = showTimestamps ? .on : .off
        menu.addItem(timestampItem)

        return menu
    }

    @objc private func copyAllAction(_ sender: Any?) {
        copyAll()
    }

    @objc private func clearAction(_ sender: Any?) {
        clear()
    }

    @objc private func toggleAutoScroll(_ sender: NSMenuItem) {
        autoScrollEnabled.toggle()
        sender.state = autoScrollEnabled ? .on : .off
        logger.debug("toggleAutoScroll: autoScrollEnabled = \(self.autoScrollEnabled)")
    }

    @objc private func toggleTimestamps(_ sender: NSMenuItem) {
        showTimestamps.toggle()
        sender.state = showTimestamps ? .on : .off
        logger.debug("toggleTimestamps: showTimestamps = \(self.showTimestamps)")
    }
}

// MARK: - ANSIColorParser

/// Parser for ANSI escape codes in terminal output.
private class ANSIColorParser {

    /// ANSI escape code regex pattern
    private let ansiPattern = try! NSRegularExpression(
        pattern: "\\x1b\\[([0-9;]*)m",
        options: []
    )

    /// Standard ANSI colors (dark variants)
    private let standardColors: [NSColor] = [
        .black,                                             // 0: Black
        NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 1.0),  // 1: Red
        NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.0, alpha: 1.0),  // 2: Green
        NSColor(calibratedRed: 0.8, green: 0.8, blue: 0.0, alpha: 1.0),  // 3: Yellow
        NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.8, alpha: 1.0),  // 4: Blue
        NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.8, alpha: 1.0),  // 5: Magenta
        NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.8, alpha: 1.0),  // 6: Cyan
        NSColor(calibratedWhite: 0.75, alpha: 1.0),                       // 7: White
    ]

    /// Bright ANSI colors
    private let brightColors: [NSColor] = [
        NSColor(calibratedWhite: 0.5, alpha: 1.0),                        // 0: Bright Black (Gray)
        NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),  // 1: Bright Red
        NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0),  // 2: Bright Green
        NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.0, alpha: 1.0),  // 3: Bright Yellow
        NSColor(calibratedRed: 0.0, green: 0.0, blue: 1.0, alpha: 1.0),  // 4: Bright Blue
        NSColor(calibratedRed: 1.0, green: 0.0, blue: 1.0, alpha: 1.0),  // 5: Bright Magenta
        NSColor(calibratedRed: 0.0, green: 1.0, blue: 1.0, alpha: 1.0),  // 6: Bright Cyan
        .white,                                                            // 7: Bright White
    ]

    /// Parses text with ANSI escape codes and returns attributed string.
    ///
    /// - Parameters:
    ///   - text: The text to parse
    ///   - defaultColor: The default text color
    /// - Returns: An attributed string with appropriate colors
    func parse(_ text: String, defaultColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor = defaultColor
        var currentBold = false
        var lastEnd = text.startIndex

        let nsText = text as NSString
        let matches = ansiPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // Add text before this escape code
            let matchStart = text.index(text.startIndex, offsetBy: match.range.location)
            if lastEnd < matchStart {
                let plainText = String(text[lastEnd..<matchStart])
                let attrs = makeAttributes(color: currentColor, bold: currentBold)
                result.append(NSAttributedString(string: plainText, attributes: attrs))
            }

            // Parse the escape code
            if match.numberOfRanges > 1 {
                let codeRange = Range(match.range(at: 1), in: text)!
                let codes = String(text[codeRange]).split(separator: ";").compactMap { Int($0) }

                for code in codes {
                    switch code {
                    case 0:
                        // Reset
                        currentColor = defaultColor
                        currentBold = false
                    case 1:
                        // Bold
                        currentBold = true
                    case 22:
                        // Normal (not bold)
                        currentBold = false
                    case 30...37:
                        // Standard foreground colors
                        currentColor = currentBold ? brightColors[code - 30] : standardColors[code - 30]
                    case 39:
                        // Default foreground color
                        currentColor = defaultColor
                    case 90...97:
                        // Bright foreground colors
                        currentColor = brightColors[code - 90]
                    default:
                        break
                    }
                }
            }

            // Move past this escape code
            lastEnd = text.index(text.startIndex, offsetBy: match.range.location + match.range.length)
        }

        // Add any remaining text
        if lastEnd < text.endIndex {
            let remainingText = String(text[lastEnd...])
            let attrs = makeAttributes(color: currentColor, bold: currentBold)
            result.append(NSAttributedString(string: remainingText, attributes: attrs))
        }

        return result
    }

    private func makeAttributes(color: NSColor, bold: Bool) -> [NSAttributedString.Key: Any] {
        let weight: NSFont.Weight = bold ? .bold : .regular
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: weight),
            .foregroundColor: color,
        ]
    }
}
