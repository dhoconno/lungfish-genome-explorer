// AppDelegate+ToolsMenu.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
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

    @objc func showFASTQQCReportingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .qcReporting)
    }

    @objc func showFASTQDemultiplexingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .demultiplexing)
    }

    @objc func showFASTQTrimmingFilteringOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .trimmingFiltering)
    }

    @objc func showFASTQDecontaminationOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .decontamination)
    }

    @objc func showFASTQReadProcessingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .readProcessing)
    }

    @objc func showFASTQSearchSubsettingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .searchSubsetting)
    }

    @objc func showFASTQAlignmentOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .alignment)
    }

    @objc func showFASTQMappingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .mapping)
    }

    @objc func showFASTQAssemblyOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .assembly)
    }

    @objc func showFASTQClusteringOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .clustering)
    }

    @objc func showFASTQClassificationOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification)
    }

    @objc func showFASTQGenotypingOperations(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .genotyping)
    }

    @objc func showFASTQReverseComplementOperation(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .readProcessing, initialToolID: .reverseComplement)
    }

    @objc func showFASTQTranslateOperation(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .readProcessing, initialToolID: .translate)
    }

    @objc func launchFASTQOperationToolFromMenu(_ sender: NSMenuItem) {
        guard let toolID = sender.representedObject as? FASTQOperationToolID else { return }
        showFASTQOperationsDialog(sender, initialCategory: toolID.categoryID, initialToolID: toolID)
    }

    @objc func showFreyjaDemix(_ sender: Any?) {
        PluginManagerWindowController.show(packID: "wastewater-surveillance")
    }

    func canShowBAMVariantCalling(bundle: ReferenceBundle?) -> Bool {
        guard let bundle else { return false }
        return !BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle).isEmpty
    }

    @objc func showBAMVariantCalling(_ sender: Any?) {
        guard let split = mainWindowController?.mainSplitViewController else { return }
        split.inspectorController.presentVariantCallingDialog(
            bundle: split.viewerController.currentReferenceBundle,
            preferredAlignmentTrackID: nil
        )
    }

    func showFASTQOperationsDialog(
        _ sender: Any?,
        initialCategory: FASTQOperationCategoryID,
        initialToolID: FASTQOperationToolID? = nil,
        preferredInputURLs: [URL] = []
    ) {
        guard let originController = activeMainWindowController(sender: sender),
              let originSplit = originController.mainSplitViewController,
              let window = originController.window else {
            debugLog("showFASTQOperationsDialog: No main window available")
            NSSound.beep()
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

            FASTQOperationsDialogPresenter.present(
                from: window,
                selectedInputURLs: selectedInputURLs,
                initialCategory: initialCategory,
                initialToolID: initialToolID,
                projectURL: currentProjectURL,
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

                if let config = state.pendingMinimap2Config {
                    self.runMinimap2Mapping(config: config, routeContext: routeContext)
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
                    self.runClassification(configs: state.pendingClassificationConfigs, viewerController: viewerController, routeContext: routeContext)
                    return
                }

                if !state.pendingEsVirituConfigs.isEmpty {
                    self.runEsViritu(configs: state.pendingEsVirituConfigs, viewerController: viewerController, routeContext: routeContext)
                    return
                }

                if let config = state.pendingTaxTriageConfig {
                    self.runTaxTriage(config: config, viewerController: viewerController, routeContext: routeContext)
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
            NSSound.beep()
            return
        }
        let routeContext = currentOperationRouteContext(for: controller)

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "NAO-MGS Import"
        wizardPanel.isReleasedWhenClosed = false

        var sheet = NaoMgsImportSheet(datasetURL: nil)
        sheet.onImport = { [weak self] (resultsDir: URL) in
            window.endSheet(wizardPanel)
            self?.importNaoMgsResultFromURL(resultsDir, routeContext: routeContext)
        }
        sheet.onCancel = {
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 520, height: 400))
        window.beginSheet(wizardPanel)
    }

    @objc func launchPrimerSchemeImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchPrimerSchemeImport: No main window available")
            NSSound.beep()
            return
        }
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
                window.endSheet(wizardPanel)
            }
        )

        let hostingController = NSHostingController(rootView: view)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 540, height: 480))
        window.beginSheet(wizardPanel)
    }

    @objc func launchNvdImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchNvdImport: No main window available")
            NSSound.beep()
            return
        }
        let routeContext = currentOperationRouteContext(for: controller)

        let wizardPanel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        wizardPanel.title = "NVD Import"
        wizardPanel.isReleasedWhenClosed = false

        var sheet = NvdImportSheet(datasetURL: nil)
        sheet.onImport = { [weak self] (nvdDir: URL) in
            window.endSheet(wizardPanel)
            self?.importNvdResultFromURL(nvdDir, routeContext: routeContext)
        }
        sheet.onCancel = {
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 500, height: 450))
        window.beginSheet(wizardPanel)
    }

    @objc func launchCzIdImport(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("launchCzIdImport: No main window available")
            NSSound.beep()
            return
        }
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

        var sheet = CzIdImportSheet(projectURL: projectURL, datasetURL: nil)
        sheet.onImport = { [weak self] sourceURL in
            window.endSheet(wizardPanel)
            self?.importCzIdResultFromURL(sourceURL, routeContext: routeContext)
        }
        sheet.onCancel = {
            window.endSheet(wizardPanel)
        }

        let hostingController = NSHostingController(rootView: sheet)
        wizardPanel.contentViewController = hostingController
        wizardPanel.setContentSize(NSSize(width: 520, height: 460))
        window.beginSheet(wizardPanel)
    }

    func importNvdResultFromURL(_ url: URL, routeContext explicitRouteContext: OperationRouteContext? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let controller = targetMainWindowController(routeContext: routeContext) ?? activeMainWindowController(),
              let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            showAlert(
                title: "No Project Open",
                message: "Please open a project before importing NVD results.",
                presentingWindow: targetMainWindowController(routeContext: explicitRouteContext)?.window
            )
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "NVD Import",
            presentingWindow: controller.window
        ) else { return }

        let importsDir = projectURL.appendingPathComponent("Imports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
        } catch {
            showAlert(title: "Import Failed", message: "Could not prepare Imports folder: \(error.localizedDescription)", presentingWindow: controller.window)
            return
        }

        let opID = OperationCenter.shared.start(
            title: "NVD Import",
            detail: "Importing \(url.lastPathComponent)...",
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: ["nvd", url.path, "--output-dir", importsDir.path]
            ),
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                let result = try await MetagenomicsImportHelperClient.importViaCLI(
                    kind: .nvd,
                    inputURL: url,
                    outputDirectory: importsDir
                ) { progress, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(
                                id: opID,
                                progress: progress,
                                detail: message
                            )
                        }
                    }
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: result.detail,
                            bundleURLs: [result.resultDirectory]
                        )
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "NVD import complete: \(result.resultDirectory.lastPathComponent)"
                        )
                        self?.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?.sidebarController.requestReloadFromFilesystem()
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "NVD import cancelled"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        if let partialDir = (error as? MetagenomicsImportHelperClientError)?
                            .partialResultDirectory {
                            try? FileManager.default.removeItem(at: partialDir)
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "Cleaned up partial NVD import directory"
                            )
                        }
                        OperationCenter.shared.log(
                            id: opID,
                            level: .error,
                            message: "NVD import failed: \(error.localizedDescription)"
                        )
                        self?.showAlert(
                            title: "NVD Import Failed",
                            message: error.localizedDescription,
                            presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                        )
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    @objc func launchOrientReads(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .readProcessing, initialToolID: .orientReads)
    }

    private func runMinimap2Mapping(
        config: Minimap2Config,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Read mapping"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL) {
                config.outputDirectory = analysisDir
            }
        }

        let opID = OperationCenter.shared.start(
            title: "Map Reads (minimap2)",
            detail: "Mapping \(config.inputFiles.count) file(s) to \(config.referenceURL.lastPathComponent)",
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs before running the pipeline.
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "minimap2-", contextURL: config.inputFiles.first ?? config.referenceURL)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    config.inputFiles,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                        }}
                    }
                ) ?? config.inputFiles

                var resolvedConfig = config
                resolvedConfig.provenanceInputFiles = config.provenanceInputFiles
                    ?? Self.durableSequenceInputsForProvenance(config.inputFiles)
                resolvedConfig.provenanceInputFileRecords = config.provenanceInputFileRecords
                    ?? Self.durableSequenceInputRecordsForProvenance(config.inputFiles)
                resolvedConfig.inputFiles = resolvedFiles

                let pipeline = Minimap2Pipeline()
                let result = try await pipeline.run(config: resolvedConfig) { fraction, message in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }}
                }
                let capturedConfig = config
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "Mapping complete: \(result.mappedReads)/\(result.totalReads) reads mapped",
                        bundleURLs: [result.bamURL]
                    )

                    // Record analysis in source bundle manifest
                    if let bundleURL = Self.findSourceBundle(for: capturedConfig.inputFiles) {
                        let entry = AnalysisManifestEntry(
                            tool: "minimap2",
                            analysisDirectoryName: Self.analysisManifestDirectoryName(
                                for: capturedConfig.outputDirectory,
                                projectURL: routeContext?.projectURL
                            ),
                            displayName: "Minimap2 Alignment",
                            parameters: capturedConfig.summaryParameters(),
                            summary: "\(result.mappedReads)/\(result.totalReads) reads mapped",
                            status: .completed
                        )
                        do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                    }

                    // Reload the originating window's sidebar.
                    self?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                        .sidebarController.requestReloadFromFilesystem()
                }}
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(id: opID, detail: "\(error)")
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    func importCzIdResultFromURL(_ url: URL, routeContext explicitRouteContext: OperationRouteContext? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let controller = targetMainWindowController(routeContext: routeContext) ?? activeMainWindowController(),
              let projectURL = routeContext?.projectURL
                ?? controller.projectSession.projectURL
                ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
            showAlert(
                title: "No Project Open",
                message: "Please open a project before importing CZ-ID results.",
                presentingWindow: targetMainWindowController(routeContext: explicitRouteContext)?.window
            )
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "CZ-ID Import",
            presentingWindow: controller.window
        ) else { return }

        Task.detached { [weak self] in
            var opID: UUID?
            var bundleURL: URL?
            do {
                try Task.checkCancellation()

                let preview = try await CzIdImportPreview.scan(url)
                let sampleName = preview.sampleName
                let finalBundleURL = projectURL
                    .standardizedFileURL
                    .appendingPathComponent("Classifications", isDirectory: true)
                    .appendingPathComponent(
                        "\(CzIdProjectImportWorkflow.bundleFileName(for: sampleName)).lungfishtax",
                        isDirectory: true
                    )
                bundleURL = finalBundleURL

                let cliCmd = OperationCenter.buildCLICommand(
                    subcommand: "import",
                    args: [
                        "cz-id",
                        url.path,
                        "--project",
                        projectURL.standardizedFileURL.path,
                        "--sample-name",
                        sampleName,
                    ]
                )
                opID = await appPerformOnMainRunLoop {
                    OperationCenter.shared.start(
                        title: "CZ-ID Import",
                        detail: "Converting \(preview.reportFileName)...",
                        cliCommand: cliCmd,
                        routeContext: routeContext
                    )
                }

                if let opID {
                    await appPerformOnMainRunLoop {
                        _ = OperationCenter.shared.updateWithLog(
                            id: opID,
                            progress: 0.35,
                            detail: "Converting \(preview.reportFileName)..."
                        )
                    }
                }

                let imported = try await CzIdProjectImportWorkflow.importFromURL(
                    url,
                    projectURL: projectURL,
                    sampleName: sampleName
                )

                let completedOpID = opID
                await appPerformOnMainRunLoop {
                    guard let opID = completedOpID else { return }
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "Imported \(imported.sampleName)",
                        bundleURLs: [imported.bundleURL]
                    )
                    OperationCenter.shared.log(
                        id: opID,
                        level: .info,
                        message: "Imported CZ-ID result at \(imported.bundleURL.lastPathComponent)"
                    )
                }
            } catch is CancellationError {
                if let bundleURL {
                    try? FileManager.default.removeItem(at: bundleURL)
                }
                if let opID {
                    await appPerformOnMainRunLoop {
                        _ = OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                }
            } catch {
                if let bundleURL {
                    try? FileManager.default.removeItem(at: bundleURL)
                }
                let detail = error.localizedDescription
                let failedOpID = opID
                await appPerformOnMainRunLoop {
                    if let opID = failedOpID {
                        _ = OperationCenter.shared.fail(id: opID, detail: detail)
                    }
                    self?.showAlert(
                        title: "CZ-ID Import Failed",
                        message: detail,
                        presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                    )
                }
            }
        }

    }

    /// Derives the correct `pairedEnd` value for a mapping request from its
    /// ACTUALLY-RESOLVED file list (never from the raw file count -- see
    /// F2 in the C2 fix-round-1 review: pooling two single-end bundles that
    /// each resolve to exactly one file would otherwise fabricate a mate
    /// pair between two unrelated samples).
    ///
    /// Reuses `MetagenomicsSampleGrouper`, which infers R1/R2 role from
    /// filename convention (`_R1`/`_R2`, `_1`/`_2`, etc.) rather than
    /// position or count: `pairedEnd` is true only when the resolved files
    /// collapse to exactly one grouped sample that itself has both a
    /// `fastq1` and `fastq2` role match. Any other shape (a lone file, two
    /// files with no matching R1/R2 stem, 3+ files, multiple distinct
    /// grouped samples after pooling) maps to `false`, degrading safely to
    /// single-end/"-U"/"in=" command construction instead of fabricating a
    /// pair.
    static func resolvedPairedEnd(for resolvedFiles: [URL]) -> Bool {
        guard resolvedFiles.count == 2 else { return false }
        let grouped = MetagenomicsSampleGrouper.group(resolvedFiles)
        guard grouped.count == 1, let sample = grouped.first else { return false }
        return sample.isPairedEnd
    }

    /// Resolves the true input file list and `pairedEnd` value for ONE
    /// assembly bundle URL, derived from that bundle's OWN manifest/payload
    /// content -- never from group size or input count (MB-2 review round 1,
    /// point 2: a genuine `.fullPaired` bundle must not collapse to
    /// `pairedEnd == false` just because the wizard passed one bundle URL
    /// per element, and two unrelated bundles happening to be named
    /// `X_R1.lungfishfastq` / `X_R2.lungfishfastq` must never be treated as
    /// mates just because they were adjacent in a selection).
    ///
    /// This operates on ONE bundle's contents at a time, so
    /// `MetagenomicsSampleGrouper`'s filename-convention role inference is
    /// safe here in a way it would NOT be if applied across multiple
    /// bundles' pooled file lists: every file it sees already lives inside
    /// the single bundle directory being resolved.
    ///
    /// - A `.fullPaired` derived bundle (the FASTQ Ops / BAM primer-trim /
    ///   WorkflowBuilder interleave payload shape) resolves via
    ///   `FASTQBundle.pairedFASTQURLs`, which is the only API that returns
    ///   BOTH R1 and R2 for that payload --
    ///   `SequenceInputResolver.resolvePrimarySequenceURL` deliberately
    ///   returns R1 only for this payload and must not be used here.
    /// - A plain (non-derived) bundle -- including a multi-file bundle whose
    ///   `source-files.json` lists a genuine R1+R2 pair imported together --
    ///   resolves via `FASTQBundle.resolveAllFASTQURLs`, then
    ///   `MetagenomicsSampleGrouper.group` determines whether those files
    ///   are a real mate pair from their OWN filenames.
    /// - A virtual/derived bundle that still requires async materialization
    ///   (subset/trim/demuxedVirtual -- content isn't on disk yet) cannot be
    ///   inspected synchronously here; it is left as a single placeholder
    ///   input with `pairedEnd == false`, matching this fix's placeholder
    ///   behavior for every other not-yet-resolvable shape and consistent
    ///   with pre-existing single-bundle assembly behavior for these
    ///   payloads (materialization always yields exactly one file).
    /// - Anything else (a loose non-bundle file, an unreadable bundle)
    ///   passes through unchanged as a single input with `pairedEnd ==
    ///   false`.
    nonisolated static func resolvedAssemblyPairedEnd(for bundleURL: URL) -> (inputURLs: [URL], pairedEnd: Bool) {
        let standardizedURL = bundleURL.standardizedFileURL

        guard let enclosingBundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedURL) else {
            return ([standardizedURL], false)
        }

        if let pairedURLs = FASTQBundle.pairedFASTQURLs(forDerivedBundle: enclosingBundleURL) {
            return ([pairedURLs.r1, pairedURLs.r2], true)
        }

        if AssemblyInputMaterialization.requiresMaterialization(standardizedURL) {
            return ([standardizedURL], false)
        }

        guard let resolvedURLs = FASTQBundle.resolveAllFASTQURLs(for: enclosingBundleURL),
              !resolvedURLs.isEmpty else {
            return ([standardizedURL], false)
        }

        // Mirrors `resolvedPairedEnd(for:)`'s logic exactly (same
        // MetagenomicsSampleGrouper-backed role inference used by the C2
        // mapping fix), duplicated here rather than shared because that
        // sibling function is `@MainActor`-isolated (an `AppDelegate`
        // member) while this one must stay `nonisolated` -- it is called
        // synchronously from `FASTQOperationLaunchRequest
        // .independentAssembleLaunchRequests`, itself invoked from
        // `runFASTQOperationLaunchRequestValidated` before any `Task` is
        // created.
        let pairedEnd: Bool
        if resolvedURLs.count == 2 {
            let grouped = MetagenomicsSampleGrouper.group(resolvedURLs)
            pairedEnd = grouped.count == 1 && (grouped.first?.isPairedEnd ?? false)
        } else {
            pairedEnd = false
        }
        return (resolvedURLs, pairedEnd)
    }

    /// Precomputes the on-disk output layout for a mapping fan-out batch
    /// (BG3, batch-results-grouping spec §2/§3).
    ///
    /// Returns `nil` when `requests.count <= 1` -- the caller keeps the
    /// existing single-run behavior unchanged (each child creates its own
    /// flat `Analyses/<tool>-<timestamp>/` directory, exactly as before this
    /// change).
    ///
    /// For `requests.count > 1`, creates ONE
    /// `Analyses/<tool>-batch-<timestamp>/` directory up front, then walks
    /// `requests` **in their given order** -- never reordered, never
    /// computed inside a concurrently-running child -- creating one
    /// `batchSampleDirectory(named:in:)` per request via the bundle display
    /// name already used for that request's operation title/@RG SM tag
    /// (`request.sampleName`). This satisfies the spec §3 ordering
    /// invariant: sample directory names are fully determined before any
    /// child dispatch begins.
    ///
    /// Returns `nil` (rather than throwing) if directory creation fails, so
    /// callers can fall back to the pre-BG3 per-child behavior -- matching
    /// the existing `try?`-based failure tolerance of
    /// `createAnalysisDirectory` at the single-run call site.
    static func precomputedMappingBatchOutputDirectories(
        requests: [MappingRunRequest],
        in projectURL: URL,
        date: Date = Date()
    ) -> [URL]? {
        guard requests.count > 1,
              let tool = requests.first?.tool.rawValue,
              let batchDirectory = try? AnalysesFolder.createAnalysisDirectory(
                  tool: tool, in: projectURL, isBatch: true, date: date
              )
        else { return nil }

        var sampleDirectories: [URL] = []
        sampleDirectories.reserveCapacity(requests.count)
        for request in requests {
            guard let sampleDirectory = try? AnalysesFolder.batchSampleDirectory(
                named: request.sampleName, in: batchDirectory
            ) else { return nil }
            sampleDirectories.append(sampleDirectory)
        }
        return sampleDirectories
    }

    /// Runs a planned mapping request for every bundle in `plan`,
    /// SEQUENTIALLY (matching `runClassificationBatch`'s precedent) rather
    /// than N concurrent `Task.detached` mappers -- an unbounded fan-out
    /// would otherwise spawn N mappers each requesting up to
    /// `processorCount` threads plus N reference-index rebuilds
    /// simultaneously (F5 in the C2 fix-round-1 review). `.perBundle` plans
    /// start one independent `OperationCenter` operation per bundle in
    /// sequence, so each bundle's progress/success/failure is still
    /// individually tracked; `.combined` plans have exactly one pooled
    /// request, whose operation history gets `plan.warning` logged as a
    /// warning line before the run starts (MB-1: explicit pooled-naming +
    /// logged warning instead of silent @RG misattribution).
    ///
    /// BG3: when `plan.requests.count > 1`, all N children's results are
    /// grouped under one `Analyses/<tool>-batch-<timestamp>/` directory
    /// (`precomputedMappingBatchOutputDirectories`, computed once before the
    /// loop starts) instead of each child creating its own sibling
    /// `Analyses/<tool>-<timestamp>/` directory. If every child fails and
    /// leaves nothing behind, the now-empty batch directory is removed after
    /// the loop completes (spec §6).
    private func runManagedMapping(
        plan: MappingRunPlan,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Read mapping"
        ) else { return }

        let requests = plan.requests
        guard !requests.isEmpty else { return }

        // Precomputed IN REQUEST ORDER, before any child dispatch (spec §3
        // ordering invariant) -- `nil` for a single-request plan, which
        // keeps the pre-BG3 per-child `createAnalysisDirectory` behavior
        // unchanged.
        let batchProjectURL = routeContext?.projectURL ?? requests.first?.projectURL
        let preassignedDirectories: [URL]? = batchProjectURL.flatMap {
            Self.precomputedMappingBatchOutputDirectories(requests: requests, in: $0)
        }
        let batchDirectory = preassignedDirectories?.first?.deletingLastPathComponent()

        // Declared before the Task literal (rather than `let task =
        // Task.detached { ... }`) so `registerCancel`'s closure, invoked
        // from inside the loop, can capture `taskHandle` by reference and
        // call `.cancel()` on whichever `Task` ends up assigned -- avoids
        // the "captures 'task' before it is declared" forward-reference
        // error a `let`-bound self-referential closure would hit here.
        // Zipped with `requests` (rather than indexed inside the loop) so
        // the loop body below can keep the exact `for request in requests`
        // shape `OperationRoutingTests` pins as evidence of the single
        // sequential `Task.detached` driver (F5) -- each element is either
        // this request's precomputed batch sample directory, or `nil` for a
        // single-request plan.
        let perRequestDirectories: [URL?] = preassignedDirectories ?? Array(repeating: nil, count: requests.count)
        let taskHandle = MappingBatchTaskHandle()
        let task = Task.detached { [weak self] in
            var anySucceeded = false
            var preassignedIterator = perRequestDirectories.makeIterator()
            for request in requests {
                let preassignedDirectory = preassignedIterator.next() ?? nil
                if Task.isCancelled { break }
                guard let self else { break }
                let succeeded = await self.runSingleManagedMappingAwaitingCompletion(
                    request: request,
                    warning: plan.warning,
                    routeContext: routeContext,
                    preassignedAnalysisDirectory: preassignedDirectory,
                    registerCancel: { @MainActor opID in
                        // Cancelling any one bundle's row cancels the whole
                        // remaining sequential batch, since they share one
                        // outer Task; the currently in-flight bundle stops
                        // at its next cancellation checkpoint (resolveInputFiles
                        // / pipeline.run), and the loop's `Task.isCancelled`
                        // guard prevents any further bundle from starting.
                        OperationCenter.shared.setCancelCallback(for: opID) { taskHandle.cancel() }
                    }
                )
                anySucceeded = anySucceeded || succeeded
            }

            // Empty-batch cleanup (spec §6): only after every child has
            // reached a terminal state (the sequential loop above has just
            // finished, whether by completion or cancellation) and only when
            // nothing succeeded -- a lone surviving sample directory (even
            // from a bundle whose own row later shows "failed" for a
            // post-output-write error) means the batch directory is not
            // empty and must stay.
            if !anySucceeded, let batchDirectory {
                await MainActor.run {
                    AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)
                }
            }
        }
        taskHandle.assign(task)
    }

    /// Runs one `MappingRunRequest` to completion (success or failure),
    /// awaiting the whole pipeline before returning, so the sequential loop
    /// in `runManagedMapping` never starts a second bundle's mapping while
    /// this one is still using the CPU/reference index.
    ///
    /// This method is a member of `AppDelegate` (`@MainActor`), so its
    /// declaration is `@MainActor`-isolated -- it does NOT run "exactly
    /// like" the old per-request `Task.detached` body, which executed on a
    /// background executor throughout. What actually keeps this off the
    /// main thread for the expensive parts is that `resolveInputFiles`,
    /// `ManagedMappingPipeline.run`, and `prepareMappingViewerBundleIfPossible`
    /// are themselves `async` calls whose bodies are not further
    /// `@MainActor`-isolated (`ManagedMappingPipeline` is a plain,
    /// non-actor `Sendable` class); `await`-ing them from a `@MainActor`
    /// caller still lets their own work run on a background executor, and
    /// control only returns to the main actor at each `await` resumption.
    /// This depends on the current (default) Swift 6 concurrency model,
    /// where a `nonisolated`/non-actor `async` function's body executes on
    /// the caller-supplied executor rather than inheriting the caller's
    /// actor; it would change under `NonisolatedNonsendingByDefault`
    /// (SE-0461), which this package does not opt into (no
    /// `SwiftSetting.enableUpcomingFeature("NonisolatedNonsendingByDefault")`
    /// anywhere in `Package.swift`) -- if that mode is ever adopted here,
    /// this method's off-main-actor guarantee for those calls would need
    /// re-verification. `registerCancel` is invoked with the freshly-started
    /// operation's ID so the caller can wire cancellation before any
    /// awaiting begins.
    ///
    /// `preassignedAnalysisDirectory`, when non-nil, is used verbatim as the
    /// request's output directory and the usual per-child
    /// `createAnalysisDirectory` call is skipped entirely (BG3: batch fan-out
    /// precomputes and passes one `batchSampleDirectory(named:in:)` per
    /// request BEFORE this method is ever invoked, so every child's
    /// directory already exists under a single shared batch root). `nil`
    /// preserves the original single-run behavior unchanged.
    ///
    /// Returns `true` if the mapping completed successfully, `false` if it
    /// failed -- callers use this to detect "every child in the batch
    /// failed" for the empty-batch cleanup in `runManagedMapping`.
    @discardableResult
    private func runSingleManagedMappingAwaitingCompletion(
        request initialRequest: MappingRunRequest,
        warning: String?,
        routeContext: OperationRouteContext?,
        preassignedAnalysisDirectory: URL? = nil,
        registerCancel: @MainActor (UUID) -> Void
    ) async -> Bool {
        var request = initialRequest
        if let preassignedAnalysisDirectory {
            request = request.withOutputDirectory(preassignedAnalysisDirectory)
        } else {
            let projectURL = routeContext?.projectURL ?? request.projectURL
            if let projectURL,
               let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: request.tool.rawValue, in: projectURL) {
                request = request.withOutputDirectory(analysisDir)
            }
        }

        let opID = OperationCenter.shared.start(
            title: "Map Reads (\(request.tool.displayName)): \(request.sampleName)",
            detail: "Mapping \(request.inputFASTQURLs.count) file(s) to \(request.referenceFASTAURL.lastPathComponent)",
            routeContext: routeContext
        )
        registerCancel(opID)

        if let warning {
            OperationCenter.shared.log(id: opID, level: .warning, message: warning)
        }

        do {
            if AppUITestConfiguration.current.isEnabled,
               AppUITestConfiguration.current.backendMode == .deterministic {
                let result = try AppUITestMappingBackend.writeResult(for: request)
                let outputDirectory = request.outputDirectory
                let capturedRequest = request
                _ = OperationCenter.shared.complete(
                    id: opID,
                    detail: "Mapping complete: \(result.mappedReads)/\(result.totalReads) reads mapped"
                )
                AppUITestConfiguration.current.appendEvent(
                    "mapping.operation.completed target=\(outputDirectory.lastPathComponent)"
                )
                routePostMappingDeterministicCompletion(
                    outputDirectory: outputDirectory,
                    request: capturedRequest
                )
                return true
            }

            let materializeTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "\(request.tool.rawValue)-",
                contextURL: request.inputFASTQURLs.first ?? request.referenceFASTAURL
            )
            defer { try? FileManager.default.removeItem(at: materializeTempDir) }

            let resolvedFiles = try await self.resolveInputFiles(
                request.inputFASTQURLs,
                tempDirectory: materializeTempDir,
                progress: { message in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }}
                }
            )

            // F2 fix: pairedEnd is derived from the ACTUALLY-RESOLVED files'
            // R1/R2 roles here, never from the pre-resolve URL count.
            let resolvedPairedEnd = Self.resolvedPairedEnd(for: resolvedFiles)
            let resolvedRequest = request.withInputFASTQURLs(resolvedFiles, pairedEnd: resolvedPairedEnd)
            let pipeline = ManagedMappingPipeline()
            let result = try await pipeline.run(request: resolvedRequest) { fraction, message in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                    OperationCenter.shared.log(id: opID, level: .info, message: message)
                }}
            }

            var finalResult = result
            if let preparedResult = try await self.prepareMappingViewerBundleIfPossible(
                result: result,
                request: resolvedRequest,
                opID: opID
            ) {
                finalResult = preparedResult
            }

            // capturedRequest carries the ORIGINAL (pre-resolve) input URLs
            // so findSourceBundle can still walk up to the enclosing bundle
            // even when resolveInputFiles() materialized a virtual bundle's
            // reads into a scratch temp directory (which has no enclosing
            // .lungfishfastq bundle of its own). But summaryParameters()
            // must come from resolvedRequest -- the request actually run
            // through the pipeline -- so the persisted manifest records the
            // true isPairedEnd (and other resolved fields), not the
            // wizard's pre-resolve pairedEnd:false placeholder.
            let capturedRequest = request
            _ = OperationCenter.shared.complete(
                id: opID,
                detail: "Mapping complete: \(finalResult.mappedReads)/\(finalResult.totalReads) reads mapped",
                bundleURLs: [finalResult.viewerBundleURL ?? finalResult.bamURL]
            )

            if let bundleURL = Self.findSourceBundle(for: capturedRequest.inputFASTQURLs) {
                let entry = AnalysisManifestEntry(
                    tool: capturedRequest.tool.rawValue,
                    analysisDirectoryName: Self.analysisManifestDirectoryName(
                        for: capturedRequest.outputDirectory,
                        projectURL: routeContext?.projectURL ?? capturedRequest.projectURL
                    ),
                    displayName: "\(capturedRequest.tool.displayName) Mapping",
                    parameters: resolvedRequest.summaryParameters(),
                    summary: "\(finalResult.mappedReads)/\(finalResult.totalReads) reads mapped",
                    status: .completed
                )
                do {
                    try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
                } catch {
                    appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)")
                }
            }

            targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                .sidebarController.requestReloadFromFilesystem()
            return true
        } catch {
            _ = OperationCenter.shared.fail(id: opID, detail: "\(error)")
            return false
        }
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
            extraArguments: request.extraArguments
        )
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "align",
            args: Array(cliArgs.dropFirst())
        )
        let opID = OperationCenter.shared.start(
            title: "Align Sequences (MAFFT)",
            detail: "Preparing MAFFT alignment...",
            operationType: .multipleSequenceAlignmentGeneration,
            cliCommand: cliCommand,
            routeContext: routeContext
        )

        let runner = CLIMSAAlignmentRunner()
        let task = Task.detached { [weak self] in
            do {
                let result = try await runner.run(
                    arguments: cliArgs,
                    operationID: opID
                )
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "MAFFT complete: \(result.rowCount) rows, \(result.alignedLength) columns",
                        bundleURLs: [result.bundleURL]
                    )
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

    @MainActor
    private func routePostMappingDeterministicCompletion(
        outputDirectory: URL,
        request: MappingRunRequest
    ) {
        guard let split = mainWindowController?.mainSplitViewController else { return }
        if let bundleURL = Self.findSourceBundle(for: request.inputFASTQURLs) {
            let entry = AnalysisManifestEntry(
                tool: request.tool.rawValue,
                analysisDirectoryName: Self.analysisManifestDirectoryName(
                    for: outputDirectory,
                    projectURL: request.projectURL
                ),
                displayName: "\(request.tool.displayName) Mapping",
                parameters: request.summaryParameters(),
                summary: "Deterministic UI test mapping",
                status: .completed
            )
            try? AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
        }
        split.refreshSidebarAndDisplayMappingResult(at: outputDirectory)
    }

    private func prepareMappingViewerBundleIfPossible(
        result: MappingResult,
        request: MappingRunRequest,
        opID: UUID
    ) async throws -> MappingResult? {
        let inferredSourceBundleURL = ReferenceBundleSourceResolver.canonicalSourceBundleURL(
            for: request.referenceFASTAURL,
            projectURL: request.projectURL
        )
        let candidateSourceBundleURL = request.sourceReferenceBundleURL
            ?? result.sourceReferenceBundleURL
            ?? (inferredSourceBundleURL?.pathExtension.lowercased() == "lungfishref" ? inferredSourceBundleURL : nil)

        guard let sourceBundleURL = candidateSourceBundleURL,
              FileManager.default.fileExists(atPath: sourceBundleURL.path) else {
            return nil
        }

        let viewerBundleURL = request.outputDirectory.appendingPathComponent(
            sourceBundleURL.lastPathComponent,
            isDirectory: true
        )
        let fm = FileManager.default
        let candidateName = [
            ".\(sourceBundleURL.deletingPathExtension().lastPathComponent)",
            "candidate-\(UUID().uuidString)",
            sourceBundleURL.pathExtension,
        ].joined(separator: ".")
        let candidateBundleURL = request.outputDirectory.appendingPathComponent(
            candidateName,
            isDirectory: true
        )
        defer {
            if fm.fileExists(atPath: candidateBundleURL.path) {
                try? fm.removeItem(at: candidateBundleURL)
            }
        }

        DispatchQueue.main.async { MainActor.assumeIsolated {
            _ = OperationCenter.shared.update(
                id: opID,
                progress: 0.93,
                detail: "Preparing reference mapping viewer..."
            )
            OperationCenter.shared.log(
                id: opID,
                level: .info,
                message: "Preparing lightweight reference bundle for integrated BAM viewing."
            )
        }}

        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundleURL,
            viewerBundleURL: candidateBundleURL,
            fileManager: fm
        )

        _ = try await BAMImportService.importBAM(
            bamURL: result.bamURL,
            bundleURL: candidateBundleURL,
            name: "\(request.tool.displayName) Mapping",
            progressHandler: { fraction, message in
                let progress = 0.93 + (fraction * 0.06)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.update(id: opID, progress: progress, detail: message)
                    OperationCenter.shared.log(id: opID, level: .info, message: message)
                }}
            }
        )

        let preparedResult = result.withViewerBundle(
            viewerBundleURL: viewerBundleURL,
            sourceReferenceBundleURL: sourceBundleURL
        )
        try MappingViewerBundlePublicationService.publishCandidate(
            candidateBundleURL: candidateBundleURL,
            finalBundleURL: viewerBundleURL,
            fileManager: fm
        ) { publishedBundleURL, publicationPlan in
            try MappingViewerBundlePublicationService.publish(
                result: preparedResult,
                resultDirectoryURL: request.outputDirectory,
                sourceReferenceBundleURL: sourceBundleURL,
                viewerBundleURL: publishedBundleURL,
                fileManager: fm,
                viewerPublicationPlan: publicationPlan
            )
        }
        return preparedResult
    }

    private func runOrientReads(config: OrientConfig) {
        let opID = OperationCenter.shared.start(
            title: "Orient Reads",
            detail: "Orienting reads against \(config.referenceURL.lastPathComponent)",
            routeContext: currentOperationRouteContext()
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs before running the pipeline.
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "orient-", contextURL: config.inputURL)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    [config.inputURL],
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                        }}
                    }
                ) ?? [config.inputURL]

                let resolvedConfig = OrientConfig(
                    inputURL: resolvedFiles.first ?? config.inputURL,
                    referenceURL: config.referenceURL,
                    wordLength: config.wordLength,
                    dbMask: config.dbMask,
                    qMask: config.qMask,
                    saveUnoriented: config.saveUnoriented,
                    threads: config.threads
                )

                let pipeline = OrientPipeline()
                let result = try await pipeline.run(config: resolvedConfig) { fraction, message in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }}
                }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "Orient complete: \(result.forwardCount) fwd, \(result.reverseComplementedCount) RC, \(result.unmatchedCount) unmatched"
                    )
                }}
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(id: opID, detail: "\(error)")
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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

    @objc func showWorkflowBuilder(_ sender: Any?) {
        guard AppSettings.shared.experimentalFeaturesEnabled else {
            NSSound.beep()
            SettingsNavigationState.shared.open(.advanced)
            return
        }
        let sourceController = activeMainWindowController(sender: sender)

        if workflowBuilderWindowController == nil {
            let viewController = WorkflowBuilderViewController()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Workflow Builder"
            window.contentViewController = viewController
            window.setFrame(NSRect(x: 0, y: 0, width: 1024, height: 720), display: false)
            window.delegate = viewController
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setAccessibilityIdentifier("WorkflowBuilderWindow")
            window.center()

            workflowBuilderWindowController = NSWindowController(window: window)
        }

        if let viewController = workflowBuilderWindowController?.window?.contentViewController as? WorkflowBuilderViewController {
            let sidebarController = sourceController?.mainSplitViewController?.sidebarController
            let selectedFileURLs = sidebarController?.selectedFileURLs() ?? []
            viewController.configureRunContext(
                projectURL: sidebarController?.currentProjectURL,
                preferredSampleURL: sidebarController?.selectedFileURL,
                windowStateScope: sourceController?.projectSession.windowStateScope,
                isReadOnlyRecommended: sourceController?.projectSession.isReadOnlyRecommended == true,
                ignoredPreferredSampleSelectionCount: max(0, selectedFileURLs.count - 1)
            )
        }

        workflowBuilderWindowController?.showWindow(sender)
        workflowBuilderWindowController?.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
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
        let workflowTitle = sender.title.replacingOccurrences(of: " (not enabled)", with: "")
        guard let window = activeMainWindowController(sender: sender)?.window else {
            WorkflowLibraryWindowController.show()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable “\(workflowTitle)”?"
        alert.informativeText = "This workflow is available but not yet enabled. Enable it in the Workflow Library?"
        alert.addButton(withTitle: "Open Workflow Library")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            WorkflowLibraryWindowController.show()
        }
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
        WorkflowOperationsWindowController.show(
            projectURL: projectURL,
            routeContext: routeContext,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarResolution?.sidebarInputSelection,
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

    @objc func classifyReads(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification)
    }
}
