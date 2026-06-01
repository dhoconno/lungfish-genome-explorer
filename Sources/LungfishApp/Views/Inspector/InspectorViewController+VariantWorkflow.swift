// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension InspectorViewController {
    // MARK: - Variant Calling Workflow

    func presentVariantCallingDialog(
        bundle explicitBundle: ReferenceBundle? = nil,
        preferredAlignmentTrackID: String? = nil
    ) {
        let bundle = explicitBundle ?? viewModel.selectionSectionViewModel.referenceBundle
        guard let bundle else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before calling variants.")
            return
        }

        let eligibleTracks = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        guard !eligibleTracks.isEmpty else {
            presentSimpleAlert(
                title: "No Analysis-Ready BAM Tracks",
                message: "This bundle has no analysis-ready BAM alignment tracks to call variants from."
            )
            return
        }

        guard OperationCenter.shared.canStartOperation(on: bundle.url) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundle.url) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }

            let sidebarItems = await BAMVariantCallingCatalog().sidebarItems()
            guard let window = self.view.window ?? NSApp.keyWindow else { return }

            BAMVariantCallingDialogPresenter.present(
                from: window,
                bundle: bundle,
                preferredAlignmentTrackID: preferredAlignmentTrackID,
                sidebarItems: sidebarItems,
                onRun: { [weak self] state in
                    self?.launchVariantCallingOperation(state: state)
                }
            )
        }
    }

    func runCallVariantsWorkflow() {
        presentVariantCallingDialog()
    }

    private func launchVariantCallingOperation(state: BAMVariantCallingDialogState) {
        let bundleURL = state.bundle.url

        guard canWriteProjectOutputs(bundleURL: bundleURL, workflowName: "Variant calling") else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        if let gatkRequest = state.pendingGATKRequest {
            launchGATKVariantCallingOperation(
                request: gatkRequest,
                bundleURL: bundleURL,
                alignmentTrackID: state.selectedAlignmentTrackID,
                outputTrackID: state.generatedTrackID,
                outputTrackName: state.outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: state.selectedToolDisplayName
            )
            return
        }

        guard let request = state.pendingRequest else {
            presentSimpleAlert(
                title: "Variant Calling Not Ready",
                message: state.readinessText
            )
            return
        }

        let cliArguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "variants",
            args: Array(cliArguments.dropFirst())
        )
        let operationTitle = "Calling variants with \(state.selectedCaller.displayName)"
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Preparing \(state.selectedCaller.displayName)...",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand,
            routeContext: operationRouteContext(for: bundleURL)
        )

        final class ResultTracker: @unchecked Sendable {
            var completedTrackName: String?
            var failureMessage: String?
        }
        let tracker = ResultTracker()
        let runner = CLIVariantCallingRunner()

        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                try await runner.run(arguments: cliArguments) { event in
                    switch event {
                    case .runComplete(_, let trackName, _, _, _):
                        tracker.completedTrackName = trackName
                    case .runFailed(let message):
                        tracker.failureMessage = message
                    default:
                        break
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Self.applyVariantCallingEvent(event, operationID: opID)
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, let split = self.parent as? MainSplitViewController {
                            split.sidebarController.reloadFromFilesystem()
                            do {
                                if shouldReloadMappingViewer {
                                    try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                                } else {
                                    try split.viewerController.displayBundle(at: bundleURL)
                                }
                            } catch {
                                self.presentSimpleAlert(
                                    title: shouldReloadMappingViewer ? "Mapping Viewer Reload Failed" : "Variant Calling Reload Failed",
                                    message: "Variant calling completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }

                        let detail = tracker.completedTrackName.map { "Created variant track \($0)" }
                            ?? "Variant calling complete"
                        OperationCenter.shared.complete(id: opID, detail: detail)
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                }
            } catch {
                let message = tracker.failureMessage ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: message,
                            errorMessage: message
                        )
                        self?.presentSimpleAlert(
                            title: "Variant Calling Failed",
                            message: message
                        )
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            Task {
                await runner.cancel()
            }
        }
    }

    private func launchGATKVariantCallingOperation(
        request: GATKPipelineExecutionRequest,
        bundleURL: URL,
        alignmentTrackID: String,
        outputTrackID: String,
        outputTrackName: String,
        displayName: String
    ) {
        let commandPreview = request.commands.map(\.shellCommand).joined(separator: " && ")
        let operationTitle = "Calling variants with \(displayName)"
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Running \(displayName)...",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: commandPreview,
            routeContext: operationRouteContext(for: bundleURL)
        )

        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                let executor = GATKPipelineExecutor(runner: ManagedGATKCommandRunner())
                let result = try await executor.run(request)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(
                            id: opID,
                            progress: 0.75,
                            detail: "Attaching GATK variants to bundle..."
                        )
                    }
                }

                let outputVCFURL = try Self.primaryGATKVCFOutputURL(from: request)
                let attachment = try await GATKBundleVariantAttachmentService().attach(
                    request: GATKBundleVariantAttachmentRequest(
                        bundleURL: bundleURL,
                        alignmentTrackID: alignmentTrackID,
                        outputTrackID: outputTrackID,
                        outputTrackName: outputTrackName.isEmpty ? displayName : outputTrackName,
                        outputVCFURL: outputVCFURL,
                        executionProvenanceURL: result.provenanceURL,
                        executionRequest: request
                    )
                )

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, let split = self.parent as? MainSplitViewController {
                            split.sidebarController.reloadFromFilesystem()
                            do {
                                if shouldReloadMappingViewer {
                                    try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                                } else {
                                    try split.viewerController.displayBundle(at: bundleURL)
                                }
                            } catch {
                                self.presentSimpleAlert(
                                    title: shouldReloadMappingViewer ? "Mapping Viewer Reload Failed" : "Variant Calling Reload Failed",
                                    message: "GATK completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }

                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "Created variant track \(attachment.trackInfo.name)"
                        )
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                        self?.presentSimpleAlert(
                            title: "GATK Variant Calling Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
        }
    }

    private static func primaryGATKVCFOutputURL(
        from request: GATKPipelineExecutionRequest
    ) throws -> URL {
        guard let output = request.outputs.first(where: { $0.format == .vcf })?.url else {
            throw NSError(
                domain: "Lungfish.GATKVariantCalling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "GATK request did not declare a VCF output."]
            )
        }
        return output
    }

    @MainActor
    private static func applyVariantCallingEvent(_ event: CLIVariantCallingEvent, operationID: UUID) {
        let (progress, detail, level): (Double, String, OperationLogLevel) = {
            switch event {
            case .runStart(let message):
                return (0.01, message, .info)
            case .preflightStart(let message):
                return (0.02, message, .info)
            case .preflightComplete(let message):
                return (0.08, message, .info)
            case .stageStart(let message):
                return (0.10, message, .info)
            case .stageProgress(let progress, let message):
                return (max(0.10, min(0.88, progress)), message, .info)
            case .stageComplete(let message):
                return (0.70, message, .info)
            case .importStart(let message):
                return (0.74, message, .info)
            case .importComplete(let message, _):
                return (0.88, message, .info)
            case .attachStart(let message):
                return (0.90, message, .info)
            case .attachComplete(_, let trackName, _, _, _):
                let detail = trackName.map { "Attached variant track \($0)" } ?? "Attached variant track"
                return (0.97, detail, .info)
            case .runComplete(_, let trackName, _, _, _):
                return (0.99, "Reloading bundle with \(trackName)...", .info)
            case .runFailed(let message):
                return (0.99, message, .error)
            }
        }()

        OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
        OperationCenter.shared.log(id: operationID, level: level, message: detail)
    }

}
