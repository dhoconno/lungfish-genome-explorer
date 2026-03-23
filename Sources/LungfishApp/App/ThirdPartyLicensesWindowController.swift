// ThirdPartyLicensesWindowController.swift - Third-party license viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

/// Displays the full text of third-party licenses for all embedded tools.
///
/// Opened from the About window's "Third-Party Licenses" link.
/// Follows macOS HIG: uses a standard document-style window with a monospaced
/// text view showing the complete THIRD-PARTY-NOTICES content.
@MainActor
final class ThirdPartyLicensesWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Third-Party Licenses"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.minSize = NSSize(width: 400, height: 300)
        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let window, let contentView = window.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let licenseText = Self.loadLicenseText()
        let attributed = NSAttributedString(
            string: licenseText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        textView.textStorage?.setAttributedString(attributed)
    }

    /// Loads the THIRD-PARTY-NOTICES text. Tries the app bundle resource first,
    /// then falls back to generating it dynamically from the tool manifest.
    private static func loadLicenseText() -> String {
        // Try loading from the app's resource bundle (copied by build-app.sh)
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        // Fallback: generate a summary from the tool manifest
        guard let manifest = NativeToolRunner.toolManifest else {
            return "Third-party license information is not available."
        }

        var lines = [
            "Lungfish Genome Explorer \u{2014} Third-Party Software",
            String(repeating: "=", count: 50),
            "",
        ]

        for tool in manifest.tools {
            lines.append("\(tool.displayName) \(tool.version)")
            lines.append("License: \(tool.license)")
            lines.append("Source: \(tool.sourceUrl)")
            lines.append(tool.copyright)
            if let notes = tool.notes {
                lines.append("Note: \(notes)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    override func showWindow(_ sender: Any?) {
        window?.center()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}
