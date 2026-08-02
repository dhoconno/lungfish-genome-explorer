// MainSplitViewController+ContentDisplay.swift - Content viewport display routing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishPhylogeneticsUI
import LungfishKit
import LungfishTwelveSUI
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    func displayContent(for item: SidebarItem) {
        if let genotypeController =
            viewerController.genotypeResultViewController,
           genotypeController.deferManualHaplotypeTransition(
            .bundleSwitch,
            mutation: { [weak self] in
                guard let self else { return }
                self.displayContent(for: item)
            }
           ) {
            return
        }
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

        // TaxTriage results all go through the DB-backed classifier router.
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activityIndicator.hide() }
            guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

            do {
                self.inspectorController.clearSelection()
                let bundle = try MultipleSequenceAlignmentBundle.load(from: url)
                self.inspectorController.updateMultipleSequenceAlignmentDocument(bundle)
                // `displayMultipleSequenceAlignmentBundle` reads the primary
                // alignment FASTA off the main actor. A newer sidebar selection
                // may supersede this load while that read is in flight, so the
                // generation guard is threaded in and re-checked on the main
                // actor after the read but before the viewport install — the
                // guard dominates the install, so a stale read commits nothing.
                try await self.viewerController.displayMultipleSequenceAlignmentBundle(at: url) { [weak self] in
                    guard let self else { return false }
                    return self.canCommitDisplayRequest(displayToken, identity: displayIdentity)
                }
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
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

    /// Display an MHC amplicon reference bundle (`.lungfishmhcref`) with its
    /// paired FASTA and haplotype definitions.
    func displayMHCReferenceBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayMHCReferenceBundle: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "mhcReferenceBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)

        activityIndicator.show(message: "Loading \(url.lastPathComponent)...", style: .indeterminate)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activityIndicator.hide() }
            guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

            do {
                // Read the reference FASTA off the main actor; a large reference
                // must not block the UI during display.
                let model = try await MHCReferenceBundleViewportModel.loadAsync(bundleURL: url)
                // A newer sidebar selection may have superseded this load while the
                // FASTA read was in flight; re-check the generation guard before
                // committing the viewport.
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                self.inspectorController.clearSelection()
                self.inspectorController.updateMHCReferenceBundleDocument(url)
                self.viewerController.displayMHCReferenceBundle(model) { [weak self] in
                    guard let self else { return }
                    HaplotypeDefinitionManagerWindowController.show(
                        projectURL: self.sidebarController.currentProjectURL
                            ?? DocumentManager.shared.activeProject?.url,
                        editingBundleURL: url
                    )
                }
            } catch {
                mainSplitLogger.error(
                    "displayMHCReferenceBundle: Failed - \(error.localizedDescription, privacy: .public)"
                )
                self.viewerController.clearViewport(statusMessage: "Unable to load MHC reference bundle.")
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
        let loader = genotypeResultLoader

        genotypeResultLoadTask?.cancel()
        genotypeResultLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await loader(url)
                try Task.checkCancellation()
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                inspectorController.clearSelection()
                inspectorController.updateGenotypeResultDocument(result)
                if Self.shouldPreviewPrimaryWorkbook(for: result) {
                    mainSplitLogger.info(
                        "displayGenotypeResultBundle: Previewing genotype workbook for '\(url.lastPathComponent, privacy: .public)' because no native genotype calls are present"
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
                controller.onAnnotationSidecarChanged = { [weak self, weak controller] sidecar in
                    guard let self,
                          self.viewerController.genotypeResultViewController === controller
                    else {
                        return
                    }
                    self.inspectorController.updateGenotypeAnnotationSidecar(sidecar)
                }
                controller.onMatrixReviewCapabilityChanged = { [weak self] capability in
                    self?.inspectorController.genotypeResultDisplaySectionViewModel
                        .updateMatrixReviewCapability(capability)
                }
                controller.onMatrixVisibilityCapabilityChanged = { [weak self, weak controller] capability in
                    guard let self,
                          self.viewerController.genotypeResultViewController === controller
                    else {
                        return
                    }
                    self.inspectorController.genotypeResultDisplaySectionViewModel
                        .updateMatrixVisibilityCapability(capability)
                }
                controller.onCandidatePersistenceWarningChanged = { [weak self] warning in
                    self?.inspectorController.genotypeResultDisplaySectionViewModel
                        .updateMHCCandidatePersistenceWarning(warning)
                }
                controller.onCurrentWorkbookSyncRequested = { [weak self] request in
                    self?.routeGenotypeCurrentWorkbookRequest(request)
                }
                controller.onAIHaplotypingRequested = { [weak self, weak controller] bundleURL, request in
                    guard let self else { return }
                    guard self.canWriteProjectOutputs(workflowName: request.mode.displayName) else { return }
                    let routeContext = OperationRouteContext(
                        projectURL: self.sidebarController.currentProjectURL,
                        windowStateScope: self.projectSession.windowStateScope
                    )
                    Task { @MainActor [weak self, weak controller] in
                        guard let self else { return }
                        do {
                            try await GenotypeAIHaplotypingExecutionService().run(
                                bundleURL: bundleURL,
                                mode: Self.workflowMode(for: request.mode),
                                routeContext: routeContext
                            )
                            let updated = try await ONTGenotypeResultBundle.loadResultAsync(from: bundleURL)
                            controller?.applyAIHaplotypingCompleted(result: updated)
                            self.inspectorController.updateGenotypeResultDocument(updated)
                            self.sidebarController.requestReloadFromFilesystem()
                        } catch {
                            controller?.applyAIHaplotypingFailed(error)
                            (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
                        }
                    }
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
                inspectorController.genotypeResultDisplaySectionViewModel.onMatrixStyleRequested = { [weak controller] request in
                    controller?.applyMatrixStyle(request)
                }
                inspectorController.genotypeResultDisplaySectionViewModel.onMatrixReviewRequested = { [weak controller] request in
                    controller?.applyMatrixReview(request)
                }
                inspectorController.genotypeResultDisplaySectionViewModel.onMatrixCommentRequested = { [weak controller] request in
                    controller?.editMatrixComment(request)
                }
                inspectorController.genotypeResultDisplaySectionViewModel.onSupportSelectionPreviewChanged = { [weak controller] minimumReads in
                    controller?.setMatrixSupportSelectionPreviewMinimumReads(minimumReads)
                }
                inspectorController.genotypeResultDisplaySectionViewModel.onMatrixVisibilityCommandRequested = { [weak self, weak controller] command in
                    guard let self,
                          self.viewerController.genotypeResultViewController === controller
                    else {
                        return
                    }
                    controller?.performMatrixVisibilityCommand(command)
                }
                inspectorController.selectionSectionViewModel.onGenotypeHighlightRequested = { [weak controller] request in
                    controller?.applyHighlight(request)
                }
                controller.notifyDisplayStateIfAvailable()
                controller.notifySelectionStateIfAvailable()
                controller.notifyMatrixVisibilityCapabilityIfAvailable()
                controller.requestCurrentWorkbookRegistration()
            } catch is CancellationError {
                return
            } catch {
                guard self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                mainSplitLogger.warning(
                    "displayGenotypeResultBundle: Falling back to workbook preview for '\(url.lastPathComponent, privacy: .public)' after native load failed: \(error.localizedDescription, privacy: .public)"
                )
                guard let workbookURL = Self.genotypeResultWorkbookURL(forBundle: url) else {
                    mainSplitLogger.warning("displayGenotypeResultBundle: Missing genotype workbook for '\(url.lastPathComponent, privacy: .public)'")
                    inspectorController.clearSelection()
                    viewerController.showNoSequenceSelected()
                    return
                }

                inspectorController.clearSelection()
                viewerController.displayQuickLookPreview(url: workbookURL)
            }
        }
    }

    func routeGenotypeCurrentWorkbookRequest(
        _ request: GenotypeCurrentWorkbookUIRequest
    ) {
        let key = request.snapshot.bundleURL.standardizedFileURL.path
        nextGenotypeCurrentWorkbookRouteGeneration &+= 1
        let generation = nextGenotypeCurrentWorkbookRouteGeneration
        let action = preferredGenotypeCurrentWorkbookAction(
            pendingGenotypeCurrentWorkbookRoutes[key]?.action,
            request.action
        )
        pendingGenotypeCurrentWorkbookRoutes[key] = PendingGenotypeCurrentWorkbookRoute(
            generation: generation,
            snapshot: request.snapshot,
            action: action,
            routeContext: operationRouteContext
        )

        Task { @MainActor [weak self] in
            do {
                let fingerprint = try await Task.detached {
                    try GenotypeCurrentWorkbookInputFingerprint.make(
                        calls: request.snapshot.calls,
                        includedLoci: request.snapshot.includedLoci,
                        annotationSidecar: request.snapshot.annotationSidecar,
                        candidateArtifacts: request.snapshot.candidateArtifacts,
                        reviewableRowCatalog:
                            request.snapshot.reviewableRowCatalog,
                        reviewableRowCatalogSchemaVersion:
                            request.snapshot.reviewableRowCatalogSchemaVersion,
                        haplotypeProjectionMode:
                            request.snapshot.haplotypeProjectionMode
                    )
                }.value
                guard let self,
                      let pending = self.pendingGenotypeCurrentWorkbookRoutes[key],
                      pending.generation == generation
                else {
                    return
                }
                self.pendingGenotypeCurrentWorkbookRoutes.removeValue(forKey: key)
                self.genotypeCurrentWorkbookCompletionContexts[key] =
                    GenotypeCurrentWorkbookCompletionContext(
                        generation: generation,
                        annotationOnly: pending.snapshot.annotationOnly
                    )
                let bundleURL = pending.snapshot.bundleURL
                let isReadOnly = pending.snapshot.isReadOnly
                let coordinatorRequest = GenotypeCurrentWorkbookSyncCoordinator.Request(
                    bundleURL: bundleURL,
                    calls: pending.snapshot.calls,
                    includedLoci: pending.snapshot.includedLoci,
                    annotationSidecarURL: pending.snapshot.annotationSidecarURL,
                    annotationSidecarData: pending.snapshot.annotationSidecarData,
                    annotationOnly: pending.snapshot.annotationOnly,
                    haplotypeProjectionMode:
                        pending.snapshot.haplotypeProjectionMode,
                    fingerprint: fingerprint,
                    routeContext: pending.routeContext,
                    mayUpdate: self.mayUpdateGenotypeCurrentWorkbook(
                        bundleURL: bundleURL,
                        isReadOnly: isReadOnly
                    ),
                    authorizationRevalidator: { @MainActor [weak self] in
                        guard let self else { return false }
                        return self.mayUpdateGenotypeCurrentWorkbook(
                            bundleURL: bundleURL,
                            isReadOnly: isReadOnly
                        )
                    }
                )
                switch pending.action {
                case .register:
                    await self.genotypeCurrentWorkbookSyncCoordinator.register(
                        coordinatorRequest
                    )
                    self.applyGenotypeCurrentWorkbookSyncPhase(
                        self.genotypeCurrentWorkbookSyncCoordinator.phase(
                            for: coordinatorRequest.bundleURL
                        ),
                        bundleURL: coordinatorRequest.bundleURL
                    )
                case .markDirty:
                    self.genotypeCurrentWorkbookSyncCoordinator.markDirty(
                        coordinatorRequest
                    )
                case .synchronize(let intent):
                    do {
                        _ = try await self.genotypeCurrentWorkbookSyncCoordinator
                            .synchronize(coordinatorRequest, intent: intent)
                    } catch {
                        self.removeGenotypeCurrentWorkbookCompletionContext(
                            for: key,
                            generation: generation
                        )
                        (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
                    }
                }
            } catch {
                guard let self,
                      self.pendingGenotypeCurrentWorkbookRoutes[key]?.generation == generation
                else {
                    return
                }
                self.pendingGenotypeCurrentWorkbookRoutes.removeValue(forKey: key)
                self.removeGenotypeCurrentWorkbookCompletionContext(
                    for: key,
                    generation: generation
                )
                self.applyGenotypeCurrentWorkbookSyncPhase(
                    .failed(error.localizedDescription),
                    bundleURL: request.snapshot.bundleURL
                )
            }
        }
    }

    private func mayUpdateGenotypeCurrentWorkbook(
        bundleURL: URL,
        isReadOnly: Bool
    ) -> Bool {
        let projectSessionAllowsWrites =
            genotypeCurrentWorkbookProjectWriteAuthorizationProvider?()
            ?? !projectSession.isReadOnlyRecommended
        return projectSessionAllowsWrites
            && !isReadOnly
            && FileManager.default.isWritableFile(
                atPath: bundleURL.path
            )
    }

    func prepareGenotypeResultViewForRemoval(
        _ controller: GenotypeResultViewController
    ) {
        controller.requestCurrentWorkbookSyncForBundleSwitch()
        guard controller.hasDeferredMatrixAnnotationMutations else { return }
        let identifier = ObjectIdentifier(controller)
        retainedDeferredGenotypeResultControllers[identifier] = controller
        controller.onDeferredMatrixAnnotationMutationsDrained = {
            [weak self, weak controller] in
            guard let self, let controller else { return }
            self.retainedDeferredGenotypeResultControllers.removeValue(
                forKey: ObjectIdentifier(controller)
            )
        }
        if !controller.hasDeferredMatrixAnnotationMutations {
            retainedDeferredGenotypeResultControllers.removeValue(
                forKey: identifier
            )
        }
    }

    func applyGenotypeCurrentWorkbookSyncPhase(
        _ phase: GenotypeCurrentWorkbookSyncCoordinator.Phase,
        bundleURL: URL
    ) {
        let key = bundleURL.standardizedFileURL.path
        let isTerminal: Bool
        switch phase {
        case .current, .failed:
            isTerminal = true
        case .dirty, .updating, .dirtyWhileUpdating:
            isTerminal = false
        }
        guard let controller = viewerController.genotypeResultViewController,
              controller.currentResultBundleURL?.standardizedFileURL
                == bundleURL.standardizedFileURL
        else {
            if isTerminal {
                cleanupGenotypeCurrentWorkbookTerminalState(
                    for: key,
                    bundleURL: bundleURL
                )
            }
            return
        }
        let uiPhase: GenotypeCurrentWorkbookUIPhase
        switch phase {
        case .current:
            uiPhase = .current
        case .dirty:
            uiPhase = .dirty
        case .updating:
            uiPhase = .updating
        case .dirtyWhileUpdating:
            uiPhase = .dirtyWhileUpdating
        case .failed(let message):
            uiPhase = .failed(message)
        }
        let isReadOnly = controller.currentResultBundleIsReadOnly
        controller.applyCurrentWorkbookSyncPhase(uiPhase, isReadOnly: isReadOnly)
        inspectorController.updateGenotypeCurrentWorkbookSyncState(
            bundleURL: bundleURL,
            phase: uiPhase,
            isReadOnly: isReadOnly
        )
        if phase == .current {
            reloadCompletedGenotypeCurrentWorkbookResult(
                bundleURL: bundleURL,
                controller: controller
            )
        } else if case .failed = phase {
            cleanupGenotypeCurrentWorkbookTerminalState(
                for: key,
                bundleURL: bundleURL
            )
        }
    }

    private func reloadCompletedGenotypeCurrentWorkbookResult(
        bundleURL: URL,
        controller: GenotypeResultViewController
    ) {
        let key = bundleURL.standardizedFileURL.path
        guard let context = genotypeCurrentWorkbookCompletionContexts[key] else {
            return
        }
        let expectedGeneration = context.generation
        let expectedControllerAuthority =
            controller.desiredResultConfigurationAuthority
        guard expectedControllerAuthority.bundleURL?.standardizedFileURL
            == bundleURL.standardizedFileURL else {
            cleanupGenotypeCurrentWorkbookTerminalState(
                for: key,
                bundleURL: bundleURL
            )
            return
        }
        genotypeCurrentWorkbookResultReloadTasks
            .removeValue(forKey: key)?
            .task
            .cancel()
        let loader = genotypeResultLoader
        let reloadID = UUID()
        let reloadTask = Task {
            @MainActor [weak self, weak controller] in
            defer {
                self?.finishGenotypeCurrentWorkbookReload(
                    for: key,
                    reloadID: reloadID,
                    expectedGeneration: expectedGeneration
                )
            }
            do {
                let updated = try await loader(bundleURL)
                try Task.checkCancellation()
                guard let self,
                      let controller,
                      self.genotypeCurrentWorkbookCompletionContexts[key]?
                        .generation == expectedGeneration,
                      self.viewerController.genotypeResultViewController
                        === controller,
                      controller.ownsDesiredResultConfiguration(
                        expectedControllerAuthority
                      ),
                      updated.bundleURL.standardizedFileURL
                        == bundleURL.standardizedFileURL
                else {
                    return
                }
                controller.applyCurrentWorkbookUpdateCompleted(
                    result: updated,
                    annotationOnly: context.annotationOnly
                )
                self.inspectorController.updateGenotypeResultDocument(updated)
                controller.notifyMatrixVisibilityCapabilityIfAvailable()
                self.sidebarController.requestReloadFromFilesystem()
            } catch is CancellationError {
                return
            } catch {
                mainSplitLogger.warning(
                    "Could not reload completed current workbook result for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        genotypeCurrentWorkbookResultReloadTasks[key] =
            GenotypeCurrentWorkbookReloadTask(
                id: reloadID,
                task: reloadTask
            )
    }

    private func finishGenotypeCurrentWorkbookReload(
        for key: String,
        reloadID: UUID,
        expectedGeneration: UInt64
    ) {
        guard genotypeCurrentWorkbookResultReloadTasks[key]?.id == reloadID else {
            return
        }
        genotypeCurrentWorkbookResultReloadTasks.removeValue(forKey: key)
        removeGenotypeCurrentWorkbookCompletionContext(
            for: key,
            generation: expectedGeneration
        )
    }

    private func removeGenotypeCurrentWorkbookCompletionContext(
        for key: String,
        generation: UInt64
    ) {
        guard genotypeCurrentWorkbookCompletionContexts[key]?.generation
                == generation
        else {
            return
        }
        genotypeCurrentWorkbookCompletionContexts.removeValue(forKey: key)
    }

    private func cleanupGenotypeCurrentWorkbookTerminalState(
        for key: String,
        bundleURL: URL
    ) {
        genotypeCurrentWorkbookResultReloadTasks
            .removeValue(forKey: key)?
            .task
            .cancel()
        genotypeCurrentWorkbookCompletionContexts.removeValue(forKey: key)
        let activeController = viewerController.genotypeResultViewController
        let releasableControllerIDs: [ObjectIdentifier] =
            retainedDeferredGenotypeResultControllers.compactMap { entry in
                let (identifier, retainedController) = entry
                guard retainedController !== activeController,
                      retainedController.currentResultBundleURL?
                        .standardizedFileURL
                        == bundleURL.standardizedFileURL,
                      !retainedController.hasDeferredMatrixAnnotationMutations
                else {
                    return nil
                }
                return identifier
            }
        for identifier in releasableControllerIDs {
            retainedDeferredGenotypeResultControllers.removeValue(
                forKey: identifier
            )
        }
    }

    private func preferredGenotypeCurrentWorkbookAction(
        _ lhs: GenotypeCurrentWorkbookUIRequest.Action?,
        _ rhs: GenotypeCurrentWorkbookUIRequest.Action
    ) -> GenotypeCurrentWorkbookUIRequest.Action {
        guard let lhs else { return rhs }
        func rank(_ action: GenotypeCurrentWorkbookUIRequest.Action) -> Int {
            switch action {
            case .register:
                return 0
            case .markDirty:
                return 1
            case .synchronize(.automaticIdle):
                return 2
            case .synchronize(.bundleSwitch):
                return 3
            case .synchronize(.updateAndView):
                return 4
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }

    static func shouldPreviewPrimaryWorkbook(for result: ONTGenotypeResultBundleData) -> Bool {
        result.haplotypeAnalysis == nil
            && !result.hasNativeGenotypeMatrixContent
            && FileManager.default.fileExists(atPath: result.artifacts.workbookURL.path)
    }

    private static func workflowMode(for mode: GenotypeAIHaplotypingUIMode) -> AIHaplotypingPromptMode {
        switch mode {
        case .aiDiscovery: return .aiDiscovery
        case .aiRefinement: return .aiRefinement
        }
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
            let result = try TwelveSAmpliconResultBundle.loadResult(from: url, loadUnresolvedSequences: false)
            inspectorController.clearSelection()
            inspectorController.updateTwelveSAmpliconResultDocument(result)
            let controller = viewerController.displayTwelveSAmpliconResult(result)
            let knownSampleIDs = Set(result.samples.map(\.sampleID))
            let metadataStore = SampleMetadataStore.load(from: result.bundleURL, knownSampleIds: knownSampleIDs)
            metadataStore?.wireAutosave(bundleURL: result.bundleURL)
            controller.applyMetadataStore(metadataStore)
            inspectorController.updateTwelveSImportedSampleMetadata(metadataStore)
            let sampleEntries = result.samples.map {
                TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
            }
            let strippedPrefix = ClassifierSamplePickerView.commonPrefix(of: sampleEntries.map(\.displayName))
            if let pickerState = controller.inspectorSamplePickerState {
                let inspectorEntries: [any ClassifierSampleEntry] = sampleEntries
                inspectorController.updateClassifierSampleState(
                    pickerState: pickerState,
                    entries: inspectorEntries,
                    strippedPrefix: strippedPrefix,
                    metadata: metadataStore,
                    attachments: BundleAttachmentStore(bundleURL: result.bundleURL)
                )
            }
            controller.onDisplaySummaryChanged = { [weak self] summary in
                self?.inspectorController.updateTwelveSResultDisplaySummary(summary)
            }
            controller.onDisplayStateChanged = { [weak self] state in
                self?.inspectorController.updateTwelveSResultDisplayState(state)
            }
            controller.onSelectedRowDetailChanged = { [weak self] payload in
                self?.inspectorController.updateTwelveSDetail(payload)
            }
            controller.onMetadataImportRequested = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.presentTwelveSMetadataImport(
                    into: controller,
                    knownSampleIDs: knownSampleIDs,
                    bundleURL: result.bundleURL
                )
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
    /// `updateMHCReferenceBundleDocument` sets the `.mhcReferenceBundle` provenance target.
    func displayMHCReferenceBundleFromExternalOpen(at url: URL) {
        // External open is a one-shot (Finder double-click / Open Recent), not a
        // sidebar selection that a later selection can supersede, so no display
        // generation guard is needed. Unlike the sidebar path (which uses
        // `loadAsync` because rapid navigation can spam large reference reads),
        // this one-shot path reads synchronously to match its non-MHC sibling
        // `displayReferenceBundleFromExternalOpen` and to keep the inspector and
        // viewport populated together on return.
        do {
            let model = try MHCReferenceBundleViewportModel.load(bundleURL: url)
            inspectorController.clearSelection()
            inspectorController.updateMHCReferenceBundleDocument(url)
            viewerController.displayMHCReferenceBundle(model) { [weak self] in
                guard let self else { return }
                HaplotypeDefinitionManagerWindowController.show(
                    projectURL: self.sidebarController.currentProjectURL
                        ?? DocumentManager.shared.activeProject?.url,
                    editingBundleURL: url
                )
            }
        } catch {
            mainSplitLogger.error(
                "displayMHCReferenceBundleFromExternalOpen: Failed - \(error.localizedDescription, privacy: .public)"
            )
            viewerController.clearViewport(statusMessage: "Unable to load MHC reference bundle.")
        }
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

    // MARK: - 12S sample-metadata import

    /// Presents the shared CSV/TSV metadata-import panel for the 12S viewport
    /// and applies the parsed store as per-sample matrix columns. Reuses the
    /// same panel + scanner + import service NVD/genotype use.
    func presentTwelveSMetadataImport(
        into controller: TwelveSAmpliconResultViewController,
        knownSampleIDs: Set<String>,
        bundleURL: URL
    ) {
        guard !knownSampleIDs.isEmpty, let window = view.window else { return }
        let panel = FeatureFilePanelFactory.inspectorTextMetadataImportPanel()
        panel.beginSheetModal(for: window) { [weak self, weak controller] response in
            guard let self, let controller, response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.finishTwelveSMetadataImport(
                        from: url, into: controller, knownSampleIDs: knownSampleIDs, bundleURL: bundleURL)
                }
            }
        }
    }

    private func finishTwelveSMetadataImport(
        from url: URL,
        into controller: TwelveSAmpliconResultViewController,
        knownSampleIDs: Set<String>,
        bundleURL: URL
    ) {
        func alert(_ title: String, _ message: String) {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            if let window = view.window { a.beginSheetModal(for: window) }
        }

        guard let data = try? Data(contentsOf: url) else {
            alert("Metadata Import Failed", "The selected metadata file could not be read.")
            return
        }
        guard let scanResult = try? SampleMetadataStore.scanForSampleColumn(
            csvData: data, knownSampleIds: knownSampleIDs),
              let best = scanResult.bestColumn else {
            alert("No Sample Column Found",
                  "No column in this file matched the bundle's sample IDs. Include a column with sample names.")
            return
        }
        do {
            let result = try SampleMetadataBundleImportService().importMetadata(
                data: data,
                sourceURL: url,
                scanResult: scanResult,
                sampleColumnIndex: best.index,
                knownSampleIds: knownSampleIDs,
                bundleURL: bundleURL
            )
            controller.applyMetadataStore(result.store)
            inspectorController.updateTwelveSImportedSampleMetadata(result.store)
            if let pickerState = controller.inspectorSamplePickerState {
                inspectorController.updateClassifierSampleState(
                    pickerState: pickerState,
                    entries: controller.inspectorSampleEntries,
                    strippedPrefix: controller.inspectorSampleStrippedPrefix,
                    metadata: result.store,
                    attachments: BundleAttachmentStore(bundleURL: bundleURL)
                )
            }
        } catch {
            alert("Metadata Import Failed", error.localizedDescription)
        }
    }
}
