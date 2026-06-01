// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension InspectorViewController {
    // MARK: - Primer Trim Workflow

    func presentPrimerTrimDialog(
        bundle explicitBundle: ReferenceBundle? = nil
    ) {
        let bundle = explicitBundle ?? viewModel.selectionSectionViewModel.referenceBundle
        guard let bundle else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before trimming primers.")
            return
        }

        let eligibleTracks = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        guard !eligibleTracks.isEmpty else {
            presentSimpleAlert(
                title: "No Analysis-Ready BAM Tracks",
                message: "This bundle has no analysis-ready BAM alignment tracks to primer-trim."
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

            let builtIn = BuiltInPrimerSchemeService.listBuiltInSchemes()
            let projectLocal: [PrimerSchemeBundle]
            if let projectURL = (self.parent as? MainSplitViewController)?.sidebarController.currentProjectURL {
                projectLocal = PrimerSchemesFolder.listBundles(in: projectURL)
            } else {
                projectLocal = []
            }
            let uiTestConfiguration = AppUITestConfiguration.current
            let availability: DatasetOperationAvailability
            if uiTestConfiguration.isEnabled,
               uiTestConfiguration.backendMode == .deterministic {
                availability = .available
            } else {
                availability = await BAMPrimerTrimCatalog().availability()
            }

            guard let window = self.view.window ?? NSApp.keyWindow else { return }

            BAMPrimerTrimDialogPresenter.present(
                from: window,
                bundle: bundle,
                builtInSchemes: builtIn,
                projectSchemes: projectLocal,
                availability: availability,
                onRun: { [weak self] state in
                    self?.launchPrimerTrimOperation(state: state)
                },
                onBrowseScheme: { [weak self] state in
                    self?.presentPrimerSchemeBrowseSheet(for: state)
                }
            )
        }
    }

    func runPrimerTrimWorkflow() {
        presentPrimerTrimDialog()
    }

    private func launchPrimerTrimOperation(state: BAMPrimerTrimDialogState) {
        let bundleURL = state.bundle.url

        guard canWriteProjectOutputs(bundleURL: bundleURL, workflowName: "Primer trim") else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        // Validate through the dialog's readiness gate, then extract the
        // wire-level inputs the CLI runner needs.
        guard let primerTrimRequest = state.prepareForRun() else {
            presentSimpleAlert(
                title: "Primer Trim Not Ready",
                message: state.readinessText
            )
            return
        }
        guard let scheme = state.selectedScheme,
              let alignmentTrackID = state.alignmentTrackID else {
            return
        }
        let outputTrackName = state.outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)

        let cliArguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: bundleURL,
            alignmentTrackID: alignmentTrackID,
            schemeURL: scheme.url,
            outputTrackName: outputTrackName,
            ivarMinQuality: primerTrimRequest.minQuality,
            ivarMinLength: primerTrimRequest.minReadLength,
            ivarSlidingWindow: primerTrimRequest.slidingWindow,
            ivarPrimerOffset: primerTrimRequest.primerOffset
        )
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "bam primer-trim",
            args: Array(cliArguments.dropFirst(2))
        )
        let operationTitle = "Primer-trimming with \(scheme.manifest.displayName)"
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Preparing primer trim...",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand,
            routeContext: operationRouteContext(for: bundleURL)
        )

        final class ResultTracker: @unchecked Sendable {
            var completedTrackName: String?
            var failureMessage: String?
        }
        let tracker = ResultTracker()
        let runner = CLIPrimerTrimRunner()

        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                if AppUITestConfiguration.current.isEnabled,
                   AppUITestConfiguration.current.backendMode == .deterministic {
                    let result = try AppUITestPrimerTrimBackend.writeResult(
                        bundleURL: bundleURL,
                        alignmentTrackID: alignmentTrackID,
                        scheme: scheme,
                        outputTrackName: outputTrackName,
                        cliArguments: cliArguments,
                        minReadLength: primerTrimRequest.minReadLength,
                        minQuality: primerTrimRequest.minQuality,
                        slidingWindow: primerTrimRequest.slidingWindow,
                        primerOffset: primerTrimRequest.primerOffset
                    )
                    tracker.completedTrackName = result.trackName
                    let events: [CLIPrimerTrimEvent] = [
                        .runStart(message: "Starting deterministic UI test primer trim"),
                        .attachStart(message: "Adopting deterministic primer-trimmed BAM into bundle"),
                        .attachComplete(
                            trackID: result.trackID,
                            trackName: result.trackName,
                            bamPath: result.bamURL.path,
                            baiPath: result.indexURL.path,
                            provenanceSidecarPath: result.provenanceSidecarURL.path
                        ),
                        .runComplete(
                            trackID: result.trackID,
                            trackName: result.trackName,
                            bamPath: result.bamURL.path,
                            baiPath: result.indexURL.path,
                            provenanceSidecarPath: result.provenanceSidecarURL.path
                        )
                    ]
                    for event in events {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                Self.applyPrimerTrimEvent(event, operationID: opID)
                            }
                        }
                    }
                } else {
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
                                Self.applyPrimerTrimEvent(event, operationID: opID)
                            }
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, let split = self.parent as? MainSplitViewController {
                            split.sidebarController.reloadFromFilesystem()
                            do {
                                try split.viewerController.displayBundle(at: bundleURL)
                            } catch {
                                self.presentSimpleAlert(
                                    title: "Bundle Reload Failed",
                                    message: "Primer trim completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }

                        let detail = tracker.completedTrackName.map { "Adopted alignment track \($0)" }
                            ?? "Primer trim complete"
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
                            title: "Primer Trim Failed",
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

    @MainActor
    private static func applyPrimerTrimEvent(_ event: CLIPrimerTrimEvent, operationID: UUID) {
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
                return (max(0.10, min(0.80, progress)), message, .info)
            case .stageComplete(let message):
                return (0.80, message, .info)
            case .attachStart(let message):
                return (0.90, message, .info)
            case .attachComplete(_, let trackName, _, _, _):
                let detail = trackName.map { "Adopted alignment track \($0)" } ?? "Adopted alignment track"
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

    private func presentPrimerSchemeBrowseSheet(for state: BAMPrimerTrimDialogState) {
        guard let window = view.window ?? NSApp.keyWindow else { return }

        let panel = FeatureFilePanelFactory.primerSchemeFolderPanel(
            directoryURL: (parent as? MainSplitViewController)?
                .sidebarController
                .currentProjectURL
                .flatMap { PrimerSchemesFolder.folderURL(in: $0) }
        )

        panel.beginSheetModal(for: window) { [weak self, weak state] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let scheme = try PrimerSchemeBundle.load(from: url)
                state?.addProjectSchemeAndSelect(scheme)
            } catch {
                self?.presentSimpleAlert(
                    title: "Could Not Load Primer Scheme",
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Duplicate Workflows

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

        let operationID = Self.startMappedReadsAnnotationWorkflowOperation(
            bundleURL: bundleURL,
            outputTrackName: request.outputTrackName
        )
        let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
            .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
        viewModel.readStyleSectionViewModel.latestMappedReadsAnnotationMessage = nil
        viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = true
        split.activityIndicator.show(message: "Converting mapped reads to annotations...", style: .indeterminate)

        Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await MappedReadsAnnotationService().convertMappedReads(
                    request: request.workflowRequest(bundleURL: bundleURL),
                    progressHandler: { [weak self] progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.update(
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
                        OperationCenter.shared.complete(
                            id: operationID,
                            detail: "Created annotation track \"\(result.annotationTrackInfo.name)\"."
                        )
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
                        OperationCenter.shared.fail(
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

        let operationID = Self.startFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            outputTrackName: request.outputTrackName
        )
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
                                OperationCenter.shared.update(
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
                        OperationCenter.shared.complete(
                            id: operationID,
                            detail: "Created filtered alignment track \"\(result.trackInfo.name)\"."
                        )
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
                        OperationCenter.shared.fail(
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

    static func startFilteredAlignmentWorkflowOperation(
        bundleURL: URL,
        outputTrackName: String
    ) -> UUID {
        OperationCenter.shared.start(
            title: "Create Filtered Alignment Track",
            detail: "Preparing \(outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
    }

    static func startMappedReadsAnnotationWorkflowOperation(
        bundleURL: URL,
        outputTrackName: String
    ) -> UUID {
        OperationCenter.shared.start(
            title: "Convert Mapped Reads to Annotations",
            detail: "Preparing \(outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
    }

    /// Runs `samtools markdup` over all loaded alignment tracks and replaces those tracks in-place.
    func runMarkDuplicatesWorkflow() {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before running duplicate workflows.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Mark Duplicates in Alignment Tracks?"
        confirm.informativeText = "This will run samtools markdup for each alignment track in the current bundle and replace existing tracks with duplicate-marked versions."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Mark Duplicates")
        confirm.addButton(withTitle: "Cancel")
        guard let window = view.window ?? NSApp.keyWindow else { return }
        confirm.beginSheetModal(for: window) { [weak self] confirmResponse in
            guard confirmResponse == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self, let split = self.parent as? MainSplitViewController else { return }

                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = true
                split.activityIndicator.show(message: "Marking duplicates...", style: .indeterminate)

                Task(priority: .userInitiated) { [weak self] in
                    do {
                        let result = try await AlignmentDuplicateService.markDuplicatesInBundle(bundleURL: bundleURL)

                        DispatchQueue.main.async { [weak self] in
                            guard let self, let split = self.parent as? MainSplitViewController else { return }
                            MainActor.assumeIsolated {
                                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                                split.activityIndicator.hide()

                                do {
                                    try split.viewerController.displayBundle(at: result.bundleURL)
                                    // Markdup sets SAM duplicate flag; keep duplicates hidden by default.
                                    self.viewModel.readStyleSectionViewModel.showDuplicates = false
                                    self.viewModel.readStyleSectionViewModel.onSettingsChanged?()
                                    self.presentSimpleAlert(
                                        title: "Duplicate Marking Complete",
                                        message: "Processed \(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s"). Duplicate-marked tracks are now loaded."
                                    )
                                } catch {
                                    self.presentSimpleAlert(
                                        title: "Reload Failed",
                                        message: "Duplicate marking completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let split = self.parent as? MainSplitViewController else { return }
                            MainActor.assumeIsolated {
                                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                                split.activityIndicator.hide()
                                self.presentSimpleAlert(
                                    title: "Duplicate Marking Failed",
                                    message: error.localizedDescription
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Creates a sibling deduplicated bundle by running `samtools markdup -r` on alignment tracks.
    func runCreateDeduplicatedBundleWorkflow() {
        guard let sourceBundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before creating a deduplicated copy.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Create Deduplicated Bundle?"
        confirm.informativeText = "This creates a sibling .lungfishref bundle with duplicate reads removed from all alignment tracks. The current bundle will not be modified."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Create Bundle")
        confirm.addButton(withTitle: "Cancel")
        guard let window = view.window ?? NSApp.keyWindow else { return }
        confirm.beginSheetModal(for: window) { [weak self] confirmResponse in
            guard confirmResponse == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self, let split = self.parent as? MainSplitViewController else { return }

                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = true
                split.activityIndicator.show(message: "Creating deduplicated bundle...", style: .indeterminate)

                Task(priority: .userInitiated) { [weak self] in
                    do {
                        let result = try await AlignmentDuplicateService.createDeduplicatedBundle(from: sourceBundleURL)

                        DispatchQueue.main.async { [weak self] in
                            guard let self, let split = self.parent as? MainSplitViewController else { return }
                            MainActor.assumeIsolated {
                                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                                split.activityIndicator.hide()
                                split.sidebarController.reloadFromFilesystem()

                                do {
                                    try split.viewerController.displayBundle(at: result.bundleURL)
                                    self.presentSimpleAlert(
                                        title: "Deduplicated Bundle Created",
                                        message: "Processed \(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s"). New bundle: \(result.bundleURL.lastPathComponent)"
                                    )
                                } catch {
                                    self.presentSimpleAlert(
                                        title: "Open New Bundle Failed",
                                        message: "Deduplicated bundle was created at \(result.bundleURL.path), but opening it failed: \(error.localizedDescription)"
                                    )
                                }
                            }
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let split = self.parent as? MainSplitViewController else { return }
                            MainActor.assumeIsolated {
                                self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                                split.activityIndicator.hide()
                                self.presentSimpleAlert(
                                    title: "Deduplicated Bundle Failed",
                                    message: error.localizedDescription
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Updates the quality section with new quality data.
    ///
    /// Call this when loading a file to update quality statistics display.
    ///
    /// - Parameters:
    ///   - hasData: Whether the loaded file has quality data (true for FASTQ)
    ///   - statistics: Quality statistics if available
    public func updateQualityData(hasData: Bool, statistics: QualityStatistics?) {
        viewModel.hasQualityData = hasData
        viewModel.qualityStats = statistics
        viewModel.qualitySectionViewModel.update(hasData: hasData, statistics: statistics)
    }

    /// Called by the split view controller when inspector visibility changes.
    ///
    /// Ensures control callbacks and current annotation settings remain active
    /// after collapse/expand transitions.
    public func inspectorVisibilityDidChange(isVisible: Bool) {
        inspectorLogger.info(
            "inspectorVisibilityDidChange: isVisible=\(isVisible), wasVisible=\(self.wasInspectorVisible)"
        )
        wasInspectorVisible = isVisible

        guard isVisible else { return }

        inspectorLogger.info("inspectorVisibilityDidChange: refreshing hosting view for visible inspector")
        refreshHostingView()

        ensureInspectorWiring()
        syncAnnotationStateToViewer()
    }

}
