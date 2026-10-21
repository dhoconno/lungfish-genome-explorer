// AppDelegate+ToolsMenu.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os
import LungfishKit

/// Holds a `Task<Void, Never>` handle for a sequential mapping batch so its
/// cancel callback (registered per-bundle, before the batch `Task` literal
/// finishes being constructed) can cancel whichever task ends up assigned.
/// An actor rather than a plain class + `@unchecked Sendable`: `Task` is
/// itself `Sendable`, so an actor gives race-free cross-isolation access to
/// the stored handle without any unsafe opt-out.
///
/// `assign` and `cancel` are both `nonisolated` and hop onto the actor via
/// their own unordered `Task { await ... }` -- the Swift runtime gives no
/// ordering guarantee between two such hops fired from different call
/// sites. Without `cancelRequested`, a `cancel()` that wins the race while
/// `assign(_:)`'s hop is still pending would find `task == nil` and be a
/// silent no-op: the `OperationCenter` row would show "Cancelled by user"
/// while the mapper keeps running underneath. `cancelRequested` closes that
/// window: whichever hop loses the race still observes the other's intent
/// and acts on it.
// `internal` (not `private`) rather than file-scoped so
// `MappingBatchTaskHandleTests` can drive its actor-isolated methods
// directly via `@testable import LungfishApp` -- it is still an
// implementation detail, not part of any public API, and its production
// call sites (`assign`/`cancel`) are only ever used from within this file.
actor MappingBatchTaskHandle {
    private var task: Task<Void, Never>?
    private var cancelRequested = false

    /// Production entry point: hops onto the actor via its own unordered
    /// `Task { await ... }`, so calling this back-to-back with `cancel()`
    /// from a `nonisolated` context gives NO ordering guarantee between the
    /// two -- see `setTask`'s `cancelRequested` check for why that's safe.
    nonisolated func assign(_ task: Task<Void, Never>) {
        Task { await self.setTask(task) }
    }

    /// Actor-isolated and directly `await`-able, so a test can drive the
    /// exact "cancel already requested before assignment lands" ordering
    /// deterministically by calling this and `cancelStoredTask` (via
    /// `cancelForTesting`) as plain sequential `await`s, instead of relying
    /// on `assign`/`cancel`'s racy `Task { await ... }` hops to land in a
    /// particular order.
    func setTask(_ task: Task<Void, Never>) {
        if cancelRequested {
            // cancel() already ran (or is concurrently running) before this
            // assignment landed -- honor the earlier request immediately
            // instead of storing a task nobody will ever cancel.
            task.cancel()
            return
        }
        self.task = task
    }

    /// Production entry point: see `assign`'s doc comment for the ordering
    /// caveat this exists to close (`cancelRequested`).
    nonisolated func cancel() {
        Task { await self.cancelStoredTask() }
    }

    /// Actor-isolated and directly `await`-able -- see `setTask`.
    func cancelStoredTask() {
        cancelRequested = true
        task?.cancel()
    }

    /// Test-only observers of internal state, so a deterministic test can
    /// assert on the actual stored flag/task rather than only inferring
    /// correctness from `Task.isCancelled` side effects.
    func currentlyHasCancelRequested() -> Bool { cancelRequested }
    func currentlyAssignedTask() -> Task<Void, Never>? { task }
}

extension AppDelegate {
    // MARK: - ToolsMenuActions

    @objc func launchFASTQOperationToolFromMenu(_ sender: NSMenuItem) {
        guard let toolID = sender.representedObject as? FASTQOperationToolID else { return }
        showFASTQOperationsDialog(sender, initialCategory: toolID.categoryID, initialToolID: toolID)
    }

