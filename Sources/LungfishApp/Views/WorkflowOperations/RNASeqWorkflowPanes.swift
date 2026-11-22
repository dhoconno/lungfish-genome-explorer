// RNASeqWorkflowPanes.swift - The inputs and settings of the export and pseudobulk rows of the Workflow Operations dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
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
    static let singleCellCaption = "Choose a .lungfishrnaseq folder."
    static let labelsCaption = "A tab-separated table with barcode and label columns, and sample for a result of two or more samples."
    static let smallGroupCaption = "Groups under 10 cells and cells with no label are left out. The Operations row says which."
    static let selectionCaption = "Per sample, one column for selected cells, one for other drawn cells."
    static let selectionLabelsTableFact = "LGE writes the selection's labels table before the run, outside the single-cell result, and the record names it."
    static let pseudobulkFolderCaption = "LGE always appends .lungfishrnaseq and saves the result in the output directory, where the resulting folder name must be unused."
    static let importResultCaption = "A single-cell .lungfishrnaseq result. LGE matches each cell by sample and barcode, as the result holds them."
    static let importCoordinatesCaption = "LGE's table, or one of 10x's projection.csv files. Choose more than one file for more embeddings."
    static let importClustersCaption = "One of 10x's clusters.csv files."
    static let importLabelColumnsCaption = "The columns of LGE's table that hold labels, separated by commas."
    static let importToolCaption = "The tool that made the files and its version, as you state them. LGE records both and did not compute the embedding."
    static let importFolderCaption = "The new cell map is written in the output directory with .lungfishrnaseq added to the name. It must not exist."
    static let importBarcodesCaption = "Barcodes match as given. When a refusal says the files and the result differ by -1, turn on one of these and import again."
    static let importSkipCaption = "Leave out the barcodes of the files that the result does not hold. The record counts them."
    static let importOtherCountsCaption = "Turn this on when the embedding was computed on counts other than this result's, such as 10x's analysis of Cell Ranger counts. The record and the view then say computed on other counts."
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

    /// One or more files, for the coordinates and clusters of the Import Embedding row.
    static func chooseTables(title: String, message: String, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        present(panel, completion: completion)
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
            RNASeqPaneGroup(title: "RNA-seq results") {
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
            RNASeqPaneGroup(title: "Sample sheet (optional)") {
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
            RNASeqPaneGroup(title: "Export folder") {
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
            RNASeqPaneGroup(title: "Adjusted p-value cutoff") {
                TextField("0.05", text: $model.cutoffText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityIdentifier("rnaseq-export-cutoff")
                RNASeqPaneCaption(RNASeqExportDefaults.cutoffHelp + ".")
            }
            RNASeqPaneGroup(title: "Fold-change bar") {
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
            RNASeqPaneGroup(title: "Single-cell RNA-seq result") {
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
                .lungfishHelp(RNASeqPseudobulkHelp.singleCellResult)
            }
            if let selection = state.rnaSeqPseudobulk.selection {
                // Pseudobulk Selected Cells… names the selection by count and cell map, never by the table's path (UX OBJECT U8).
                RNASeqPaneGroup(title: "Selected cells") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(selection.line)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("rnaseq-pseudobulk-selection")
                            .lungfishHelp(RNASeqPseudobulkHelp.selectionLabelsTable)
                        LungfishInfoButtonView(RNASeqPseudobulkHelp.selectionTest, about: RNASeqPseudobulkHelp.selectionTestSubject)
                    }
                    ForEach(selection.underTenWords, id: \.self) { RNASeqPaneCaption($0) }
                    RNASeqPaneCaption(RNASeqPaneWords.selectionCaption)
                }
            } else {
            RNASeqPaneGroup(title: "Labels table") {
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
}

/// The settings of the pseudobulk row, which are the name of the new result.
struct RNASeqPseudobulkSettingsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        RNASeqPaneGroup(title: "Result name") {
            TextField("Result name", text: $state.outputName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rnaseq-pseudobulk-result-name")
                .lungfishHelp(RNASeqPseudobulkHelp.resultFolder)
        }
    }
}

// MARK: - Import Embedding

private struct RNASeqPaneFilesRow: View {
    let urls: [URL]
    let emptyText: String
    let projectURL: URL?
    let identifier: String
    let choose: () -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if urls.isEmpty {
                Text(emptyText).font(.body).foregroundStyle(Color.lungfishOrangeFallback)
            } else {
                ForEach(urls, id: \.self) { url in
                    Text(WorkflowOperationDialogState.displayPath(for: url, relativeTo: projectURL))
                        .font(.body)
                        .lineLimit(1)
                        .help(url.path)
                }
            }
            HStack(spacing: 10) {
                Button(urls.isEmpty ? "Choose…" : "Replace…", action: choose)
                    .accessibilityIdentifier("\(identifier)-choose")
                if !urls.isEmpty {
                    Button("Clear", action: clear).accessibilityIdentifier("\(identifier)-clear")
                }
            }
        }
    }
}

/// The inputs of the Import Embedding row. The files are the person's own, so LGE records them as given and the CLI checks them.
struct RNASeqCellMapImportInputsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    var body: some View {
        @Bindable var model = state.rnaSeqCellMapImport
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "Single-cell RNA-seq result") {
                RNASeqPaneFileRow(
                    url: model.resultURL,
                    emptyText: "No single-cell result selected",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-import-result",
                    choose: {
                        RNASeqPanePicker.chooseResults(
                            title: "Choose a Single-cell RNA-seq Result",
                            message: "Choose a single-cell .lungfishrnaseq result folder.",
                            multiple: false
                        ) { urls in model.resultURL = urls.first }
                    },
                    clear: { model.resultURL = nil }
                )
                RNASeqPaneCaption(RNASeqPaneWords.importResultCaption)
            }
            RNASeqPaneGroup(title: "Coordinates") {
                RNASeqPaneFilesRow(
                    urls: model.coordinateURLs,
                    emptyText: "No coordinates file selected",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-import-coordinates",
                    choose: {
                        RNASeqPanePicker.chooseTables(
                            title: "Choose Coordinates",
                            message: "Choose LGE's table or 10x's projection.csv files."
                        ) { urls in model.coordinateURLs = urls }
                    },
                    clear: { model.coordinateURLs = [] }
                )
                RNASeqPaneCaption(RNASeqPaneWords.importCoordinatesCaption)
            }
            RNASeqPaneGroup(title: "Clusters (optional)") {
                RNASeqPaneFilesRow(
                    urls: model.clusterURLs,
                    emptyText: "No clusters file selected",
                    projectURL: state.projectURL,
                    identifier: "rnaseq-import-clusters",
                    choose: {
                        RNASeqPanePicker.chooseTables(
                            title: "Choose Clusters",
                            message: "Choose 10x's clusters.csv files."
                        ) { urls in model.clusterURLs = urls }
                    },
                    clear: { model.clusterURLs = [] }
                )
                RNASeqPaneCaption(RNASeqPaneWords.importClustersCaption)
            }
            RNASeqPaneGroup(title: "Label columns (optional)") {
                TextField("Label columns", text: $model.labelColumnsText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rnaseq-import-label-columns")
                RNASeqPaneCaption(RNASeqPaneWords.importLabelColumnsCaption)
            }
            RNASeqPaneGroup(title: "Tool and version (optional)") {
                HStack(spacing: 10) {
                    TextField("Tool", text: $model.tool)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("rnaseq-import-tool")
                    TextField("Version", text: $model.toolVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .accessibilityIdentifier("rnaseq-import-tool-version")
                }
                RNASeqPaneCaption(RNASeqPaneWords.importToolCaption)
            }
        }
    }
}

/// The settings of the Import Embedding row. The three flags that unlock a refusal of the import are checkboxes here, off until
/// the person turns one on, and the alert of a refusal names the one that unlocks it (`RNASeqCellMapImportWords`).
struct RNASeqCellMapImportSettingsPane: View {
    @Bindable var state: WorkflowOperationDialogState

    private func suffixBinding(_ value: RNASeqCellMapImportRunRequest.BarcodeSuffix) -> Binding<Bool> {
        Binding(
            get: { state.rnaSeqCellMapImport.barcodeSuffix == value },
            set: { state.rnaSeqCellMapImport.barcodeSuffix = $0 ? value : nil })
    }

    var body: some View {
        @Bindable var model = state.rnaSeqCellMapImport
        VStack(alignment: .leading, spacing: 12) {
            RNASeqPaneGroup(title: "Result name") {
                TextField("Result name", text: $state.outputName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rnaseq-import-result-name")
                RNASeqPaneCaption(RNASeqPaneWords.importFolderCaption)
            }
            RNASeqPaneGroup(title: "Barcodes") {
                Toggle(RNASeqCellMapImportWords.dropControl, isOn: suffixBinding(.drop))
                    .accessibilityIdentifier("rnaseq-import-drop-suffix")
                Toggle(RNASeqCellMapImportWords.addControl, isOn: suffixBinding(.add))
                    .accessibilityIdentifier("rnaseq-import-add-suffix")
                RNASeqPaneCaption(RNASeqPaneWords.importBarcodesCaption)
                Toggle(RNASeqCellMapImportWords.skipControl, isOn: $model.skipBarcodesNotHeld)
                    .accessibilityIdentifier("rnaseq-import-skip-not-held")
                RNASeqPaneCaption(RNASeqPaneWords.importSkipCaption)
            }
            RNASeqPaneGroup(title: "Counts") {
                Toggle(RNASeqCellMapImportWords.otherCountsControl, isOn: $model.otherCounts)
                    .accessibilityIdentifier("rnaseq-import-other-counts")
                RNASeqPaneCaption(RNASeqPaneWords.importOtherCountsCaption)
            }
        }
    }
}
