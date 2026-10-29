// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishOperations
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
        Self.beginPrimerTrimOperation(
            title: "Primer-trimming with \(scheme.manifest.displayName)",
            bundleURL: bundleURL,
            cliArguments: cliArguments,
            routeContext: operationRouteContext(for: bundleURL)
        ) { opID in
            final class ResultTracker: @unchecked Sendable {
                var completedTrackName: String?
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
                        let events: [CLIEvent] = [
                            .start(message: "Starting deterministic UI test primer trim"),
                            .log(level: .info, message: "Adopting deterministic primer-trimmed BAM into bundle"),
                            .complete(
                                outputs: [result.bamURL.path, result.indexURL.path, result.provenanceSidecarURL.path],
                                message: "trackID=\(result.trackID) trackName=\(result.trackName)"
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
                        let result = try await runner.run(arguments: cliArguments) { event in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    Self.applyPrimerTrimEvent(event, operationID: opID)
                                }
                            }
                        }
                        tracker.completedTrackName = result.trackName
                    }

                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            let detail = tracker.completedTrackName.map { "Adopted alignment track \($0)" }
                                ?? "Primer trim complete"
                            guard OperationCenter.shared.complete(id: opID, detail: detail) else { return }
                            if let self, let split = self.parent as? MainSplitViewController {
                                do {
                                    try split.displayReferenceBundleAfterWorkflow(at: bundleURL)
                                } catch {
                                    self.presentFailure(InspectorFailureReports.reloadBundleAfterPrimerTrim(error))
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
    }

    @MainActor
    private static func applyPrimerTrimEvent(_ event: CLIEvent, operationID: UUID) {
        let (progress, detail, level): (Double?, String, OperationLogLevel) = {
            switch event {
            case let .start(message):
                return (0.01, message, .info)
            case let .progress(fraction, message):
                return (max(0.10, min(0.80, fraction)), message, .info)
            case let .log(cliLevel, message):
                return (nil, message, cliLevel.primerTrimOperationLogLevel)
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
                self?.presentFailure(InspectorFailureReports.loadPrimerScheme(error))
            }
        }
    }

    // MARK: - Duplicate workflows

    /// The two duplicate workflows the Read Style section offers, and the
    /// words each one uses in its Operations Panel row and alerts.
    enum DuplicateWorkflowKind: Equatable {
        /// `samtools markdup` over every unmarked track, marked copies attached
        /// alongside the originals.
        case markDuplicates
        /// A sibling bundle with duplicates removed from every track.
        case createDeduplicatedBundle

        var operationTitle: String {
            switch self {
            case .markDuplicates: return "Mark Duplicates in Bundle Tracks"
            case .createDeduplicatedBundle: return "Create Deduplicated Bundle"
            }
        }

        var startingDetail: String {
            switch self {
            case .markDuplicates: return "Marking duplicates..."
            case .createDeduplicatedBundle: return "Creating deduplicated bundle..."
            }
        }

        /// The `lungfish-cli` subcommand the kind runs. Both are the existing duplicate leaves, not
        /// `bam markdup`, which takes BAM files and no bundle (Phase 2.10 decision C14).
        var subcommand: String {
            switch self {
            case .markDuplicates: return "bundle mark-duplicates"
            case .createDeduplicatedBundle: return "bundle deduplicate-alignments"
            }
        }

        /// The argv after the binary that the CLI route runs. `--format json` makes the leaf speak events.
        func cliArguments(bundleURL: URL) -> [String] {
            subcommand.split(separator: " ").map(String.init) + [bundleURL.path, "--format", "json"]
        }

        /// The command the row records, the argv the L3 runner runs, for the row's Copy CLI Command.
        func cliCommand(bundleURL: URL) -> String {
            OperationCenter.buildCLICommand(
                subcommand: subcommand, args: Array(cliArguments(bundleURL: bundleURL).dropFirst(2))
            )
        }

        var failureAlertTitle: String {
            switch self {
            case .markDuplicates: return "Duplicate Marking Failed"
            case .createDeduplicatedBundle: return "Deduplicated Bundle Failed"
            }
        }
    }

    /// The confirmation sheet for a duplicate workflow. The Mark Duplicates
    /// title matches the "Mark Duplicates in Bundle Tracks" button that opens it.
    static func duplicateWorkflowConfirmation(for kind: DuplicateWorkflowKind) -> InspectorWorkflowAlert {
        switch kind {
        case .markDuplicates:
            return InspectorWorkflowAlert(
                title: "Mark Duplicates in Bundle Tracks?",
                message: "This runs samtools markdup for each unmarked alignment track in the current bundle and adds a duplicate-marked copy next to it. The original tracks are kept and renamed with an [unmarked] suffix; no files are deleted."
            )
        case .createDeduplicatedBundle:
            return InspectorWorkflowAlert(
                title: "Create Deduplicated Bundle?",
                message: "This creates a sibling .lungfishref bundle with duplicate reads removed from all alignment tracks. The current bundle will not be modified."
            )
        }
    }

    /// The gate every duplicate workflow passes before it starts: the same
    /// bundle lock the other bundle mutations respect. `.blocked` carries the
    /// "Operation in Progress" alert the filtered-alignment workflow shows.
    static func makeDuplicateWorkflowStartOutcome(
        bundleURL: URL,
        canStartBundleMutation: (URL) -> Bool = { OperationCenter.shared.canStartOperation(on: $0) },
        activeBundleMutationTitle: (URL) -> String? = { OperationCenter.shared.activeLockHolder(for: $0)?.title }
    ) -> DuplicateWorkflowStartOutcome {
        guard canStartBundleMutation(bundleURL) else {
            let message: String
            if let title = activeBundleMutationTitle(bundleURL) {
                message = "\"\(title)\" is currently running on this bundle. Please wait for it to finish."
            } else {
                message = "Another operation is currently running on this bundle. Please wait for it to finish."
            }
            return .blocked(InspectorWorkflowAlert(title: "Operation in Progress", message: message))
        }
        return .launch
    }

    /// Registers the Operations Panel row for a duplicate workflow, holding
    /// the bundle's write lock for the run. `.refused` when another operation
    /// took the lock between the gate and this call. The row records the
    /// argv the L3 runner runs.
    static func startDuplicateWorkflowOperation(
        kind: DuplicateWorkflowKind,
        bundleURL: URL,
        routeContext: OperationRouteContext?,
        center: OperationCenter = .shared,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> OperationStartResult {
        center.begin(
            title: kind.operationTitle,
            detail: kind.startingDetail,
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: kind.cliCommand(bundleURL: bundleURL),
            routeContext: routeContext,
            onCancel: onCancel
        )
    }

    /// Runs `samtools markdup` over every unmarked alignment track and attaches the marked
    /// copies alongside the originals, which are kept and renamed "[unmarked]".
    func runMarkDuplicatesWorkflow() {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before running duplicate workflows.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }
        confirmAndLaunchDuplicateWorkflow(kind: .markDuplicates, bundleURL: bundleURL)
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
        confirmAndLaunchDuplicateWorkflow(kind: .createDeduplicatedBundle, bundleURL: sourceBundleURL)
    }

    private func confirmAndLaunchDuplicateWorkflow(kind: DuplicateWorkflowKind, bundleURL: URL) {
        let confirmation = Self.duplicateWorkflowConfirmation(for: kind)
        let confirm = NSAlert()
        confirm.messageText = confirmation.title
        confirm.informativeText = confirmation.message
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: kind == .markDuplicates ? "Mark Duplicates" : "Create Bundle")
        confirm.addButton(withTitle: "Cancel")
        guard let window = view.window ?? NSApp.keyWindow else { return }
        confirm.beginSheetModal(for: window) { [weak self] confirmResponse in
            guard confirmResponse == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.launchDuplicateWorkflow(kind: kind, bundleURL: bundleURL)
            }
        }
    }

    /// Runs a duplicate workflow through the OperationCenter like every other
    /// bundle mutation: the project and bundle locks are checked first, the
    /// run gets an Operations Panel row with progress and a Cancel button, and
    /// the row is completed, failed, or marked cancelled when the work ends.
    private func launchDuplicateWorkflow(kind: DuplicateWorkflowKind, bundleURL: URL) {
        guard let split = parent as? MainSplitViewController else { return }
        guard canWriteProjectOutputs(bundleURL: bundleURL, workflowName: kind.operationTitle) else { return }
        switch Self.makeDuplicateWorkflowStartOutcome(bundleURL: bundleURL) {
        case .blocked(let alert):
            presentSimpleAlert(title: alert.title, message: alert.message)
            return
        case .launch:
            break
        }

        // The plan holds the count read before the row begins, because the leaf's `complete` message is text
        // and the app parses no number out of it. The runner sets the row's Cancel once its run starts.
        let plan: DuplicateWorkflowPlan
        switch Self.beginDuplicateWorkflow(
            kind: kind,
            bundleURL: bundleURL,
            routeContext: operationRouteContext(for: bundleURL)
        ) {
        case .started(let started):
            plan = started
        case .refused(let refusal):
            presentSimpleAlert(title: "Operation in Progress", message: refusal.message)
            return
        }
        let operationID = plan.operationID

        viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = true
        split.activityIndicator.show(message: kind.startingDetail, style: .indeterminate)

        switch plan.launch {
        case .leaf(let arguments):
            // The leaf marks or copies the bundle and writes its record before it exits. The row completes
            // before the bundle opens or an alert shows, so the result stays hidden until then.
            Self.runAlignmentLeafThroughCLI(
                arguments: arguments,
                operationID: operationID,
                cancelled: { [weak self] in self?.resetDuplicateWorkflowUI() }
            ) { [weak self] outcome in
                self?.finishDuplicateWorkflowThroughCLI(
                    kind: kind, bundleURL: bundleURL, trackCount: plan.trackCount, operationID: operationID, outcome: outcome
                )
            }
        }
    }

    private func resetDuplicateWorkflowUI() {
        viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
        (parent as? MainSplitViewController)?.activityIndicator.hide()
    }

    /// Ends a duplicate workflow. A leaf that completed gives the result the completion code reads: the row
    /// completes first, and the bundle opens and the alert shows only then. A leaf that failed fails the row
    /// with its own words.
    private func finishDuplicateWorkflowThroughCLI(
        kind: DuplicateWorkflowKind,
        bundleURL: URL,
        trackCount: Int,
        operationID: UUID,
        outcome: Result<CLIAlignmentActionRunner.Completion, any Error>
    ) {
        do {
            let result = try Self.duplicateWorkflowResult(
                kind: kind, bundleURL: bundleURL, trackCount: trackCount, completion: try outcome.get()
            )
            finishDuplicateWorkflow(kind: kind, operationID: operationID, result: result)
        } catch {
            let message = error.localizedDescription
            OperationCenterCLIBridge.failOperation(operationID, detail: message, fallbackMessage: message)
            resetDuplicateWorkflowUI()
            presentSimpleAlert(title: kind.failureAlertTitle, message: message)
        }
    }

    private func finishDuplicateWorkflow(
        kind: DuplicateWorkflowKind,
        operationID: UUID,
        result: AlignmentDuplicateService.WorkflowResult
    ) {
        let trackCount = Self.alignmentTrackCountText(result.processedTracks)
        resetDuplicateWorkflowUI()
        guard let split = parent as? MainSplitViewController else { return }

        switch kind {
        case .markDuplicates:
            guard Self.completeDuplicateWorkflowRow(kind: kind, operationID: operationID, result: result) else { return }
            do {
                try split.viewerController.displayBundle(at: result.bundleURL)
                // Markdup sets SAM duplicate flag; keep duplicates hidden by default.
                viewModel.readStyleSectionViewModel.showDuplicates = false
                viewModel.readStyleSectionViewModel.onSettingsChanged?()
                presentSimpleAlert(
                    title: "Duplicate Marking Complete",
                    message: "Processed \(trackCount). Duplicate-marked tracks were added; the original tracks are kept with an [unmarked] suffix."
                )
            } catch {
                presentFailure(InspectorFailureReports.reloadBundleAfterDuplicateMarking(error))
            }
        case .createDeduplicatedBundle:
            guard Self.completeDuplicateWorkflowRow(kind: kind, operationID: operationID, result: result) else { return }
            do {
                try split.displayReferenceBundleAfterWorkflow(at: result.bundleURL)
                presentSimpleAlert(
                    title: "Deduplicated Bundle Created",
                    message: "Processed \(trackCount). New bundle: \(result.bundleURL.lastPathComponent)"
                )
            } catch {
                presentFailure(InspectorFailureReports.openDeduplicatedBundle(at: result.bundleURL.path, error))
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

private extension CLIEventLogLevel {
    var primerTrimOperationLogLevel: OperationLogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
