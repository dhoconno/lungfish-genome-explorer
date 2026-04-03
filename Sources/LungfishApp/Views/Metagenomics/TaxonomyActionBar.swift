// TaxonomyActionBar.swift - Bottom action bar for taxonomy view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - TaxonomyActionBar

/// A 36pt bottom bar showing a collections toggle, selected taxon info, and an Extract button.
///
/// ## Layout
///
/// ```
/// [Collections] |  Escherichia coli -- 1,234 reads (12.3%)  | [Extract Sequences]
/// ```
///
/// The left side has a "Collections" button that toggles the taxa collections drawer.
/// The center shows the currently selected taxon's name, read count, and clade
/// percentage. The right side has the Extract Sequences button, which is disabled
/// until a node is selected.
@MainActor
final class TaxonomyActionBar: NSView {

    // MARK: - Callbacks

    /// Called when the user clicks the Extract Sequences button.
    ///
    /// The boolean indicates whether child taxa should be included.
    var onExtractSequences: ((TaxonNode, Bool) -> Void)?

    /// Called when the user clicks the Collections toggle button.
    var onToggleCollections: (() -> Void)?

    /// Called when the user clicks the BLAST Results toggle button.
    var onToggleBlastResults: (() -> Void)?

    // MARK: - State

    /// The currently selected taxon node.
    private var selectedNode: TaxonNode?

    /// Total reads for percentage calculation.
    private var totalReads: Int = 0

    // MARK: - Subviews

    private let collectionsButton = NSButton(
        title: "Collections",
        target: nil,
        action: nil
    )
    private let blastResultsButton = NSButton(
        title: "BLAST Results",
        target: nil,
        action: nil
    )
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

        // Collections toggle button (left side)
        collectionsButton.translatesAutoresizingMaskIntoConstraints = false
        collectionsButton.bezelStyle = .accessoryBarAction
        collectionsButton.setButtonType(.pushOnPushOff)
        collectionsButton.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Collections")
        collectionsButton.imagePosition = .imageLeading
        collectionsButton.target = self
        collectionsButton.action = #selector(collectionsToggleTapped(_:))
        collectionsButton.setContentHuggingPriority(.required, for: .horizontal)
        collectionsButton.setAccessibilityLabel("Toggle Taxa Collections Drawer")
        addSubview(collectionsButton)

        // BLAST Results toggle button (left side, after Collections)
        blastResultsButton.translatesAutoresizingMaskIntoConstraints = false
        blastResultsButton.bezelStyle = .accessoryBarAction
        blastResultsButton.setButtonType(.pushOnPushOff)
        blastResultsButton.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST Results")
        blastResultsButton.imagePosition = .imageLeading
        blastResultsButton.target = self
        blastResultsButton.action = #selector(blastResultsToggleTapped(_:))
        blastResultsButton.setContentHuggingPriority(.required, for: .horizontal)
        blastResultsButton.setAccessibilityLabel("Toggle BLAST Results Drawer")
        addSubview(blastResultsButton)

        // Info label (center)
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

            collectionsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            collectionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            blastResultsButton.leadingAnchor.constraint(equalTo: collectionsButton.trailingAnchor, constant: 4),
            blastResultsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: blastResultsButton.trailingAnchor, constant: 12),
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

    /// Updates the collections button visual state to reflect drawer open/closed.
    ///
    /// When the drawer is open the button appears pressed (`.on` state).
    ///
    /// - Parameter isOpen: Whether the drawer is currently open.
    func setCollectionsDrawerOpen(_ isOpen: Bool) {
        collectionsButton.state = isOpen ? .on : .off
    }

    /// Updates the BLAST results button visual state to reflect drawer tab state.
    ///
    /// When the drawer is open on the BLAST tab the button appears pressed.
    ///
    /// - Parameter isOn: Whether the BLAST results tab is currently active.
    func setBlastResultsActive(_ isOn: Bool) {
        blastResultsButton.state = isOn ? .on : .off
    }

    /// Returns the current info label text (for testing).
    var infoText: String {
        infoLabel.stringValue
    }

    /// Returns whether the extract button is enabled (for testing).
    var isExtractEnabled: Bool {
        extractButton.isEnabled
    }

    /// Returns the collections button state (for testing).
    var isCollectionsToggleOn: Bool {
        collectionsButton.state == .on
    }

    // MARK: - Actions

    @objc private func extractTapped(_ sender: NSButton) {
        guard let node = selectedNode else { return }
        onExtractSequences?(node, true)
    }

    @objc private func collectionsToggleTapped(_ sender: NSButton) {
        onToggleCollections?()
    }

    @objc private func blastResultsToggleTapped(_ sender: NSButton) {
        onToggleBlastResults?()
    }
}
