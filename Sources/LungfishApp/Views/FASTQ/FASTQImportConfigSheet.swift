// FASTQImportConfigSheet.swift - Modal sheet for configuring FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

/// Callback invoked when the user clicks "Import" with configured settings.
public typealias FASTQImportCompletion = @MainActor (
    _ configuration: FASTQImportConfiguration
) -> Void

/// Modal sheet that presents import options for FASTQ files before ingestion.
///
/// Allows the user to:
/// - Confirm auto-detected platform and pairing mode
/// - Choose quality binning scheme
/// - Toggle clumpify (k-mer sorting) on or off
/// - Optionally select a processing recipe to apply post-import
@MainActor
public final class FASTQImportConfigSheet: NSViewController {

    // MARK: - State

    private let pairs: [FASTQFilePair]
    private let detectedPlatform: SequencingPlatform
    private let onImport: FASTQImportCompletion?
    private let onCancel: (() -> Void)?
    private var allRecipes: [ProcessingRecipe] = []

    // MARK: - UI

    private let headerLabel = NSTextField(labelWithString: "Import FASTQ")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let platformLabel = NSTextField(labelWithString: "Platform:")
    private let platformPopup = NSPopUpButton()
    private let pairingLabel = NSTextField(labelWithString: "Pairing:")
    private let pairingPopup = NSPopUpButton()
    private let binningLabel = NSTextField(labelWithString: "Quality Binning:")
    private let binningPopup = NSPopUpButton()
    private let clumpifyCheckbox = NSButton(checkboxWithTitle: "Clumpify (k-mer sort for compression)", target: nil, action: nil)
    private let recipeCheckbox = NSButton(checkboxWithTitle: "Apply processing recipe after import", target: nil, action: nil)
    private let recipePopup = NSPopUpButton()
    private let recipeDescLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: - Init

    public init(
        pairs: [FASTQFilePair],
        detectedPlatform: SequencingPlatform,
        onImport: FASTQImportCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.pairs = pairs
        self.detectedPlatform = detectedPlatform
        self.onImport = onImport
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
        setupUI()
    }

    // MARK: - Layout

    private func setupUI() {
        // Header
        headerLabel.font = .boldSystemFont(ofSize: 14)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerLabel)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.maximumNumberOfLines = 6
        summaryLabel.preferredMaxLayoutWidth = 520
        view.addSubview(summaryLabel)

        // Build summary text
        updateSummary()

