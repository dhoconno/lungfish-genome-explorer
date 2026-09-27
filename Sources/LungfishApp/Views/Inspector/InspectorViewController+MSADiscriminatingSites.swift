// InspectorViewController+MSADiscriminatingSites.swift - Run `msa discriminating-sites` via the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import UniformTypeIdentifiers

extension InspectorViewController {
    /// Builds the Discriminating Sites model for a bundle and wires its callbacks to
    /// the CLI run, the export panels, the file chooser, and the viewport notifications.
    func makeMSADiscriminatingSitesModel(
        for bundle: MultipleSequenceAlignmentBundle
    ) -> MSADiscriminatingSitesInspectorModel {
        let model = MSADiscriminatingSitesInspectorModel(
            bundleURL: bundle.url,
            rows: bundle.rows.map { .init(id: $0.id, name: $0.displayName) }
        )
        model.onRunRequested = { [weak self] model in
            self?.runMSADiscriminatingSitesViaCLI(model)
        }
        model.onExportRequested = { [weak self] model, format in
            self?.exportMSADiscriminatingSitesViaCLI(model, format: format)
        }
        model.onChooseExclusionFileRequested = { [weak self] model in
            self?.chooseMSADiscriminatingSitesExclusionFile(model)
        }
        model.onHighlightChanged = { [weak self] model in
            self?.broadcastMSADiscriminatingSitesHighlight(model)
        }
        model.onJumpRequested = { [weak self] column in
            self?.broadcastMSAFocusAlignmentColumn(column)
        }
        return model
    }

    /// Posts the current highlight (or its absence) to the alignment viewport.
    func broadcastMSADiscriminatingSitesHighlight(_ model: MSADiscriminatingSitesInspectorModel) {
        var userInfo: [AnyHashable: Any] = [:]
        if let highlight = model.highlight {
            userInfo[NotificationUserInfoKey.msaDiscriminatingSitesHighlight] = highlight
        }
        NotificationCenter.default.post(
            name: .msaDiscriminatingSitesHighlightChanged,
            object: self,
            userInfo: windowScopedUserInfo(userInfo)
        )
    }

