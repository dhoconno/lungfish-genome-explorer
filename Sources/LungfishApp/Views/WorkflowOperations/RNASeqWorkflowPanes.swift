// RNASeqWorkflowPanes.swift - The inputs and settings of the export and pseudobulk rows of the Workflow Operations dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import SwiftUI

/// The words the two rows add to the CLI's own help. The cutoff and the fold-change bar come from `RNASeqExportDefaults`, which a
/// test pins to the golden help.
enum RNASeqPaneWords {
    static let resultsCaption = "One or more .lungfishrnaseq result folders. A single-cell result is exported alone. The results must come from one route and one reference set."
    static let sampleSheetCaption = "A tab-separated sheet with a sample column. Its other columns join samples.tsv."
    static let exportFolderCaption = "The new folder to write inside the output directory. It must not exist."
    static let designCaption = "A column of samples.tsv that enters the model. Separate more than one with commas, and the last one is the tested factor."
    static let contrastCaption = "FACTOR:NUMERATOR:DENOMINATOR, such as group:TB:HIV. Put each contrast on its own line."
    static let batchCaption = "The column of samples.tsv that names each sample's batch, used for batch correction."
    static let singleCellCaption = "A single-cell .lungfishrnaseq result."
    static let labelsCaption = "A tab-separated table with barcode and label columns, and sample for a result of two or more samples."
    static let smallGroupCaption = "A group under 10 cells is left out, and so are the cells with no label. The Operations row says which."
    static let pseudobulkFolderCaption = "The new result is written in the output directory with .lungfishrnaseq added to the name. It must not exist."
}

private struct RNASeqPaneGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RNASeqPaneCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// The open panels of the two rows. A result is a folder that Finder may show as a package, so the panel opens packages as folders.
@MainActor
private enum RNASeqPanePicker {
    static func chooseResults(title: String, message: String, multiple: Bool, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = multiple
        present(panel, completion: completion)
    }

    static func chooseTable(title: String, message: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        present(panel) { urls in
            if let url = urls.first { completion(url) }
        }
    }

    private static func present(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            completion(panel.urls.map(\.standardizedFileURL))
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}

private struct RNASeqPaneFileRow: View {
    let url: URL?
    let emptyText: String
    let projectURL: URL?
    let identifier: String
    let choose: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let url {
                Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: projectURL))
                    .font(.body)
                    .lineLimit(2)
                    .help(url.path)
            } else {
                Text(emptyText)
                    .font(.body)
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }
            Spacer()
            Button(url == nil ? "Choose…" : "Replace…", action: choose)
                .accessibilityIdentifier("\(identifier)-choose")
            if url != nil {
                Button("Clear", action: clear)
                    .accessibilityIdentifier("\(identifier)-clear")
            }
        }
    }
}

/// The inputs of the export row, in place of the reference and the FASTQ bundles.
struct RNASeqExportInputsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "RNA-seq Results") {
                if state.rnaSeqExport.resultURLs.isEmpty {
                    Text("No RNA-seq results selected")
                        .font(.body)
                        .foregroundStyle(Color.lungfishOrangeFallback)
                } else {
                    ForEach(state.rnaSeqExport.resultURLs, id: \.self) { url in
                        Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: state.projectURL))
                            .font(.body)
                            .lineLimit(1)
                            .help(url.path)
                    }
                }
                HStack(spacing: 10) {
                    Button(state.rnaSeqExport.resultURLs.isEmpty ? "Choose…" : "Replace…") {
                        RNASeqPanePicker.chooseResults(
                            title: "Choose RNA-seq Results",
                            message: "Choose one or more .lungfishrnaseq result folders.",
                            multiple: true
                        ) { urls in state.rnaSeqExport.resultURLs = urls }
                    }
                    .accessibilityIdentifier("rnaseq-export-results-choose")
                    if !state.rnaSeqExport.resultURLs.isEmpty {
                        Button("Clear") { state.rnaSeqExport.resultURLs = [] }
                            .accessibilityIdentifier("rnaseq-export-results-clear")
                    }
                }
                RNASeqPaneCaption(RNASeqPaneWords.resultsCaption)
            }
            RNASeqPaneGroup(title: "Sample Sheet (optional)") {
                RNASeqPaneFileRow(
                    url: state.rnaSeqExport.sampleSheetURL,
                    emptyText: "No sample sheet",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-export-sample-sheet",
                    choose: {
                        RNASeqPanePicker.chooseTable(
                            title: "Choose Sample Sheet",
                            message: "Choose a tab-separated sheet with a sample column."
                        ) { url in state.rnaSeqExport.sampleSheetURL = url }
                    },
                    clear: { state.rnaSeqExport.sampleSheetURL = nil }
                )
                RNASeqPaneCaption(RNASeqPaneWords.sampleSheetCaption)
            }
        }
    }
}

