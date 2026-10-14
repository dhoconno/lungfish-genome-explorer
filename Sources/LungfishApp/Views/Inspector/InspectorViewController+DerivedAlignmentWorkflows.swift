// InspectorViewController+DerivedAlignmentWorkflows.swift - Filtered alignment and mapped-read annotation workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Inspector's two derived-track workflows, Create Filtered Alignment Track and Convert Mapped
// Reads to Annotations (Phase 2.10 lane A54, census rows p36 and p37). They moved out of
// InspectorViewController+TrimDuplicateWorkflows.swift as they were, so that file stays under its
// size baseline when the rows launch lungfish-cli behind a key.

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
                            guard OperationCenter.shared.complete(
                                id: operationID,
                                detail: "Created annotation track \"\(result.annotationTrackInfo.name)\"."
                            ) else { return }
                            guard let self,
                                  let split = self.parent as? MainSplitViewController else { return }
                            self.viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = false
                            split.activityIndicator.hide()

                            let createdTrackName = result.annotationTrackInfo.name
                            self.viewModel.readStyleSectionViewModel.noteMappedReadsAnnotationCreation(
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
                                self.viewModel.selectedTab = .analysis
                                self.presentSimpleAlert(
                                    title: "Mapped Reads Converted",
                                    message: "Created annotation track \"\(createdTrackName)\" from \"\(sourceTrackName)\". Open the annotation table to sort and filter mapped-read fields."
                                )
                            } catch {
                                self.presentSimpleAlert(
                                    title: launchContext.reloadFailureAlertTitle,
                                    message: "Annotation track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.fail(
                                id: operationID,
                                detail: error.localizedDescription,
                                errorMessage: error.localizedDescription
                            )
                            guard let self,
                                  let split = self.parent as? MainSplitViewController else { return }
                            self.viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = false
                            split.activityIndicator.hide()
                            self.presentSimpleAlert(
                                title: "Mapped-Read Annotation Failed",
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            }
        }
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
                            guard OperationCenter.shared.complete(
                                id: operationID,
                                detail: "Created filtered alignment track \"\(result.trackInfo.name)\"."
                            ) else { return }
                            guard let self,
                                  let split = self.parent as? MainSplitViewController else { return }
                            self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                            split.activityIndicator.hide()

                            let createdTrackName = result.trackInfo.name
                            self.viewModel.readStyleSectionViewModel.noteDerivedAlignmentCreation(
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
                                self.applyFilteredAlignmentSuccess(createdTrackID: result.trackInfo.id)
                                self.viewModel.readStyleSectionViewModel.onSettingsChanged?()
                                self.presentSimpleAlert(
                                    title: "Filtered Alignment Created",
                                    message: "Created a new filtered alignment from \"\(sourceTrackName)\". The source alignment was not changed. Now viewing \"\(createdTrackName)\". Use Bundle > Alignment Tracks or View > Alignment to switch between them."
                                )
                            } catch {
                                self.presentSimpleAlert(
                                    title: launchContext.reloadFailureAlertTitle,
                                    message: "Filtered alignment track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.fail(
                                id: operationID,
                                detail: error.localizedDescription,
                                errorMessage: error.localizedDescription
                            )
                            guard let self,
                                  let split = self.parent as? MainSplitViewController else { return }
                            self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                            split.activityIndicator.hide()
                            self.presentSimpleAlert(
                                title: "Filtered Alignment Failed",
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            }
        }
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
