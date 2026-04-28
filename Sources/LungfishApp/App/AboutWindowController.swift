// AboutWindowController.swift - Custom About Lungfish Genome Explorer window
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow

/// A custom About window following macOS HIG conventions.
///
/// Displays app identity, credits, funding acknowledgments, open-source
/// dependencies, data sources, and a disclaimer in a scrolling credits view.
@MainActor
final class AboutWindowController: NSWindowController {

    private var creditsTextView: NSTextView!

    private enum AccessibilityID {
        static let window = "about-window"
        static let root = "about-root"
        static let creditsScrollView = "about-credits-scroll-view"
        static let creditsTextView = "about-credits-text-view"
        static let licensesButton = "about-third-party-licenses-button"
        static let websiteButton = "about-lab-website-button"
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "About Lungfish Genome Explorer"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.window)
        window.isMovableByWindowBackground = true
        self.init(window: window)
        setupContent()
    }

    // MARK: - Layout

    private func setupContent() {
        guard let window, let contentView = window.contentView else { return }

        let container = NSView(frame: contentView.bounds)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier(AccessibilityID.root)
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Logo
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let logoURL = RuntimeResourceLocator.path("Images/about-logo.png", in: .app),
           let logo = NSImage(contentsOf: logoURL) {
            iconView.image = logo
        } else {
            iconView.image = NSApp.applicationIconImage
        }
        container.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "Lungfish Genome Explorer")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.textColor = .labelColor
        container.addSubview(nameLabel)

        // Tagline
        let taglineLabel = NSTextField(labelWithString: "Seeing the invisible. Informing action.")
        taglineLabel.translatesAutoresizingMaskIntoConstraints = false
        taglineLabel.font = .systemFont(ofSize: 12, weight: .regular)
        taglineLabel.alignment = .center
        taglineLabel.textColor = .secondaryLabelColor
        container.addSubview(taglineLabel)

        // Version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0-alpha.4"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.alignment = .center
        versionLabel.textColor = .tertiaryLabelColor
        container.addSubview(versionLabel)

        // Separator
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        container.addSubview(separator)

        // Scrolling credits
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier(AccessibilityID.creditsScrollView)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 8)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier(AccessibilityID.creditsTextView)
        scrollView.documentView = textView

        container.addSubview(scrollView)

        self.creditsTextView = textView

        // Copyright
        let copyrightLabel = NSTextField(labelWithString: "Copyright \u{00A9} 2024\u{2013}2026 Lungfish Contributors")
        copyrightLabel.translatesAutoresizingMaskIntoConstraints = false
        copyrightLabel.font = .systemFont(ofSize: 10)
        copyrightLabel.alignment = .center
        copyrightLabel.textColor = .tertiaryLabelColor
        container.addSubview(copyrightLabel)

        // Third-Party Licenses button
        let licensesButton = NSButton(title: "Third-Party Licenses", target: self, action: #selector(showThirdPartyLicenses(_:)))
        licensesButton.translatesAutoresizingMaskIntoConstraints = false
        licensesButton.bezelStyle = .inline
        licensesButton.isBordered = false
        licensesButton.font = .systemFont(ofSize: 10)
        licensesButton.contentTintColor = .linkColor
        licensesButton.setAccessibilityIdentifier(AccessibilityID.licensesButton)
        let licensesTitle = NSAttributedString(
            string: "Third-Party Licenses",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
        licensesButton.attributedTitle = licensesTitle
        container.addSubview(licensesButton)

        // Lab website link
        let linkButton = NSButton(title: "dho.pathology.wisc.edu", target: self, action: #selector(openLabWebsite(_:)))
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.font = .systemFont(ofSize: 10)
        linkButton.contentTintColor = .linkColor
        linkButton.setAccessibilityIdentifier(AccessibilityID.websiteButton)
        let linkTitle = NSAttributedString(
            string: "dho.pathology.wisc.edu",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
        linkButton.attributedTitle = linkTitle
        container.addSubview(linkButton)

        // Constraints
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            nameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            taglineLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            taglineLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: taglineLabel.bottomAnchor, constant: 4),
            versionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            separator.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: copyrightLabel.topAnchor, constant: -8),

            copyrightLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            copyrightLabel.bottomAnchor.constraint(equalTo: licensesButton.topAnchor, constant: -4),

            licensesButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            licensesButton.bottomAnchor.constraint(equalTo: linkButton.topAnchor, constant: -2),

            linkButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            linkButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        populateCredits()
    }

    // MARK: - Credits Content

    private func populateCredits() {
        let credits = NSMutableAttributedString()

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 4

        let sectionSpacing = NSMutableParagraphStyle()
        sectionSpacing.alignment = .center
        sectionSpacing.paragraphSpacingBefore = 14
        sectionSpacing.paragraphSpacing = 4

        let bodyStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]

        let secondaryStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]

        func appendHeading(_ text: String) {
            credits.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: sectionSpacing,
            ]))
        }

        func appendBody(_ text: String) {
            credits.append(NSAttributedString(string: text + "\n", attributes: bodyStyle))
        }

        func appendSecondary(_ text: String) {
            credits.append(NSAttributedString(string: text + "\n", attributes: secondaryStyle))
        }

        // Designed By
        appendHeading("Designed By")
        appendBody("Dave O\u{2019}Connor, Claude Code, and Codex")

        // Funding
        appendHeading("Funding")
        appendBody("Inkfish")
        appendBody("Wisconsin National Primate Research Center")
        appendSecondary("NIH/ORIP P51OD011106")
        appendBody("National Institute of Allergy and Infectious Diseases")
        appendSecondary("NIH/NIAID Contract 75N93021C00006")

        // Acknowledgments
        appendHeading("Acknowledgments")
        appendBody("Genomics Services Unit")
        appendSecondary("Wisconsin National Primate Research Center")
        appendSecondary("Early testing and feedback")

        // Bundled bootstrap tooling stays separate from the pinned managed pack.
        appendHeading("Bundled Bootstrap")

        let versionStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: centered,
        ]

        let linkStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.linkColor,
            .paragraphStyle: centered,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        for section in AboutAcknowledgements.currentSections() {
            appendHeading(section.title)
            for entry in section.entries {
                credits.append(NSAttributedString(string: entry.displayName, attributes: bodyStyle))
                if let detail = entry.detail {
                    credits.append(NSAttributedString(string: "  \(detail)\n", attributes: versionStyle))
                }
                if let secondaryDetail = entry.secondaryDetail {
                    credits.append(NSAttributedString(string: "  \(secondaryDetail)\n", attributes: secondaryStyle))
                }
                if let urlString = entry.sourceURL, let url = URL(string: urlString) {
                    var attrs = linkStyle
                    attrs[.link] = url
                    credits.append(NSAttributedString(string: "\(urlString)\n", attributes: attrs))
                }
            }
        }

        // Swift Libraries
        appendHeading("Swift Libraries")
        let swiftDeps: [(String, String, String?)] = [
            ("Swift Argument Parser", "Apache 2.0", "https://github.com/apple/swift-argument-parser"),
            ("Swift Collections", "Apache 2.0", "https://github.com/apple/swift-collections"),
            ("Swift Algorithms", "Apache 2.0", "https://github.com/apple/swift-algorithms"),
            ("Swift System", "Apache 2.0", "https://github.com/apple/swift-system"),
            ("Swift Async Algorithms", "Apache 2.0", "https://github.com/apple/swift-async-algorithms"),
            ("Apple Containerization", "Apache 2.0", "https://github.com/apple/containerization"),
        ]
        for (name, license, urlString) in swiftDeps {
            credits.append(NSAttributedString(string: name, attributes: bodyStyle))
            credits.append(NSAttributedString(string: "  \(license)\n", attributes: secondaryStyle))
            if let urlString, let url = URL(string: urlString) {
                var attrs = linkStyle
                attrs[.link] = url
                credits.append(NSAttributedString(string: "\(urlString)\n", attributes: attrs))
            }
        }

        // Data Sources
        appendHeading("Data Sources")
        appendBody("NCBI GenBank / Nucleotide / SRA")
        appendBody("European Nucleotide Archive (ENA)")
        appendBody("NCBI Datasets API")
        appendBody("Pathoplexus")

        // Disclaimer
        appendHeading("Disclaimer")

        let disclaimerParagraph = NSMutableParagraphStyle()
        disclaimerParagraph.alignment = .center
        disclaimerParagraph.paragraphSpacing = 4
        disclaimerParagraph.paragraphSpacingBefore = 2

        credits.append(NSAttributedString(
            string: "This software is provided \u{201C}as is,\u{201D} without warranty of any kind, "
                + "express or implied. The authors and contributors are not responsible "
                + "for any loss of data, damages, or other liability arising from the "
                + "use of this software. Use at your own risk.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: disclaimerParagraph,
            ]
        ))

        // Trailing space for scroll
        credits.append(NSAttributedString(string: "\n", attributes: bodyStyle))

        creditsTextView.textStorage?.setAttributedString(credits)
    }

    // MARK: - Actions

    private var licensesWindowController: ThirdPartyLicensesWindowController?

    @objc private func showThirdPartyLicenses(_ sender: Any?) {
        if licensesWindowController == nil {
            licensesWindowController = ThirdPartyLicensesWindowController()
        }
        licensesWindowController?.showWindow(sender)
    }

    @objc private func openLabWebsite(_ sender: Any?) {
        if let url = URL(string: "https://dho.pathology.wisc.edu") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Window Lifecycle

    override func showWindow(_ sender: Any?) {
        window?.center()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        // Reset scroll position to top
        creditsTextView.scrollToBeginningOfDocument(nil)
    }
}