/// The settings of the export row. The CLI checks every one of them, so a refusal shows on the Operations row in its words.
struct RNASeqExportSettingsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "Export Folder") {
                TextField("Folder name", text: $state.outputName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rnaseq-export-folder-name")
                RNASeqPaneCaption(RNASeqPaneWords.exportFolderCaption)
            }
            RNASeqExportOptionFields(model: state.rnaSeqExport)
        }
    }
}

private struct RNASeqExportOptionFields: View {
    @Bindable var model: RNASeqExportDialogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "Design") {
                TextField("Design terms", text: $model.designText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rnaseq-export-design")
                RNASeqPaneCaption(RNASeqPaneWords.designCaption)
            }
            RNASeqPaneGroup(title: "Contrasts") {
                TextEditor(text: $model.contrastsText)
                    .font(.body)
                    .frame(minHeight: 52, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                    .accessibilityIdentifier("rnaseq-export-contrasts")
                RNASeqPaneCaption(RNASeqPaneWords.contrastCaption)
            }
            RNASeqPaneGroup(title: "Adjusted p-value Cutoff") {
                TextField("0.05", text: $model.cutoffText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityIdentifier("rnaseq-export-cutoff")
                RNASeqPaneCaption(RNASeqExportDefaults.cutoffHelp + ".")
            }
            RNASeqPaneGroup(title: "Fold-change Bar") {
                TextField("None", text: $model.lfcBarText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityIdentifier("rnaseq-export-lfc-bar")
                RNASeqPaneCaption(RNASeqExportDefaults.lfcBarHelp + ".")
            }
            RNASeqPaneGroup(title: "Batch") {
                TextField("Batch column", text: $model.batchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rnaseq-export-batch")
                Picker("Batch correction", selection: $model.batchCorrection) {
                    Text("None").tag(RNASeqExportRunRequest.BatchCorrection.none)
                    Text("ComBat-seq").tag(RNASeqExportRunRequest.BatchCorrection.combatSeq)
                    Text("SVA").tag(RNASeqExportRunRequest.BatchCorrection.sva)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("rnaseq-export-batch-correction")
                RNASeqPaneCaption(RNASeqPaneWords.batchCaption)
            }
        }
    }
}

/// The inputs of the pseudobulk row, in place of the reference and the FASTQ bundles.
struct RNASeqPseudobulkInputsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "Single-cell RNA-seq Result") {
                RNASeqPaneFileRow(
                    url: state.rnaSeqPseudobulk.resultURL,
                    emptyText: "No single-cell result selected",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-pseudobulk-result",
                    choose: {
                        RNASeqPanePicker.chooseResults(
                            title: "Choose a Single-cell RNA-seq Result",
                            message: "Choose a single-cell .lungfishrnaseq result folder.",
                            multiple: false
                        ) { urls in state.rnaSeqPseudobulk.resultURL = urls.first }
                    },
                    clear: { state.rnaSeqPseudobulk.resultURL = nil }
                )
                RNASeqPaneCaption(RNASeqPaneWords.singleCellCaption)
            }
            RNASeqPaneGroup(title: "Labels Table") {
                RNASeqPaneFileRow(
                    url: state.rnaSeqPseudobulk.labelsURL,
                    emptyText: "No labels table selected",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-pseudobulk-labels",
                    choose: {
                        RNASeqPanePicker.chooseTable(
                            title: "Choose Labels Table",
                            message: "Choose a tab-separated table with barcode and label columns."
                        ) { url in state.rnaSeqPseudobulk.labelsURL = url }
                    },
                    clear: { state.rnaSeqPseudobulk.labelsURL = nil }
                )
                RNASeqPaneCaption(RNASeqPaneWords.labelsCaption)
                RNASeqPaneCaption(RNASeqPaneWords.smallGroupCaption)
            }
        }
    }
}

/// The settings of the pseudobulk row, which are the name of the new result.
struct RNASeqPseudobulkSettingsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        RNASeqPaneGroup(title: "Result Name") {
            TextField("Result name", text: $state.outputName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rnaseq-pseudobulk-result-name")
            RNASeqPaneCaption(RNASeqPaneWords.pseudobulkFolderCaption)
        }
    }
}
