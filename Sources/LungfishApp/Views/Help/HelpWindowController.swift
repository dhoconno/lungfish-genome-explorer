// HelpWindowController.swift - In-app help documentation viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import os

private let logger = Logger(subsystem: "com.lungfish", category: "HelpWindow")

// MARK: - Help Topic

/// A single help documentation topic.
struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let icon: String
    let filename: String
    let helpAnchor: String
}

/// All available help topics in display order.
let helpTopics: [HelpTopic] = [
    HelpTopic(id: "index", title: "Welcome", icon: "house", filename: "index", helpAnchor: "index"),
    HelpTopic(id: "getting-started", title: "Getting Started", icon: "play.circle", filename: "getting-started", helpAnchor: "getting-started"),
    HelpTopic(id: "vcf-variants", title: "VCF Variants", icon: "chart.bar.doc.horizontal", filename: "vcf-variants", helpAnchor: "vcf-variants"),
    HelpTopic(id: "ai-assistant", title: "AI Assistant", icon: "sparkles", filename: "ai-assistant", helpAnchor: "ai-assistant"),
    HelpTopic(id: "settings", title: "Settings", icon: "gearshape", filename: "settings", helpAnchor: "settings"),
]

enum HelpBookIntegration {
    static let bookName = "Lungfish Genome Explorer Help"

    /// Opens the system Help Book for the given topic, returning true on success.
    @MainActor
    @discardableResult
    static func openTopic(_ topicID: String) -> Bool {
        guard let topic = helpTopics.first(where: { $0.id == topicID }) else { return false }
        guard hasBundledHelpBook() else {
            logger.warning("Help Book resources not found in app bundle")
            return false
        }

        NSHelpManager.shared.openHelpAnchor(topic.helpAnchor, inBook: bookName)
        return true
    }

    private static func hasBundledHelpBook() -> Bool {
        if Bundle.main.url(forResource: "Lungfish", withExtension: "help") != nil {
            return true
        }
        return Bundle.main.url(forResource: "Lungfish.help", withExtension: nil) != nil
    }
}

// MARK: - HelpWindowController

/// Manages the in-app help documentation window.
@MainActor
public final class HelpWindowController: NSWindowController {

    private var helpViewController: HelpViewController?

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Lungfish Genome Explorer Help"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        window.setFrameAutosaveName("LungfishHelpWindow")

        let vc = HelpViewController()
        super.init(window: window)
        self.helpViewController = vc
        window.contentViewController = vc
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the help window, creating it if necessary.
    public func showHelp() {
        guard let window else { return }
        if !window.isVisible && shouldCenterOnFirstShow(window: window) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows help for a specific topic by ID.
    public func showTopic(_ topicID: String) {
        showHelp()
        helpViewController?.selectTopic(topicID)
    }

    private func shouldCenterOnFirstShow(window: NSWindow) -> Bool {
        let autosaveName = window.frameAutosaveName
        guard !autosaveName.isEmpty else { return true }
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        return UserDefaults.standard.string(forKey: autosaveKey) == nil
    }
}

// MARK: - HelpViewController

/// View controller for the help documentation interface with sidebar navigation.
@MainActor
final class HelpViewController: NSViewController {