        // Separator
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep1)

        // Labels
        for label in [platformLabel, pairingLabel, binningLabel] {
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .right
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            view.addSubview(label)
        }

        // Platform popup
        let platformNames: [(SequencingPlatform, String)] = [
            (.illumina, "Illumina"),
            (.oxfordNanopore, "Oxford Nanopore"),
            (.pacbio, "PacBio"),
            (.element, "Element Biosciences"),
            (.ultima, "Ultima Genomics"),
            (.mgi, "MGI / DNBSEQ"),
            (.unknown, "Unknown / Other"),
        ]
        for (_, name) in platformNames {
            platformPopup.addItem(withTitle: name)
        }
        // Select detected platform
        let detectedIndex = platformNames.firstIndex { $0.0 == detectedPlatform } ?? platformNames.count - 1
        platformPopup.selectItem(at: detectedIndex)
        platformPopup.font = .systemFont(ofSize: 12)
        platformPopup.translatesAutoresizingMaskIntoConstraints = false
        platformPopup.target = self
        platformPopup.action = #selector(platformChanged(_:))
        view.addSubview(platformPopup)

        // Pairing popup
        pairingPopup.addItems(withTitles: ["Single-end", "Paired-end", "Interleaved"])
        let hasPaired = pairs.contains { $0.isPaired }
        pairingPopup.selectItem(at: hasPaired ? 1 : 0)
        pairingPopup.font = .systemFont(ofSize: 12)
        pairingPopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pairingPopup)

        // Quality binning popup
        binningPopup.addItems(withTitles: ["Illumina 4-level", "8-level", "None (preserve original)"])
        binningPopup.selectItem(at: defaultBinningIndex(for: detectedPlatform))
        binningPopup.font = .systemFont(ofSize: 12)
        binningPopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(binningPopup)

        // Clumpify checkbox
        clumpifyCheckbox.state = .on
        clumpifyCheckbox.font = .systemFont(ofSize: 12)
        clumpifyCheckbox.toolTip = "Disable if your machine has limited memory. Clumpify reorders reads by k-mer similarity for better compression."
        clumpifyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clumpifyCheckbox)

        // Separator 2
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep2)

        // Recipe checkbox
        recipeCheckbox.state = .off
        recipeCheckbox.font = .systemFont(ofSize: 12)
        recipeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        recipeCheckbox.target = self
        recipeCheckbox.action = #selector(recipeToggled(_:))
        view.addSubview(recipeCheckbox)

        // Recipe popup
        allRecipes = RecipeRegistry.loadAllRecipes()
        for recipe in allRecipes {
            recipePopup.addItem(withTitle: recipe.name)
        }
        recipePopup.font = .systemFont(ofSize: 12)
        recipePopup.translatesAutoresizingMaskIntoConstraints = false
        recipePopup.isHidden = true
        recipePopup.target = self
        recipePopup.action = #selector(recipeChanged(_:))
        view.addSubview(recipePopup)

        // Recipe description
        recipeDescLabel.font = .systemFont(ofSize: 11)
        recipeDescLabel.textColor = .tertiaryLabelColor
        recipeDescLabel.translatesAutoresizingMaskIntoConstraints = false
        recipeDescLabel.maximumNumberOfLines = 2
        recipeDescLabel.preferredMaxLayoutWidth = 400
        recipeDescLabel.isHidden = true
        view.addSubview(recipeDescLabel)

        // Bottom buttons
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.target = self
        importButton.action = #selector(importClicked(_:))
        view.addSubview(importButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        view.addSubview(cancelButton)

        // Constraints
        let labelWidth: CGFloat = 110
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            // Header
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            summaryLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            sep1.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            sep1.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Platform row
            platformLabel.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 12),
            platformLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            platformLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            platformPopup.centerYAnchor.constraint(equalTo: platformLabel.centerYAnchor),
            platformPopup.leadingAnchor.constraint(equalTo: platformLabel.trailingAnchor, constant: 8),
            platformPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            // Pairing row
            pairingLabel.topAnchor.constraint(equalTo: platformLabel.bottomAnchor, constant: 10),
            pairingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            pairingLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            pairingPopup.centerYAnchor.constraint(equalTo: pairingLabel.centerYAnchor),
            pairingPopup.leadingAnchor.constraint(equalTo: pairingLabel.trailingAnchor, constant: 8),

            // Binning row
            binningLabel.topAnchor.constraint(equalTo: pairingLabel.bottomAnchor, constant: 10),
            binningLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            binningLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            binningPopup.centerYAnchor.constraint(equalTo: binningLabel.centerYAnchor),
            binningPopup.leadingAnchor.constraint(equalTo: binningLabel.trailingAnchor, constant: 8),

            // Clumpify checkbox
            clumpifyCheckbox.topAnchor.constraint(equalTo: binningLabel.bottomAnchor, constant: 12),
            clumpifyCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin + labelWidth + 8),

            sep2.topAnchor.constraint(equalTo: clumpifyCheckbox.bottomAnchor, constant: 12),
            sep2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            sep2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Recipe section
            recipeCheckbox.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 12),
            recipeCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            recipePopup.topAnchor.constraint(equalTo: recipeCheckbox.bottomAnchor, constant: 6),
            recipePopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin + 20),
            recipePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),

            recipeDescLabel.topAnchor.constraint(equalTo: recipePopup.bottomAnchor, constant: 4),
            recipeDescLabel.leadingAnchor.constraint(equalTo: recipePopup.leadingAnchor),
            recipeDescLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Bottom buttons
            importButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            importButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    // MARK: - Summary

    private func updateSummary() {
        if pairs.count == 1 {
            let pair = pairs[0]
            if let r2 = pair.r2 {
                summaryLabel.stringValue = "R1: \(pair.r1.lastPathComponent)\nR2: \(r2.lastPathComponent)\nTotal size: \(formatBytes(pair.totalSizeBytes))"
            } else {
                summaryLabel.stringValue = "\(pair.r1.lastPathComponent)\nSize: \(formatBytes(pair.totalSizeBytes))"
            }
        } else {
            let pairedCount = pairs.filter(\.isPaired).count
            let singleCount = pairs.count - pairedCount
            var lines = ["\(pairs.count) samples detected"]
            if pairedCount > 0 { lines.append("  \(pairedCount) paired-end") }
            if singleCount > 0 { lines.append("  \(singleCount) single-end") }
            let totalSize = pairs.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            lines.append("Total size: \(formatBytes(totalSize))")
            summaryLabel.stringValue = lines.joined(separator: "\n")
        }
    }

    // MARK: - Platform Defaults

    private func defaultBinningIndex(for platform: SequencingPlatform) -> Int {
        switch platform {
        case .illumina, .element, .mgi: return 0  // illumina4
        case .oxfordNanopore, .pacbio, .ultima, .unknown: return 2  // none
        }
    }

    private func selectedPlatform() -> SequencingPlatform {
        let platforms: [SequencingPlatform] = [.illumina, .oxfordNanopore, .pacbio, .element, .ultima, .mgi, .unknown]
        let idx = platformPopup.indexOfSelectedItem
        return idx >= 0 && idx < platforms.count ? platforms[idx] : .unknown
    }

    private func selectedPairingMode() -> FASTQIngestionConfig.PairingMode {
        switch pairingPopup.indexOfSelectedItem {
        case 1: return .pairedEnd
        case 2: return .interleaved
        default: return .singleEnd
        }
    }

    private func selectedBinning() -> QualityBinningScheme {
        switch binningPopup.indexOfSelectedItem {
        case 0: return .illumina4
        case 1: return .eightLevel
        default: return .none
        }
    }

    // MARK: - Actions

    @objc private func platformChanged(_ sender: Any) {
        binningPopup.selectItem(at: defaultBinningIndex(for: selectedPlatform()))
    }

    @objc private func recipeToggled(_ sender: Any) {
        let show = recipeCheckbox.state == .on
        recipePopup.isHidden = !show
        recipeDescLabel.isHidden = !show
        if show { updateRecipeDescription() }
    }

    @objc private func recipeChanged(_ sender: Any) {
        updateRecipeDescription()
    }

    private func updateRecipeDescription() {
        let idx = recipePopup.indexOfSelectedItem
        guard idx >= 0, idx < allRecipes.count else {
            recipeDescLabel.stringValue = ""
            return
        }
        let recipe = allRecipes[idx]
        recipeDescLabel.stringValue = "\(recipe.description)\n\(recipe.pipelineSummary)"
    }

    @objc private func importClicked(_ sender: Any) {
        let platform = selectedPlatform()
        let pairingMode = selectedPairingMode()
        let binning = selectedBinning()
        let skipClumpify = clumpifyCheckbox.state == .off

        let recipe: ProcessingRecipe?
        if recipeCheckbox.state == .on {
            let idx = recipePopup.indexOfSelectedItem
            recipe = (idx >= 0 && idx < allRecipes.count) ? allRecipes[idx] : nil
        } else {
            recipe = nil
        }

        let config = FASTQImportConfiguration(
            inputFiles: pairs.flatMap { pair in
                if let r2 = pair.r2 { return [pair.r1, r2] }
                return [pair.r1]
            },
            detectedPlatform: detectedPlatform,
            confirmedPlatform: platform,
            pairingMode: pairingMode,
            qualityBinning: binning,
            skipClumpify: skipClumpify,
            deleteOriginals: false,
            postImportRecipe: recipe,
            resolvedPlaceholders: [:]
        )

        onImport?(config)
        dismissSheet()
    }

    @objc private func cancelClicked(_ sender: Any) {
        onCancel?()
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window = view.window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Presentation

    /// Presents this sheet attached to the given window.
    public static func present(
        on window: NSWindow,
        pairs: [FASTQFilePair],
        detectedPlatform: SequencingPlatform,
        onImport: FASTQImportCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let controller = FASTQImportConfigSheet(
            pairs: pairs,
            detectedPlatform: detectedPlatform,
            onImport: onImport,
            onCancel: onCancel
        )

        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.title = "Import FASTQ"
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.isReleasedWhenClosed = false

        window.beginSheet(sheetWindow) { _ in
            _ = controller  // prevent premature release
        }
    }
}
