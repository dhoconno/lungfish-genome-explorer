// ViewerViewController+TreeInference.swift - IQ-TREE launch from an alignment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishWorkflow

extension ViewerViewController {
    func inferTreeFromMSAViaCLI(_ request: MultipleSequenceAlignmentTreeInferenceRequest) {
        guard let projectURL = Self.enclosingProjectURL(for: request.bundleURL)
                ?? projectURLForDerivedReferenceBundle() else {
            presentBlockingAlert(
                title: "No Project",
                message: "Open a Lungfish project before building a tree from this alignment."
            )
            return
        }

        guard let window = view.window else {
            presentBlockingAlert(
                title: "No Window",
                message: "Open this alignment in a project window before building a tree."
            )
            return
        }

        guard canWriteProjectOutputs(projectURL: projectURL, workflowName: "Tree inference") else { return }

        IQTreeInferenceDialogPresenter.present(
            from: window,
            request: request,
            projectURL: projectURL
        ) { [weak self] state in
            guard let self, let options = state.pendingOptions else { return }
            self.runIQTreeInferenceViaCLI(request, projectURL: projectURL, options: options)
        }
    }

    private func runIQTreeInferenceViaCLI(
        _ request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL,
        options: IQTreeInferenceOptions
    ) {
        guard canWriteProjectOutputs(projectURL: projectURL, workflowName: "Tree inference") else { return }

        do {
            let treeDirectory = projectURL.appendingPathComponent("Phylogenetic Trees", isDirectory: true)
            try FileManager.default.createDirectory(at: treeDirectory, withIntermediateDirectories: true)
            let suggestedName = options.outputName.hasSuffix(".lungfishtree")
                ? options.outputName
                : "\(options.outputName).lungfishtree"
            let outputURL = Self.nextAvailableBundleURL(
                suggestedName: suggestedName,
                pathExtension: "lungfishtree",
                in: treeDirectory
            )
            let outputName = outputURL.deletingPathExtension().lastPathComponent
            let args = CLIMSAActionCommandBuilder.buildIQTreeInferenceArguments(
                bundleURL: request.bundleURL,
                projectURL: projectURL,
                outputURL: outputURL,
                rows: request.rows,
                columns: request.columns,
                name: outputName,
                model: options.model,
                sequenceType: options.sequenceType,
                bootstrap: options.bootstrap,
                alrt: options.alrt,
                seed: options.seed,
                threads: options.threads,
                safeMode: options.safeMode,
                keepIdenticalSequences: options.keepIdenticalSequences,
                extraIQTreeOptions: options.extraIQTreeOptions,
                iqtreePath: options.iqtreePath,
                force: false
            )
            let cliCommand = CLIMSAActionCommandBuilder.displayCommand(arguments: args)
            let startResult = OperationCenter.shared.begin(
                title: "Build Tree with IQ-TREE",
                detail: "Inferring tree from \(request.displayName)...",
                operationType: .phylogeneticTreeInference,
                targetBundleURL: request.bundleURL,
                cliCommand: cliCommand,
                routeContext: OperationRouteContext(
                    projectURL: projectURL,
                    windowStateScope: windowStateScope
                )
            )
            guard case .started(let opID) = startResult else {
                // The bundle is locked by another operation. The visible
                // "Bundle is busy" row is already inserted; do not launch the CLI runner.
                return
            }
            let runner = CLITreeRunner(label: "tree inference")
            OperationCenter.shared.setCancelCallback(for: opID) {
                runner.cancel()
            }

            Task.detached {
                do {
                    _ = try await runner.run(arguments: args, operationID: opID)
                } catch is CancellationError {
                    return
                } catch {
                    // CLITreeRunner already records failure on OperationCenter.
                }
            }
        } catch {
            presentBlockingAlert(
                title: "Tree Inference Failed",
                message: error.localizedDescription
            )
        }
    }
}
