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
                            _ = try await service.run(request, bundleRoot: bundleRoot, routeContext: routeContext)
                        } catch {
                            debugLog("showFASTQOperationsDialog: Viral Recon failed to start: \(String(describing: error))")
                        }
                    }
                    return
                }

                if let request = state.pendingMappingRequest {
                    self.runManagedMapping(request: request, routeContext: routeContext)
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

    private func runManagedMapping(
        request: MappingRunRequest,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        var request = request
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Read mapping"
        ) else { return }
        let projectURL = routeContext?.projectURL ?? request.projectURL
        if let projectURL,
           let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: request.tool.rawValue, in: projectURL) {
            request = request.withOutputDirectory(analysisDir)
        }

        let opID = OperationCenter.shared.start(
            title: "Map Reads (\(request.tool.displayName))",
            detail: "Mapping \(request.inputFASTQURLs.count) file(s) to \(request.referenceFASTAURL.lastPathComponent)",
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                if AppUITestConfiguration.current.isEnabled,
                   AppUITestConfiguration.current.backendMode == .deterministic {
                    let result = try AppUITestMappingBackend.writeResult(for: request)
                    let outputDirectory = request.outputDirectory
                    let capturedRequest = request
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: "Mapping complete: \(result.mappedReads)/\(result.totalReads) reads mapped"
                        )
                        AppUITestConfiguration.current.appendEvent(
                            "mapping.operation.completed target=\(outputDirectory.lastPathComponent)"
                        )
                        AppDelegate.shared?.routePostMappingDeterministicCompletion(
                            outputDirectory: outputDirectory,
                            request: capturedRequest
                        )
                    }}
                    return
                }

                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "\(request.tool.rawValue)-",
                    contextURL: request.inputFASTQURLs.first ?? request.referenceFASTAURL
                )
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    request.inputFASTQURLs,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                        }}
                    }
                ) ?? request.inputFASTQURLs

                let resolvedRequest = request.withInputFASTQURLs(resolvedFiles)
                let pipeline = ManagedMappingPipeline()
                let result = try await pipeline.run(request: resolvedRequest) { fraction, message in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }}
                }

                var finalResult = result
                if let self {
                    do {
                        if let preparedResult = try await self.prepareMappingViewerBundleIfPossible(
                            result: result,
                            request: resolvedRequest,
                            opID: opID
                        ) {
                            finalResult = preparedResult
                        }
                    } catch {
                        DispatchQueue.main.async { MainActor.assumeIsolated {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "Reference viewer bundle could not be prepared: \(error.localizedDescription)"
                            )
                        }}
                    }
                }

                let capturedRequest = request
                DispatchQueue.main.async { MainActor.assumeIsolated {
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
                            parameters: capturedRequest.summaryParameters(),
                            summary: "\(finalResult.mappedReads)/\(finalResult.totalReads) reads mapped",
                            status: .completed
                        )
                        do {
                            try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
                        } catch {
                            appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)")
                        }
                    }

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
            viewerBundleURL: viewerBundleURL,
            fileManager: fm
        )

        _ = try await BAMImportService.importBAM(
            bamURL: result.bamURL,
            bundleURL: viewerBundleURL,
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
        try preparedResult.save(to: request.outputDirectory)
        if let provenance = MappingProvenance.load(from: request.outputDirectory) {
            try provenance
                .withViewerBundleURL(viewerBundleURL)
                .withSourceReferenceBundleURL(sourceBundleURL)
                .save(to: request.outputDirectory)
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
            viewController.configureRunContext(
                projectURL: sidebarController?.currentProjectURL,
                preferredSampleURL: sidebarController?.selectedFileURL,
                windowStateScope: sourceController?.projectSession.windowStateScope,
                isReadOnlyRecommended: sourceController?.projectSession.isReadOnlyRecommended == true
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
