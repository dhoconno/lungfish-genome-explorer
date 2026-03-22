// TaxonomyActionBar.swift - Bottom action bar for taxonomy view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomyActionBar

/// A 36pt bottom bar showing selected taxon info and an Extract Sequences button.
///
/// ## Layout
///
/// ```
/// [  Escherichia coli -- 1,234 reads (12.3%)     |  [Extract Sequences]  ]
/// ```
///
/// The left side shows the currently selected taxon's name, read count, and
/// clade percentage. The right side has the Extract Sequences button, which
/// is disabled until a node is selected.
@MainActor
final class TaxonomyActionBar: NSView {

    // MARK: - Callback

    /// Called when the user clicks the Extract Sequences button.
    ///
    /// The boolean indicates whether child taxa should be included.
    var onExtractSequences: ((TaxonNode, Bool) -> Void)?

    // MARK: - State

    /// The currently selected taxon node.
    private var selectedNode: TaxonNode?

    /// Total reads for percentage calculation.
    private var totalReads: Int = 0

    // MARK: - Subviews

    private let infoLabel = NSTextField(labelWithString: "")
    private let extractButton = NSButton(
        title: "Extract Sequences",
        target: nil,
        action: nil
    )
    private let separator = NSBox()

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Separator at top
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Info label (left side)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = "Select a taxon to view details"
        addSubview(infoLabel)

        // Extract button (right side)
        extractButton.translatesAutoresizingMaskIntoConstraints = false
        extractButton.bezelStyle = .rounded
        extractButton.target = self
        extractButton.action = #selector(extractTapped(_:))
        extractButton.isEnabled = false
        extractButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(extractButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: extractButton.leadingAnchor, constant: -12
            ),

            extractButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            extractButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Taxonomy Action Bar")
    }

    // MARK: - Public API

    /// Configures the action bar with the total read count for the dataset.
    ///
    /// - Parameter totalReads: Total reads from the classification result.
    func configure(totalReads: Int) {
        self.totalReads = totalReads
    }

    /// Updates the action bar to reflect the given selected taxon.
    ///
    /// - Parameter node: The selected node, or `nil` to clear the selection.
    func updateSelection(_ node: TaxonNode?) {
        selectedNode = node

        if let node {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: node.readsClade)) ?? "\(node.readsClade)"

            let pct = totalReads > 0
                ? Double(node.readsClade) / Double(totalReads) * 100
                : 0
            let pctStr = String(format: "%.1f%%", pct)

            infoLabel.stringValue = "\(node.name) \u{2014} \(readStr) reads (\(pctStr))"
            infoLabel.textColor = .labelColor
            extractButton.isEnabled = true
        } else {
            infoLabel.stringValue = "Select a taxon to view details"
            infoLabel.textColor = .secondaryLabelColor
            extractButton.isEnabled = false
        }
    }

    /// Returns the current info label text (for testing).
    var infoText: String {
        infoLabel.stringValue
    }

    /// Returns whether the extract button is enabled (for testing).
    var isExtractEnabled: Bool {
        extractButton.isEnabled
    }

    // MARK: - Actions

    @objc private func extractTapped(_ sender: NSButton) {
        guard let node = selectedNode else { return }
        onExtractSequences?(node, true)
    }
}
