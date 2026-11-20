// RNASeqCellMapSelectRun.swift - The App's side of selecting cells in a cell map (Phase 5.5 lane CM-SELECT-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The cell-map view hands a selection over through `RNASeqResultSurface.onSelectionAction`. Save Selection as Labels Table…
// launches `lungfish-cli rnaseq cell-map select … --output <path>` on `RNASeqLeafRoute` to a path a save panel gives, so the bytes
// equal the CLI's by construction and the app adds no write path. Pseudobulk Selected Cells… opens the pseudobulk pane filled in,
// with the selection named by its count and cell map, and its run writes the table with `cell-map select` before the pseudobulk
// row's `begin` (`RNASeqLeafRoute.launchPseudobulkOfSelection`).

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishRNASeqUI
import UniformTypeIdentifiers

/// The words of the two actions. UX reads them at the notes step.
enum RNASeqCellMapSelectWords {
    static let title = "Save Selection as Labels Table"
    static let panelMessage = "Choose where the labels table goes. LGE writes it outside every RNA-seq result, with its record beside it."

    /// The CLI's refusal with the words that name a flag rewritten for a person who chose a place in a panel. `nil` for words
    /// that name no flag, which the alert shows as they are.
    static func paneWords(forCLIWords message: String) -> String? {
        let rewrites: [(String, String)] = [
            ("--output names a file inside the result", "The place chosen for the table is inside the result"),
        ]
        var words = message
        var changed = false
        for (cli, pane) in rewrites where words.contains(cli) {
            words = words.replacingOccurrences(of: cli, with: pane)
            changed = true
        }
        return changed ? words : nil
    }

    static func tableMissing(_ name: String) -> String {
        "cell-map select ended, but the table \(name) is not there or is empty, so the selection was not saved."
    }
}

@MainActor
enum RNASeqCellMapSelectRun {
    /// The check the runner makes once the leaf exited 0 and before it settles the row. It reads off the main actor and writes
    /// nothing, and returns words for a table that is missing or empty.
    nonisolated static let tableCheck: @Sendable (URL) async -> String? = { url in
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return RNASeqCellMapSelectWords.tableMissing(url.lastPathComponent) }
            return nil
        }.value
    }

    /// Removes the folder of one run's table, then `.lungfish-cell-map-inputs` when nothing else is in it, after a run that did
    /// not complete. No record names that table, so nothing is lost.
    nonisolated static func removeInputs(_ folder: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        let inputs = folder.deletingLastPathComponent()
        if inputs.lastPathComponent == ".lungfish-cell-map-inputs", (try? manager.contentsOfDirectory(atPath: inputs.path))?.isEmpty == true {
            try? manager.removeItem(at: inputs)
        }
    }

    /// Runs one action of the view.
    static func perform(_ action: RNASeqEmbeddingSelectionAction, projectURL: URL?, routeContext: OperationRouteContext?) {
        switch action {
        case .saveLabelsTable(let request):
            chooseTable(for: request) { url in save(request, to: url, routeContext: routeContext) }
        case .pseudobulk(let request):
            WorkflowOperationsWindowController.showPseudobulk(of: request, projectURL: projectURL, routeContext: routeContext)
        }
    }

    /// A save panel for the table, as a sheet of the key window when there is one.
    static func chooseTable(for request: RNASeqEmbeddingSelectionRequest, then: @escaping @MainActor (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = RNASeqCellMapSelectWords.title
        panel.message = RNASeqCellMapSelectWords.panelMessage
        panel.nameFieldStringValue = "\(request.cellMapName) selection.tsv"
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.canCreateDirectories = true
        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { then(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handle(response) } }
        } else {
            handle(panel.runModal())
        }
    }

    /// Launches the select row to `url` and shows an alert when the leaf refuses. `report` is for a test.
    @discardableResult
    static func save(
        _ request: RNASeqEmbeddingSelectionRequest,
        to url: URL,
        routeContext: OperationRouteContext? = nil,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        environmentAdditions: [String: String] = [:],
        report: @escaping @MainActor (String, String) -> Void = RNASeqCellMapImportRun.showAlert
    ) -> RNASeqLeafLaunch? {
        let select = RNASeqCellMapSelectRunRequest(
            cellMapURL: request.cellMapURL, embedding: request.embedding, form: request.form, outputURL: url.standardizedFileURL)
        guard let launched = RNASeqLeafRoute.launchSelect(
            select, routeContext: routeContext, runner: runner, environmentAdditions: environmentAdditions)
        else {
            report(RNASeqCellMapSelectWords.title, "The cell map \(request.cellMapName) is busy. Wait for its current operation to finish.")
            return nil
        }
        Task { @MainActor in
            if case .failed(let failure) = await launched.task.value {
                report(RNASeqCellMapSelectWords.title, RNASeqCellMapSelectWords.paneWords(forCLIWords: failure.message) ?? failure.message)
            }
        }
        return launched
    }

    /// Fills the pseudobulk pane with a selection: the parent result, the selection by count and cell map, a folder beside the
    /// parent and a name, and no labels file.
    static func fill(_ state: WorkflowOperationDialogState, with request: RNASeqEmbeddingSelectionRequest) {
        state.rnaSeqPseudobulk.resultURL = request.parentURL
        state.rnaSeqPseudobulk.labelsURL = nil
        state.rnaSeqPseudobulk.selection = RNASeqPseudobulkSelection(request)
        if let parent = request.parentURL { state.outputDirectoryURL = parent.deletingLastPathComponent() }
        state.outputName = "\(request.cellMapName) selected"
    }
}
