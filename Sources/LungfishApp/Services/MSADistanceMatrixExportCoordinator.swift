// MSADistanceMatrixExportCoordinator.swift - Export the MSA distance matrix through lungfish-cli msa distance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import UniformTypeIdentifiers

/// The one export path for the distance matrix (ruling U8). The Distances
/// pane's Export button, View > Distance Matrix > Export Matrix as TSV… and
/// File > Export > Distance Matrix (TSV)… all end here. It asks for a
/// destination, then runs `lungfish-cli msa distance` with the options on
/// screen through the Operation Center, so the TSV lands next to its
/// provenance sidecar and the Operations row records the exact command.
@MainActor
enum MSADistanceMatrixExportCoordinator {
    /// The suggested file name, for example `primates-k2p.tsv`.
    static func suggestedFileName(bundleURL: URL, options: MSADistanceOptions) -> String {
        "\(bundleURL.deletingPathExtension().lastPathComponent)-\(options.model.rawValue).tsv"
    }

    /// Shows the save sheet on `window`, then starts the export.
    static func export(
        bundleURL: URL,
        options: MSADistanceOptions,
        window: NSWindow?,
        windowStateScope: WindowStateScope?
    ) {
        guard let window = window ?? NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(options.model.displayName) Matrix"
        panel.message = "The matrix is written as TSV with a provenance sidecar by lungfish-cli msa distance."
        panel.nameFieldStringValue = suggestedFileName(bundleURL: bundleURL, options: options)
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.canCreateDirectories = true
        // Completion-handler presentation, never an awaited sheet inside a
        // MainActor task (AppKitConcurrencyModalSafetyTests).
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let outputURL = panel.url else { return }
            Task { @MainActor in
                run(bundleURL: bundleURL, options: options, outputURL: outputURL, windowStateScope: windowStateScope)
            }
        }
    }

    /// The argv the export runs, also recorded on the Operations row.
    static func arguments(bundleURL: URL, options: MSADistanceOptions, outputURL: URL) -> [String] {
        CLIMSAActionCommandBuilder.buildDistanceArguments(bundleURL: bundleURL, options: options, outputURL: outputURL)
    }

    /// Starts the export without a save sheet. Returns the operation ID, or
    /// nil when a bundle lock refused the run.
    @discardableResult
    static func run(
        bundleURL: URL,
        options: MSADistanceOptions,
        outputURL: URL,
        windowStateScope: WindowStateScope?,
        runner: CLIMSAActionRunner = CLIMSAActionRunner()
    ) -> UUID? {
        let arguments = arguments(bundleURL: bundleURL, options: options, outputURL: outputURL)
        let cliCommand = CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
        let startResult = OperationCenter.shared.begin(
            title: "Export \(options.model.displayName) Matrix",
            detail: "Computing pairwise \(options.model.displayName.lowercased()) for \(bundleURL.lastPathComponent)...",
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
            return nil
        }
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }

        Task {
            do {
                _ = try await runner.run(arguments: arguments, operationID: operationID)
                OperationCenter.shared.log(
                    id: operationID,
                    level: .info,
                    message: "Wrote \(outputURL.lastPathComponent) and its provenance sidecar."
                )
            } catch is CancellationError {
                return
            } catch {
                _ = OperationCenter.shared.fail(
                    id: operationID,
                    detail: error.localizedDescription,
                    errorMessage: error.localizedDescription
                )
            }
        }
        return operationID
    }
}
