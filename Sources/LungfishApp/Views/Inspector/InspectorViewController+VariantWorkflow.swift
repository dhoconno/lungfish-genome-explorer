// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit
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
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        Self.beginVariantCallingOperation(
            title: "Calling variants with \(state.selectedCaller.displayName)",
            detail: "Preparing \(state.selectedCaller.displayName)...",
            bundleURL: bundleURL,
            cliArguments: cliArguments,
            routeContext: operationRouteContext(for: bundleURL)
        ) { opID in
            let runner = CLIVariantCallingRunner()

            let task = Task(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await runner.run(arguments: cliArguments) { event in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                Self.applyVariantCallingEvent(event, operationID: opID)
                            }
                        }
                    }

                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            let detail = result.trackName.map { "Created variant track \($0)" }
                                ?? "Variant calling complete"
                            guard OperationCenter.shared.complete(id: opID, detail: detail) else { return }
                            if let self, let split = self.parent as? MainSplitViewController {
                                split.sidebarController.requestReloadFromFilesystem()
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
                        }
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.acknowledgeCancellation(id: opID, detail: "Cancelled")
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(
                                id: opID,
                                detail: message,
                                errorMessage: message
                            ) else { return }
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
    }

    private func launchGATKVariantCallingOperation(
        request: GATKPipelineExecutionRequest,
        bundleURL: URL,
        alignmentTrackID: String,
        outputTrackID: String,
        outputTrackName: String,
        displayName: String
    ) {
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        Self.beginGATKVariantCallingOperation(
            title: "Calling variants with \(displayName)",
            detail: "Running \(displayName)...",
            bundleURL: bundleURL,
            request: request,
            routeContext: operationRouteContext(for: bundleURL)
        ) { opID in
            let task = Task(priority: .userInitiated) { [weak self] in
                do {
                    let executor = GATKPipelineExecutor(runner: ManagedGATKCommandRunner())
                    let result = try await executor.run(request)

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.updateWithLog(
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
                            guard OperationCenter.shared.complete(
                                id: opID,
                                detail: "Created variant track \(attachment.trackInfo.name)"
                            ) else { return }
                            if let self, let split = self.parent as? MainSplitViewController {
                                split.sidebarController.requestReloadFromFilesystem()
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
                        }
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.acknowledgeCancellation(id: opID, detail: "Cancelled")
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(
                                id: opID,
                                detail: error.localizedDescription,
                                errorMessage: error.localizedDescription
                            ) else { return }
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
    }

    /// Registers the variant-calling row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL` and records
    /// the `lungfish-cli variants call` command built from `cliArguments`,
    /// the argv the runner executes.
    @discardableResult
    static func beginVariantCallingOperation(
        title: String,
        detail: String,
        bundleURL: URL,
        cliArguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: detail,
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "variants",
                args: Array(cliArguments.dropFirst())
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the GATK variant-calling row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks `bundleURL`.
    ///
    /// CLI parity gap. `lungfish-cli gatk haplotype-caller --execute` runs the
    /// GATK step, but no CLI command attaches the VCF to the bundle, and the
    /// pipeline runs in the app process (finding R3). The row keeps recording
    /// the GATK commands joined by `&&` until a CLI command covers the run.
    @discardableResult
    static func beginGATKVariantCallingOperation(
        title: String,
        detail: String,
        bundleURL: URL,
        request: GATKPipelineExecutionRequest,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: detail,
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: request.commands.map(\.shellCommand).joined(separator: " && "),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
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
    private static func applyVariantCallingEvent(_ event: CLIEvent, operationID: UUID) {
        let (progress, detail, level): (Double?, String, OperationLogLevel) = {
            switch event {
            case let .start(message):
                return (0.01, message, .info)
            case let .progress(fraction, message):
                return (max(0.10, min(0.88, fraction)), message, .info)
            case let .log(cliLevel, message):
                return (nil, message, cliLevel.operationLogLevel)
            case .output:
                return (nil, "", .info)
            case .complete:
                return (0.99, "Reloading bundle...", .info)
            case let .failed(message, _):
                return (0.99, message, .error)
            }
        }()

        if let progress {
            _ = OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
        }
        guard !detail.isEmpty else { return }
        OperationCenter.shared.log(id: operationID, level: level, message: detail)
    }

}

private extension CLIEventLogLevel {
    var operationLogLevel: OperationLogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
