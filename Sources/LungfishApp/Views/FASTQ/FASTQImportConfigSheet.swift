// FASTQImportConfigSheet.swift - Modal sheet for configuring FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers


/// Callback invoked when the user clicks "Import" with configured settings.
public typealias FASTQImportCompletion = @MainActor (
    _ configuration: FASTQImportConfiguration
) -> Void

/// Recipe presentation model used by the shared FASTQ import sheet.
public struct FASTQImportSheetRecipeOption: Sendable, Equatable {
    public let id: String
    public let name: String
    public let presentationText: String
    public let requiresBarcodeDefinition: Bool
    public let usesDemultiplexOutputFolder: Bool

    public init(
        id: String,
        name: String,
        presentationText: String,
        requiresBarcodeDefinition: Bool = false,
        usesDemultiplexOutputFolder: Bool = false
    ) {
        self.id = id
        self.name = name
        self.presentationText = presentationText
        self.requiresBarcodeDefinition = requiresBarcodeDefinition
        self.usesDemultiplexOutputFolder = usesDemultiplexOutputFolder
    }

    public init(recipe: Recipe) {
        var lines: [String] = []
        if let purpose = recipe.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !purpose.isEmpty {
            lines.append(purpose)
        }

        let workflow = recipe.steps
            .compactMap { $0.label ?? $0.type }
            .joined(separator: " \u{2192} ")
        lines.append("Workflow: \(workflow)")

        switch recipe.requiredInput {
        case .paired: lines.append("Input: paired-end reads")
        case .single: lines.append("Input: single-end reads")
        case .any: break
        }

        self.init(
            id: recipe.id,
            name: recipe.name,
            presentationText: lines.joined(separator: "\n")
        )
    }

    public static let ontFluidigmSampleSplit = FASTQImportSheetRecipeOption(
        id: "ont-fluidigm-sample-split",
        name: "Split by Fluidigm sample barcodes",
        presentationText: [
            "Creates one counted .lungfishfastq bundle per sample using a Fluidigm barcode sample sheet.",
            "Workflow: detect CS1-CS2 insert \u{2192} assign Fluidigm sample barcode \u{2192} write counted sample FASTQ bundles",
            "Input: ONT run folder"
        ].joined(separator: "\n"),
        requiresBarcodeDefinition: true,
        usesDemultiplexOutputFolder: true
    )

