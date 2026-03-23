// TaxonomyExtractionSheet.swift - SwiftUI sheet for configuring taxonomy-based read extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO
import LungfishWorkflow

// MARK: - TaxonomyExtractionSheet

/// A SwiftUI sheet presented when the user clicks "Extract Sequences" for a taxon.
///
/// Displays the selected taxon name(s), estimated read count, an "include children"
/// toggle, and an output file name field. On confirmation, it creates a
/// ``TaxonomyExtractionConfig`` and passes it to the `onExtract` callback.
///
/// ## Paired-End Support
///
/// When ``sourceURLs`` contains two files (R1 and R2), the sheet generates
/// paired output filenames (e.g., `sample_E_coli_R1.fastq` and
/// `sample_E_coli_R2.fastq`) and creates a multi-file config.
///
/// ## Presentation
///
/// Presented via `NSHostingController` wrapped in an `NSPanel`, following the
/// established sheet pattern used by ``SampleGroupSheet`` and ``TranslationToolView``.
///
/// ## Layout
///
/// ```
/// +------------------------------------------+
/// | Extract Sequences                        |
/// +------------------------------------------+
/// | Selected: Escherichia coli               |
/// | Estimated reads: 1,234 (clade)           |
/// |                                          |
/// | [x] Include child taxa                   |
/// |     Includes 12 descendant taxa          |
/// |                                          |
/// | Output name: [sample_E_coli.fastq  ]     |
/// +------------------------------------------+
/// |               [Cancel]  [Extract]        |
/// +------------------------------------------+
/// ```
struct TaxonomyExtractionSheet: View {

    /// The selected taxon nodes to extract.
    let selectedNodes: [TaxonNode]

    /// The taxonomy tree for descendant lookup and count estimation.
    let tree: TaxonTree

    /// The source FASTQ file URL(s). One for single-end, two for paired-end.
    let sourceURLs: [URL]

    /// The Kraken2 per-read classification output URL.
    let classificationOutputURL: URL

    /// Initial value for the "include children" toggle.
    let initialIncludeChildren: Bool

    // MARK: - State

    @State private var includeChildren: Bool
    @State private var outputName: String

    // MARK: - Callbacks

