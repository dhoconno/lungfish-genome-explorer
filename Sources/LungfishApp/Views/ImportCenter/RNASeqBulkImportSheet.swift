// RNASeqBulkImportSheet.swift - The sheet of the Import Center's bulk RNA-seq card, and the parts both sheets share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.4 lane RS-GLUE. The card asks for salmon folders, one count table or the tables nf-core/rnaseq wrote. This sheet
// then asks for the name, a sample sheet, a transcript-to-gene table (folders only) and the unit (a table only). The
// values become `lungfish-cli import rnaseq` options in `RNASeqImportSheetModel`, and nothing here computes a number.

import AppKit
import SwiftUI

/// The open panel both sheets use to choose a file or a folder. It opens on the sheet.
@MainActor
enum RNASeqImportPanels {
    static func choose(message: String, directories: Bool, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            panel.begin { response in
                completion(response == .OK ? panel.url : nil)
            }
        }
    }
}

/// One optional file or folder: its label, the name chosen or None, the two buttons and a line of help below.
struct RNASeqImportChooserRow: View {
    let title: String
    let help: String?
    let value: URL?
    let identifier: String
    let choose: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                Text(value?.lastPathComponent ?? "None")
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("\(identifier)-value")
                Spacer()
                Button("Choose\u{2026}", action: choose)
                    .accessibilityIdentifier("\(identifier)-choose")
                Button("Clear", action: clear)
                    .disabled(value == nil)
                    .accessibilityIdentifier("\(identifier)-clear")
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, RNASeqImportLayout.labelWidth + 8)
            }
        }
    }
}

enum RNASeqImportLayout {
    static let labelWidth: CGFloat = 170
}

/// The name field both sheets start with.
struct RNASeqImportNameRow: View {
    @Bindable var model: RNASeqImportSheetModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Name:")
                .frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
            TextField("Name of the result", text: $model.name)
                .accessibilityIdentifier("rnaseq-import-name")
        }
    }
}

/// The sample sheet row both sheets share. A sheet's ids must name the same samples as the folders or the columns, and
/// the command refuses a sheet that does not, in words that list both sides.
struct RNASeqImportSampleSheetRow: View {
    @Bindable var model: RNASeqImportSheetModel

    var body: some View {
        RNASeqImportChooserRow(
            title: "Sample sheet:",
            help: "Optional. A tab-separated sheet with a sample column and, when known, run, animal, species, origin and group. "
                + "Its sample column, or its run column when it has one, must name the same samples as the \(model.kind == .bulk ? "folders or columns" : "folders"). "
                + "Without one, each is a sample whose other fields read Not recorded.",
            value: model.sampleSheet,
            identifier: "rnaseq-import-samples",
            choose: {
                RNASeqImportPanels.choose(message: "Choose the sample sheet", directories: false) { url in
                    if let url { model.sampleSheet = url }
                }
            },
            clear: { model.sampleSheet = nil }
        )
    }
}

/// The note about a project path, the CLI's refusal, the progress line and the two buttons.
struct RNASeqImportFooter: View {
    @Bindable var model: RNASeqImportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = model.outsideProjectNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rnaseq-import-outside-note")
            }
            if let failure = model.failure {
                // Red is for a refusal, which carries a hint. A cancel, and the line that sends a person to the Operations
                // panel, read in the secondary colour, since a cancel is Cancelled and not an error (RS-GLUE-UX SF-3).
                Text(failure)
                    .foregroundStyle(model.hint == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("rnaseq-import-failure")
                if let hint = model.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("rnaseq-import-hint")
                }
            }
            if model.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Importing. The Operations panel shows each step.")
                        .foregroundStyle(.secondary)
                }
            } else if let missing = model.missingChoice {
                Text(missing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("rnaseq-import-missing")
            }
            HStack {
                Spacer()
                Button(model.phase == .running ? "Cancel Import" : "Cancel") { model.cancelClicked() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rnaseq-import-cancel")
                Button("Import") { model.importClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                    .accessibilityIdentifier("rnaseq-import-run")
            }
        }
    }
}

/// The sheet of the bulk card.
struct RNASeqBulkImportSheet: View {
    @Bindable var model: RNASeqImportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import RNA-seq Counts")
                .font(.headline)
            Text(model.inputSummary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("rnaseq-import-inputs")
            Text(RNASeqImportWords.externalInputs)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                RNASeqImportNameRow(model: model)
                RNASeqImportSampleSheetRow(model: model)
                if model.isSalmonFolders {
                    RNASeqImportChooserRow(
                        title: "Transcript-to-gene table:",
                        help: "Optional. With it the result adds gene counts summed from the transcripts. "
                            + "Without it the result holds the transcript counts only.",
                        value: model.tx2gene,
                        identifier: "rnaseq-import-tx2gene",
                        choose: {
                            RNASeqImportPanels.choose(message: "Choose the transcript-to-gene table", directories: false) { url in
                                if let url { model.tx2gene = url }
                            }
                        },
                        clear: { model.tx2gene = nil }
                    )
                }
                if model.isCountTable {
                    unitRow
                }
            }
            .disabled(model.phase == .running)
            RNASeqImportFooter(model: model)
        }
        .padding(20)
        .frame(width: 580)
    }

    private var unitRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Unit:")
                    .frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                Picker("Unit", selection: $model.unit) {
                    Text("Choose\u{2026}").tag(String?.none)
                    ForEach(RNASeqImportSheetModel.unitChoices) { choice in
                        Text(choice.title).tag(String?.some(choice.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityIdentifier("rnaseq-import-unit")
                Spacer()
            }
            Text("A count table states no unit, so choose what its numbers count. salmon's own numbers are estimated counts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, RNASeqImportLayout.labelWidth + 8)
        }
    }
}
