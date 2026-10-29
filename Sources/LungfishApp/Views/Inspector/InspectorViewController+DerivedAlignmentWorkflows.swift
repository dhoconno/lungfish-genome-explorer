// InspectorViewController+DerivedAlignmentWorkflows.swift - Filtered alignment and mapped-read annotation workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Inspector's two derived-track workflows, Create Filtered Alignment Track and Convert Mapped
// Reads to Annotations (Phase 2.10 lane A54, census rows p36 and p37). They moved out of
// InspectorViewController+TrimDuplicateWorkflows.swift as they were, so that file stays under its
// size baseline. Both launch `lungfish-cli bam filter` and `bam annotate` on A51's L3 runner with no
// key (ruling on deviation 6: the services the leaves call are the services the app awaited, and the
// M1 pin shows both write the same bytes). AlignmentWorkflowCLIGUIParityReplayTests shows A against C
// empty for both, so the in-process task each launch closure ran is gone.

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
        Self.beginMappedReadsAnnotationWorkflowOperation(request: workflowRequest) { operationID in
            let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
                .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
            viewModel.readStyleSectionViewModel.latestMappedReadsAnnotationMessage = nil
            viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = true
            split.activityIndicator.show(message: "Converting mapped reads to annotations...", style: .indeterminate)

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
            presentFailure(InspectorFailureReports.reloadBundleAfterMappedReadsAnnotation(
                trackName: createdTrackName,
                inMappingViewer: launchContext.reloadTarget == .mappingViewer,
                error
            ))
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

    /// The name of the annotation track the service makes, from the rule the service applies. The app reads
    /// it here because the leaf's `complete` message is text.
    static func annotationTrackName(for request: MappedReadsAnnotationRequest) -> String {
        MappedReadsAnnotationService.normalizedOutputTrackName(request.outputTrackName)
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

        Self.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: launchContext.serviceTarget,
            request: request
        ) { operationID in
            let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
                .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
            viewModel.readStyleSectionViewModel.latestDerivedAlignmentMessage = nil
            viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = true
            split.activityIndicator.show(message: "Creating filtered alignment track...", style: .indeterminate)

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
            presentFailure(InspectorFailureReports.reloadBundleAfterFilteredAlignment(
                trackName: createdTrackName,
                inMappingViewer: launchContext.reloadTarget == .mappingViewer,
                error
            ))
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
