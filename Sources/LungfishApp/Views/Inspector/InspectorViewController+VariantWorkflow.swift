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
            let displayName = state.selectedToolDisplayName
            let trimmedName = state.outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputTrackName = trimmedName.isEmpty ? displayName : trimmedName
            let cliArguments = CLIVariantCallingRunner.buildGATKCLIArguments(
                request: gatkRequest,
                bundleURL: bundleURL,
                alignmentTrackID: state.selectedAlignmentTrackID,
                outputTrackName: outputTrackName
            )
            // The hidden key keeps the in-process route for one release (Phase 2.11 lane A50 M3, C4).
            switch GATKVariantCallingRouteSettings.currentRoute {
            case .cli:
                launchCLIVariantCallingOperation(
                    title: "Calling variants with \(displayName)",
                    detail: "Running \(displayName)...",
                    bundleURL: bundleURL,
                    cliArguments: cliArguments,
                    failureTitle: "GATK Variant Calling Failed",
                    reloadFailurePrefix: "GATK completed"
                )
            case .legacy:
                launchGATKVariantCallingOperation(
                    request: gatkRequest,
                    bundleURL: bundleURL,
                    alignmentTrackID: state.selectedAlignmentTrackID,
                    outputTrackID: state.generatedTrackID,
                    outputTrackName: outputTrackName,
                    displayName: displayName,
                    cliArguments: cliArguments
                )
            }
            return
        }

        guard let request = state.pendingRequest else {
            presentSimpleAlert(
                title: "Variant Calling Not Ready",
                message: state.readinessText
            )
            return
        }

        launchCLIVariantCallingOperation(
            title: "Calling variants with \(state.selectedCaller.displayName)",
            detail: "Preparing \(state.selectedCaller.displayName)...",
            bundleURL: bundleURL,
            cliArguments: CLIVariantCallingRunner.buildCLIArguments(request: request),
            failureTitle: "Variant Calling Failed",
            reloadFailurePrefix: "Variant calling completed"
        )
    }

    /// Runs `lungfish-cli variants call` with `cliArguments` on `CLIVariantCallingRunner`, on a row that
    /// records the command. Every caller of the dialog takes it, and the GATK row does on the `cli` route.
    private func launchCLIVariantCallingOperation(
        title: String,
        detail: String,
        bundleURL: URL,
        cliArguments: [String],
        failureTitle: String,
        reloadFailurePrefix: String
    ) {
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        Self.beginVariantCallingOperation(
            title: title,
            detail: detail,
            bundleURL: bundleURL,
            cliArguments: cliArguments,
            routeContext: operationRouteContext(for: bundleURL)
        ) { opID in
            let runner = CLIVariantCallingRunner()

            let task = Task(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await runner.run(
                        arguments: cliArguments,
                        onEvent: Self.variantCallingEventHandler(operationID: opID)
                    )

                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            let detail = Self.variantCallingCompletionDetail(for: result)
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
                                        message: "\(reloadFailurePrefix), but the bundle could not be reloaded: \(error.localizedDescription)"
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
                                title: failureTitle,
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
        displayName: String,
        cliArguments: [String]
    ) {
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        Self.beginGATKVariantCallingOperation(
            title: "Calling variants with \(displayName)",
            detail: "Running \(displayName)...",
            bundleURL: bundleURL,
            request: request,
            cliArguments: cliArguments,
            routeContext: operationRouteContext(for: bundleURL)
        ) { opID in
            let task = Task(priority: .userInitiated) { [weak self] in
                do {
                    let attachment = try await Self.runGATKVariantCallingInProcess(
                        request: request,
                        runner: ManagedGATKCommandRunner(),
                        bundleURL: bundleURL,
                        alignmentTrackID: alignmentTrackID,
                        outputTrackID: outputTrackID,
                        outputTrackName: outputTrackName
                    ) {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = OperationCenter.shared.updateWithLog(
                                    id: opID,
                                    progress: 0.75,
                                    detail: "Attaching GATK variants to bundle..."
                                )
                            }
                        }
                    }

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

    /// Registers the GATK variant-calling row of the `legacy` route and, only
    /// when it starts, calls `launch` with the operation ID. The row locks
    /// `bundleURL` and records the `lungfish-cli variants call --caller gatk`
    /// command built from `cliArguments`, the command the `cli` route runs
    /// (Phase 2.11 lane A50 M3). The GATK commands of the in-process run also
    /// go to the row's log, so its history keeps them.
    @discardableResult
    static func beginGATKVariantCallingOperation(
        title: String,
        detail: String,
        bundleURL: URL,
        request: GATKPipelineExecutionRequest,
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
            for command in request.commands {
                reporter.log(id: operationID, level: .info, message: "GATK command: \(command.shellCommand)")
            }
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The in-process run of the `legacy` route, kept for one release (C4). `GATKPipelineExecutor` runs
    /// on `runner`, then the attach writes into `variants/gatk/`, and `onAttachStart` runs between the
    /// two. The row passes `ManagedGATKCommandRunner`, and side A of the GATK parity class a stand-in.
    nonisolated static func runGATKVariantCallingInProcess<Runner: GATKCommandRunning>(
        request: GATKPipelineExecutionRequest,
        runner: Runner,
        bundleURL: URL,
        alignmentTrackID: String,
        outputTrackID: String,
        outputTrackName: String,
        onAttachStart: @escaping @Sendable () -> Void = {}
    ) async throws -> GATKBundleVariantAttachmentResult {
        let result = try await GATKPipelineExecutor(runner: runner).run(request)
        onAttachStart()
        return try await GATKBundleVariantAttachmentService().attach(
            request: GATKBundleVariantAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: alignmentTrackID,
                outputTrackID: outputTrackID,
                outputTrackName: outputTrackName,
                outputVCFURL: try primaryGATKVCFOutputURL(from: request),
                executionProvenanceURL: result.provenanceURL,
                executionRequest: request
            )
        )
    }

    nonisolated private static func primaryGATKVCFOutputURL(
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

    /// The `onEvent` closure the launcher gives the runner, a static function so a test can feed it
    /// the events of a run and read the row. The shared bridge maps every event onto the row, holds the
    /// bar and logs each progress message once (ADDING-AN-OPERATION rule 8), and one rule of this row
    /// stays on top of it. The caller workflow and the SQLite import each report 0 to 1, so the bar
    /// keeps to 0.10...0.88 between the first and the last narrated step.
    static func variantCallingEventHandler(operationID: UUID) -> @Sendable (CLIEvent) -> Void {
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID)
        return { event in
            guard case let .progress(fraction, message) = event else { return bridge(event) }
            bridge(.progress(fraction: max(0.10, min(0.88, fraction)), message: message))
        }
    }

    /// The detail the row ends on after a successful run.
    static func variantCallingCompletionDetail(for result: CLIVariantCallingResult) -> String {
        result.trackName.map { "Created variant track \($0)" } ?? "Variant calling complete"
    }

}
