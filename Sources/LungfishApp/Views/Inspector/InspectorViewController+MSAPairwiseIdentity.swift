// InspectorViewController+MSAPairwiseIdentity.swift - Export the MSA pairwise identity matrix via the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import UniformTypeIdentifiers

extension InspectorViewController {
    /// Asks for a destination, then runs `lungfish-cli msa distance` through the Operation
    /// Center so the TSV lands next to a `.lungfish-provenance.json` sidecar, exactly as a
    /// terminal run would. The Inspector table itself is computed in-process by the same
    /// `MSADistanceMatrix` service, so the exported numbers match what is on screen.
    func exportMSAPairwiseIdentityMatrixViaCLI(_ model: MSAPairwiseIdentityInspectorModel) {
        guard let window = view.window ?? NSApp.keyWindow else { return }
        let bundleURL = model.bundleURL
        let distanceModel = model.model

        let panel = NSSavePanel()
        panel.title = "Export \(distanceModel.displayName) Matrix"
        panel.message = "The matrix is written as TSV with a provenance sidecar by lungfish-cli msa distance."
        panel.nameFieldStringValue = "\(bundleURL.deletingPathExtension().lastPathComponent)-\(distanceModel.rawValue).tsv"
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputURL = panel.url else { return }
            MainActor.assumeIsolated {
                self?.runMSAPairwiseIdentityExport(bundleURL: bundleURL, model: distanceModel, outputURL: outputURL)
            }
        }
    }

    private func runMSAPairwiseIdentityExport(bundleURL: URL, model: MSADistanceModel, outputURL: URL) {
        let arguments = CLIMSAActionCommandBuilder.buildDistanceArguments(
            bundleURL: bundleURL,
            options: MSADistanceOptions(
                model: model,
                alphabet: (try? MSASequenceAlphabet.load(fromBundle: bundleURL)) ?? .nucleotide
            ),
            outputURL: outputURL
        )
        let cliCommand = CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
        let startResult = OperationCenter.shared.begin(
            title: "Export \(model.displayName) Matrix",
            detail: "Computing pairwise \(model.displayName.lowercased()) for \(bundleURL.lastPathComponent)...",
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
        let runner = CLIMSAActionRunner()
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
    }
}
