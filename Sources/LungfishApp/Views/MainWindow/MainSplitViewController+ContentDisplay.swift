// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishTwelveSUI
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    func displayContent(for item: SidebarItem) {
        mainSplitLogger.info("displayContent: Selected '\(item.title, privacy: .public)' type=\(String(describing: item.type))")
        let displayIdentity = contentSelectionIdentity(for: item)
        let displayToken = beginDisplayRequest(identity: displayIdentity)

        let selectedFASTQURL: URL? = {
            guard let url = item.url else { return nil }
            if FASTQBundle.isBundleURL(url) {
                return url.standardizedFileURL
            }
            return FASTQBundle.resolvePrimaryFASTQURL(for: url)?.standardizedFileURL
        }()
        if selectedFASTQURL == nil {
            cancelFASTQLoadIfNeeded(hideProgress: true, reason: "selected non-FASTQ item '\(item.title)'")
        }

        // Skip non-displayable container types
        guard item.type != .folder && item.type != .project && item.type != .group else {
            mainSplitLogger.debug("displayContent: Skipping container item type")
            return
        }

        // Batch group items: route directly to the batch aggregated viewer
        if item.type == .batchGroup, let batchURL = item.url {
            displayBatchGroup(at: batchURL)
            return
        }

        // When switching away from a bundle to a non-bundle item, clean up the navigator
        if item.type != .referenceBundle {
            viewerController.clearBundleDisplay()
        }

        // Always clear FASTA collection view when switching sidebar items
        viewerController.hideFASTACollectionView()
        viewerController.hideCollectionBackButton()

        // QuickLook preview for document, image, unknown types
        if item.type.usesQuickLook, let url = item.url {
            mainSplitLogger.info("displayContent: Using QuickLook preview for '\(item.title, privacy: .public)'")
            viewerController.displayQuickLookPreview(url: url)
            return
        }

        // Reference genome bundles (.lungfishref)
        if item.type == .referenceBundle, let url = item.url {
            displayReferenceBundleViewportFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        if item.type == .genotypeResultBundle, let url = item.url {
            displayGenotypeResultBundleFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        if item.type == .twelveSAmpliconResultBundle, let url = item.url {
            displayTwelveSAmpliconResultBundleFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        if item.type == .multipleSequenceAlignmentBundle, let url = item.url {
            displayMultipleSequenceAlignmentBundleFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        if item.type == .mhcReferenceBundle, let url = item.url {
            displayMHCReferenceBundleFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        if item.type == .phylogeneticTreeBundle, let url = item.url {
            displayPhylogeneticTreeBundleFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        // Classification results (Kraken2 kreport/kraken output)
        if item.type == .classificationResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // EsViritu viral detection results
        if item.type == .esvirituResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // TaxTriage results — all go through the DB router now.
        // Per-sample display will be handled via DB queries (Task 6).
        if item.type == .taxTriageResult, let url = item.url {
            routeClassifierDisplay(url: url)
            return
        }

        // NAO-MGS surveillance result bundles
        if item.type == .naoMgsResult, let url = item.url {
            displayNaoMgsResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        // NVD result bundles
        if item.type == .nvdResult, let url = item.url {
            displayNvdResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        // CZ-ID imported taxonomy result bundles
        if item.type == .czIdResult, let url = item.url {
            displayCzIdResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            return
        }

        // Generic analysis results in Analyses/ folder — try to detect tool type
        // from directory name and dispatch to the appropriate viewer.
        // Classifier results route through the ClassifierDatabaseRouter; non-classifier
        // results are dispatched by prefix or analysis-metadata.json.
        if item.type == .analysisResult, let url = item.url {
            if ClassifierDatabaseRouter.route(for: url) != nil {
                routeClassifierDisplay(url: url)
                return
            }
            // Determine tool: check metadata first (works for renamed dirs), then prefix.
            let dirName = url.lastPathComponent
            let toolId = item.userInfo["analysisTool"]
                ?? AnalysesFolder.readAnalysisMetadata(from: url)?.tool
                ?? dirName
            switch AnalysisResultDisplayRoute.route(forToolID: toolId) {
            case .naoMgs:
                displayNaoMgsResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            case .nvd:
                displayNvdResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            case .czId:
                displayCzIdResultFromSidebar(at: url, identity: displayIdentity, token: displayToken)
            case .assembly:
                displayAssemblyAnalysisFromSidebar(at: url)
            case .mapping:
                displayMappingAnalysisFromSidebar(at: url)
            case .unknown:
                mainSplitLogger.warning("displayContent: Unknown analysis type for '\(dirName, privacy: .public)'")
            }
            return
        }

        // Genomics files - check cache first
        if let url = item.url {
            displayGenomicsFile(url: url)
        } else if item.type == .sequence || item.type == .annotation || item.type == .alignment {
            // Check for already-loaded document by name
            if let document = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                mainSplitLogger.info("displayContent: Found matching document by name, displaying")
                viewerController.displayDocument(document)
                projectSession.setActiveDocument(document)
                DocumentManager.shared.setActiveDocument(document)
            }
        }
    }

    func displayMultipleSequenceAlignmentBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayMultipleSequenceAlignmentBundle: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "multipleSequenceAlignmentBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)

        activityIndicator.show(message: "Loading \(url.lastPathComponent)...", style: .indeterminate)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.activityIndicator.hide() }
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

                do {
                    self.inspectorController.clearSelection()
                    let bundle = try MultipleSequenceAlignmentBundle.load(from: url)
                    self.inspectorController.updateMultipleSequenceAlignmentDocument(bundle)
                    try self.viewerController.displayMultipleSequenceAlignmentBundle(at: url)
                    if let controller = self.viewerController.multipleSequenceAlignmentViewController {
                        controller.onSelectionStateChanged = { [weak self] state in
                            self?.inspectorController.updateMultipleSequenceAlignmentSelection(state)
                        }
                        controller.notifySelectionStateIfAvailable()
                    }
                } catch {
                    mainSplitLogger.error(
                        "displayMultipleSequenceAlignmentBundle: Failed - \(error.localizedDescription, privacy: .public)"
                    )
                    self.viewerController.clearViewport(statusMessage: "Unable to load alignment bundle.")
                }
            }
        }
    }

    /// Display an MHC amplicon reference bundle (`.lungfishmhcref`). This bundle is
    /// metadata-only with no viewport, so the viewport is cleared with an informative
    /// status and all details are surfaced in the Bundle inspector tab.
    func displayMHCReferenceBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayMHCReferenceBundle: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "mhcReferenceBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)

        activityIndicator.show(message: "Loading \(url.lastPathComponent)...", style: .indeterminate)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.activityIndicator.hide() }
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

                self.inspectorController.clearSelection()
                self.inspectorController.updateMHCReferenceBundleDocument(url)
                self.viewerController.clearViewport(
                    statusMessage: "MHC reference bundle — see the Bundle inspector for details."
                )
            }
        }
    }

    func displayGenotypeResultBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "genotypeResultBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

        do {
            let result = try ONTGenotypeResultBundle.loadResult(from: url)
            inspectorController.clearSelection()
            inspectorController.updateGenotypeResultDocument(result)
            if Self.shouldPreviewPrimaryWorkbook(for: result) {
                mainSplitLogger.info(
                    "displayGenotypeResultBundle: Previewing primary workbook for '\(url.lastPathComponent, privacy: .public)' because no haplotyping analysis is present"
                )
                inspectorController.updateGenotypeResultSelection(nil)
                viewerController.displayQuickLookPreview(url: result.artifacts.workbookURL)
                return
            }
            let controller = viewerController.displayGenotypeResult(result)
            controller.onSelectionStateChanged = { [weak self] selection in
                self?.inspectorController.updateGenotypeResultSelection(selection)
            }
            controller.onDisplaySummaryChanged = { [weak self] visibleRows, totalRows, hiddenCells in
                self?.inspectorController.updateGenotypeResultDisplaySummary(
                    visibleRows: visibleRows,
                    totalRows: totalRows,
                    hiddenCells: hiddenCells
                )
            }
            controller.onDisplayStateChanged = { [weak self] state in
                self?.inspectorController.updateGenotypeResultDisplayState(state)
            }
            controller.onAnnotationSidecarChanged = { [weak self] sidecar in
                self?.inspectorController.updateGenotypeAnnotationSidecar(sidecar)
            }
            inspectorController.onGenotypeResultDisplayStateChanged = { [weak controller] state in
                controller?.applyDisplayState(state)
            }
            inspectorController.onGenotypeSampleMetadataImported = { [weak controller] store in
                controller?.applySampleMetadataStore(store)
            }
            inspectorController.genotypeResultDisplaySectionViewModel.onGenotypeHighlightRequested = { [weak controller] request in
                controller?.applyHighlight(request)
            }
            inspectorController.selectionSectionViewModel.onGenotypeHighlightRequested = { [weak controller] request in
                controller?.applyHighlight(request)
            }
            controller.notifySelectionStateIfAvailable()
        } catch {
            mainSplitLogger.warning(
                "displayGenotypeResultBundle: Falling back to workbook preview for '\(url.lastPathComponent, privacy: .public)' after native load failed: \(error.localizedDescription, privacy: .public)"
            )
            guard let workbookURL = Self.genotypeResultWorkbookURL(forBundle: url) else {
                mainSplitLogger.warning("displayGenotypeResultBundle: Missing primary workbook for '\(url.lastPathComponent, privacy: .public)'")
                inspectorController.clearSelection()
                viewerController.showNoSequenceSelected()
                return
            }

            inspectorController.clearSelection()
            viewerController.displayQuickLookPreview(url: workbookURL)
        }
    }

    static func shouldPreviewPrimaryWorkbook(for result: ONTGenotypeResultBundleData) -> Bool {
        result.haplotypeAnalysis == nil
            && FileManager.default.fileExists(atPath: result.artifacts.workbookURL.path)
    }

    func displayTwelveSAmpliconResultBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "twelveSAmpliconResultBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

        do {
            let result = try TwelveSAmpliconResultBundle.loadResult(from: url)
            inspectorController.clearSelection()
            inspectorController.updateTwelveSAmpliconResultDocument(result)
            let controller = viewerController.displayTwelveSAmpliconResult(result)
            controller.onDisplaySummaryChanged = { [weak self] summary in
                self?.inspectorController.updateTwelveSResultDisplaySummary(summary)
            }
            controller.onDisplayStateChanged = { [weak self] state in
                self?.inspectorController.updateTwelveSResultDisplayState(state)
            }
            inspectorController.onTwelveSResultDisplayStateChanged = { [weak controller] state in
                controller?.applyDisplayState(state)
            }
            inspectorController.twelveSResultDisplaySectionViewModel.onExportRequested = { [weak controller] format in
                controller?.presentExport(format: format)
            }
        } catch {
            mainSplitLogger.error(
                "displayTwelveSAmpliconResultBundle: Failed to load '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            inspectorController.clearSelection()
            viewerController.showNoSequenceSelected()
        }
    }

    func displayPhylogeneticTreeBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayPhylogeneticTreeBundle: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "phylogeneticTreeBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)

        activityIndicator.show(message: "Loading \(url.lastPathComponent)...", style: .indeterminate)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.activityIndicator.hide() }
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

                do {
                    self.inspectorController.clearSelection()
                    let bundle = try PhylogeneticTreeBundle.load(from: url)
                    self.inspectorController.updatePhylogeneticTreeDocument(bundle)
                    try self.viewerController.displayPhylogeneticTreeBundle(at: url)
                    if let controller = self.viewerController.phylogeneticTreeViewController {
                        controller.onSelectionStateChanged = { [weak self] state in
                            self?.inspectorController.updatePhylogeneticTreeSelection(state)
                        }
                        controller.notifySelectionStateIfAvailable()
                    }
                } catch {
                    mainSplitLogger.error(
                        "displayPhylogeneticTreeBundle: Failed - \(error.localizedDescription, privacy: .public)"
                    )
                    self.viewerController.clearViewport(statusMessage: "Unable to load tree bundle.")
                }
            }
        }
    }

    /// Display a direct reference bundle opened outside the project sidebar.
    func displayReferenceBundleFromExternalOpen(at url: URL) throws {
        inspectorController.clearSelection()
        try viewerController.displayBundle(at: url)
        inspectorController.updateProvenanceTarget(
            url: url,
            sidebarType: .referenceBundle,
            displayName: url.lastPathComponent
        )
        wireDirectReferenceViewportInspectorUpdates()
    }

    /// Display an MHC amplicon reference bundle (`.lungfishmhcref`) opened outside the
    /// project sidebar (Finder double-click, "Open With", File > Open Recent, drag-to-dock).
    /// The bundle is metadata-only with no viewport, so the viewport is cleared with an
    /// informative status and all details are surfaced in the Bundle inspector tab.
    /// `updateMHCReferenceBundleDocument` sets the `.mhcReferenceBundle` provenance target.
    func displayMHCReferenceBundleFromExternalOpen(at url: URL) {
        inspectorController.clearSelection()
        inspectorController.updateMHCReferenceBundleDocument(url)
        viewerController.clearViewport(
            statusMessage: "MHC reference bundle — see the Bundle inspector for details."
        )
    }

    /// Display a direct reference bundle in the shared list/detail reference viewport.
    func displayReferenceBundleViewportFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayReferenceBundleViewport: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "referenceBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)

        activityIndicator.show(
            message: "Loading \(url.lastPathComponent)...",
            style: .indeterminate
        )

        // Defer execution to the next runloop so the loading indicator paints immediately.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.activityIndicator.hide() }
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

                do {
                    self.inspectorController.clearSelection()
                    let manifest = try BundleManifest.load(from: url)
                    let route = ViewerDisplayRouteFactory.directReferenceBundle(
                        bundleURL: url,
                        manifest: manifest
                    )
                    try self.viewerController.display(route)
                    self.wireDirectReferenceViewportInspectorUpdates()
                    mainSplitLogger.info("displayReferenceBundleViewport: Bundle displayed successfully")
                } catch {
                    mainSplitLogger.error("displayReferenceBundleViewport: Failed - \(error.localizedDescription, privacy: .public)")
                    self.viewerController.clearViewport(statusMessage: "Unable to load reference bundle.")
                }
            }
        }
    }

    func wireDirectReferenceViewportInspectorUpdates() {
        guard let controller = viewerController.referenceBundleViewportController else { return }
        controller.onEmbeddedReferenceBundleLoaded = { [weak self, weak controller] bundle in
            guard let self, let controller else { return }
            self.inspectorController.updateReferenceBundleTrackSections(
                from: bundle,
                applySettings: { payload in
                    controller.applyEmbeddedReadDisplaySettings(payload)
                }
            )
        }
        controller.onSequenceSelectionStateChanged = { [weak self] state in
            self?.inspectorController.updateSequenceRegionSelection(state)
        }
        controller.notifyEmbeddedReferenceBundleLoadedIfAvailable()
        controller.notifySequenceSelectionStateIfAvailable()
    }

    func wireMappingReferenceViewportInspectorUpdates() {
        guard let controller = viewerController.referenceBundleViewportController else { return }
        controller.onEmbeddedReferenceBundleLoaded = { [weak self, weak controller] bundle in
            guard let self, let controller else { return }
            self.inspectorController.updateMappingAlignmentSection(
                from: bundle,
                applySettings: { payload in
                    controller.applyEmbeddedReadDisplaySettings(payload)
                }
            )
        }
        controller.notifyEmbeddedReferenceBundleLoadedIfAvailable()
    }

    func displayAssemblyAnalysisFromSidebar(at url: URL) {
        mainSplitLogger.info("displayAssemblyAnalysis: Opening '\(url.lastPathComponent, privacy: .public)'")
        recordUITestEvent("assembly.display.requested \(url.lastPathComponent)")
        invalidatePendingSelectionDebounce(reason: "display assembly analysis")
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "display assembly analysis")
        cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: "display assembly analysis")

        do {
            let result = try AssemblyResult.load(from: url)
            let provenance = try? AssemblyProvenance.load(from: url)
            inspectorController.clearSelection()
            inspectorController.updateAssemblyDocument(
                result: result,
                provenance: provenance,
                projectURL: sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
            )
            viewerController.displayAssemblyResult(result)
            recordUITestEvent(
                "assembly.display.succeeded tool=\(result.tool.rawValue) contigs=\(result.statistics.contigCount)"
            )
        } catch {
            mainSplitLogger.error(
                "displayAssemblyAnalysis: Failed to load result from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            recordUITestEvent("assembly.display.failed \(url.lastPathComponent) error=\(error.localizedDescription)")
            viewerController.clearViewport(statusMessage: "Unable to load assembly result.")
        }
    }

    func refreshSidebarAndDisplayMappingResult(at url: URL) {
        refreshSidebarAndSelectDerivedURL(url)
        displayMappingAnalysisFromSidebar(at: url)
    }

    func displayMappingAnalysisFromSidebar(at url: URL) {
        mainSplitLogger.info("displayMappingAnalysis: Opening '\(url.lastPathComponent, privacy: .public)'")
        recordUITestEvent("mapping.display.requested \(url.lastPathComponent)")
        invalidatePendingSelectionDebounce(reason: "display mapping analysis")
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "display mapping analysis")
        cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: "display mapping analysis")

        do {
            let result = try MappingResult.load(from: url)
            let provenance = MappingProvenance.load(from: url)
            let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
            let route = ViewerDisplayRouteFactory.mappingResult(
                result,
                resultDirectoryURL: url,
                provenance: provenance
            )
            inspectorController.clearSelection()
            inspectorController.updateProvenanceTarget(
                url: url,
                sidebarType: .analysisResult,
                displayName: url.lastPathComponent
            )
            inspectorController.updateMappingDocument(
                MappingDocumentStateBuilder.build(
                    result: result,
                    provenance: provenance,
                    projectURL: projectURL
                )
            )
            try viewerController.display(route)
            wireMappingReferenceViewportInspectorUpdates()
            recordUITestEvent(
                "mapping.display.succeeded tool=\(result.mapper.rawValue) contigs=\(result.contigs.count)"
            )
        } catch {
            mainSplitLogger.error(
                "displayMappingAnalysis: Failed to load result from \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            recordUITestEvent("mapping.display.failed \(url.lastPathComponent) error=\(error.localizedDescription)")
            viewerController.clearViewport(statusMessage: "Unable to load mapping result.")
        }
    }


    /// Routes a classifier result directory through the DB router.
    ///
    /// - Top-level classifier dir with DB → loads batch view.
    /// - Per-sample subdir with DB → loads batch view, filters picker to that sample.
    /// - Any classifier dir without DB → shows auto-build placeholder.
    /// - Non-classifier dir → logs and no-ops.
}
