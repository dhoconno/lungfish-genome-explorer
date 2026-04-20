// ExtractionConfigurationView.swift - SwiftUI sheet for configuring sequence extraction
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

// MARK: - Output Mode

/// How to deliver the extracted sequence.
enum ExtractionOutputMode: String, CaseIterable, Identifiable {
    case clipboardNucleotide = "Copy Nucleotide FASTA"
    case clipboardProtein = "Copy Protein FASTA"
    case newBundle = "Create New Bundle"

    var id: String { rawValue }

    /// Short label for segmented control.
    var label: String {
        switch self {
        case .clipboardNucleotide: return "Copy as FASTA"
        case .clipboardProtein: return "Copy Protein"
        case .newBundle: return "New Bundle"
        }
    }
}

// MARK: - Extraction Configuration

/// Configuration produced by the extraction sheet.
struct ExtractionConfiguration {
    let flank5Prime: Int
    let flank3Prime: Int
    let reverseComplement: Bool
    let concatenateExons: Bool
    let outputMode: ExtractionOutputMode
    let bundleName: String
}

// MARK: - ExtractionConfigurationView

/// A SwiftUI sheet for configuring sequence extraction options.
struct ExtractionConfigurationView: View {

    /// Metadata about the source (set before presenting).
    let sourceName: String
    let sourceType: String
    let isDiscontiguous: Bool
    let isCDS: Bool
    let strand: Strand

    /// Callbacks.
    var onExtract: ((ExtractionConfiguration) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - State

    @State private var flank5Text: String = "0"
    @State private var flank3Text: String = "0"
    @State private var reverseComplement: Bool = false
    @State private var concatenateExons: Bool = true
    @State private var outputMode: ExtractionOutputMode = .clipboardNucleotide
    @State private var bundleName: String = ""

    private let presets = [0, 100, 500, 1000, 5000]

    /// Default bundle name derived from the source.
    private var defaultBundleName: String {
        sourceName.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "scissors")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Extract Sequence")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            // Output mode — prominent segmented control
            Picker("Action", selection: $outputMode) {
                Text("Copy as FASTA")
                    .tag(ExtractionOutputMode.clipboardNucleotide)

                if isCDS {
                    Text("Copy Protein")
                        .tag(ExtractionOutputMode.clipboardProtein)
                }

                Text("New Bundle")
                    .tag(ExtractionOutputMode.newBundle)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("extraction-output-mode-picker")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Content
            Form {
                // Source info
                Section("Source") {
                    LabeledContent("Name", value: sourceName)
                    LabeledContent("Type", value: sourceType)
                    if strand != .unknown {
                        LabeledContent("Strand", value: strand == .forward ? "Forward (+)" : "Reverse (-)")
                    }
                    if isDiscontiguous {
                        LabeledContent("Structure", value: "Discontiguous (multi-exon)")
                    }
                }

                // Flanking
                Section("Flanking Sequence") {
                    HStack {
                        Text("5\u{2032} Flank")
                            .frame(width: 60, alignment: .leading)
                        TextField("0", text: $flank5Text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityIdentifier("extraction-flank5-field")
                        Text("bp")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ForEach(presets.filter { $0 > 0 }, id: \.self) { preset in
                            Button("\(preset)") {
                                flank5Text = "\(preset)"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        Text("3\u{2032} Flank")
                            .frame(width: 60, alignment: .leading)
                        TextField("0", text: $flank3Text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityIdentifier("extraction-flank3-field")
                        Text("bp")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ForEach(presets.filter { $0 > 0 }, id: \.self) { preset in
                            Button("\(preset)") {
                                flank3Text = "\(preset)"
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // Options
                Section("Options") {
                    Toggle("Reverse Complement", isOn: $reverseComplement)
                        .accessibilityIdentifier("extraction-reverse-complement-toggle")

                    if isDiscontiguous {
                        Toggle("Concatenate Exons (remove introns)", isOn: $concatenateExons)
                            .accessibilityIdentifier("extraction-concatenate-exons-toggle")
                    }
                }

                // Bundle name (visible only for New Bundle)
                if outputMode == .newBundle {
                    Section("Bundle") {
                        TextField("Bundle Name", text: $bundleName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("extraction-bundle-name-field")
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("extraction-configuration-sheet")

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("extraction-cancel-button")

                Button("Extract") {
                    let config = ExtractionConfiguration(
                        flank5Prime: Int(flank5Text) ?? 0,
                        flank3Prime: Int(flank3Text) ?? 0,
                        reverseComplement: reverseComplement,
                        concatenateExons: isDiscontiguous ? concatenateExons : false,
                        outputMode: outputMode,
                        bundleName: bundleName.isEmpty ? defaultBundleName : bundleName
                    )
                    onExtract?(config)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("extraction-extract-button")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .frame(minHeight: 400)
        .onAppear {
            bundleName = defaultBundleName
        }
    }
}