    func canShowBAMVariantCalling(bundle: ReferenceBundle?) -> Bool {
        guard let bundle else { return false }
        return !BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle).isEmpty
    }

    @objc func showBAMVariantCalling(_ sender: Any?) {
        let controller = activeMainWindowController(sender: sender)
        guard let split = controller?.mainSplitViewController else { return }
        // The same resolver the menu validation uses, so the dialog opens on the
        // bundle the item was enabled for: the displayed reference bundle, a
        // mapping result's reference copy, or the sidebar's selected bundle.
        split.inspectorController.presentVariantCallingDialog(
            bundle: currentReferenceBundle(in: controller),
            preferredAlignmentTrackID: nil
        )
    }

    func showFASTQOperationsDialog(
        _ sender: Any?,
        initialCategory: FASTQOperationCategoryID,
        initialToolID: FASTQOperationToolID? = nil,
        preferredInputURLs: [URL] = [],
        mafftAllSequenceCount: Int = 0,
        mafftSelectedSequenceNames: [String] = []
    ) {
        guard let originController = activeMainWindowController(sender: sender),
              let originSplit = originController.mainSplitViewController,
              let window = originController.window else {
            answerToolsMenuItemWithNoMainWindow(category: initialCategory, toolID: initialToolID)
            return
        }

        let routeContext = currentOperationRouteContext(for: originController)
        let currentProjectURL = routeContext?.projectURL
            ?? originSplit.sidebarController?.currentProjectURL

        func showNoInputsAlert(title: String = "No FASTQ/FASTA Inputs Selected", message: String? = nil) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message ?? "Select one or more FASTQ or FASTA files, sequence bundles, or reference bundles in the sidebar, then choose the matching operation category from the Tools menu."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }

        func presentOperationsDialog(selectedInputURLs: [URL]) {
            guard !selectedInputURLs.isEmpty else {
                showNoInputsAlert()
                return
            }

            // The viewer route passes its own record count. The Tools menu
            // route only knows the selected inputs, so derive the count for the
            // MAFFT pane's "All sequences (N)" row off the main actor first;
            // otherwise the pane reads "Aligning all 0 sequences."
            guard mafftAllSequenceCount == 0,
                  Self.dialogShowsMAFFTSequenceScope(initialCategory: initialCategory, initialToolID: initialToolID) else {
                presentResolvedOperationsDialog(
                    selectedInputURLs: selectedInputURLs,
                    mafftAllSequenceCount: mafftAllSequenceCount
                )
                return
            }
            Task { @MainActor in
                let count = await Task.detached(priority: .userInitiated) {
                    await MSAInputSequenceCounter.sequenceCount(for: selectedInputURLs)
                }.value
                presentResolvedOperationsDialog(
                    selectedInputURLs: selectedInputURLs,
                    mafftAllSequenceCount: count
                )
            }
        }

        func presentResolvedOperationsDialog(selectedInputURLs: [URL], mafftAllSequenceCount: Int) {
            FASTQOperationsDialogPresenter.present(
                from: window,
                selectedInputURLs: selectedInputURLs,
                initialCategory: initialCategory,
                initialToolID: initialToolID,
                projectURL: currentProjectURL,
                mafftAllSequenceCount: mafftAllSequenceCount,
                mafftSelectedSequenceNames: mafftSelectedSequenceNames,
                onRun: { [weak self] state in
                guard let self else { return }
                debugLog("showFASTQOperationsDialog: confirmed \(state.selectedToolID.rawValue) for \(state.selectedInputURLs.count) input(s)")

                if let request = state.pendingViralReconRequest {
                    let service: ViralReconWorkflowExecutionService
                    if AppUITestConfiguration.current.isEnabled,
                       AppUITestConfiguration.current.backendMode == .deterministic {
                        service = ViralReconWorkflowExecutionService(processRunner: AppUITestViralReconWorkflowProcessRunner())
                    } else {
                        service = ViralReconWorkflowExecutionService()
                    }
                    let bundleRoot = currentProjectURL?
                        .appendingPathComponent("Analyses", isDirectory: true)
                        ?? request.outputDirectory.deletingLastPathComponent()
                    Task {
                        do {
                            _ = try await service.run(
                                request,
                                bundleRoot: bundleRoot,
                                projectURL: currentProjectURL,
                                routeContext: routeContext
                            )
                        } catch {
                            debugLog("showFASTQOperationsDialog: Viral Recon failed to start: \(String(describing: error))")
                            AppDelegate.reportViralReconLaunchFailure(error, routeContext: routeContext)
                        }
                    }
                    return
                }

                if let plan = state.pendingMappingRequest {
                    self.runManagedMapping(plan: plan, routeContext: routeContext)
                    return
                }

                if let request = state.pendingMSAAlignmentRequest {
                    self.runMAFFTAlignment(request: request, routeContext: routeContext)
                    return
                }

                if let request = state.pendingLaunchRequest,
                   state.pendingClassificationConfigs.isEmpty,
                   state.pendingEsVirituConfigs.isEmpty,
                   state.pendingTaxTriageConfig == nil {
                    originSplit.runFASTQOperationLaunchRequest(
                        request,
                        preferredOutputDirectory: state.outputDirectoryURL
                    )
                    return
                }

                guard let viewerController = originSplit.viewerController else {
                    debugLog("showFASTQOperationsDialog: No viewer controller available for \(state.selectedToolID.rawValue)")
                    return
                }

                if !state.pendingClassificationConfigs.isEmpty {
                    self.launchClassification(configs: state.pendingClassificationConfigs, viewerController: viewerController, routeContext: routeContext)
                    return
                }

                if !state.pendingEsVirituConfigs.isEmpty {
                    self.launchEsViritu(configs: state.pendingEsVirituConfigs, viewerController: viewerController, routeContext: routeContext)
                    return
                }

                if let config = state.pendingTaxTriageConfig {
                    self.launchTaxTriage(config: config, viewerController: viewerController, routeContext: routeContext)
                    return
                }
                }
            )
        }

        if initialCategory == .classification,
           preferredInputURLs.isEmpty,
           let sidebarItems = originSplit.sidebarController?.selectedItems(),
           !sidebarItems.isEmpty {
            let folderInput = Self.classificationFolderInput(items: sidebarItems, projectURL: currentProjectURL)
            if folderInput.folderSelectionCount > 0 {
                if folderInput.isEmpty {
                    showNoInputsAlert(
                        title: "No FASTQ Samples Found",
                        message: "No eligible FASTQ or FASTA samples were found in the selected folder."
                    )
                    return
                }
                if folderInput.hasSubfolderBundles {
                    ClassificationFolderPrompt.present(for: folderInput, in: window) { choice in
                        guard let readURLs = ClassificationFolderPrompt.readURLs(for: choice, from: folderInput) else {
                            return
                        }
                        presentOperationsDialog(selectedInputURLs: readURLs)
                    }
                    return
                }
                presentOperationsDialog(selectedInputURLs: folderInput.directReadURLs)
                return
            }
        }

        let selectedInputURLs = gatherFASTQOperationInputURLs(
            preferredInputURLs: preferredInputURLs,
            controller: originController
        )
        presentOperationsDialog(selectedInputURLs: selectedInputURLs)
    }

    private func gatherFASTQOperationInputURLs(
        preferredInputURLs: [URL],
        controller: MainWindowController? = nil
    ) -> [URL] {
        let controller = controller ?? activeMainWindowController()
        let selectedURLs = controller?.mainSplitViewController?.sidebarController.selectedFileURLs() ?? []
        let viewerController = controller?.mainSplitViewController?.viewerController
        let currentFASTQURL = viewerController?.currentFASTQDatasetURL ?? viewerController?.currentBundleURL
        return Self.resolveFASTQOperationInputURLs(
            preferredInputURLs: preferredInputURLs,
            selectedURLs: selectedURLs,
            currentFASTQURL: currentFASTQURL
        )
    }

    private func gatherWorkflowOperationReadInputURLs(
        controller: MainWindowController? = nil
    ) -> [URL] {
        let controller = controller ?? activeMainWindowController()
        let selectedURLs = controller?.mainSplitViewController?.sidebarController.selectedFileURLs() ?? []
        return Self.resolveWorkflowOperationReadInputURLs(
            selectedURLs: selectedURLs,
            currentFASTQURL: nil
        )
    }

    static func resolveWorkflowSidebarInputSelectionForOperations(
        items: [SidebarItem],
        projectURL: URL?
    ) -> (selectedReadURLs: [URL], sidebarInputSelection: WorkflowSidebarInputSelection?) {
        let sidebarInputSelection = WorkflowSidebarInputSelection.resolve(items: items, projectURL: projectURL)
        let selectedReadURLs = sidebarInputSelection.selectedReadURLs(includeSubfolders: false)
        if sidebarInputSelection.folderSelectionCount > 0 || !selectedReadURLs.isEmpty {
            return (selectedReadURLs, sidebarInputSelection)
        }

        return (
            resolveWorkflowOperationReadInputURLs(
                selectedURLs: items.compactMap(\.url),
                currentFASTQURL: nil
            ),
            nil
        )
    }

    /// Reference bundles selected in the sidebar, which the Workflow Operations window
    /// prefers as its Project Reference.
    static func resolveWorkflowOperationSelectedReferenceURLs(items: [SidebarItem]) -> [URL] {
        var seen = Set<String>()
        return items.compactMap { item -> URL? in
            guard let url = item.url?.standardizedFileURL,
                  WorkflowOperationDialogState.isReferenceBundleURL(url),
                  seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    /// True when the dialog opens on, or can switch to, the MAFFT pane, which is
    /// the only pane that shows the all-sequence count.
    static func dialogShowsMAFFTSequenceScope(
        initialCategory: FASTQOperationCategoryID,
        initialToolID: FASTQOperationToolID?
    ) -> Bool {
        initialToolID == .mafft || initialCategory == FASTQOperationToolID.mafft.categoryID
    }

    static func resolveWorkflowOperationReadInputURLs(
        selectedURLs: [URL],
        currentFASTQURL _: URL?
    ) -> [URL] {
        let selected = selectedURLs.compactMap(resolveWorkflowOperationReadInputURL(from:))
        if !selected.isEmpty {
            return deduplicatedFASTQOperationInputURLs(selected)
        }

        return []
    }

    static func resolveWorkflowOperationReadInputURL(from url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if FASTQBundle.isBundleURL(standardizedURL) {
            return standardizedURL
        }
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedURL) {
            return bundleURL
        }
        return nil
    }

    static func resolveFASTQOperationInputURLs(
        preferredInputURLs: [URL] = [],
        selectedURLs: [URL],
        currentFASTQURL: URL?
    ) -> [URL] {
        let preferred = preferredInputURLs.compactMap(resolveFASTQOperationInputURL(from:))
        if !preferred.isEmpty {
            return deduplicatedFASTQOperationInputURLs(preferred)
        }

        let selected = selectedURLs.compactMap(resolveFASTQOperationInputURL(from:))
        if !selected.isEmpty {
            return deduplicatedFASTQOperationInputURLs(selected)
        }

        if let currentFASTQURL,
           let resolvedCurrent = resolveFASTQOperationInputURL(from: currentFASTQURL) {
            return [resolvedCurrent]
        }

        return []
    }

    static func resolveFASTQOperationInputURL(from url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        switch standardizedURL.pathExtension.lowercased() {
        case "lungfishfastq", "lungfishref":
            return standardizedURL
        default:
            break
        }
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedURL) {
            return bundleURL
        }
        if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: standardizedURL) {
            return referenceBundleURL
        }
        if SequenceInputResolver.inputSequenceFormat(for: standardizedURL) != nil {
            return standardizedURL
        }

        return nil
    }

    private static func deduplicatedFASTQOperationInputURLs(_ inputURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return inputURLs.filter { url in
            seenPaths.insert(url.standardizedFileURL.path).inserted
        }
    }

    @objc func runSPAdes(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .assembly)
    }

    @objc func launchMinimap2Mapping(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .mapping)
    }

    @objc func launchNaoMgsImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchNaoMgsImport: No main window available")
            refuseImportWithoutProject("NAO-MGS results", window: nil)
            return
        }
        let request = sender as? ImportWizardRequest
        let routeContext = currentOperationRouteContext(for: controller)

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "NAO-MGS Import"
        wizardPanel.isReleasedWhenClosed = false

        var sheet = NaoMgsImportSheet(datasetURL: nil, initialSourceURL: request?.sourceURL)
        sheet.onImport = { [weak self] (resultsDir: URL) in
            window.endSheet(wizardPanel)
            self?.importNaoMgsResultFromURL(resultsDir, routeContext: routeContext, onDispatch: { outcome in
                if outcome == .started { request?.started(sourceURL: resultsDir) }
                else { request?.onOutcome(outcome) }
            })
        }
        sheet.onCancel = {
            request?.onOutcome(.cancelled)
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 520, height: 400))
        window.beginSheet(wizardPanel)
        request?.presented()
    }

    @objc func launchPrimerSchemeImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchPrimerSchemeImport: No main window available")
            refuseImportWithoutProject("a primer scheme", window: nil)
            return
        }
        let request = sender as? ImportWizardRequest
        let routeContext = currentOperationRouteContext(for: controller)
        guard let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            showAlert(
                title: "No Project Open",
                message: "Open a project before importing a primer scheme.",
                presentingWindow: window
            )
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            workflowName: "Primer scheme import",
            presentingWindow: window
        ) else { return }

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "Import Primer Scheme"
        wizardPanel.isReleasedWhenClosed = false

        let importViewModel = PrimerSchemeImportViewModel()
        let view = PrimerSchemeImportView(
            viewModel: importViewModel,
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            onComplete: { _ in
                window.endSheet(wizardPanel)
            },
            onCancel: {
                request?.onOutcome(.cancelled)
                window.endSheet(wizardPanel)
            },
            initialBEDURL: request?.sourceURL,
            onAcceptedSource: { request?.started(sourceURL: $0) }
        )

        let hostingController = NSHostingController(rootView: view)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 540, height: 480))
        window.beginSheet(wizardPanel)
        request?.presented()
    }

    @objc func launchNvdImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchNvdImport: No main window available")
            refuseImportWithoutProject("NVD results", window: nil)
            return
        }
        let request = sender as? ImportWizardRequest
        let routeContext = currentOperationRouteContext(for: controller)

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "NVD Import"
        wizardPanel.isReleasedWhenClosed = false

        var sheet = NvdImportSheet(datasetURL: nil, initialSourceURL: request?.sourceURL)
        sheet.onImport = { [weak self] (nvdDir: URL) in
            window.endSheet(wizardPanel)
            self?.importNvdResultFromURL(nvdDir, routeContext: routeContext, onDispatch: { outcome in
                if outcome == .started { request?.started(sourceURL: nvdDir) }
                else { request?.onOutcome(outcome) }
            })
        }
        sheet.onCancel = {
            request?.onOutcome(.cancelled)
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 500, height: 450))
        window.beginSheet(wizardPanel)
        request?.presented()
    }

    @objc func launchCzIdImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchCzIdImport: No main window available")
            refuseImportWithoutProject("CZ-ID results", window: nil)
            return
        }
        let request = sender as? ImportWizardRequest
        let routeContext = currentOperationRouteContext(for: controller)
        guard let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            showAlert(
                title: "No Project Open",
                message: "Please open a project before importing CZ-ID results.",
                presentingWindow: window
            )
            return
        }

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "CZ-ID Import"
        wizardPanel.isReleasedWhenClosed = false

        var sheet = CzIdImportSheet(projectURL: projectURL, datasetURL: nil, initialSourceURL: request?.sourceURL)
        sheet.onImport = { [weak self] sourceURL in
            window.endSheet(wizardPanel)
            self?.importCzIdResultFromURL(sourceURL, routeContext: routeContext, onDispatch: { outcome in
                if outcome == .started { request?.started(sourceURL: sourceURL) }
                else { request?.onOutcome(outcome) }
            })
        }
        sheet.onCancel = {
            request?.onOutcome(.cancelled)
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 520, height: 460))
        window.beginSheet(wizardPanel)
        request?.presented()
    }

    @objc func launchOrientReads(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .readProcessing, initialToolID: .orientReads)
    }

    /// Surfaces a Viral Recon launch failure the user can actually see.
    ///
    /// Executor validation, reference acquisition and input staging all run
    /// before the run registers its own operation row, so a failure there had
    /// nowhere to be reported and went only to `debugLog`: the user pressed Run
    /// and nothing whatsoever happened. A failed row is created here so the
    /// failure lands in the Operations panel like every other tool's does.
    ///
    /// Cancellation is a user decision, not a defect, and is not reported.
    ///
    /// A failure the run already reported on its own row is not reported again
    /// either. `run()` throws for post-registration failures too, and those
    /// rows already carry the stderr tail, so a second row here showed the user
    /// the same run failing twice with the less useful message winning.
    @discardableResult
    static func reportViralReconLaunchFailure(
        _ error: Error,
        operationCenter: any OperationReporting = OperationCenter.shared,
        routeContext: OperationRouteContext?
    ) -> UUID? {
        if error is CancellationError { return nil }
        if ViralReconWorkflowExecutionService.failureWasReportedOnItsOperationRow(error) {
            return nil
        }
        let reason = error.localizedDescription
        return Self.beginViralReconLaunchFailureOperation(
            routeContext: routeContext,
            reporter: operationCenter
        ) { operationID in
            operationCenter.log(
                id: operationID,
                level: .error,
                message: "Viral Recon could not start: \(reason)"
            )
            _ = operationCenter.fail(
                id: operationID,
                detail: reason,
                errorMessage: ViralReconWorkflowExecutionService.launchFailureTitle(for: error),
                errorDetail: reason
            )
        }.startedID
    }

    private func runMAFFTAlignment(
        request: MSAAlignmentRunRequest,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        let outputURL = request.resolvedOutputBundleURL
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL ?? request.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "MAFFT alignment"
        ) else { return }
        let cliArgs = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: request.inputSequenceURLs,
            projectURL: request.projectURL,
            outputURL: outputURL,
            name: request.name,
            strategy: request.strategy.rawValue,
            outputOrder: request.outputOrder.rawValue,
            threads: request.threads,
            sequenceType: request.sequenceType.rawValue,
            adjustDirection: request.directionAdjustment.rawValue,
            symbols: request.symbolPolicy.rawValue,
            allowNondeterministicThreads: !request.deterministicThreads,
            allowFASTQAssemblyInputs: request.allowFASTQAssemblyInputs,
            extraArguments: request.extraArguments,
            includedSequenceNames: request.includedSequenceNames
        )
        Self.beginMAFFTAlignmentOperation(cliArguments: cliArgs, routeContext: routeContext) { opID in
            let runner = CLIMSAAlignmentRunner()
            let task = Task.detached { [weak self] in
                do {
                    let result = try await runner.run(
                        arguments: cliArgs,
                        operationID: opID
                    )
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        guard OperationCenter.shared.complete(
                            id: opID,
                            detail: "MAFFT complete: \(result.rowCount) rows, \(result.alignedLength) columns",
                            bundleURLs: [result.bundleURL]
                        ) else { return }
                        self?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()
                    }}
                } catch {
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(
                            id: opID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription,
                            errorDetail: "\(error)"
                        )
                    }}
                }
            }
            OperationCenter.shared.setCancelCallback(for: opID) {
                task.cancel()
                runner.cancel()
            }
        }
    }



    @objc func searchNCBI(_ sender: Any?) {
        showDatabaseBrowser(source: .ncbi, sender: sender)
    }

    @objc func searchSRA(_ sender: Any?) {
        // Use ENA service for SRA/FASTQ retrieval
        showDatabaseBrowser(source: .ena, sender: sender)
    }

    @objc func searchPathoplexus(_ sender: Any?) {
        showDatabaseBrowser(source: .pathoplexus, sender: sender)
    }

    @objc func showPluginManager(_ sender: Any?) {
        PluginManagerWindowController.show()
    }

    @objc func showWorkflowLibrary(_ sender: Any?) {
        WorkflowLibraryWindowController.show()
    }

    @objc func showWorkflowOperations(_ sender: Any?) {
        showWorkflowOperations(sender, preselectedWorkflowID: nil)
    }

    @objc func launchWorkflowFromMenu(_ sender: NSMenuItem) {
        guard let workflowID = workflowOperationID(from: sender.representedObject) else { return }
        showWorkflowOperations(sender, preselectedWorkflowID: workflowID)
    }

    @objc func promptEnableWorkflowFromMenu(_ sender: NSMenuItem) {
        // The alert names the workflow from the catalog item the menu item represents, never from its title.
        guard let alert = MainMenu.enableWorkflowAlert(for: sender.representedObject),
              let window = activeMainWindowController(sender: sender)?.window else {
            WorkflowLibraryWindowController.show()
            return
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            WorkflowLibraryWindowController.show()
        }
    }

    @objc func launchLinkedWorkflowPackageFromMenu(_ sender: NSMenuItem) {
        guard let manifestID = sender.representedObject as? String, !manifestID.isEmpty else { return }
        showWorkflowOperations(sender, preselectedWorkflowID: Self.workflowOperationToolID(forPackageManifestID: manifestID))
    }

    @objc func revealLinkedWorkflowPackageInLibrary(_ sender: NSMenuItem) {
        let manifestID = sender.representedObject as? String
        WorkflowLibraryWindowController.show(revealingPackageID: manifestID)
    }

    /// The Workflow Operations tool ID for a linked package, matching the dialog state's naming.
    static func workflowOperationToolID(forPackageManifestID manifestID: String) -> String {
        ToolsMenuModel.LinkedPackageEntry(manifestID: manifestID, title: "", isEnabled: true).workflowOperationToolID
    }

    private func workflowOperationID(from representedObject: Any?) -> String? {
        if let toolID = representedObject as? FASTQOperationToolID {
            switch toolID {
            case .ontGenotyping:
                return "builtin.ont-genotyping"
            default:
                return toolID.rawValue
            }
        }
        return representedObject as? String
    }

    private func showWorkflowOperations(_ sender: Any?, preselectedWorkflowID: String?) {
        let sourceController = activeMainWindowController(sender: sender)
        let routeContext = sourceController.map { currentOperationRouteContext(for: $0) } ?? nil
        let projectURL = routeContext?.projectURL
            ?? sourceController?.mainSplitViewController?.sidebarController?.currentProjectURL
        let sidebarController = sourceController?.mainSplitViewController?.sidebarController
        let sidebarResolution = sidebarController.map {
            Self.resolveWorkflowSidebarInputSelectionForOperations(items: $0.selectedItems(), projectURL: projectURL)
        }
        let selectedReadURLs = sidebarResolution?.selectedReadURLs
            ?? (sourceController.map { gatherWorkflowOperationReadInputURLs(controller: $0) } ?? [])
        let selectedReferenceURLs = sidebarController.map {
            Self.resolveWorkflowOperationSelectedReferenceURLs(items: $0.selectedItems())
        } ?? []
        WorkflowOperationsWindowController.show(
            projectURL: projectURL,
            routeContext: routeContext,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarResolution?.sidebarInputSelection,
            selectedReferenceURLs: selectedReferenceURLs,
            initialToolID: preselectedWorkflowID
        )
    }

    @objc func showHaplotypeDefinitions(_ sender: Any?) {
        let sourceController = activeMainWindowController(sender: sender)
        let projectURL = sourceController?.mainSplitViewController?.sidebarController?.currentProjectURL
        HaplotypeDefinitionManagerWindowController.show(projectURL: projectURL)
    }

    @objc func showImportCenter(_ sender: Any?) {
        ImportCenterWindowController.show()
    }

    @objc func showImportCenterClassification(_ sender: Any?) {
        ImportCenterWindowController.show(tab: .classificationResults)
    }
}
