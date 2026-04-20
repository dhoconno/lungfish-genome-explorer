// AssemblyActionBar.swift - Bottom action surface for assembly contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class AssemblyActionBar: NSView {
    let blastButton = NSButton(title: "BLAST Selected", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy FASTA", target: nil, action: nil)
    let exportButton = NSButton(title: "Export FASTA", target: nil, action: nil)
    let bundleButton = NSButton(title: "Create Bundle", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "")

    var onBlast: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onBundle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-action-bar")

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [blastButton, copyButton, exportButton, bundleButton, spacer, infoLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        configure(button: blastButton, identifier: "assembly-result-action-blast", label: "BLAST selected contigs", action: #selector(blastTapped))
        configure(button: copyButton, identifier: "assembly-result-action-copy-fasta", label: "Copy selected contigs as FASTA", action: #selector(copyTapped))
        configure(button: exportButton, identifier: "assembly-result-action-export-fasta", label: "Export selected contigs as FASTA", action: #selector(exportTapped))
        configure(button: bundleButton, identifier: "assembly-result-action-create-bundle", label: "Create bundle from selected contigs", action: #selector(bundleTapped))

        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        setSelectionCount(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelectionCount(_ count: Int) {
        let hasSelection = count > 0
        blastButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
        exportButton.isEnabled = hasSelection
        bundleButton.isEnabled = hasSelection
        infoLabel.stringValue = hasSelection ? "\(count) contig\(count == 1 ? "" : "s") selected" : "Select contigs to materialize"
    }

    private func configure(button: NSButton, identifier: String, label: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
    }

    @objc private func blastTapped() { onBlast?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func exportTapped() { onExport?() }
    @objc private func bundleTapped() { onBundle?() }
}