    public static let ontPacBioBarcodeDemux = FASTQImportSheetRecipeOption(
        id: "ont-pacbio-barcode-demux",
        name: "Demultiplex full-length MHC ONT amplicons with PacBio barcodes",
        presentationText: [
            "Runs cutadapt on each ONT FASTQ chunk with a PacBio barcode-pair sheet.",
            "Workflow: demultiplex physical chunks \u{2192} concatenate per-sample FASTQ bundles",
            "Input: ONT run folder"
        ].joined(separator: "\n"),
        requiresBarcodeDefinition: true,
        usesDemultiplexOutputFolder: true
    )
}

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
    private let detectedPlatform: LungfishIO.SequencingPlatform
    private let summaryOverride: String?
    private let projectURL: URL?
    private let onImport: FASTQImportCompletion?
    private let onCancel: (() -> Void)?
    private var recipeOptions: [FASTQImportSheetRecipeOption]
    private var barcodeDefinitionCandidates: [URL]

    // MARK: - UI

    private let headerLabel = NSTextField(labelWithString: "Import FASTQ")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let platformLabel = NSTextField(labelWithString: "Platform:")
    private let platformPopup = NSPopUpButton()
    private let pairingLabel = NSTextField(labelWithString: "Pairing:")
    private let pairingPopup = NSPopUpButton()
    private let binningLabel = NSTextField(labelWithString: "Quality Binning:")
    private let binningPopup = NSPopUpButton()
    private let clumpifyCheckbox = NSButton(checkboxWithTitle: "Optimize storage (reorder reads for better compression)", target: nil, action: nil)
    private let compressionLabel = NSTextField(labelWithString: "Compression:")
    private let compressionPopup = NSPopUpButton()
    private let recipeCheckbox = NSButton(checkboxWithTitle: "Apply processing recipe after import", target: nil, action: nil)
    private let recipePopup = NSPopUpButton()
    private let recipeDescLabel = NSTextField(wrappingLabelWithString: "")
    private let barcodeDefinitionRow = NSStackView()
    private let barcodeDefinitionLabel = NSTextField(labelWithString: "Barcode Sheet:")
    private let barcodeDefinitionPopup = NSPopUpButton()
    private let chooseBarcodeDefinitionButton = NSButton(title: "Choose...", target: nil, action: nil)
    private let barcodeDefinitionStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let demultiplexFolderLabel = NSTextField(labelWithString: "Demux Folder:")
    private let demultiplexFolderField = NSTextField(string: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var binningBelowPairingConstraint: NSLayoutConstraint?
    private var binningBelowPlatformConstraint: NSLayoutConstraint?

    // MARK: - Init

    public init(
        pairs: [FASTQFilePair],
        detectedPlatform: LungfishIO.SequencingPlatform,
        summaryOverride: String? = nil,
        recipeOptions: [FASTQImportSheetRecipeOption]? = nil,
        projectURL: URL? = nil,
        barcodeDefinitionCandidates: [URL] = [],
        onImport: FASTQImportCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.pairs = pairs
        self.detectedPlatform = detectedPlatform
        self.summaryOverride = summaryOverride
        self.projectURL = projectURL
        self.recipeOptions = recipeOptions ?? RecipeRegistryV2.allRecipes().map(FASTQImportSheetRecipeOption.init(recipe:))
        self.barcodeDefinitionCandidates = barcodeDefinitionCandidates
        self.onImport = onImport
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated static func defaultDemultiplexFolderName(for sourceURL: URL) -> String {
        FASTQDemultiplexOutputFolderName.defaultName(for: sourceURL)
    }

    nonisolated static func sanitizedDemultiplexFolderName(_ value: String) -> String {
        FASTQDemultiplexOutputFolderName.sanitize(value)
    }

    // MARK: - View Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
        setupUI()
    }

    // MARK: - Layout

    private func setupUI() {
        let labelWidth: CGFloat = 110
        let margin: CGFloat = 20

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
        let platformNames: [(LungfishIO.SequencingPlatform, String)] = [
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
        clumpifyCheckbox.toolTip = "Disable if your machine has limited memory. Reorders reads by k-mer similarity for better compression."
        clumpifyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clumpifyCheckbox)

        // Compression level picker
        compressionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        compressionLabel.alignment = .right
        compressionLabel.translatesAutoresizingMaskIntoConstraints = false
        compressionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.addSubview(compressionLabel)

        compressionPopup.addItems(withTitles: ["Fast", "Balanced", "Maximum"])
        compressionPopup.selectItem(at: 1) // Balanced default
        compressionPopup.font = .systemFont(ofSize: 12)
        compressionPopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compressionPopup)

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
        for recipe in recipeOptions {
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
        recipeDescLabel.maximumNumberOfLines = 4
        recipeDescLabel.preferredMaxLayoutWidth = 400
        recipeDescLabel.isHidden = true
        view.addSubview(recipeDescLabel)

        // Barcode sample-sheet controls for recipes that require them.
        barcodeDefinitionRow.orientation = .horizontal
        barcodeDefinitionRow.alignment = .centerY
        barcodeDefinitionRow.spacing = 8
        barcodeDefinitionRow.translatesAutoresizingMaskIntoConstraints = false
        barcodeDefinitionRow.isHidden = true
        view.addSubview(barcodeDefinitionRow)

        barcodeDefinitionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        barcodeDefinitionLabel.alignment = .right
        barcodeDefinitionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        barcodeDefinitionLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        barcodeDefinitionRow.addArrangedSubview(barcodeDefinitionLabel)

        barcodeDefinitionPopup.font = .systemFont(ofSize: 12)
        barcodeDefinitionPopup.toolTip = "CSV, TSV, or text file containing sample names and barcode definitions."
        barcodeDefinitionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        barcodeDefinitionPopup.target = self
        barcodeDefinitionPopup.action = #selector(barcodeDefinitionChanged(_:))
        barcodeDefinitionRow.addArrangedSubview(barcodeDefinitionPopup)

        chooseBarcodeDefinitionButton.bezelStyle = .rounded
        chooseBarcodeDefinitionButton.target = self
        chooseBarcodeDefinitionButton.action = #selector(chooseBarcodeDefinition(_:))
        barcodeDefinitionRow.addArrangedSubview(chooseBarcodeDefinitionButton)

        barcodeDefinitionStatusLabel.font = .systemFont(ofSize: 11)
        barcodeDefinitionStatusLabel.textColor = .secondaryLabelColor
        barcodeDefinitionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        barcodeDefinitionStatusLabel.maximumNumberOfLines = 2
        barcodeDefinitionStatusLabel.preferredMaxLayoutWidth = 400
        barcodeDefinitionStatusLabel.isHidden = true
        view.addSubview(barcodeDefinitionStatusLabel)

        // Parent folder for ONT demultiplexing recipe outputs.
        demultiplexFolderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        demultiplexFolderLabel.alignment = .right
        demultiplexFolderLabel.translatesAutoresizingMaskIntoConstraints = false
        demultiplexFolderLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        demultiplexFolderLabel.isHidden = true
        view.addSubview(demultiplexFolderLabel)

        demultiplexFolderField.font = .systemFont(ofSize: 12)
        demultiplexFolderField.toolTip = "Subfolder under the project where demultiplexed FASTQ bundles will be written."
        demultiplexFolderField.stringValue = pairs.first
            .map { Self.defaultDemultiplexFolderName(for: $0.r1) }
            ?? FASTQDemultiplexOutputFolderName.fallback
        demultiplexFolderField.translatesAutoresizingMaskIntoConstraints = false
        demultiplexFolderField.isHidden = true
        view.addSubview(demultiplexFolderField)

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
        let binningBelowPairingConstraint = binningLabel.topAnchor.constraint(
            equalTo: pairingLabel.bottomAnchor,
            constant: 10
        )
        let binningBelowPlatformConstraint = binningLabel.topAnchor.constraint(
            equalTo: platformLabel.bottomAnchor,
            constant: 10
        )
        self.binningBelowPairingConstraint = binningBelowPairingConstraint
        self.binningBelowPlatformConstraint = binningBelowPlatformConstraint
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
            binningBelowPairingConstraint,
            binningLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            binningLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            binningPopup.centerYAnchor.constraint(equalTo: binningLabel.centerYAnchor),
            binningPopup.leadingAnchor.constraint(equalTo: binningLabel.trailingAnchor, constant: 8),

            // Clumpify checkbox
            clumpifyCheckbox.topAnchor.constraint(equalTo: binningLabel.bottomAnchor, constant: 12),
            clumpifyCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin + labelWidth + 8),

            // Compression row
            compressionLabel.topAnchor.constraint(equalTo: clumpifyCheckbox.bottomAnchor, constant: 10),
            compressionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            compressionLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            compressionPopup.centerYAnchor.constraint(equalTo: compressionLabel.centerYAnchor),
            compressionPopup.leadingAnchor.constraint(equalTo: compressionLabel.trailingAnchor, constant: 8),

            sep2.topAnchor.constraint(equalTo: compressionLabel.bottomAnchor, constant: 12),
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

            barcodeDefinitionRow.topAnchor.constraint(equalTo: recipeDescLabel.bottomAnchor, constant: 8),
            barcodeDefinitionRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            barcodeDefinitionStatusLabel.topAnchor.constraint(equalTo: barcodeDefinitionRow.bottomAnchor, constant: 4),
            barcodeDefinitionStatusLabel.leadingAnchor.constraint(equalTo: recipePopup.leadingAnchor),
            barcodeDefinitionStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            demultiplexFolderLabel.topAnchor.constraint(equalTo: barcodeDefinitionStatusLabel.bottomAnchor, constant: 8),
            demultiplexFolderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            demultiplexFolderLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            demultiplexFolderField.centerYAnchor.constraint(equalTo: demultiplexFolderLabel.centerYAnchor),
            demultiplexFolderField.leadingAnchor.constraint(equalTo: demultiplexFolderLabel.trailingAnchor, constant: 8),
            demultiplexFolderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            demultiplexFolderField.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -margin),

            // Bottom buttons
            importButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            importButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        populateBarcodeDefinitions()
        updateRecipeControls()
        updatePairingControlsForSelectedPlatform()
    }

    // MARK: - Summary

    private func updateSummary() {
        if let summaryOverride {
            summaryLabel.stringValue = summaryOverride
            return
        }
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

    private func defaultBinningIndex(for platform: LungfishIO.SequencingPlatform) -> Int {
        switch platform {
        case .illumina, .element, .mgi: return 0  // illumina4
        case .oxfordNanopore, .pacbio, .ultima, .unknown: return 2  // none
        }
    }

    private func selectedPlatform() -> LungfishIO.SequencingPlatform {
        let platforms: [LungfishIO.SequencingPlatform] = [.illumina, .oxfordNanopore, .pacbio, .element, .ultima, .mgi, .unknown]
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
        updatePairingControlsForSelectedPlatform()
    }

    private func updatePairingControlsForSelectedPlatform() {
        let showPairingControls = selectedPlatform() != .oxfordNanopore
        pairingLabel.isHidden = !showPairingControls
        pairingPopup.isHidden = !showPairingControls
        binningBelowPairingConstraint?.isActive = showPairingControls
        binningBelowPlatformConstraint?.isActive = !showPairingControls
        if !showPairingControls {
            pairingPopup.selectItem(at: 0)
        }
    }

    @objc private func recipeToggled(_ sender: Any) {
        updateRecipeControls()
    }

    @objc private func recipeChanged(_ sender: Any) {
        updateRecipeControls()
    }

    @objc private func barcodeDefinitionChanged(_ sender: NSPopUpButton) {
        updateRecipeControls()
    }

    @objc private func chooseBarcodeDefinition(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = "Choose Barcode Sheet"
        panel.message = "Select a CSV, TSV, or text file containing sample names and barcode definitions."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "csv"),
            UTType(filenameExtension: "tsv"),
            .plainText,
        ].compactMap { $0 }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
            Task { @MainActor in
                self?.selectBarcodeDefinition(url)
            }
        }

        if let window = sender.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func updateRecipeControls() {
        let showRecipe = recipeCheckbox.state == .on && !recipeOptions.isEmpty
        recipePopup.isHidden = !showRecipe
        recipeDescLabel.isHidden = !showRecipe
        if showRecipe {
            updateRecipeDescription()
        } else {
            recipeDescLabel.stringValue = ""
        }

        let requiresBarcodeDefinition = showRecipe && (selectedRecipeOption?.requiresBarcodeDefinition == true)
        barcodeDefinitionRow.isHidden = !requiresBarcodeDefinition
        barcodeDefinitionStatusLabel.isHidden = !requiresBarcodeDefinition
        let usesDemultiplexOutputFolder = showRecipe && (selectedRecipeOption?.usesDemultiplexOutputFolder == true)
        demultiplexFolderLabel.isHidden = !usesDemultiplexOutputFolder
        demultiplexFolderField.isHidden = !usesDemultiplexOutputFolder
        demultiplexFolderField.isEnabled = usesDemultiplexOutputFolder
        if usesDemultiplexOutputFolder,
           demultiplexFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sourceURL = pairs.first?.r1 {
            demultiplexFolderField.stringValue = Self.defaultDemultiplexFolderName(for: sourceURL)
        }

        if requiresBarcodeDefinition {
            barcodeDefinitionPopup.isEnabled = !barcodeDefinitionCandidates.isEmpty
            chooseBarcodeDefinitionButton.isEnabled = true
            if let selectedBarcodeDefinitionURL {
                barcodeDefinitionStatusLabel.stringValue = "Using \(displayPath(for: selectedBarcodeDefinitionURL))."
            } else {
                barcodeDefinitionStatusLabel.stringValue = "Choose a barcode sheet before importing."
            }
            importButton.isEnabled = selectedBarcodeDefinitionURL != nil
        } else {
            importButton.isEnabled = true
        }
    }

    private func updateRecipeDescription() {
        let idx = recipePopup.indexOfSelectedItem
        guard idx >= 0, idx < recipeOptions.count else {
            recipeDescLabel.stringValue = ""
            return
        }
        let recipe = recipeOptions[idx]
        recipeDescLabel.stringValue = recipe.presentationText
    }

    private var selectedRecipeOption: FASTQImportSheetRecipeOption? {
        let idx = recipePopup.indexOfSelectedItem
        guard idx >= 0, idx < recipeOptions.count else { return nil }
        return recipeOptions[idx]
    }

    private var selectedBarcodeDefinitionURL: URL? {
        barcodeDefinitionPopup.selectedItem?.representedObject as? URL
    }

    private func populateBarcodeDefinitions() {
        barcodeDefinitionPopup.removeAllItems()
        if barcodeDefinitionCandidates.isEmpty {
            barcodeDefinitionPopup.addItem(withTitle: "Choose a barcode sheet...")
            barcodeDefinitionPopup.lastItem?.isEnabled = false
        } else {
            for url in barcodeDefinitionCandidates {
                barcodeDefinitionPopup.addItem(withTitle: displayPath(for: url))
                barcodeDefinitionPopup.lastItem?.representedObject = url.standardizedFileURL
            }
            barcodeDefinitionPopup.selectItem(at: 0)
        }
    }

    private func selectBarcodeDefinition(_ url: URL) {
        if !barcodeDefinitionCandidates.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            barcodeDefinitionCandidates.append(url.standardizedFileURL)
            barcodeDefinitionCandidates.sort {
                displayPath(for: $0).localizedStandardCompare(displayPath(for: $1)) == .orderedAscending
            }
            populateBarcodeDefinitions()
        }
        for index in 0..<barcodeDefinitionPopup.numberOfItems {
            guard let itemURL = barcodeDefinitionPopup.item(at: index)?.representedObject as? URL,
                  itemURL.standardizedFileURL == url.standardizedFileURL else {
                continue
            }
            barcodeDefinitionPopup.selectItem(at: index)
            break
        }
        updateRecipeControls()
    }

    private func displayPath(for url: URL) -> String {
        WorkflowOperationDialogState.displayPath(for: url, relativeTo: projectURL)
    }

    @objc private func importClicked(_ sender: Any) {
        let platform = selectedPlatform()
        let pairingMode = platform == .oxfordNanopore ? .singleEnd : selectedPairingMode()
        let binning = selectedBinning()
        let skipClumpify = clumpifyCheckbox.state == .off

        let recipe: ProcessingRecipe? = nil

        // V2 recipe name from the popup (if recipe checkbox is on and a recipe is selected)
        let chosenRecipeOption = recipeCheckbox.state == .on ? self.selectedRecipeOption : nil
        let selectedRecipeName = chosenRecipeOption?.id
        var resolvedPlaceholders: [String: String] = [:]
        if chosenRecipeOption?.requiresBarcodeDefinition == true,
           let barcodeDefinitionURL = selectedBarcodeDefinitionURL {
            resolvedPlaceholders["barcodeDefinition"] = barcodeDefinitionURL.path
        }
        let demultiplexOutputFolderName = chosenRecipeOption?.usesDemultiplexOutputFolder == true
            ? Self.sanitizedDemultiplexFolderName(demultiplexFolderField.stringValue)
            : nil

        let compressionLevel: CompressionLevel = {
            switch compressionPopup.indexOfSelectedItem {
            case 0:  return .fast
            case 2:  return .maximum
            default: return .balanced
            }
        }()

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
            resolvedPlaceholders: resolvedPlaceholders,
            recipeName: selectedRecipeName,
            compressionLevel: compressionLevel,
            demultiplexOutputFolderName: demultiplexOutputFolderName
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
        detectedPlatform: LungfishIO.SequencingPlatform,
        summaryOverride: String? = nil,
        recipeOptions: [FASTQImportSheetRecipeOption]? = nil,
        projectURL: URL? = nil,
        barcodeDefinitionCandidates: [URL] = [],
        onImport: FASTQImportCompletion? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let controller = FASTQImportConfigSheet(
            pairs: pairs,
            detectedPlatform: detectedPlatform,
            summaryOverride: summaryOverride,
            recipeOptions: recipeOptions,
            projectURL: projectURL,
            barcodeDefinitionCandidates: barcodeDefinitionCandidates,
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