    private let sidebarTableView = NSTableView()
    private let contentScrollView = NSScrollView()
    private let contentTextView = NSTextView()
    private var selectedTopicIndex = 0
    private(set) var topicLoadCount = 0

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 540))
        self.view = container
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        loadTopic(helpTopics[0])
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Split view: sidebar | content
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar
        let sidebarScrollView = NSScrollView()
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autohidesScrollers = true

        sidebarTableView.headerView = nil
        sidebarTableView.rowHeight = 32
        sidebarTableView.selectionHighlightStyle = .regular
        sidebarTableView.delegate = self
        sidebarTableView.dataSource = self
        sidebarTableView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
        column.title = ""
        sidebarTableView.addTableColumn(column)

        sidebarScrollView.documentView = sidebarTableView

        // Content area
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false

        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.drawsBackground = false
        contentTextView.textContainerInset = NSSize(width: 24, height: 20)
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.autoresizingMask = [.width]

        contentScrollView.documentView = contentTextView

        // Add to split view
        splitView.addSubview(sidebarScrollView)
        splitView.addSubview(contentScrollView)
        splitView.setPosition(180, ofDividerAt: 0)

        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Set minimum widths
        sidebarScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        contentScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }

    // MARK: - Topic Loading

    func selectTopic(_ topicID: String) {
        guard let index = helpTopics.firstIndex(where: { $0.id == topicID }) else { return }
        if sidebarTableView.selectedRow == index {
            loadTopic(helpTopics[index])
            return
        }
        sidebarTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func loadTopic(_ topic: HelpTopic) {
        selectedTopicIndex = helpTopics.firstIndex(where: { $0.id == topic.id }) ?? 0
        topicLoadCount += 1

        guard let markdownText = loadMarkdownFile(topic.filename) else {
            let errorAttr = NSAttributedString(
                string: "Could not load help topic: \(topic.title)",
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            )
            contentTextView.textStorage?.setAttributedString(errorAttr)
            return
        }

        let rendered = renderMarkdown(markdownText)
        contentTextView.textStorage?.setAttributedString(rendered)
        contentTextView.scrollToBeginningOfDocument(nil)
    }

    private func loadMarkdownFile(_ name: String) -> String? {
        // Try SPM bundle first
        if let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Help") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // Try main bundle as fallback
        if let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Help") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        // Try flat resource lookup
        if let url = Bundle.module.url(forResource: name, withExtension: "md") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        logger.warning("Help file not found: \(name, privacy: .public).md")
        return nil
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension HelpViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        helpTopics.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let topic = helpTopics[row]

        let cellID = NSUserInterfaceItemIdentifier("TopicCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 13)
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = topic.title
        cell.imageView?.image = NSImage(systemSymbolName: topic.icon, accessibilityDescription: topic.title)
        cell.imageView?.contentTintColor = .secondaryLabelColor

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTableView.selectedRow
        guard row >= 0 && row < helpTopics.count else { return }
        loadTopic(helpTopics[row])
    }
}

// MARK: - Markdown Renderer

extension HelpViewController {

    /// Renders Markdown text into an NSAttributedString for display.
    func renderMarkdown(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 14)
        let boldFont = NSFont.boldSystemFont(ofSize: 14)
        let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        let h1Font = NSFont.systemFont(ofSize: 24, weight: .bold)
        let h2Font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let h3Font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let textColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 4
        bodyStyle.paragraphSpacing = 8

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacingBefore = 16
        headerStyle.paragraphSpacing = 8

        let listStyle = NSMutableParagraphStyle()
        listStyle.lineSpacing = 3
        listStyle.paragraphSpacing = 4
        listStyle.headIndent = 20
        listStyle.firstLineHeadIndent = 8

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: bodyStyle,
        ]

        var inCodeBlock = false
        var codeBlockLines: [String] = []

        let lines = markdown.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            // Code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    let codeText = codeBlockLines.joined(separator: "\n")
                    let codeStyle = NSMutableParagraphStyle()
                    codeStyle.lineSpacing = 2
                    codeStyle.paragraphSpacing = 8
                    let codeAttrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: textColor,
                        .backgroundColor: NSColor.quaternaryLabelColor,
                        .paragraphStyle: codeStyle,
                    ]
                    result.append(NSAttributedString(string: codeText + "\n", attributes: codeAttrs))
                    codeBlockLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            if lineIndex > 0 && !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
            }

            // Horizontal rule
            if line == "---" || line == "***" || line == "___" {
                let ruleStyle = NSMutableParagraphStyle()
                ruleStyle.paragraphSpacing = 12
                ruleStyle.paragraphSpacingBefore = 12
                ruleStyle.alignment = .center
                result.append(NSAttributedString(
                    string: "────────────────────────\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .paragraphStyle: ruleStyle,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                continue
            }

            // H1
            if line.hasPrefix("# ") {
                let text = String(line.dropFirst(2))
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: h1Font, .foregroundColor: textColor, .paragraphStyle: headerStyle,
                ]))
                continue
            }

            // H2
            if line.hasPrefix("## ") {
                let text = String(line.dropFirst(3))
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: h2Font, .foregroundColor: textColor, .paragraphStyle: headerStyle,
                ]))
                continue
            }

            // H3
            if line.hasPrefix("### ") {
                let text = String(line.dropFirst(4))
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: h3Font, .foregroundColor: textColor, .paragraphStyle: headerStyle,
                ]))
                continue
            }

            // Bullet lists
            if line.hasPrefix("- ") {
                let text = "\u{2022} " + String(line.dropFirst(2))
                let bulletAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: textColor, .paragraphStyle: listStyle,
                ]
                result.append(processInlineFormatting(text, defaultAttrs: bulletAttrs, boldFont: boldFont, italicFont: italicFont, codeFont: codeFont))
                result.append(NSAttributedString(string: "\n", attributes: bulletAttrs))
                continue
            }

            // Table rows (simple rendering)
            if line.hasPrefix("|") && line.hasSuffix("|") {
                // Skip separator rows
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                if trimmed.allSatisfy({ $0 == "-" || $0 == "|" || $0 == " " || $0 == ":" }) {
                    continue
                }
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let tableText = cells.joined(separator: "  |  ")
                let tableAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: textColor,
                    .paragraphStyle: bodyStyle,
                ]
                result.append(NSAttributedString(string: tableText + "\n", attributes: tableAttrs))
                continue
            }

            // Empty line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
                continue
            }

            // Regular paragraph with inline formatting
            result.append(processInlineFormatting(line, defaultAttrs: defaultAttrs, boldFont: boldFont, italicFont: italicFont, codeFont: codeFont))
            result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
        }

        return result
    }

    /// Processes **bold**, *italic*, and `code` markers within a line.
    private func processInlineFormatting(
        _ text: String,
        defaultAttrs: [NSAttributedString.Key: Any],
        boldFont: NSFont,
        italicFont: NSFont,
        codeFont: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            let boldStart = remaining.range(of: "**")
            let codeStart = remaining.range(of: "`")
            let italicStart = firstSingleAsterisk(in: remaining)

            var earliest: (kind: String, range: Range<Substring.Index>)?
            if let boldStart { earliest = ("bold", boldStart) }
            if let codeStart, earliest == nil || codeStart.lowerBound < earliest!.range.lowerBound {
                earliest = ("code", codeStart)
            }
            if let italicStart, earliest == nil || italicStart.lowerBound < earliest!.range.lowerBound {
                earliest = ("italic", italicStart)
            }

            guard let marker = earliest else {
                result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                break
            }

            let before = String(remaining[remaining.startIndex..<marker.range.lowerBound])
            if !before.isEmpty {
                result.append(NSAttributedString(string: before, attributes: defaultAttrs))
            }

            switch marker.kind {
            case "bold":
                let afterBold = remaining[marker.range.upperBound...]
                if let boldEnd = afterBold.range(of: "**") {
                    let boldText = String(afterBold[afterBold.startIndex..<boldEnd.lowerBound])
                    var attrs = defaultAttrs
                    attrs[.font] = boldFont
                    result.append(NSAttributedString(string: boldText, attributes: attrs))
                    remaining = afterBold[boldEnd.upperBound...]
                } else {
                    result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                    return result
                }
            case "code":
                let afterCode = remaining[marker.range.upperBound...]
                if let codeEnd = afterCode.range(of: "`") {
                    let codeText = String(afterCode[afterCode.startIndex..<codeEnd.lowerBound])
                    var attrs = defaultAttrs
                    attrs[.font] = codeFont
                    attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                    result.append(NSAttributedString(string: codeText, attributes: attrs))
                    remaining = afterCode[codeEnd.upperBound...]
                } else {
                    result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                    return result
                }
            default:
                let afterItalic = remaining[marker.range.upperBound...]
                if let italicEnd = firstSingleAsterisk(in: afterItalic) {
                    let italicText = String(afterItalic[afterItalic.startIndex..<italicEnd.lowerBound])
                    var attrs = defaultAttrs
                    attrs[.font] = italicFont
                    result.append(NSAttributedString(string: italicText, attributes: attrs))
                    remaining = afterItalic[italicEnd.upperBound...]
                } else {
                    result.append(NSAttributedString(string: String(remaining), attributes: defaultAttrs))
                    return result
                }
            }
        }

        return result
    }

    private func firstSingleAsterisk(in text: Substring) -> Range<Substring.Index>? {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "*" else {
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "*" {
                index = text.index(after: next)
                continue
            }
            return index..<next
        }
        return nil
    }
}
