// ClassifierExtractionDialog.swift — Unified classifier read extraction dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow
import SwiftUI

// MARK: - Dialog destination (UI-facing)

/// UI-facing destination enum. Mirrors `ExtractionDestination` but is designed
/// for view binding: it carries no associated values, so we can use it with
/// `@State` / `Picker` directly. The view model translates this into a real
/// `ExtractionDestination` when the user clicks the primary button.
enum DialogDestination: String, CaseIterable, Identifiable {
    case bundle
    case file
    case clipboard
    case share

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundle:    return "Save as Bundle"
        case .file:      return "Save to File…"
        case .clipboard: return "Copy to Clipboard"
        case .share:     return "Share…"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .bundle:    return "Create Bundle"
        case .file:      return "Save"
        case .clipboard: return "Copy"
        case .share:     return "Share"
        }
    }

    /// Whether this destination shows the name field.
    var showsNameField: Bool {
        self == .bundle || self == .file
    }
}

// MARK: - ClassifierExtractionDialogViewModel

/// `@Observable` view model for `ClassifierExtractionDialog`. The model holds
/// all user-editable state and re-computes the read-count estimate whenever
/// any relevant input changes.
///
/// The model is `@MainActor` and `@Observable`; progress updates come in via
/// a direct call on the main actor from the orchestrator.
@Observable
@MainActor
final class ClassifierExtractionDialogViewModel {

    // MARK: - Inputs (set at construction)

    let tool: ClassifierTool
    let selectionCount: Int

    // MARK: - User-editable state

    var format: CopyFormat = .fastq
    var includeUnmappedMates: Bool = false
    var destination: DialogDestination = .bundle
    var name: String

    // MARK: - Derived state

    var estimatedReadCount: Int = 0
    var estimatedUnmappedDelta: Int = 0
    var isRunning: Bool = false
    var progressFraction: Double = 0
    var progressMessage: String = ""
    var errorMessage: String?

    // MARK: - Derived: computed properties

    /// Whether the unmapped-mates toggle row should be visible at all.
    var showsUnmappedMatesToggle: Bool {
        tool != .kraken2
    }

    /// Whether the clipboard radio is disabled due to cap overflow.
    var clipboardDisabledDueToCap: Bool {
        estimatedReadCount > TaxonomyReadExtractionAction.clipboardReadCap
    }

    /// The tooltip shown when the clipboard radio is disabled.
    var clipboardDisabledTooltip: String? {
        clipboardDisabledDueToCap
            ? "Too many reads to fit on the clipboard. Choose Save to File, Save as Bundle, or Share instead."
            : nil
    }

    /// Primary button label — destination-aware.
    var primaryButtonTitle: String {
        destination.primaryButtonTitle
    }

    // MARK: - Init

    init(tool: ClassifierTool, selectionCount: Int, suggestedName: String) {
        self.tool = tool
        self.selectionCount = selectionCount
        self.name = suggestedName
    }
}

// MARK: - ClassifierExtractionDialog

/// The unified classifier extraction dialog.
struct ClassifierExtractionDialog: View {

    @Bindable var model: ClassifierExtractionDialogViewModel

    var onCancel: () -> Void
    var onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text("Extract Reads")
                    .font(.headline)
                Spacer()
                Text(model.tool.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                // Selection summary
                let selectedLabel = "Selected: \(model.selectionCount) row\(model.selectionCount == 1 ? "" : "s")"
                Text(selectedLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lungfishHelp(LungfishHelpContent.classifierExtractionSummary)

                HStack(spacing: 4) {
                    Text("≈")
                    Text("\(model.estimatedReadCount) unique read\(model.estimatedReadCount == 1 ? "" : "s")")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lungfishHelp(LungfishHelpContent.classifierExtractionSummary)

                Divider()
                    .padding(.vertical, 2)

                // Format picker
                HStack {
                    Text("Format:")
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: $model.format) {
                        Text("FASTQ").tag(CopyFormat.fastq)
                        Text("FASTA").tag(CopyFormat.fasta)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .disabled(model.isRunning)
                    .lungfishHelp(LungfishHelpContent.classifierExtractionFormat)
                    Spacer()
                }

                // Unmapped-mates toggle (hidden for Kraken2)
                if model.showsUnmappedMatesToggle {
                    HStack {
                        Text("")
                            .frame(width: 90, alignment: .trailing)
                        Toggle("Include unmapped mates of mapped pairs", isOn: $model.includeUnmappedMates)
                            .toggleStyle(.checkbox)
                            .disabled(model.isRunning)
                            .lungfishHelp(LungfishHelpContent.classifierExtractionUnmappedMates)
                    }
                    if model.estimatedUnmappedDelta != 0 {
                        HStack {
                            Text("")
                                .frame(width: 90, alignment: .trailing)
                            Text("+ ~\(model.estimatedUnmappedDelta) read\(model.estimatedUnmappedDelta == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                // Destination picker — implemented as a manual Button +
                // Image(systemName:) radio row rather than SwiftUI's
                // `Picker(selection:).pickerStyle(.radioGroup)` because the
                // latter has no clean way to disable a single tag (the
                // clipboard row is disabled when the selection exceeds the
                // clipboardReadCap). The manual pattern trades a bit of
                // VoiceOver polish for per-row disable-state control.
                HStack(alignment: .top) {
                    Text("Destination:")
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(DialogDestination.allCases) { dest in
                            let disabled = (dest == .clipboard && model.clipboardDisabledDueToCap)
                            HStack(spacing: 6) {
                                Button(action: {
                                    if !disabled { model.destination = dest }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: model.destination == dest ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(disabled ? .gray : .primary)
                                        Text(dest.label)
                                            .foregroundStyle(disabled ? .gray : .primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(disabled || model.isRunning)
                                .help(dest == .clipboard ? (model.clipboardDisabledTooltip ?? LungfishHelpContent.classifierExtractionDestination.summary) : LungfishHelpContent.classifierExtractionDestination.summary)
                                .accessibilityHint(LungfishHelpContent.classifierExtractionDestination.detail ?? LungfishHelpContent.classifierExtractionDestination.summary)
                            }
                        }
                    }
                    Spacer()
                }

                // Name field (for bundle and file)
                if model.destination.showsNameField {
                    HStack {
                        Text("Name:")
                            .font(.system(size: 12))
                            .frame(width: 90, alignment: .trailing)
                        TextField("", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(model.isRunning)
                            .lungfishHelp(LungfishHelpContent.classifierExtractionName)
                    }
                }

                // Progress / error display
                if model.isRunning {
                    Divider()
                        .padding(.vertical, 2)
                    ProgressView(value: model.progressFraction)
                    Text(model.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let err = model.errorMessage {
                    Divider()
                        .padding(.vertical, 2)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishDangerFallback)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.primaryButtonTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || (model.destination.showsNameField && model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .lungfishHelp(LungfishHelpContent.classifierExtractFASTQ)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
    }
}
