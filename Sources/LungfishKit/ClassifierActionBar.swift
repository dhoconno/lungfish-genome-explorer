// ClassifierActionBar.swift — Unified bottom action bar for all classifier result views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Shared bottom action bar for all classifier result views.
///
/// Provides core buttons (Verify with BLAST, Export, Extract Reads, Provenance) present for all classifiers,
/// plus a slot for classifier-specific custom buttons inserted after Extract Reads and before the
/// center info label. The Extract and BLAST titles are the shared row command titles, so the button and
/// the menu item cannot drift (UX-3E-LABELS, approved as O86).
///
/// Layout (36pt height):
/// ```
/// | 8pt | [Verify with BLAST…] 6pt [Export] 6pt [Extract Reads…] 6pt [Custom...] | flex info text | [Provenance i] | 12pt |
/// ```
@MainActor
public final class ClassifierActionBar: NSView {

    // MARK: - Core Buttons

    public let blastButton: NSButton = {
        let btn = NSButton()
        btn.title = ResultRowCommand.blastVerify.title
        // The title names the button, so VoiceOver reads it once.
        btn.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isEnabled = false
        return btn
    }()

    public let exportButton: NSButton = {
        let btn = NSButton()
        btn.title = "Export"
        btn.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    public let extractButton: NSButton = {
        let btn = NSButton()
        btn.title = ResultRowCommand.extractReads.title
        btn.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isEnabled = false
        return btn
    }()

    public let infoLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    public let provenanceButton: NSButton = {
        let btn = NSButton()
        // VoiceOver reads the name of the menu twin, Show Provenance….
        btn.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Show Provenance")
        btn.setAccessibilityLabel("Show Provenance")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageOnly
        btn.controlSize = .small
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    // MARK: - Callbacks

    public var onBlastVerify: (() -> Void)?
    public var onExport: (() -> Void)?
    public var onExtractFASTQ: (() -> Void)?
    public var onProvenance: ((NSButton) -> Void)?

    // MARK: - Custom Buttons

    private var customButtons: [NSButton] = []
    private var layoutConstraints: [NSLayoutConstraint] = []

    // MARK: - Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Public API

    /// Insert a custom button after Export, before the info label.
    public func addCustomButton(_ button: NSButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        customButtons.append(button)
        addSubview(button)
        rebuildLayout()
    }

    /// Update the center info label text.
    public func updateInfoText(_ text: String) {
        infoLabel.stringValue = text
    }

    /// Enable/disable BLAST button, with an optional reason shown when disabled.
    public func setBlastEnabled(_ enabled: Bool, reason: String? = nil) {
        blastButton.isEnabled = enabled
        Self.applyHelp(LungfishHelpContent.classifierBlastVerify, to: blastButton, reason: enabled ? nil : reason)
    }

    /// Enable/disable the Extract Reads button, with an optional reason shown when disabled.
    public func setExtractEnabled(_ enabled: Bool, reason: String? = nil) {
        extractButton.isEnabled = enabled
        Self.applyHelp(LungfishHelpContent.classifierExtractFASTQ, to: extractButton, reason: enabled ? nil : reason)
    }

    /// A greyed button's reason leads its tooltip and its VoiceOver hint, then the button's own help. A ruled reason
    /// is a sentence with its own period, so the join adds a space. A reason with no end mark gets a period first
    /// (UX-3E-LABELS D11).
    private static func applyHelp(_ help: LungfishHelpContent.HelpItem, to button: NSButton, reason: String?) {
        guard let reason = reason?.trimmingCharacters(in: .whitespaces), !reason.isEmpty else {
            button.applyLungfishHelp(help)
            return
        }
        let sentence = reason.last.map { ".!?".contains($0) } == true ? reason : reason + "."
        button.toolTip = "\(sentence) \(help.summary)"
        button.setAccessibilityHelp("\(sentence) \(help.detail ?? help.summary)")
    }

    /// Enable/disable the Export button. A disabled button carries `reason` as its help tag word for word, and
    /// enabling restores the shared result-export help (Phase 2.13 lane 13.40, UX ruling W3).
    public func setExportEnabled(_ enabled: Bool, reason: String? = nil) {
        exportButton.isEnabled = enabled
        if !enabled, let reason, !reason.isEmpty {
            exportButton.toolTip = reason
            exportButton.setAccessibilityHelp(reason)
        } else {
            exportButton.applyLungfishHelp(LungfishHelpContent.resultExport)
        }
    }

    // MARK: - Setup

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        // Separator at top
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Core subviews
        addSubview(blastButton)
        addSubview(exportButton)
        addSubview(extractButton)
        addSubview(infoLabel)
        addSubview(provenanceButton)

        // Actions
        blastButton.target = self
        blastButton.action = #selector(blastTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        extractButton.target = self
        extractButton.action = #selector(extractTapped)
        provenanceButton.target = self
        provenanceButton.action = #selector(provenanceTapped)
        blastButton.applyLungfishHelp(LungfishHelpContent.classifierBlastVerify)
        exportButton.applyLungfishHelp(LungfishHelpContent.resultExport)
        extractButton.applyLungfishHelp(LungfishHelpContent.classifierExtractFASTQ)
        provenanceButton.applyLungfishHelp(LungfishHelpContent.resultProvenance)

        // Height + separator
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        rebuildLayout()
    }

    private func rebuildLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        let allLeftButtons: [NSButton] = [blastButton, exportButton, extractButton] + customButtons
        var constraints: [NSLayoutConstraint] = []

        // First button: 8pt from leading
        constraints.append(allLeftButtons[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8))
        constraints.append(allLeftButtons[0].centerYAnchor.constraint(equalTo: centerYAnchor))

        // Chain remaining buttons
        for i in 1..<allLeftButtons.count {
            constraints.append(allLeftButtons[i].leadingAnchor.constraint(equalTo: allLeftButtons[i - 1].trailingAnchor, constant: 6))
            constraints.append(allLeftButtons[i].centerYAnchor.constraint(equalTo: centerYAnchor))
        }

        // Info label: after last button
        let lastButton = allLeftButtons.last!
        constraints.append(infoLabel.leadingAnchor.constraint(equalTo: lastButton.trailingAnchor, constant: 12))
        constraints.append(infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor))

        // Provenance button: right side
        constraints.append(provenanceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12))
        constraints.append(provenanceButton.centerYAnchor.constraint(equalTo: centerYAnchor))

        // Info label trailing: must not overlap provenance
        constraints.append(infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: provenanceButton.leadingAnchor, constant: -12))

        layoutConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Actions

    @objc private func blastTapped(_ sender: NSButton) {
        onBlastVerify?()
    }

    @objc private func exportTapped(_ sender: NSButton) {
        onExport?()
    }

    @objc private func extractTapped(_ sender: NSButton) {
        onExtractFASTQ?()
    }

    @objc private func provenanceTapped(_ sender: NSButton) {
        onProvenance?(sender)
    }
}
