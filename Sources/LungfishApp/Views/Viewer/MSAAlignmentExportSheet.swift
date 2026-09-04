// MSAAlignmentExportSheet.swift - Destination and format sheet for alignment export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit

/// Where an exported alignment goes. Labels and button titles deliberately
/// match ``ClassifierExtractionDialog`` so the two sheets read as one idiom.
enum MSAExportDestination: String, CaseIterable, Identifiable {
    case bundle
    case file
    case clipboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundle: return "Save as Bundle"
        case .file: return "Save to File…"
        case .clipboard: return "Copy to Clipboard"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .bundle: return "Create Bundle"
        case .file: return "Save"
        case .clipboard: return "Copy"
        }
    }
}

/// Whether the export keeps alignment gaps. This is the choice that changes
/// what the exported object *is*: an alignment, or a set of sequences.
enum MSAExportLayout: String, CaseIterable, Identifiable {
    case aligned
    case unaligned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aligned: return "Aligned FASTA (keep gaps)"
        case .unaligned: return "Unaligned FASTA (remove gaps)"
        }
    }

    /// The bundle kind this layout produces. Gapped residues in a reference
    /// bundle would be a data defect, so aligned stays a `.lungfishmsa`.
    var bundleOutputKind: String {
        switch self {
        case .aligned: return "msa"
        case .unaligned: return "reference"
        }
    }

    var bundleCaption: String {
        switch self {
        case .aligned:
            return "Creates a .lungfishmsa alignment bundle with gaps preserved. Its consensus and variable sites describe the exported subset, not the parent."
        case .unaligned:
            return "Creates a .lungfishref reference bundle holding the sequences with gaps removed."
        }
    }
}

/// Whether the export covers the whole alignment or only the current selection.
enum MSAExportScope: String, CaseIterable, Identifiable {
    case entireAlignment
    case selectedRows

    var id: String { rawValue }
}

struct MSAAlignmentExportConfiguration {
    let destination: MSAExportDestination
    let layout: MSAExportLayout
    let format: String
    let scope: MSAExportScope
    let name: String
}

enum MSAAlignmentExportSheet {
    /// Formats `msa export` accepts. The file destination offers all of them;
    /// hiding formats the CLI already ships would be a parity regression, and
    /// PHYLIP and NEXUS are what tree builders consume.
    static let alignedFileFormats = ["aligned-fasta", "phylip", "nexus", "clustal", "stockholm", "a2m", "a3m"]

    /// The clipboard cap. Gapped output is roughly rows times aligned length,
    /// so this binds sooner than users expect.
    static let clipboardByteCap = 5 * 1024 * 1024

    static func isClipboardAvailable(estimatedBytes: Int) -> Bool {
        estimatedBytes <= clipboardByteCap
    }

    static func clipboardUnavailableMessage(estimatedBytes: Int) -> String {
        let megabytes = max(1, estimatedBytes / 1_048_576)
        return "This alignment is about \(megabytes) MB, too large for the clipboard. Choose Save to File or Save as Bundle instead."
    }

    /// Maps a configuration onto the CLI. The bundle leg uses `msa extract`,
    /// whose `--output-kind` decides gapped versus ungapped; the file and
    /// clipboard legs use `msa export`, whose `--output-format` does.
    static func cliArguments(
        for configuration: MSAAlignmentExportConfiguration,
        bundleURL: URL,
        outputURL: URL,
        rows: String?,
        columns: String?
    ) -> [String] {
        let scopedRows = configuration.scope == .selectedRows ? rows : nil
        let scopedColumns = configuration.scope == .selectedRows ? columns : nil

        switch configuration.destination {
        case .bundle:
            return CLIMSAActionCommandBuilder.buildExtractArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                outputKind: configuration.layout.bundleOutputKind,
                rows: scopedRows,
                columns: scopedColumns,
                name: configuration.name,
                force: true
            )
        case .file, .clipboard:
            return CLIMSAActionCommandBuilder.buildExportArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                outputFormat: configuration.format,
                rows: scopedRows,
                columns: scopedColumns,
                force: true
            )
        }
    }
}


