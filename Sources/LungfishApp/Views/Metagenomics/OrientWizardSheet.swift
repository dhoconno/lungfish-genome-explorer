// OrientWizardSheet.swift - SwiftUI wizard for configuring a vsearch orient run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow
import LungfishIO

// MARK: - OrientWizardSheet

/// A SwiftUI sheet for configuring and launching a vsearch orient run.
///
/// Orients FASTQ reads so they face 5' -> 3' relative to a reference sequence.
/// Reads on the minus strand are reverse-complemented. Essential for amplicon
/// data with known primer orientation.
///
/// ## Reference Picker
///
/// Uses the reusable ``ReferenceSequencePickerView`` component to list project
/// references and allow browsing for external FASTA files. External files are
/// auto-imported into the project's Reference Sequences folder.
///
/// ## Presentation
///
/// Hosted in an `NSPanel` via `NSHostingController` and presented with
/// `beginSheetModal` (per macOS 26 rules -- never `runModal()`).
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | Orient Reads                          dataset_name  |
/// | Align read strand to reference                      |
/// +----------------------------------------------------+
/// | Reference Sequence                                  |
/// |   [ SARS-CoV-2              v ]  [Browse...]        |
/// +----------------------------------------------------+
/// | > Advanced Settings                                 |
/// |   Word Length: [ 12 ]                               |
/// |   DB Mask: [ dust  v ]                              |
/// |   Query Mask: [ dust  v ]                           |
/// |   Save Unoriented: [x]                              |
/// |   Threads: [ 8 ]                                    |
/// +----------------------------------------------------+
/// |                           [Cancel]  [Run]           |
/// +----------------------------------------------------+
/// ```
struct OrientWizardSheet: View {

    /// The input FASTQ files to orient.
    let inputFiles: [URL]

    /// The project directory URL, used for reference discovery.
    let projectURL: URL?

    // MARK: - State

    /// The selected reference FASTA URL.
    @State private var selectedReferenceURL: URL?

    /// Word length for vsearch k-mer matching (3-15).
    @State private var wordLength: Int = 12

    /// Low-complexity masking mode for the database.
    @State private var dbMask: String = "dust"

    /// Low-complexity masking mode for queries.
    @State private var qMask: String = "dust"

    /// Whether to save unoriented reads as a separate output.
    @State private var saveUnoriented: Bool = true

    /// Number of threads for vsearch.
    @State private var threads: Int = ProcessInfo.processInfo.processorCount

    /// Whether the advanced settings disclosure group is expanded.
    @State private var showAdvanced: Bool = false

    // MARK: - Callbacks

    /// Called when the user clicks Run with a configured ``OrientConfig``.
    var onRun: ((OrientConfig) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - Mask Options

    /// Available mask mode options for vsearch.
    private static let maskOptions = ["dust", "none"]

    // MARK: - Computed Properties

    /// Display name for the input dataset.
    ///
    /// Display name for the input dataset, stripping bundle extensions.
    private var inputDisplayName: String {
        inputFiles.first?.lungfishDisplayName ?? ""
    }

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        !inputFiles.isEmpty && selectedReferenceURL != nil
    }

    // MARK: - Body

    var body: some View {
        WizardSheet(
            title: "Orient Reads",
            subtitle: "Align read strand to reference",
            accessoryText: inputDisplayName,
            statusText: footerStatusText,
            statusColor: Color.lungfishOrangeFallback,
            isPrimaryEnabled: canRun,
            onCancel: { onCancel?() },
            onPrimary: performRun,
            icon: {
                Image(systemName: "arrow.uturn.right")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            },
            content: {
                VStack(alignment: .leading, spacing: 16) {
                    referenceSection
                    Divider()
                    advancedSettings
                }
            }
        )
    }

    // MARK: - Reference Section

    /// Reference sequence picker using the reusable component.
    private var referenceSection: some View {
        ReferenceSequencePickerView(
            projectURL: projectURL,
            selectedReferenceURL: $selectedReferenceURL
        )
    }

    // MARK: - Advanced Settings

    /// Collapsible advanced settings section.
    private var advancedSettings: some View {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // Word length
                HStack {
                    Text("Word length:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper(
                        "\(wordLength)",
                        value: $wordLength,
                        in: 3...15
                    )
                    .font(.system(size: 12))
                    Text("k-mer size for matching")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // DB mask
                HStack {
                    Text("DB mask:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: $dbMask) {
                        ForEach(Self.maskOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                // Query mask
                HStack {
                    Text("Query mask:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: $qMask) {
                        ForEach(Self.maskOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                // Save unoriented
                HStack {
                    Text("Save unoriented:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Toggle("", isOn: $saveUnoriented)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text("Keep reads that could not be oriented")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Threads
                HStack {
                    Text("Threads:")
                        .font(.system(size: 12))
                        .frame(width: 120, alignment: .trailing)
                    Stepper(
                        "\(threads)",
                        value: $threads,
                        in: 1...ProcessInfo.processInfo.processorCount
                    )
                    .font(.system(size: 12))
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var footerStatusText: String? {
        if !canRun && inputFiles.isEmpty {
            return "No input files selected"
        }
        if !canRun && selectedReferenceURL == nil {
            return "Select a reference sequence"
        }
        return nil
    }

    // MARK: - Actions

    /// Builds an ``OrientConfig`` from the current settings and calls `onRun`.
    private func performRun() {
        guard let referenceURL = selectedReferenceURL,
              let inputURL = inputFiles.first else { return }

        let config = OrientConfig(
            inputURL: inputURL,
            referenceURL: referenceURL,
            wordLength: wordLength,
            dbMask: dbMask,
            qMask: qMask,
            saveUnoriented: saveUnoriented,
            threads: threads
        )

        onRun?(config)
    }
}
