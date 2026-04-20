// TranslationToolView.swift - Geneious-style multi-frame translation tool
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

// MARK: - Translation Mode

/// Preset frame configurations for the translation tool.
enum TranslationMode: String, CaseIterable, Identifiable {
    case singleFrame = "Single Frame"
    case threeForward = "3 Forward"
    case threeReverse = "3 Reverse"
    case allSix = "All 6 Frames"

    var id: String { rawValue }

    /// The reading frames associated with this mode.
    func frames(singleFrame: ReadingFrame) -> [ReadingFrame] {
        switch self {
        case .singleFrame: return [singleFrame]
        case .threeForward: return ReadingFrame.forwardFrames
        case .threeReverse: return ReadingFrame.reverseFrames
        case .allSix: return ReadingFrame.allCases
        }
    }
}

// MARK: - Translation Tool Configuration

/// Configuration emitted by the translation tool when the user clicks Apply.
struct TranslationToolConfiguration {
    let frames: [ReadingFrame]
    let codonTable: CodonTable
    let colorScheme: AminoAcidColorScheme
    let showStopCodons: Bool
}

// MARK: - TranslationToolView

/// A Geneious-style translation tool presented as a sheet.
///
/// Allows the user to pick a translation mode (single frame, 3 forward,
/// 3 reverse, all 6), select a codon table and color scheme, and apply
/// the configuration to the viewer.
struct TranslationToolView: View {
    /// Callback invoked when the user clicks Apply.
    var onApply: ((TranslationToolConfiguration) -> Void)?

    /// Callback invoked when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - State

    @State private var mode: TranslationMode = .threeForward
    @State private var singleFrame: ReadingFrame = .plus1
    @State private var selectedTableIndex: Int = 0
    @State private var colorScheme: AminoAcidColorScheme = .zappo
    @State private var showStopCodons: Bool = true

    /// Codon table options (parallel arrays for Picker).
    private let codonTables = CodonTable.allTables
    private let codonTableNames = CodonTable.allTables.map(\.name)

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "character.textbox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Translation Tool")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Content
            Form {
                // Mode picker
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(TranslationMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("translation-tool-mode-picker")

                    if mode == .singleFrame {
                        Picker("Frame", selection: $singleFrame) {
                            ForEach(ReadingFrame.allCases, id: \.self) { frame in
                                Text(frame.rawValue).tag(frame)
                            }
                        }
                        .accessibilityIdentifier("translation-tool-frame-picker")
                    }
                } header: {
                    Text("Reading Frames")
                }

                // Codon table
                Section {
                    Picker("Genetic Code", selection: $selectedTableIndex) {
                        ForEach(0..<codonTables.count, id: \.self) { i in
                            Text(codonTableNames[i]).tag(i)
                        }
                    }
                    .accessibilityIdentifier("translation-tool-codon-table-picker")
                } header: {
                    Text("Codon Table")
                }

                // Display options
                Section {
                    Picker("Color Scheme", selection: $colorScheme) {
                        ForEach(AminoAcidColorScheme.allCases, id: \.self) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .accessibilityIdentifier("translation-tool-color-scheme-picker")

                    Toggle("Show Stop Codons", isOn: $showStopCodons)
                        .accessibilityIdentifier("translation-tool-stop-codons-toggle")
                } header: {
                    Text("Display Options")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .accessibilityIdentifier("translation-tool-sheet")

            Divider()

            // Frame preview
            framePreview
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("translation-tool-cancel-button")

                Spacer()

                Button("Hide Translation") {
                    let config = TranslationToolConfiguration(
                        frames: [],
                        codonTable: codonTables[selectedTableIndex],
                        colorScheme: colorScheme,
                        showStopCodons: showStopCodons
                    )
                    onApply?(config)
                }
                .accessibilityIdentifier("translation-tool-hide-button")

                Button("Apply") {
                    let frames = mode.frames(singleFrame: singleFrame)
                    let config = TranslationToolConfiguration(
                        frames: frames,
                        codonTable: codonTables[selectedTableIndex],
                        colorScheme: colorScheme,
                        showStopCodons: showStopCodons
                    )
                    onApply?(config)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("translation-tool-apply-button")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 480)
    }

    // MARK: - Frame Preview

    @ViewBuilder
    private var framePreview: some View {
        let frames = mode.frames(singleFrame: singleFrame)
        HStack(spacing: 4) {
            Text("Frames:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(frames, id: \.self) { frame in
                Text(frame.rawValue)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(frame.isReverse
                                  ? Color.purple.opacity(0.15)
                                  : Color.blue.opacity(0.15))
                    )
            }
            Spacer()
        }
    }
}
