// AppDelegate+MenuActions.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit
import SQLite3
import os

extension AppDelegate {
    // MARK: - Menu Actions

    @IBAction func newDocument(_ sender: Any?) {
        Task {
            let savePanel = AppFilePanelFactory.newProjectPanel()

            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await savePanel.beginSheetModal(for: window)
            } else {
                response = await savePanel.begin()
            }

            guard response == .OK, let url = savePanel.url else { return }

            let projectURL = url.deletingPathExtension().appendingPathExtension("lungfish")
            do {
                let session = ProjectSession()
                let project = try self.projectOpenCoordinator.createProject(at: projectURL, using: session)
                let controller = self.createAndShowMainWindow(projectSession: session)
                NSApp.activate()
                self.welcomeWindowController?.close()
                self.welcomeWindowController = nil
                self.workingDirectoryURL = project.url
                DocumentManager.shared.mirrorProjectSession(session)
                controller.mainSplitViewController?.applyProjectSessionState()
                self.updateProjectWindowTitle(controller)
                self.saveApplicationState()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Create Project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                if let window = NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @IBAction func openDocument(_ sender: Any?) {
        let panel = AppFilePanelFactory.documentOpenPanel()

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    _ = self.openDocument(at: url)
                }
            }
        }
    }

    @IBAction func openProjectFolder(_ sender: Any?) {
        let panel = AppFilePanelFactory.projectFolderOpenPanel()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self = self else { return }

            let controller = self.createAndShowMainWindow()
            NSApp.activate()
            self.openProject(url, in: controller)
        }
    }

    @IBAction func openRecentProjectFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let url = item.representedObject as? URL else {
            return
        }

        let controller = createAndShowMainWindow()
        NSApp.activate()
        openProject(url, in: controller)
    }

    @IBAction func clearRecentProjectsFromMenu(_ sender: Any?) {
        RecentProjectsManager.shared.clearRecentProjects()
    }

    @IBAction func showAboutPanel(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(sender)
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        checkForUpdatesHandler?(sender)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    // MARK: - FileMenuActions

    @objc func importFiles(_ sender: Any?) {
        debugLog("importFiles: Menu action triggered")

        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else {
            debugLog("importFiles: No main window available")
            return
        }

        debugLog("importFiles: Showing import dialog")

        let panel = AppFilePanelFactory.projectFileImportPanel()

        // Use beginSheetModal with completion handler
        panel.beginSheetModal(for: window) { [weak self] response in
            debugLog("importFiles: Panel response: \(response.rawValue)")

            guard response == .OK else {
                debugLog("importFiles: User cancelled")
                return
            }

            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else {
                debugLog("importFiles: No files selected")
                return
            }

            self?.importProjectFilesFromURLs(selectedURLs, in: controller)
        }
    }

    func importProjectFilesFromURLs(_ selectedURLs: [URL], in targetController: MainWindowController? = nil) {
        let controller = targetController ?? activeMainWindowController()
        guard let splitViewController = controller?.mainSplitViewController,
              controller?.projectSession.projectURL != nil
                || splitViewController.sidebarController.currentProjectURL != nil
                || workingDirectoryURL != nil else {
            let alert = NSAlert()
            alert.messageText = "No Project Open"
            alert.informativeText = "Please open or create a project before importing files."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.applyLungfishBranding()
            if let window = controller?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        guard !selectedURLs.isEmpty else { return }
        debugLog("importProjectFilesFromURLs: Selected \(selectedURLs.count) file(s)")

        scheduleOnMainRunLoop {
            debugLog("importProjectFilesFromURLs: Starting import pipeline dispatch")

            let activityIndicator = splitViewController.activityIndicator
            let importPlan = splitViewController.makeSidebarImportPlan(for: selectedURLs)
            let trackedURLs = importPlan.sourceURLs

            guard !trackedURLs.isEmpty else {
                debugLog("importProjectFilesFromURLs: No importable sources found after expansion")
                return
            }

            let fileCount = trackedURLs.count
            let requestID = UUID().uuidString
            let tracker = SidebarImportRequestTracker(requestID: requestID, trackedURLs: trackedURLs)
            activityIndicator?.show(
                message: "Importing \(fileCount) file\(fileCount == 1 ? "" : "s")...",
                style: .indeterminate
            )

            tracker.observerToken = NotificationCenter.default.addObserver(
                forName: .sidebarFileDropCompleted,
                object: nil,
                queue: .main
            ) { completion in
                let completionRequestID = completion.userInfo?["requestID"] as? String
                let completedURL = completion.userInfo?["url"] as? URL
                let wasSuccessful = (completion.userInfo?["success"] as? Bool) == true

                scheduleOnMainRunLoop {
                    guard let update = tracker.registerCompletion(
                        requestID: completionRequestID,
                        completedURL: completedURL,
                        wasSuccessful: wasSuccessful
                    ) else {
                        return
                    }

                    if update.isFinished {
                        if let observerToken = tracker.observerToken {
                            NotificationCenter.default.removeObserver(observerToken)
                            tracker.observerToken = nil
                        }
                        activityIndicator?.hide()
                        debugLog(
                            "importProjectFilesFromURLs: Completed request \(requestID). success=\(update.succeeded), failed=\(update.failed)"
                        )

                        if update.failed > 0 {
                            let alert = NSAlert()
                            alert.messageText = "Import Completed with Errors"
                            alert.informativeText = "\(update.succeeded) succeeded, \(update.failed) failed."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.applyLungfishBranding()
                            if let window = controller?.window ?? NSApp.keyWindow {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            }

            if let firstURL = trackedURLs.first {
                activityIndicator?.updateMessage("Importing \(firstURL.lastPathComponent) (1/\(fileCount))...")
            }

            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: splitViewController.sidebarController,
                userInfo: [
                    "urls": trackedURLs,
                    "destination": NSNull(),
                    "requestID": requestID,
                    NotificationUserInfoKey.windowStateScope: splitViewController.projectSession.windowStateScope
                ]
            )

            debugLog("importProjectFilesFromURLs: Dispatched batch of \(trackedURLs.count) file(s) to sidebar import pipeline")
        }
    }

    @objc func importVCFToBundle(_ sender: Any?) {
        debugLog("importVCFToBundle: Menu action triggered")

        guard let originController = activeMainWindowController(sender: sender),
              let originSplit = originController.mainSplitViewController else {
            debugLog("importVCFToBundle: No main window available")
            return
        }
        let viewerController = originSplit.viewerController
        let bundleURL = viewerController?.currentBundleURL

        guard let window = originController.window else {
            debugLog("importVCFToBundle: No main window available")
            return
        }
        let routeContext = currentOperationRouteContext(for: originController)
        if let bundleURL {
            let projectURL = ProjectTempDirectory.findProjectRoot(bundleURL)
            guard canWriteProjectOutputs(
                projectURL: projectURL,
                windowStateScope: originController.projectSession.windowStateScope,
                workflowName: "VCF import",
                presentingWindow: window
            ) else { return }
        }

        let panel = AppFilePanelFactory.vcfImportPanel(targetsCurrentBundle: bundleURL != nil)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else {
                debugLog("importVCFToBundle: User cancelled")
                return
            }
            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else { return }
            debugLog("importVCFToBundle: Selected \(selectedURLs.count) file(s)")

            if let bundleURL {
                // Existing bundle loaded — import into it (use first file for backward compat)
                if let firstURL = selectedURLs.first {
                    self?.performVCFImport(vcfURL: firstURL, bundleURL: bundleURL, routeContext: routeContext)
                }
            } else {
                // No bundle loaded — auto-ingest into a new naked bundle
                originSplit.loadVCFFilesInBackground(urls: selectedURLs)
            }
        }
    }

    @objc func importBAMToBundle(_ sender: Any?) {
        debugLog("importBAMToBundle: Menu action triggered")

        // Require a bundle to be loaded
        guard let originController = activeMainWindowController(sender: sender),
              let viewerController = originController.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing alignments.")
            return
        }

        guard let window = originController.window else {
            debugLog("importBAMToBundle: No main window available")
            return
        }
        let routeContext = currentOperationRouteContext(for: originController)
        let projectURL = ProjectTempDirectory.findProjectRoot(bundleURL)
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "BAM import",
            presentingWindow: window
        ) else { return }

        let panel = AppFilePanelFactory.bamImportPanel()

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let bamURL = panel.url else {
                debugLog("importBAMToBundle: User cancelled")
                return
            }
            debugLog("importBAMToBundle: Selected \(bamURL.lastPathComponent)")
            self?.performBAMImport(bamURL: bamURL, bundleURL: bundleURL, routeContext: routeContext)
        }
    }

    // MARK: - ViewMenuActions

    @objc func toggleSidebar(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.toggleSidebar()
    }

    @objc func toggleInspector(_ sender: Any?) {
        let senderType = sender.map { String(describing: type(of: $0)) } ?? "nil"
        debugLog("toggleInspector[AppDelegate]: sender=\(senderType)")
        activeMainWindowController(sender: sender)?.mainSplitViewController?.toggleInspector(source: "AppDelegate.toggleInspector")
    }

    @objc func focusViewer(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.focusViewer()
    }

    @objc func restoreSidePanes(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.restoreSidePanes()
    }

    @objc func zoomIn(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.viewerController?.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.viewerController?.zoomOut()
    }

    @objc func zoomToFit(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.viewerController?.zoomToFit()
    }

    @objc func zoomReset(_ sender: Any?) {
        activeMainWindowController(sender: sender)?.mainSplitViewController?.viewerController?.zoomReset()
    }

    @objc func toggleNucleotideMode(_ sender: Any?) {
        guard let viewerController = activeMainWindowController(sender: sender)?.mainSplitViewController?.viewerController else {
            return
        }

        // Toggle the RNA mode
        viewerController.isRNAMode.toggle()

        // Trigger redraw
        viewerController.viewerView.needsDisplay = true

        // Persist to bundle view state
        viewerController.scheduleViewStateSave()
    }

    @objc func resetViewSettingsToDefaults(_ sender: Any?) {
        guard let splitVC = activeMainWindowController(sender: sender)?.mainSplitViewController else { return }

        // Delegate to the inspector's existing reset (which posts all needed notifications)
        splitVC.inspectorController.resetAllAppearanceSettings()
    }

    @objc func showDocumentInspector(_ sender: Any?) {
        guard let splitViewController = activeMainWindowController(sender: sender)?.mainSplitViewController else { return }
        splitViewController.setInspectorVisible(true, animated: false, source: "AppDelegate.showDocumentInspector")
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [
                NotificationUserInfoKey.inspectorTab: "document",
                NotificationUserInfoKey.windowStateScope: splitViewController.projectSession.windowStateScope
            ]
        )
    }

    @objc func showAIAssistant(_ sender: Any?) {
        showOrToggleAIAssistant()
    }

    @objc internal func handleShowAIAssistant(_ notification: Notification) {
        showOrToggleAIAssistant()
    }

    /// Shows the AI assistant in the Inspector panel (AI tab).
    private func showOrToggleAIAssistant() {
        guard AppSettings.shared.aiSearchEnabled else {
            let alert = NSAlert()
            alert.messageText = "AI Assistant Disabled"
            alert.informativeText = "Enable AI-powered search in Settings > AI Services to use the assistant."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        guard let splitViewController = mainWindowController?.mainSplitViewController else {
            return
        }

        let service = ensureAIAssistantService()
        splitViewController.inspectorController.setAIAssistantService(service)
        splitViewController.setInspectorVisible(true, animated: false, source: "AppDelegate.showAIAssistant")

        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "ai"]
        )
    }

    /// Lazily creates and wires AI tool/service objects.
    private func ensureAIAssistantService() -> AIAssistantService {
        if let existing = aiAssistantService {
            return existing
        }

        let toolRegistry: AIToolRegistry
        if let existingRegistry = aiToolRegistry {
            toolRegistry = existingRegistry
        } else {
            toolRegistry = AIToolRegistry()
            aiToolRegistry = toolRegistry
            connectToolRegistryToViewer(toolRegistry)
        }

        let service = AIAssistantService(toolRegistry: toolRegistry)
        aiAssistantService = service
        return service
    }

    /// Updates the AI tool registry's search index when a new bundle loads.
    @objc internal func handleBundleDidLoadForAI(_ notification: Notification) {
        guard let toolRegistry = aiToolRegistry else { return }
        if let searchIndex = mainWindowController?.mainSplitViewController?.viewerController?.annotationSearchIndex {
            toolRegistry.setSearchIndex(searchIndex)
        }
    }

    /// Connects the AI tool registry to the current viewer state and search index.
    private func connectToolRegistryToViewer(_ toolRegistry: AIToolRegistry) {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        // Connect search index (for gene/variant search)
        if let searchIndex = viewerController?.annotationSearchIndex {
            toolRegistry.setSearchIndex(searchIndex)
        }

        // Connect navigation callback
        toolRegistry.navigateToRegion = { [weak self] chromosome, start, end in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController,
                  let provider = viewerController.currentBundleDataProvider else { return }

            // Look up chromosome length from the manifest
            if let chromInfo = provider.chromosomeInfo(named: chromosome) {
                viewerController.navigateToChromosomeAndPosition(
                    chromosome: chromosome,
                    chromosomeLength: Int(chromInfo.length),
                    start: start,
                    end: end
                )
            }
        }

        toolRegistry.getVariantTableContext = { [weak self] selectionScope, limit in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return "No active viewer is available."
            }
            guard let drawer = viewerController.annotationDrawerView else {
                return "Variant table is unavailable because the bottom drawer is not open."
            }

            let isVariantTabActive = drawer.activeTab == .variants
            let isCallsSubtabActive = drawer.activeVariantSubtab == .calls
            let selectedRows = drawer.aiVariantRows(
                limit: limit,
                selectedOnly: true,
                fallbackToVisibleIfSelectionEmpty: false
            )
            let visibleRows = drawer.aiVariantRows(
                limit: limit,
                selectedOnly: false,
                fallbackToVisibleIfSelectionEmpty: false
            )

            let rows: [AnnotationSearchIndex.SearchResult]
            switch selectionScope {
            case "selected":
                rows = selectedRows
            case "visible":
                rows = visibleRows
            default:
                rows = selectedRows.isEmpty ? visibleRows : selectedRows
            }

            var lines: [String] = []
            lines.append("Variant table state:")
            lines.append("  Variant tab active: \(isVariantTabActive ? "yes" : "no")")
            lines.append("  Calls subtab active: \(isCallsSubtabActive ? "yes" : "no")")
            lines.append("  Selected rows: \(selectedRows.count)")
            lines.append("  Visible rows: \(visibleRows.count)")

            if rows.isEmpty {
                lines.append("No rows available for selection_scope='\(selectionScope)'.")
                return lines.joined(separator: "\n")
            }

            lines.append("Rows returned (\(rows.count), scope=\(selectionScope)):")
            for row in rows {
                let qualityString = row.quality.map { String(format: "%.1f", $0) } ?? "."
                var infoParts: [String] = []
                if let info = row.infoDict {
                    for key in ["CSQ_SYMBOL", "SYMBOL", "CSQ_IMPACT", "IMPACT", "CSQ_Consequence", "Consequence", "AF"] {
                        if let value = info[key], !value.isEmpty {
                            infoParts.append("\(key)=\(value)")
                        }
                    }
                    if infoParts.isEmpty {
                        let keys = info.keys.sorted().prefix(4)
                        for key in keys {
                            if let value = info[key], !value.isEmpty {
                                infoParts.append("\(key)=\(value)")
                            }
                        }
                    }
                }

                let infoSummary = infoParts.isEmpty ? "" : " info{\(infoParts.joined(separator: "; "))}"
                let rowId = row.variantRowId.map(String.init) ?? "nil"
                lines.append(
                    "- id=\(row.name) chrom=\(row.chromosome) pos1=\(row.start + 1) ref=\(row.ref ?? ".") alt=\(row.alt ?? ".") type=\(row.type) qual=\(qualityString) filter=\(row.filter ?? ".") samples=\(row.sampleCount ?? 0) track=\(row.trackId) row_id=\(rowId)\(infoSummary)"
                )
            }

            return lines.joined(separator: "\n")
        }

        toolRegistry.getSampleTableContext = { [weak self] selectionScope, limit, visibleOnly in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return "No active viewer is available."
            }
            guard let drawer = viewerController.annotationDrawerView else {
                return "Sample table is unavailable because the bottom drawer is not open."
            }

            let isSampleTabActive = drawer.activeTab == .samples
            let selectedRows = drawer.aiSampleRows(
                limit: limit,
                selectedOnly: true,
                visibleOnly: visibleOnly,
                fallbackToVisibleIfSelectionEmpty: false
            )
            let visibleRows = drawer.aiSampleRows(
                limit: limit,
                selectedOnly: false,
                visibleOnly: visibleOnly,
                fallbackToVisibleIfSelectionEmpty: false
            )

            let rows: [AnnotationTableDrawerView.SampleDisplayRow]
            switch selectionScope {
            case "selected":
                rows = selectedRows
            case "visible":
                rows = visibleRows
            default:
                rows = selectedRows.isEmpty ? visibleRows : selectedRows
            }

            var lines: [String] = []
            lines.append("Sample table state:")
            lines.append("  Samples tab active: \(isSampleTabActive ? "yes" : "no")")
            lines.append("  Selected rows: \(selectedRows.count)")
            lines.append("  Visible rows: \(visibleRows.count)")
            lines.append("  visible_only: \(visibleOnly ? "true" : "false")")

            if rows.isEmpty {
                lines.append("No rows available for selection_scope='\(selectionScope)'.")
                return lines.joined(separator: "\n")
            }

            lines.append("Rows returned (\(rows.count), scope=\(selectionScope)):")
            for row in rows {
                let metadataPairs = row.metadata
                    .sorted { $0.key < $1.key }
                    .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .prefix(6)
                    .map { "\($0.key)=\($0.value)" }
                let metadataSummary = metadataPairs.isEmpty ? "" : " metadata{\(metadataPairs.joined(separator: "; "))}"
                lines.append("- sample=\(row.name) visible=\(row.isVisible ? "true" : "false") source=\(row.sourceFile)\(metadataSummary)")
            }

            return lines.joined(separator: "\n")
        }

        // Connect current view state callback
        toolRegistry.getCurrentViewState = { [weak self] in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return AIToolRegistry.ViewerState()
            }

            let provider = viewerController.currentBundleDataProvider
            let frame = viewerController.referenceFrame

            // Count variant tracks
            let variantHandles = viewerController.annotationSearchIndex?.variantDatabaseHandles ?? []
            let variantTrackCount = variantHandles.count
            let totalVariantCount = variantHandles.reduce(0) { $0 + $1.db.totalCount() }

            var sampleCount = 0
            var allSampleNames: [String] = []
            var sampleNameExamples: [String] = []
            for handle in variantHandles {
                let count = handle.db.sampleCount()
                if count > sampleCount {
                    sampleCount = count
                    allSampleNames = handle.db.sampleNames()
                    sampleNameExamples = Array(allSampleNames.prefix(4))
                }
            }

            // Visible sample subset from current sample display state (visualizer-driven).
            let hiddenSamples = viewerController.viewerView.sampleDisplayState.hiddenSamples
            let visibleSampleNames = allSampleNames.filter { !hiddenSamples.contains($0) }
            let visibleSampleCount = visibleSampleNames.count
            let visibleSampleExamples = Array(visibleSampleNames.prefix(6))

            // Table-visible rows from the annotation drawer (when initialized/opened).
            let drawer = viewerController.annotationDrawerView
            let displayedVariantRows = (drawer?.activeTab == .variants)
                ? (drawer?.displayedAnnotations ?? [])
                : []
            let variantTableExamples = displayedVariantRows.prefix(6).map { row in
                "\(row.name) \(row.chromosome):\(row.start + 1)-\(row.end) [\(row.type)]"
            }

            let displayedSampleRows = drawer?.displayedSamples ?? []
            let sampleTableRows = displayedSampleRows.isEmpty
                ? allSampleNames.map { name in !hiddenSamples.contains(name) ? name : nil }.compactMap { $0 }
                : displayedSampleRows.filter(\.isVisible).map(\.name)
            let sampleTableExamples = Array(sampleTableRows.prefix(6))

            return AIToolRegistry.ViewerState(
                chromosome: frame?.chromosome,
                start: frame.map { Int($0.start) },
                end: frame.map { Int($0.end) },
                organism: provider?.organism,
                assembly: provider?.assembly,
                bundleName: provider?.name,
                chromosomeNames: provider?.chromosomes.map(\.name) ?? [],
                annotationTrackCount: provider?.annotationTrackIds.count ?? 0,
                variantTrackCount: variantTrackCount,
                totalVariantCount: totalVariantCount,
                sampleCount: sampleCount,
                sampleNameExamples: sampleNameExamples,
                visibleSampleCount: visibleSampleCount,
                visibleSampleExamples: visibleSampleExamples,
                variantTableRowCount: displayedVariantRows.count,
                variantTableExamples: variantTableExamples,
                sampleTableRowCount: sampleTableRows.count,
                sampleTableExamples: sampleTableExamples
            )
        }
    }

    // MARK: - OperationsMenuActions

    @objc func showOperationsPanel(_ sender: Any?) {
        if operationsPanelController == nil {
            operationsPanelController = OperationsPanelController()
        }
        operationsPanelController?.showWindow(nil)
    }

    @objc func cancelAllOperations(_ sender: Any?) {
        let runningCount = OperationCenter.shared.activeCount
        guard runningCount > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel All Operations?"
        alert.informativeText = "This will cancel \(runningCount) running operation\(runningCount == 1 ? "" : "s")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Operations")
        alert.addButton(withTitle: "Keep Running")

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                OperationCenter.shared.cancelAll()
            }
        }
    }

    @objc func clearCompletedOperations(_ sender: Any?) {
        OperationCenter.shared.clearCompleted()
    }

    @objc func cancelOperation(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let operationID = menuItem.representedObject as? UUID else { return }

        guard let item = OperationCenter.shared.items.first(where: { $0.id == operationID }),
              item.state == .running else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel \"\(item.title)\"?"
        alert.informativeText = "This operation is \(Int(item.progress * 100))% complete."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Operation")
        alert.addButton(withTitle: "Keep Running")

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                OperationCenter.shared.cancel(id: operationID)
            }
        }
    }

    // MARK: - HelpMenuActions

    private func showHelpTopic(_ topicID: String) {
        // Prefer macOS Help Book integration for indexed, searchable docs.
        if HelpBookIntegration.openTopic(topicID) {
            return
        }

        // Fallback to the in-app help browser if Help Book resources are unavailable.
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.showTopic(topicID)
    }

    @objc func showLungfishHelp(_ sender: Any?) {
        showHelpTopic("index")
    }

    @objc func showGettingStarted(_ sender: Any?) {
        showHelpTopic("getting-started")
    }

    @objc func showVCFGuide(_ sender: Any?) {
        showHelpTopic("vcf-variants")
    }

    @objc func showAIGuide(_ sender: Any?) {
        showHelpTopic("ai-assistant")
    }

    @objc func openOnlineDocumentation(_ sender: Any?) {
        if let url = URL(string: "https://lungfish-genome-explorer.readthedocs.io/en/latest/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openReleaseNotes(_ sender: Any?) {
        if let url = URL(string: "https://github.com/dhoconno/lungfish-genome-explorer/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reportIssue(_ sender: Any?) {
        if let url = OperationFailureIssueReporter.generalIssueURL(context: issueReportContext(sender: sender)) {
            GitHubIssueOpener.open(url)
        }
    }

    private func issueReportContext(sender: Any?) -> OperationFailureIssueContext {
        let controller = activeMainWindowController(sender: sender)
        let projectURL = controller?.projectSession.projectURL
            ?? controller?.mainSplitViewController?.sidebarController?.currentProjectURL
        let warningState = controller?.projectSession.openWarningState
        let lockSummary: String?
        if let warningState {
            lockSummary = ProjectLockWarningPresentation(state: warningState)?.detail
                ?? warningState.warningMessage
        } else {
            lockSummary = nil
        }

        return OperationFailureIssueContext(
            environment: .current,
            projectPath: projectURL?.standardizedFileURL.path,
            isReadOnlyRecommended: controller?.projectSession.isReadOnlyRecommended ?? false,
            lockSummary: lockSummary,
            windowTitle: controller?.window?.title ?? NSApp.keyWindow?.title
        )
    }

    internal func seedOperationsPanelFailureForUITest() {
        OperationCenter.shared.clearCompleted()
        let operationID = OperationCenter.shared.start(
            title: "UI test failed operation",
            detail: "Preparing deterministic failure",
            operationType: .classification,
            cliCommand: "lungfish classify --reads '~/ui-test/R1.fastq.gz'"
        )
        OperationCenter.shared.log(
            id: operationID,
            level: .info,
            message: "UI test seeded operation"
        )
        OperationCenter.shared.fail(
            id: operationID,
            detail: "Deterministic failure used by XCUI",
            errorMessage: "UI test failure",
            errorDetail: "This fixture exercises the Operations panel GitHub issue action."
        )
    }
}