    /// Called when the user clicks Extract.
    var onExtract: ((TaxonomyExtractionConfig) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - Initialization

    /// Creates an extraction sheet for one or more source files.
    ///
    /// - Parameters:
    ///   - selectedNodes: Taxon nodes the user selected.
    ///   - tree: The taxonomy tree.
    ///   - sourceURLs: One or two FASTQ file URLs.
    ///   - classificationOutputURL: Kraken2 per-read output.
    ///   - initialIncludeChildren: Default toggle state.
    ///   - onExtract: Callback with the built config.
    ///   - onCancel: Callback on cancel.
    init(
        selectedNodes: [TaxonNode],
        tree: TaxonTree,
        sourceURLs: [URL],
        classificationOutputURL: URL,
        initialIncludeChildren: Bool = true,
        onExtract: ((TaxonomyExtractionConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.selectedNodes = selectedNodes
        self.tree = tree
        self.sourceURLs = sourceURLs
        self.classificationOutputURL = classificationOutputURL
        self.initialIncludeChildren = initialIncludeChildren
        self.onExtract = onExtract
        self.onCancel = onCancel

        // Build a default output name from the source filename and selected taxon
        let primaryURL = sourceURLs.first ?? URL(fileURLWithPath: "reads.fastq")
        let sourceStem = primaryURL.deletingPathExtension().lastPathComponent
        // Strip .fastq if there's a double extension like .fastq.gz
        let cleanStem: String
        if sourceStem.hasSuffix(".fastq") {
            cleanStem = String(sourceStem.dropLast(6))
        } else {
            cleanStem = sourceStem
        }
        let taxonSuffix: String
        if let firstNode = selectedNodes.first {
            taxonSuffix = firstNode.name
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
        } else {
            taxonSuffix = "extracted"
        }

        _includeChildren = State(initialValue: initialIncludeChildren)
        _outputName = State(initialValue: "\(cleanStem)_\(taxonSuffix).fastq")
    }

    /// Backward-compatible single-URL initializer.
    init(
        selectedNodes: [TaxonNode],
        tree: TaxonTree,
        sourceURL: URL,
        classificationOutputURL: URL,
        initialIncludeChildren: Bool = true,
        onExtract: ((TaxonomyExtractionConfig) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.init(
            selectedNodes: selectedNodes,
            tree: tree,
            sourceURLs: [sourceURL],
            classificationOutputURL: classificationOutputURL,
            initialIncludeChildren: initialIncludeChildren,
            onExtract: onExtract,
            onCancel: onCancel
        )
    }

    // MARK: - Computed Properties

    /// The names of selected taxa, joined for display.
    private var taxonNames: String {
        selectedNodes.map(\.name).joined(separator: ", ")
    }

    /// The estimated number of reads (clade count) for the selected taxa.
    private var estimatedReads: Int {
        selectedNodes.reduce(0) { $0 + $1.readsClade }
    }

    /// The number of descendant taxa if "include children" is enabled.
    private var descendantCount: Int {
        var count = 0
        for node in selectedNodes {
            // allDescendants includes the node itself, so subtract 1
            count += node.allDescendants().count - 1
        }
        return count
    }

    /// The estimated reads for direct assignment only (no children).
    private var directReads: Int {
        selectedNodes.reduce(0) { $0 + $1.readsDirect }
    }

    /// Whether the input is paired-end.
    private var isPairedEnd: Bool {
        sourceURLs.count > 1
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text("Extract Sequences")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                // Selected taxon info
                infoRow(label: "Selected:", value: taxonNames)

                if selectedNodes.count == 1, let node = selectedNodes.first {
                    infoRow(label: "Rank:", value: node.rank.displayName)
                }

                // Estimated reads
                let readEstimate = includeChildren ? estimatedReads : directReads
                infoRow(
                    label: "Estimated reads:",
                    value: "\(formatNumber(readEstimate)) (\(includeChildren ? "clade" : "direct"))"
                )

                if tree.totalReads > 0 {
                    let pct = Double(readEstimate) / Double(tree.totalReads) * 100
                    infoRow(
                        label: "% of total:",
                        value: String(format: "%.1f%%", pct)
                    )
                }

                if isPairedEnd {
                    infoRow(label: "Mode:", value: "Paired-end (\(sourceURLs.count) files)")
                }

                Divider()
                    .padding(.vertical, 4)

                // Include children toggle
                Toggle("Include child taxa", isOn: $includeChildren)
                    .toggleStyle(.checkbox)

                if descendantCount > 0 {
                    Text("Includes \(descendantCount) descendant \(descendantCount == 1 ? "taxon" : "taxa")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }

                Divider()
                    .padding(.vertical, 4)

                // Output name
                HStack {
                    Text("Output name:")
                        .font(.system(size: 12))
                    TextField("Output filename", text: $outputName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                if isPairedEnd {
                    Text("Paired files will be named _R1 and _R2 automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Action buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Extract") {
                    performExtract()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440)
    }

    // MARK: - Subviews

    /// A labeled information row.
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    // MARK: - Actions

    /// Builds the extraction config and calls the onExtract callback.
    private func performExtract() {
        let taxIds = Set(selectedNodes.map(\.taxId))
        // Place extracted reads in the parent bundle's directory so the sidebar
        // can discover them. The bundle creation step wraps them in a .lungfishfastq.
        let parentDir = sourceURLs.first!.deletingLastPathComponent()
        let outputDir = parentDir
        let cleanName = outputName.trimmingCharacters(in: .whitespacesAndNewlines)

        if isPairedEnd {
            // Generate paired output filenames
            let stem = cleanName.hasSuffix(".fastq")
                ? String(cleanName.dropLast(6))
                : cleanName
            var outputURLs: [URL] = []
            for (index, _) in sourceURLs.enumerated() {
                let suffix = "_R\(index + 1).fastq"
                outputURLs.append(outputDir.appendingPathComponent(stem + suffix))
            }

            let config = TaxonomyExtractionConfig(
                taxIds: taxIds,
                includeChildren: includeChildren,
                sourceFiles: sourceURLs,
                outputFiles: outputURLs,
                classificationOutput: classificationOutputURL
            )
            onExtract?(config)
        } else {
            // Ensure output has .fastq extension so FASTQBundle can resolve it
            let fileName = cleanName.hasSuffix(".fastq") || cleanName.hasSuffix(".fastq.gz")
                ? cleanName
                : "\(cleanName).fastq"
            let outputURL = outputDir.appendingPathComponent(fileName)
            let config = TaxonomyExtractionConfig(
                taxIds: taxIds,
                includeChildren: includeChildren,
                sourceFile: sourceURLs[0],
                outputFile: outputURL,
                classificationOutput: classificationOutputURL
            )
            onExtract?(config)
        }
    }

    // MARK: - Formatting

    /// Formats a number with thousands separators.
    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