// MARK: - Sheet model and view

/// Observable state for ``MSAAlignmentExportView``.
@Observable
@MainActor
final class MSAAlignmentExportModel {
    var destination: MSAExportDestination = .file
    var layout: MSAExportLayout = .aligned
    var format: String = "aligned-fasta"
    var scope: MSAExportScope = .entireAlignment
    var name: String

    /// Rough size of the exported text, used to gate the clipboard before the
    /// user commits rather than refusing afterwards.
    let estimatedBytes: Int
    /// Whether a multi-row selection exists, which is what makes the scope
    /// control meaningful.
    let hasSelection: Bool
    let selectedRowCount: Int
    let totalRowCount: Int

    init(
        name: String,
        estimatedBytes: Int,
        hasSelection: Bool,
        selectedRowCount: Int,
        totalRowCount: Int
    ) {
        self.name = name
        self.estimatedBytes = estimatedBytes
        self.hasSelection = hasSelection
        self.selectedRowCount = selectedRowCount
        self.totalRowCount = totalRowCount
    }

    var isClipboardAvailable: Bool {
        MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: estimatedBytes)
    }

    var clipboardTooltip: String? {
        isClipboardAvailable ? nil : MSAAlignmentExportSheet.clipboardUnavailableMessage(estimatedBytes: estimatedBytes)
    }

    /// Formats offered for the current destination. Only the file destination
    /// exposes the tree-builder formats; bundle and clipboard stay FASTA.
    var availableFormats: [String] {
        guard destination == .file else {
            return layout == .aligned ? ["aligned-fasta"] : ["fasta"]
        }
        return layout == .aligned ? MSAAlignmentExportSheet.alignedFileFormats : ["fasta"]
    }

    /// Keeps `format` consistent whenever destination or layout changes.
    func reconcileFormat() {
        if !availableFormats.contains(format) {
            format = availableFormats[0]
        }
        if destination == .clipboard && !isClipboardAvailable {
            destination = .file
            reconcileFormat()
        }
    }

    var configuration: MSAAlignmentExportConfiguration {
        MSAAlignmentExportConfiguration(
            destination: destination,
            layout: layout,
            format: format,
            scope: scope,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct MSAAlignmentExportView: View {
    @Bindable var model: MSAAlignmentExportModel
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Export Alignment")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destination")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.lungfishSecondaryText)
                    ForEach(MSAExportDestination.allCases) { destination in
                        let enabled = destination != .clipboard || model.isClipboardAvailable
                        Button {
                            guard enabled else { return }
                            model.destination = destination
                            model.reconcileFormat()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.destination == destination ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(enabled ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                                Text(destination.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(enabled ? Color.primary : Color.lungfishSecondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .help(destination == .clipboard ? (model.clipboardTooltip ?? "") : "")
                        .accessibilityIdentifier("msa-export-destination-\(destination.rawValue)")
                    }
                }

                Picker("Sequences", selection: $model.layout) {
                    ForEach(MSAExportLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .onChange(of: model.layout) { _, _ in model.reconcileFormat() }
                .accessibilityIdentifier("msa-export-layout")

                if model.destination == .file && model.availableFormats.count > 1 {
                    Picker("Format", selection: $model.format) {
                        ForEach(model.availableFormats, id: \.self) { format in
                            Text(format).tag(format)
                        }
                    }
                    .accessibilityIdentifier("msa-export-format")
                }

                if model.hasSelection {
                    Picker("Scope", selection: $model.scope) {
                        Text("Entire alignment (\(model.totalRowCount))").tag(MSAExportScope.entireAlignment)
                        Text("Selected rows (\(model.selectedRowCount))").tag(MSAExportScope.selectedRows)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("msa-export-scope")
                }

                if model.destination == .bundle {
                    Text(model.layout.bundleCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Bundle name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.destination.primaryButtonTitle, action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.destination == .bundle && model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
    }
}
