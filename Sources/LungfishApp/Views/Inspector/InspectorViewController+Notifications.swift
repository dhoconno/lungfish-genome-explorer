// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTwelveSUI
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import os.log
import LungfishKit

extension InspectorViewController {

    // MARK: - Notification Handlers

    /// Handles sidebar selection changes to update inspector UI state.
    ///
    /// Note: This method only updates the inspector's display state (selected item name/type).
    /// Document loading is handled exclusively by MainSplitViewController to avoid race conditions
    /// where both controllers attempt to load the same document concurrently.
    @objc func selectionDidChange(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }

        // Handle empty selection (items array is empty, no "item" key)
        if let items = notification.userInfo?["items"] as? [SidebarItem], items.isEmpty {
            activeContentSelectionIdentity = nil
            selectedFASTQMetadataTargetBundleURLs = []
            clearTransientSelectionState()
            return
        }

        guard let item = notification.userInfo?["item"] as? SidebarItem else { return }
        activeContentSelectionIdentity = notification.userInfo?[NotificationUserInfoKey.contentSelectionIdentity]
            as? ContentSelectionIdentity
        let selectedItems = notification.userInfo?["items"] as? [SidebarItem] ?? [item]
        selectedFASTQMetadataTargetBundleURLs = Self.fastqBundleURLs(from: selectedItems)

        // Update UI state only - document loading is handled by MainSplitViewController
        viewModel.selectedItem = item.title
        viewModel.selectedType = item.type.description
        updateProvenanceTarget(url: item.url, sidebarType: item.type, displayName: item.title)

        if selectedFASTQMetadataTargetBundleURLs.count > 1,
           let firstFASTQBundleURL = selectedFASTQMetadataTargetBundleURLs.first {
            viewModel.fastqMetadataSectionViewModel.load(
                from: firstFASTQBundleURL,
                readTypeTargetBundleURLs: selectedFASTQMetadataTargetBundleURLs
            )
            viewModel.selectedTab = .bundle
        } else if selectedFASTQMetadataTargetBundleURLs.count == 1 {
            viewModel.fastqMetadataSectionViewModel.setReadTypeTargetBundleURLs(selectedFASTQMetadataTargetBundleURLs)
        }

        if item.type == .sequence || item.type == .annotation || item.type == .alignment || item.type == .referenceBundle {
            syncAnnotationStateToViewer()
        }