    /// Asks the alignment viewport to select and centre a 1-based column.
    func broadcastMSAFocusAlignmentColumn(_ column: Int) {
        NotificationCenter.default.post(
            name: .msaFocusAlignmentColumnRequested,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.msaAlignmentColumn: column])
        )
    }

    // MARK: - Running

    /// Runs the analysis into the project's temporary folder (or the system one when
    /// the bundle is outside a project) so the Inspector can read the JSON report back.
    /// The run is the CLI through the Operation Center, so a provenance sidecar lands
    /// beside the TSV exactly as a terminal run would leave it.
    func runMSADiscriminatingSitesViaCLI(_ model: MSADiscriminatingSitesInspectorModel) {
        let request: MSADiscriminatingSitesRequest
        do {
            request = try model.makeRequest()
        } catch {
            model.markFailed(error.localizedDescription)
            return
        }
        let outputURL: URL
        do {
            let directory = try ProjectTempDirectory.createFromContext(
                prefix: "discriminating-sites-",
                contextURL: model.bundleURL
            )
            outputURL = directory.appendingPathComponent(
                "\(model.bundleURL.deletingPathExtension().lastPathComponent)-discriminating-sites.tsv"
            )
        } catch {
            model.markFailed("Could not create a working folder for the report: \(error.localizedDescription)")
            return
        }
        runMSADiscriminatingSites(
            model: model,
            request: request,
            outputURL: outputURL,
            title: "Find Discriminating Sites",
            loadsResult: true
        )
    }

    /// Re-runs the same CLI command into a destination the user picks, so the exported
    /// tables carry their own provenance sidecar.
    func exportMSADiscriminatingSitesViaCLI(
        _ model: MSADiscriminatingSitesInspectorModel,
        format: MSADiscriminatingSitesInspectorModel.ExportFormat
    ) {
        guard let window = view.window ?? NSApp.keyWindow else { return }
        let stem = "\(model.bundleURL.deletingPathExtension().lastPathComponent)-discriminating-sites"
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = ProjectTempDirectory.findProjectRoot(model.bundleURL)?
            .appendingPathComponent("Analyses", isDirectory: true)
        switch format {
        case .tsv:
            panel.title = "Export Discriminating Sites TSV"
            panel.message = "The per-column table, its candidate-window table, the JSON report, and a provenance sidecar are written by lungfish-cli msa discriminating-sites."
            panel.nameFieldStringValue = "\(stem).tsv"
            panel.allowedContentTypes = [.tabSeparatedText]
        case .json:
            panel.title = "Export Discriminating Sites JSON"
            panel.message = "The JSON report is written beside the per-column TSV and its provenance sidecar by lungfish-cli msa discriminating-sites."
            panel.nameFieldStringValue = "\(stem).json"
            panel.allowedContentTypes = [.json]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosenURL = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let request: MSADiscriminatingSitesRequest
                do {
                    request = try model.makeRequest()
                } catch {
                    model.markFailed(error.localizedDescription)
                    return
                }
                let outputURL: URL
                let jsonOutputURL: URL?
                switch format {
                case .tsv:
                    outputURL = chosenURL
                    jsonOutputURL = nil
                case .json:
                    outputURL = chosenURL.deletingPathExtension().appendingPathExtension("tsv")
                    jsonOutputURL = chosenURL
                }
                self.runMSADiscriminatingSites(
                    model: model,
                    request: request,
                    outputURL: outputURL,
                    jsonOutputURL: jsonOutputURL,
                    title: "Export Discriminating Sites",
                    loadsResult: false
                )
            }
        }
    }

    private func runMSADiscriminatingSites(
        model: MSADiscriminatingSitesInspectorModel,
        request: MSADiscriminatingSitesRequest,
        outputURL: URL,
        jsonOutputURL: URL? = nil,
        title: String,
        loadsResult: Bool
    ) {
        let bundleURL = request.bundleURL
        let arguments = CLIMSAActionCommandBuilder.buildDiscriminatingSitesArguments(
            request: request,
            outputURL: outputURL,
            jsonOutputURL: jsonOutputURL
        )
        let cliCommand = CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
        let startResult = OperationCenter.shared.begin(
            title: title,
            detail: "Scoring alignment columns of \(bundleURL.lastPathComponent)...",
            operationType: .multipleSequenceAlignmentAction,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand,
            routeContext: OperationRouteContext(
                projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
                windowStateScope: windowStateScope
            )
        )
        guard case .started(let operationID) = startResult else {
            // The bundle is locked by another operation; the "Bundle is busy" row is shown.
            return
        }
        if loadsResult {
            model.markRunning()
        }
        let runner = CLIMSAActionRunner()
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
        let reportURL = jsonOutputURL ?? MSADiscriminatingSitesRequest.defaultJSONOutputURL(for: outputURL)

        Task {
            do {
                _ = try await runner.run(arguments: arguments, operationID: operationID)
                OperationCenter.shared.log(
                    id: operationID,
                    level: .info,
                    message: "Wrote \(outputURL.lastPathComponent), its candidate-window table, the JSON report, and the provenance sidecar."
                )
                guard loadsResult else { return }
                do {
                    try model.loadReport(jsonURL: reportURL, outputURL: outputURL)
                } catch {
                    model.markFailed("The run finished but its report could not be read: \(error.localizedDescription)")
                }
            } catch is CancellationError {
                if loadsResult { model.discardResult() }
                return
            } catch {
                if loadsResult { model.markFailed(error.localizedDescription) }
                _ = OperationCenter.shared.fail(
                    id: operationID,
                    detail: error.localizedDescription,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Exclusion file chooser

    func chooseMSADiscriminatingSitesExclusionFile(_ model: MSADiscriminatingSitesInspectorModel) {
        guard let window = view.window ?? NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Exclusion Sequences"
        panel.message = "Choose a FASTA file or a .lungfishref reference bundle. Its sequences are aligned onto the target alignment with the managed MAFFT."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = ProjectTempDirectory.findProjectRoot(model.bundleURL)?
            .appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                model.exclusionFileURL = url.standardizedFileURL
            }
        }
    }
}
