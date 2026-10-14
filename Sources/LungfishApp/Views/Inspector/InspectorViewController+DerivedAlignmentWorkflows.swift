// InspectorViewController+DerivedAlignmentWorkflows.swift - Filtered alignment and mapped-read annotation workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Inspector's two derived-track workflows, Create Filtered Alignment Track and Convert Mapped
// Reads to Annotations (Phase 2.10 lane A54, census rows p36 and p37). They moved out of
// InspectorViewController+TrimDuplicateWorkflows.swift as they were, so that file stays under its
// size baseline. Both launch `lungfish-cli bam filter` and `bam annotate` on A51's L3 runner with no
// key (ruling on deviation 6: the services the leaves call are the services the app awaited, and the
// M1 pin shows both write the same bytes). The in-process task stays in each launch closure until the
// commit that carries the parity cases removes it.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow

extension InspectorViewController {

    func runConvertMappedReadsToAnnotationsWorkflow(_ request: MappedReadsAnnotationInspectorLaunchRequest) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before converting mapped reads to annotations.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }

        let launchContext: FilteredAlignmentWorkflowLaunchContext
        switch Self.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: split.viewerController.activeMappingViewportController != nil
        ) {
        case .blocked(let alert):
            presentSimpleAlert(title: alert.title, message: alert.message)
            return
        case .launch(let context):
            launchContext = context
        }

        let workflowRequest = request.workflowRequest(bundleURL: bundleURL)
        // No key: the route launches the leaf. The in-process branch below goes with the parity cases.
        let route = InspectorDuplicateWorkflowRoute.cli
        Self.beginMappedReadsAnnotationWorkflowOperation(request: workflowRequest, route: route) { operationID in
            let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
                .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
            viewModel.readStyleSectionViewModel.latestMappedReadsAnnotationMessage = nil
            viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = true
            split.activityIndicator.show(message: "Converting mapped reads to annotations...", style: .indeterminate)

            if route == .cli {
                // The leaf converts the reads and writes the annotation track before it exits. The row
                // completes first, so the track opens and the alert shows only once the row is done.
                Self.runAlignmentLeafThroughCLI(
                    arguments: Self.mappedReadsAnnotationCLIArguments(request: workflowRequest),
                    operationID: operationID,
                    overlay: { [weak self] message in
                        (self?.parent as? MainSplitViewController)?.activityIndicator.updateMessage(message)
                    },
                    cancelled: { [weak self] in self?.resetMappedReadsAnnotationUI() }
                ) { [weak self] outcome in
                    switch outcome {
                    case .success:
                        self?.finishMappedReadsAnnotation(
                            operationID: operationID,
                            createdTrackName: Self.annotationTrackName(for: workflowRequest),
                            sourceTrackName: sourceTrackName,
                            launchContext: launchContext
                        )
                    case .failure(let error):
                        self?.failMappedReadsAnnotation(operationID: operationID, message: error.localizedDescription)
                    }
                }
                return
            }

            Task(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await MappedReadsAnnotationService().convertMappedReads(
                        request: workflowRequest,
                        progressHandler: { [weak self] progress, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    _ = OperationCenter.shared.updateWithLog(
                                        id: operationID,
                                        progress: max(0.01, min(0.99, progress)),
                                        detail: message
                                    )
                                    if let self,
                                       let split = self.parent as? MainSplitViewController {
                                        split.activityIndicator.updateMessage(message)
                                    }
                                }
                            }
                        }
                    )
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.finishMappedReadsAnnotation(
                                operationID: operationID,
                                createdTrackName: result.annotationTrackInfo.name,
                                sourceTrackName: sourceTrackName,
                                launchContext: launchContext
                            )
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.failMappedReadsAnnotation(operationID: operationID, message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    /// Ends the annotation row and shows the new track. Both routes end here, the row first.
    private func finishMappedReadsAnnotation(
        operationID: UUID,
        createdTrackName: String,
        sourceTrackName: String,
        launchContext: FilteredAlignmentWorkflowLaunchContext
    ) {
        guard OperationCenter.shared.complete(
            id: operationID,
            detail: "Created annotation track \"\(createdTrackName)\"."
        ) else { return }
        guard let split = parent as? MainSplitViewController else { return }
        resetMappedReadsAnnotationUI()

        viewModel.readStyleSectionViewModel.noteMappedReadsAnnotationCreation(
            createdTrackName: createdTrackName,
            sourceTrackName: sourceTrackName
        )
        do {
            try launchContext.reload(
                using: FilteredAlignmentWorkflowReloadActions(
                    reloadMappingViewerBundle: {
                        try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                    },
                    displayBundle: { url in
                        try split.viewerController.displayBundle(at: url)
                    }
                )
            )
            viewModel.selectedTab = .analysis
            presentSimpleAlert(
                title: "Mapped Reads Converted",
                message: "Created annotation track \"\(createdTrackName)\" from \"\(sourceTrackName)\". Open the annotation table to sort and filter mapped-read fields."
            )
        } catch {
            presentSimpleAlert(
                title: launchContext.reloadFailureAlertTitle,
                message: "Annotation track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
            )
        }
    }

    private func failMappedReadsAnnotation(operationID: UUID, message: String) {
        _ = OperationCenter.shared.fail(id: operationID, detail: message, errorMessage: message)
        guard parent is MainSplitViewController else { return }
        resetMappedReadsAnnotationUI()
        presentSimpleAlert(title: "Mapped-Read Annotation Failed", message: message)
    }

    private func resetMappedReadsAnnotationUI() {
        viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = false
        (parent as? MainSplitViewController)?.activityIndicator.hide()
    }

    /// The name of the annotation track the service makes: the request's name trimmed, or "Mapped Reads"
    /// when it is blank. The app reads it here because the leaf's `complete` message is text.
    static func annotationTrackName(for request: MappedReadsAnnotationRequest) -> String {
        let trimmed = request.outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mapped Reads" : trimmed
    }

    func runCreateFilteredAlignmentWorkflow(_ request: AlignmentFilterInspectorLaunchRequest) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before creating a filtered alignment track.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }

        let startOutcome = Self.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: split.viewerController.activeMappingViewportController?.filteredAlignmentServiceTarget ?? .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: split.viewerController.activeMappingViewportController != nil
        )
        let launchContext: FilteredAlignmentWorkflowLaunchContext
        switch startOutcome {
        case .blocked(let alert):
            presentSimpleAlert(title: alert.title, message: alert.message)
            return
        case .launch(let context):
            launchContext = context
        }

        // No key: the route launches the leaf. The in-process branch below goes with the parity cases.
        let route = InspectorDuplicateWorkflowRoute.cli
        Self.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: launchContext.serviceTarget,
            request: request,
            route: route
        ) { operationID in
            let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
                .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
            viewModel.readStyleSectionViewModel.latestDerivedAlignmentMessage = nil
            viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = true
            split.activityIndicator.show(message: "Creating filtered alignment track...", style: .indeterminate)

            if route == .cli {
                // The leaf filters and attaches the new track before it exits. The row completes first,
                // so the track opens and the alert shows only once the row is done.
                Self.runAlignmentLeafThroughCLI(
                    arguments: Self.filteredAlignmentCLIArguments(serviceTarget: launchContext.serviceTarget, request: request),
                    operationID: operationID,
                    overlay: { [weak self] message in
                        (self?.parent as? MainSplitViewController)?.activityIndicator.updateMessage(message)
                    },
                    cancelled: { [weak self] in self?.resetFilteredAlignmentUI() }
                ) { [weak self] outcome in
                    do {
                        let createdTrackID = try Self.filteredAlignmentTrackID(from: try outcome.get())
                        self?.finishFilteredAlignment(
                            operationID: operationID,
                            createdTrackID: createdTrackID,
                            createdTrackName: request.outputTrackName,
                            sourceTrackName: sourceTrackName,
                            launchContext: launchContext
                        )
                    } catch {
                        self?.failFilteredAlignment(operationID: operationID, message: error.localizedDescription)
                    }
                }
                return
            }

            Task(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await BundleAlignmentFilterService().deriveFilteredAlignment(
                        target: launchContext.serviceTarget,
                        sourceTrackID: request.sourceTrackID,
                        outputTrackName: request.outputTrackName,
                        filterRequest: request.filterRequest,
                        progressHandler: { [weak self] progress, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    _ = OperationCenter.shared.updateWithLog(
                                        id: operationID,
                                        progress: max(0.01, min(0.99, progress)),
                                        detail: message
                                    )
                                    if let self,
                                       let split = self.parent as? MainSplitViewController {
                                        split.activityIndicator.updateMessage(message)
                                    }
                                }
                            }
                        }
                    )
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.finishFilteredAlignment(
                                operationID: operationID,
                                createdTrackID: result.trackInfo.id,
                                createdTrackName: result.trackInfo.name,
                                sourceTrackName: sourceTrackName,
                                launchContext: launchContext
                            )
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.failFilteredAlignment(operationID: operationID, message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    /// Ends the filtered-alignment row and shows the new track. Both routes end here, the row first.
    private func finishFilteredAlignment(
        operationID: UUID,
        createdTrackID: String,
        createdTrackName: String,
        sourceTrackName: String,
        launchContext: FilteredAlignmentWorkflowLaunchContext
    ) {
        guard OperationCenter.shared.complete(
            id: operationID,
            detail: "Created filtered alignment track \"\(createdTrackName)\"."
        ) else { return }
        guard let split = parent as? MainSplitViewController else { return }
        resetFilteredAlignmentUI()

        viewModel.readStyleSectionViewModel.noteDerivedAlignmentCreation(
            createdTrackName: createdTrackName,
            sourceTrackName: sourceTrackName
        )
        do {
            try launchContext.reload(
                using: FilteredAlignmentWorkflowReloadActions(
                    reloadMappingViewerBundle: {
                        try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                    },
                    displayBundle: { url in
                        try split.viewerController.displayBundle(at: url)
                    }
                )
            )
            applyFilteredAlignmentSuccess(createdTrackID: createdTrackID)
            viewModel.readStyleSectionViewModel.onSettingsChanged?()
            presentSimpleAlert(
                title: "Filtered Alignment Created",
                message: "Created a new filtered alignment from \"\(sourceTrackName)\". The source alignment was not changed. Now viewing \"\(createdTrackName)\". Use Bundle > Alignment Tracks or View > Alignment to switch between them."
            )
        } catch {
            presentSimpleAlert(
                title: launchContext.reloadFailureAlertTitle,
                message: "Filtered alignment track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
            )
        }
    }

    private func failFilteredAlignment(operationID: UUID, message: String) {
        _ = OperationCenter.shared.fail(id: operationID, detail: message, errorMessage: message)
        guard parent is MainSplitViewController else { return }
        resetFilteredAlignmentUI()
        presentSimpleAlert(title: "Filtered Alignment Failed", message: message)
    }

    private func resetFilteredAlignmentUI() {
        viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
        (parent as? MainSplitViewController)?.activityIndicator.hide()
    }

    /// The ID of the track `bam filter` made. The leaf names the derived BAM first among its outputs and
    /// the service names that file for the new track, so the app reads the ID from the path, never from
    /// the `complete` message, which is text.
    static func filteredAlignmentTrackID(from completion: CLIAlignmentActionRunner.Completion) throws -> String {
        guard let bam = completion.outputs.first else {
            throw AlignmentLeafCompletionError(message: "The command finished without naming the filtered alignment.")
        }
        return URL(fileURLWithPath: bam).deletingPathExtension().lastPathComponent
    }

    func applyFilteredAlignmentSuccess(createdTrackID: String) {
        viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID = createdTrackID
        viewModel.documentSectionViewModel.markRecentlyCreatedAlignmentTrack(createdTrackID)
        viewModel.documentSectionViewModel.visibleAlignmentTrackID = createdTrackID
        viewModel.selectedTab = .analysis
    }

    static func makeFilteredAlignmentWorkflowStartOutcome(
        bundleURL: URL,
        serviceTarget: AlignmentFilterTarget,
        isMappingViewerDisplayedAtLaunch: Bool,
        canStartBundleMutation: (URL) -> Bool = { OperationCenter.shared.canStartOperation(on: $0) },
        activeBundleMutationTitle: (URL) -> String? = { OperationCenter.shared.activeLockHolder(for: $0)?.title }
    ) -> FilteredAlignmentWorkflowStartOutcome {
        guard canStartBundleMutation(bundleURL) else {
            let message: String
            if let title = activeBundleMutationTitle(bundleURL) {
                message = "\"\(title)\" is currently running on this bundle. Please wait for it to finish."
            } else {
                message = "Another operation is currently running on this bundle. Please wait for it to finish."
            }
            return .blocked(
                InspectorWorkflowAlert(
                    title: "Operation in Progress",
                    message: message
                )
            )
        }

        return .launch(
            FilteredAlignmentWorkflowLaunchContext(
                bundleURL: bundleURL,
                serviceTarget: serviceTarget,
                reloadTarget: isMappingViewerDisplayedAtLaunch ? .mappingViewer : .bundleViewer
            )
        )
    }
}