        inspectorLogger.debug("selectionDidChange: Updated inspector state for '\(item.title, privacy: .public)' type=\(item.type.description, privacy: .public)")
    }

    /// Clears all selection state in the inspector, resetting it to "No Selection".
    ///
    /// Called when the sidebar selection is emptied (clicking empty space, deselecting).
    /// Resets the sidebar item display, annotation selection, variant details, document
    /// metadata, and read selection to their default empty states.
    private func clearTransientSelectionState() {
        activeContentSelectionIdentity = nil
        selectedFASTQMetadataTargetBundleURLs = []
        // Clear sidebar selection display
        viewModel.selectedItem = nil
        viewModel.selectedType = nil

        // Clear annotation selection
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(annotation: nil)

        // Clear variant details
        viewModel.variantSectionViewModel.clear()

        // Clear read selection
        viewModel.readStyleSectionViewModel.selectedRead = nil

        // Clear provenance state for empty sidebar selections.
        viewModel.provenanceSectionViewModel.clear()
        viewModel.fastqPBAAArtifactsSectionViewModel.clear()
    }

    public func clearSelection() {
        inspectorLogger.info("clearSelection: Resetting inspector to empty state")

        clearTransientSelectionState()
        viewModel.selectionSectionViewModel.referenceBundle = nil
        viewModel.readStyleSectionViewModel.clear()
        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = nil
        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = nil
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil

        // Clear document section (bundle metadata, FASTQ stats, etc.)
        viewModel.documentSectionViewModel.update(manifest: nil, bundleURL: nil)
        viewModel.documentSectionViewModel.fastqStatistics = nil
        viewModel.documentSectionViewModel.sraRunInfo = nil
        viewModel.documentSectionViewModel.enaReadRecord = nil
        viewModel.documentSectionViewModel.ingestionMetadata = nil
        viewModel.documentSectionViewModel.fastqDerivativeManifest = nil
        viewModel.documentSectionViewModel.analysisManifestEntries = []
        viewModel.documentSectionViewModel.updateMappingDocument(nil)
        viewModel.documentSectionViewModel.updateAssemblyDocument(nil)
        loadedGenotypeResult = nil
        viewModel.documentSectionViewModel.navigateToSourceData = nil
        viewModel.provenanceSectionViewModel.clear()

        // Clear sample section
        viewModel.sampleSectionViewModel.clear()
        viewModel.genotypeResultDisplaySectionViewModel.clear()
        viewModel.twelveSResultDisplaySectionViewModel.clear()
        viewModel.twelveSResultDisplaySectionViewModel.onExportRequested = nil
        viewModel.twelveSDetailSectionViewModel.reset()
        onGenotypeResultDisplayStateChanged = nil
        onTwelveSResultDisplayStateChanged = nil
        onGenotypeSampleMetadataImported = nil
        viewModel.genotypeResultDisplaySectionViewModel.onGenotypeHighlightRequested = nil
        viewModel.selectionSectionViewModel.onGenotypeHighlightRequested = nil

        // Clear FASTQ metadata section
        viewModel.fastqMetadataSectionViewModel.clear()
        viewModel.fastqPBAAArtifactsSectionViewModel.clear()

        inspectorLogger.info("clearSelection: Inspector reset to empty state")
    }

    /// Handles annotation selection from the viewer.
    ///
    /// Updates the selection section with the newly selected annotation.
    /// Passing nil in userInfo clears the selection.
    @objc func handleAnnotationSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let selectedAnnotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation

        // Translation track persists across annotation selection changes.
        // The inspector button state resets in SelectionSectionViewModel.select(),
        // but we do NOT post a hide-translation notification to the viewer.
        // The user must explicitly hide the translation via the inspector button.

        if let annotation = selectedAnnotation {
            viewModel.selectedAnnotation = annotation
            viewModel.selectionSectionViewModel.select(annotation: annotation)
            if annotation.type != .snp && annotation.type != .insertion && annotation.type != .deletion && annotation.type != .variation {
                viewModel.variantSectionViewModel.clear()
            }
            // Auto-switch to Selected Item when an annotation is selected.
            viewModel.selectedTab = .selectedItem
        } else {
            // Deselection - clear the annotation
            viewModel.selectedAnnotation = nil
            viewModel.selectionSectionViewModel.select(annotation: nil)
            viewModel.variantSectionViewModel.clear()
            applyInspectorTabSelection(from: notification)
        }
    }

    /// Handles variant selection notifications carrying row/track identity.
    @objc func handleVariantSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let result = notification.userInfo?[NotificationUserInfoKey.searchResult] as? AnnotationSearchIndex.SearchResult else {
            viewModel.variantSectionViewModel.clear()
            return
        }
        viewModel.variantSectionViewModel.select(variant: result)
        viewModel.selectedTab = .selectedItem
    }

    /// Handles read selection from the viewer.
    @objc func handleReadSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let read = notification.userInfo?[NotificationUserInfoKey.alignedRead] as? AlignedRead
        viewModel.readStyleSectionViewModel.selectedRead = read
        if read != nil {
            viewModel.selectedTab = .selectedItem
        }
    }

    /// Handles bundle load notifications to update the Document tab.
    ///
    /// Extracts the manifest and bundle URL from the notification's userInfo
    /// and updates the document section view model.
    @objc func handleBundleDidLoad(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let userInfo = notification.userInfo else { return }

        let bundleURL = userInfo[NotificationUserInfoKey.bundleURL] as? URL
        let manifest = userInfo[NotificationUserInfoKey.manifest] as? BundleManifest

        inspectorLogger.info("handleBundleDidLoad: Updating document tab with manifest=\(manifest != nil), bundleURL=\(bundleURL?.lastPathComponent ?? "nil", privacy: .public)")

        let bundle = userInfo[NotificationUserInfoKey.referenceBundle] as? ReferenceBundle
        updateReferenceBundleDocumentState(manifest: manifest, bundleURL: bundleURL, bundle: bundle)

        if let bundle {
            updateAlignmentSection(from: bundle)
        }
    }

    /// Handles requests to show/focus inspector with a specific tab.
    @objc func handleShowInspectorRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        applyInspectorTabSelection(from: notification)
    }

    /// Handles chromosome inspector requests and updates chromosome details state.
    ///
    /// Always switches to the Bundle tab when a chromosome is selected so the
    /// chromosome metadata is immediately visible in the inspector.
    @objc func handleChromosomeInspectorRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let chromosome = notification.userInfo?[NotificationUserInfoKey.chromosome] as? ChromosomeInfo
        updateSelectedChromosome(chromosome)
        if chromosome != nil {
            viewModel.selectedTab = .bundle
        }
    }

    @objc func handleFASTQDatasetLoaded(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let stats = notification.userInfo?["statistics"] as? FASTQDatasetStatistics else { return }
        viewModel.documentSectionViewModel.updateFASTQStatistics(stats)

        let sra = notification.userInfo?["sraRunInfo"] as? SRARunInfo
        let ena = notification.userInfo?["enaReadRecord"] as? ENAReadRecord
        if sra != nil || ena != nil {
            viewModel.documentSectionViewModel.updateSRAMetadata(sra: sra, ena: ena)
        }

        let ingestion = notification.userInfo?["ingestionMetadata"] as? IngestionMetadata
        viewModel.documentSectionViewModel.updateIngestionMetadata(ingestion)
        let derivative = notification.userInfo?["fastqDerivativeManifest"] as? FASTQDerivedBundleManifest
        viewModel.documentSectionViewModel.updateFASTQDerivativeMetadata(derivative)

        // Load FASTQ sample metadata and analysis manifest if bundle URL is provided
        if let bundleURL = notification.userInfo?["bundleURL"] as? URL {
            let readTypeTargets = selectedFASTQMetadataTargetBundleURLs.contains(bundleURL.standardizedFileURL)
                ? selectedFASTQMetadataTargetBundleURLs
                : [bundleURL.standardizedFileURL]
            viewModel.fastqMetadataSectionViewModel.load(
                from: bundleURL,
                readTypeTargetBundleURLs: readTypeTargets
            )
            viewModel.fastqPBAAArtifactsSectionViewModel.load(from: bundleURL)
            updateProvenanceTarget(
                url: bundleURL,
                sidebarType: .fastqBundle,
                displayName: bundleURL.deletingPathExtension().lastPathComponent
            )
            let routeContext = OperationRouteContext(
                projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
                windowStateScope: windowStateScope
            )
            let projectURL = routeContext.projectURL
                ?? AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                    .projectSession.projectURL
            viewModel.documentSectionViewModel.updateAnalysisManifest(
                bundleURL: bundleURL,
                projectURL: projectURL
            )

            // Wire navigation callback so clicking an analysis entry in the
            // Inspector opens it in the viewer via the sidebar selection path.
            viewModel.documentSectionViewModel.navigateToAnalysis = { [weak self] entry in
                guard let projectURL else { return }
                let analysisURL = projectURL
                    .appendingPathComponent(AnalysesFolder.directoryName)
                    .appendingPathComponent(entry.analysisDirectoryName)
                guard FileManager.default.fileExists(atPath: analysisURL.path) else {
                    // Stale entry — prune and refresh
                    self?.viewModel.documentSectionViewModel.updateAnalysisManifest(
                        bundleURL: bundleURL,
                        projectURL: projectURL
                    )
                    return
                }
                var userInfo: [AnyHashable: Any] = ["url": analysisURL]
                if let scope = self?.windowStateScope {
                    userInfo[NotificationUserInfoKey.windowStateScope] = scope
                }
                NotificationCenter.default.post(
                    name: .navigateToSidebarItem,
                    object: self,
                    userInfo: userInfo
                )
            }
        }

        viewModel.selectedTab = .bundle
    }

    private static func fastqBundleURLs(from items: [SidebarItem]) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for item in items where item.type == .fastqBundle {
            guard let url = item.url?.standardizedFileURL,
                  FASTQBundle.isBundleURL(url),
                  seen.insert(url.path).inserted else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    /// Handles viewport content mode changes.
    ///
    /// Updates the view model's content mode and ensures the selected tab is valid
    /// for the new mode. If the current tab is no longer available, switches to the
    /// first available tab.
    @objc func handleContentModeChanged(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let rawMode = notification.userInfo?[NotificationUserInfoKey.contentMode] as? String,
              let mode = ViewportContentMode(rawValue: rawMode) else { return }

        inspectorLogger.info("handleContentModeChanged: mode=\(rawMode, privacy: .public)")
        viewModel.contentMode = mode
        if let currentItem = viewModel.provenanceSectionViewModel.currentItem {
            updateProvenanceTarget(
                url: currentItem.url,
                sidebarType: currentItem.sidebarType,
                displayName: currentItem.displayName
            )
        }

        // If the currently selected tab is not available in the new mode, switch to the first available tab.
        let available = viewModel.availableTabs
        if !available.contains(viewModel.selectedTab), let first = available.first {
            viewModel.selectedTab = first
        }
    }

    /// Handles the `.batchManifestCached` notification.
    ///
    /// When a batch aggregated manifest is saved to disk (first-load slow path), this transitions
    /// the Inspector status indicator from `.building` to `.cached`.
    @objc func handleBatchManifestCached(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        if viewModel.documentSectionViewModel.batchManifestStatus == .building {
            viewModel.documentSectionViewModel.batchManifestStatus = .cached
        }
    }

    /// Applies inspector tab selection from notification userInfo if provided.
    private func applyInspectorTabSelection(from notification: Notification) {
        guard let tabName = notification.userInfo?[NotificationUserInfoKey.inspectorTab] as? String,
              let tab = InspectorTab(rawValue: tabName) else {
            return
        }
        viewModel.selectedTab = tab
    }

    func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    func operationRouteContext(for bundleURL: URL?) -> OperationRouteContext? {
        OperationRouteContext(
            projectURL: bundleURL.flatMap(ProjectTempDirectory.findProjectRoot),
            windowStateScope: windowStateScope
        )
    }

    func canWriteProjectOutputs(bundleURL: URL?, workflowName: String) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return true }
        return appDelegate.canWriteProjectOutputs(
            projectURL: bundleURL.flatMap(ProjectTempDirectory.findProjectRoot),
            windowStateScope: windowStateScope,
            workflowName: workflowName,
            presentingWindow: view.window
        )
    }

    public func restorableSelectedTabIdentifier() -> String {
        viewModel.selectedTab.rawValue
    }

    public func restoreSelectedTabIdentifier(_ identifier: String) {
        guard let tab = InspectorTab(rawValue: identifier) else { return }
        viewModel.selectedTab = tab
    }

    func updateProvenanceTarget(
        url: URL?,
        sidebarType: SidebarItemType?,
        displayName: String?
    ) {
        viewModel.provenanceSectionViewModel.load(
            item: ProvenanceInspectableItem(
                url: url,
                sidebarType: sidebarType,
                contentMode: viewModel.contentMode,
                displayName: displayName
            )
        )
    }

    func presentProvenanceExport(format: ProvenanceExportFormat) {
        guard let item = viewModel.provenanceSectionViewModel.currentItem,
              let sourceURL = item.url,
              let envelope = viewModel.provenanceSectionViewModel.resolvedEnvelope else {
            presentSimpleAlert(
                title: "No Provenance Available",
                message: "No complete provenance record is available for the current selection."
            )
            return
        }

        let savePanel = FeatureFilePanelFactory.inspectorProvenanceExportPanel(
            defaultDirectoryName: "\(sourceURL.deletingPathExtension().lastPathComponent)-provenance-\(format.cliToken)"
        )

        guard let window = view.window ?? NSApp.keyWindow else { return }
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputDirectory = savePanel.url else { return }
            do {
                let existingState = self?.existingDirectoryState(outputDirectory)
                if existingState == false {
                    throw ProvenanceError.exportFailed(
                        "The selected path exists and is not a folder: \(outputDirectory.path)"
                    )
                }
                let bundle = try ProvenanceExporter().exportBundle(
                    envelope,
                    format: format,
                    to: outputDirectory,
                    sourceSidecarURL: self?.viewModel.provenanceSectionViewModel.resolvedSidecarURL,
                    sourceRootURL: sourceURL,
                    exportArgv: AppProvenanceExportCommandBuilder.argv(
                        format: format,
                        sourceURL: sourceURL,
                        outputDirectory: outputDirectory
                    )
                )
                self?.presentProvenanceExportComplete(bundle: bundle, format: format, window: window)
            } catch {
                self?.presentSimpleAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    private func existingDirectoryState(_ url: URL) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
    }

    private func presentProvenanceExportComplete(
        bundle: ProvenanceExportBundle,
        format: ProvenanceExportFormat,
        window: NSWindow
    ) {
        let alert = NSAlert()
        alert.messageText = "Provenance Export Complete"
        alert.informativeText = "\(format.rawValue) exported to \(bundle.primaryArtifactURL.lastPathComponent)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.primaryArtifactURL])
            }
        }
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

}
