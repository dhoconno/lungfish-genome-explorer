// MainSplitViewController+MultiDocument.swift - Project session and document coordination
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    /// External opens and sidebar reads share the same publication gate. The
    /// session loader registers only after the originating display is still current.
    func loadExternalDocument(at url: URL) {
        let identity = contentSelectionIdentity(url: url, kind: "externalDocument")
        let token = beginDisplayRequest(identity: identity)
        let session = projectSession
        let generation = session.documentGeneration
        let loader = externalDocumentLoader
        externalDocumentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await session.loadAndPublishDocument(at: url, loader: loader,
                canPublish: { [weak self] in
                    guard let self else { return false }
                    return session.documentGeneration == generation
                        && self.canCommitDisplayRequest(token, identity: identity)
                },
                publish: { [weak self] document in
                    guard let self else { return }
                    self.inspectorController.clearSelection()
                    self.inspectorController.activeContentSelectionIdentity = identity
                    self.viewerController.displayDocument(document)
                },
                failure: { [weak self] error in
                    guard let self else { return }
                    self.inspectorController.clearSelection()
                    self.viewerController.clearViewport(statusMessage: "Unable to load \(url.lastPathComponent): \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "Failed to Open File"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    if let window = self.view.window { alert.beginSheetModal(for: window) }
                },
                loading: { [weak self] active in
                    guard let self else { return }
                    if active { self.viewerController.showProgress("Loading \(url.lastPathComponent)...") }
                    else { self.viewerController.hideProgress() }
                })
            if self.canCommitDisplayRequest(token, identity: identity) { self.externalDocumentLoadTask = nil }
        }
    }

    func loadProjectDocument(_ document: LoadedDocument) {
        let identity = contentSelectionIdentity(url: document.url, kind: "projectSequence",
            resultID: document.projectSequenceID?.uuidString)
        let token = beginDisplayRequest(identity: identity)
        viewerController.showProgress("Loading \(document.name)...")
        externalDocumentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.canCommitDisplayRequest(token, identity: identity) {
                    self.viewerController.hideProgress()
                    self.externalDocumentLoadTask = nil
                }
            }
            do {
                guard let hydrated = try await self.projectSession.hydrateProjectDocument(document, canPublish: { [weak self] in
                    self?.canCommitDisplayRequest(token, identity: identity) == true
                }), self.canCommitDisplayRequest(token, identity: identity) else { return }
                self.inspectorController.clearSelection()
                self.inspectorController.activeContentSelectionIdentity = identity
                self.viewerController.displayDocument(hydrated)
            } catch {
                guard self.canCommitDisplayRequest(token, identity: identity), !(error is CancellationError) else { return }
                self.inspectorController.clearSelection()
                self.viewerController.clearViewport(statusMessage: "Unable to load \(document.name): \(error.localizedDescription)")
            }
        }
    }

    /// Handles multiple sidebar items being selected.
    ///
    /// This method collects sequences from all selected documents and displays them
    /// stacked in the viewer using multi-sequence support.
    ///
    /// - Parameter items: Array of selected sidebar items
    func handleMultipleItemsSelected(_ items: [SidebarItem]) {
        let identity = ContentSelectionIdentity(url: nil, kind: "multipleDocuments",
            resultID: items.compactMap { $0.url?.standardizedFileURL.path }.joined(separator: "\n"),
            windowID: windowStateScope.id)
        let token = beginDisplayRequest(identity: identity)
        let projectGeneration = projectSession.documentGeneration
        // Filter to only sequence-type items that can be displayed together
        // in the collection view.
        let displayableItems = items.filter { item in
            item.type == .sequence || item.type == .annotation || item.type == .alignment
        }

        // Disclosure (task E2 / AS5): a mixed-type selection silently drops
        // every non-displayable item with zero indication of what was
        // excluded. We can't put a modal alert on every selection change —
        // that would fire on every arrow-key/click multi-select — so this
        // logs the excluded items at .info (not .debug) with their types and
        // count, giving support/QA an audit trail, and (see below) makes
        // sure an empty surviving subset clears the viewport instead of
        // leaving stale content on screen.
        if displayableItems.count != items.count {
            let excludedItems = items.filter { item in
                !(item.type == .sequence || item.type == .annotation || item.type == .alignment)
            }
            let excludedDescription = excludedItems
                .map { "\($0.title) (\($0.type))" }
                .joined(separator: ", ")
            mainSplitLogger.info(
                "handleMultipleItemsSelected: Excluded \(excludedItems.count) non-displayable item(s) from a \(items.count)-item selection: [\(excludedDescription, privacy: .public)]"
            )
        }

        guard !displayableItems.isEmpty else {
            mainSplitLogger.info(
                "handleMultipleItemsSelected: No displayable items in a \(items.count)-item selection; clearing viewport"
            )
            // Previously this left the viewer showing whatever was
            // displayed before the selection changed — a stale, misleading
            // state. Explicitly clear to "No sequence selected" instead.
            cancelFASTQLoadIfNeeded(hideProgress: true, reason: "multi-select with no displayable items")
            viewerController.clearBundleDisplay()
            viewerController.hideFASTACollectionView()
            viewerController.hideCollectionBackButton()
            viewerController.showNoSequenceSelected()
            inspectorController.clearSelection()
            return
        }

        let itemNames = displayableItems.map { $0.title }.joined(separator: ", ")
        mainSplitLogger.info("handleMultipleItemsSelected: Processing \(displayableItems.count) items: [\(itemNames, privacy: .public)]")

        // Cancel any in-flight FASTQ load since we are switching to multi-select
        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "multi-select")

        // Clear bundle display so collection view is unobstructed
        viewerController.clearBundleDisplay()
        viewerController.hideFASTACollectionView()
        viewerController.hideCollectionBackButton()

        // Categorize documents: fully loaded, placeholders (need lazy load), or unregistered
        var fullyLoadedDocuments: [LoadedDocument] = []
        var catalogDocuments: [LoadedDocument] = []
        var placeholderDocuments: [(LoadedDocument, URL, DocumentType)] = []
        var unregisteredURLs: [(URL, DocumentType)] = []

        for item in displayableItems {
            if let documentID = item.userInfo["documentID"].flatMap(UUID.init(uuidString:)),
               let catalog = projectSession.documents.first(where: { $0.id == documentID && $0.projectSequenceID != nil }) {
                catalogDocuments.append(catalog)
                continue
            }
            if let url = item.url {
                if let existingDoc = projectSession.documents.first(where: { $0.projectSequenceID == nil && $0.url == url }) {
                    // Check if fully loaded
                    let isFullyLoaded = !existingDoc.sequences.isEmpty || !existingDoc.annotations.isEmpty
                    if isFullyLoaded {
                        fullyLoadedDocuments.append(existingDoc)
                    } else if let docType = DocumentType.detect(from: url) {
                        placeholderDocuments.append((existingDoc, url, docType))
                    } else {
                        // AS36 (task E4): DocumentType.detect returning nil
                        // (unrecognized/renamed/corrupted extension) used to
                        // drop the item with zero trace, even in debug logs.
                        mainSplitLogger.info(
                            "handleMultipleItemsSelected: Dropped '\(item.title, privacy: .public)' - DocumentType.detect returned nil for \(url.lastPathComponent, privacy: .public)"
                        )
                    }
                } else if let docType = DocumentType.detect(from: url) {
                    unregisteredURLs.append((url, docType))
                } else {
                    mainSplitLogger.info(
                        "handleMultipleItemsSelected: Dropped '\(item.title, privacy: .public)' - DocumentType.detect returned nil for \(url.lastPathComponent, privacy: .public)"
                    )
                }
            } else if let documentID = item.userInfo["documentID"].flatMap(UUID.init(uuidString:)),
                      let doc = projectSession.documents.first(where: { $0.id == documentID }) {
                fullyLoadedDocuments.append(doc)
            }
        }

        let needsLoading = !catalogDocuments.isEmpty || !placeholderDocuments.isEmpty || !unregisteredURLs.isEmpty

        // If we have documents to load, do it asynchronously
        if needsLoading {
            multiDocumentLoadTask?.cancel()
            multiDocumentLoadTask = nil
            let generation = selectionGeneration

            // Use a regular Task (not detached) to maintain MainActor isolation
            multiDocumentLoadTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                let totalToLoad = catalogDocuments.count + placeholderDocuments.count + unregisteredURLs.count
                self.viewerController.showProgress("Loading \(totalToLoad) documents...")

                // Start with already-loaded documents
                var loadedDocs = fullyLoadedDocuments

                let selectedCatalogIDs = Set(catalogDocuments.map(\.id))
                for document in catalogDocuments {
                    do {
                        guard let hydrated = try await self.projectSession.hydrateProjectDocument(document, keeping: selectedCatalogIDs, canPublish: {
                            self.selectionGeneration == generation && self.projectSession.documentGeneration == projectGeneration
                                && self.canCommitDisplayRequest(token, identity: identity)
                        }) else { return }
                        loadedDocs.append(hydrated)
                    } catch {
                        guard !Task.isCancelled, self.canCommitDisplayRequest(token, identity: identity) else { return }
                        mainSplitLogger.warning("Selected project sequence failed to load: \(error.localizedDescription)")
                    }
                }

                // Load placeholder documents via DocumentLoader
                for (existingDoc, url, docType) in placeholderDocuments {
                    guard !Task.isCancelled, self.selectionGeneration == generation,
                          self.projectSession.documentGeneration == projectGeneration,
                          self.canCommitDisplayRequest(token, identity: identity) else {
                        mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before lazy load")
                        return
                    }

                    do {
                        let result = try await DocumentLoader.loadFile(at: url, type: docType)
                        guard !Task.isCancelled, self.selectionGeneration == generation,
                          self.projectSession.documentGeneration == projectGeneration,
                          self.canCommitDisplayRequest(token, identity: identity) else {
                            mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load after lazy load")
                            return
                        }
                        existingDoc.sequences = result.sequences
                        existingDoc.annotations = result.annotations
                        loadedDocs.append(existingDoc)
                        self.sidebarController.refreshItem(for: url)
                        mainSplitLogger.debug("handleMultipleItemsSelected: Lazy loaded '\(existingDoc.name, privacy: .public)'")
                    } catch {
                        mainSplitLogger.error("handleMultipleItemsSelected: Failed to lazy load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                // Load unregistered documents via DocumentManager
                for (url, _) in unregisteredURLs {
                    guard !Task.isCancelled, self.selectionGeneration == generation,
                          self.projectSession.documentGeneration == projectGeneration,
                          self.canCommitDisplayRequest(token, identity: identity) else {
                        mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before document load")
                        return
                    }

                    do {
                        let document = try await DocumentManager.shared.readDocument(at: url)
                        guard !Task.isCancelled, self.selectionGeneration == generation,
                          self.projectSession.documentGeneration == projectGeneration,
                          self.canCommitDisplayRequest(token, identity: identity) else {
                            mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load after document load")
                            return
                        }
                        self.projectSession.registerDocument(document, makeActive: false)
                        DocumentManager.shared.refreshMirror(ifOwnedBy: self.projectSession)
                        loadedDocs.append(document)
                        mainSplitLogger.debug("handleMultipleItemsSelected: Loaded '\(document.name, privacy: .public)'")
                    } catch {
                        mainSplitLogger.error("handleMultipleItemsSelected: Failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                guard !Task.isCancelled, self.selectionGeneration == generation,
                          self.projectSession.documentGeneration == projectGeneration,
                          self.canCommitDisplayRequest(token, identity: identity) else {
                    mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before collection display")
                    return
                }

                self.viewerController.hideProgress()
                self.multiDocumentLoadTask = nil

                if self.hasActiveSidebarChildViewport {
                    mainSplitLogger.info("handleMultipleItemsSelected: Skipping collection display — active child viewport already present")
                    return
                }

                // Display combined sequences from all documents in the collection view
                self.displayMultiDocumentCollection(loadedDocs)
            }
        } else if !fullyLoadedDocuments.isEmpty {
            // All documents already loaded, display immediately
            displayMultiDocumentCollection(fullyLoadedDocuments)
        }
    }

    /// Combines sequences from multiple documents and displays them in a
    /// ``FASTACollectionViewController`` with source file attribution.
    ///
    /// Each sequence is tagged with the name of the document it came from,
    /// allowing the user to see the origin of every sequence in the collection.
    ///
    /// - Parameter documents: The loaded documents to combine.
    func displayMultiDocumentCollection(_ documents: [LoadedDocument]) {
        guard !documents.isEmpty else {
            mainSplitLogger.warning("displayMultiDocumentCollection: No documents provided")
            return
        }

        var allSequences: [LungfishCore.Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []
        var sourceNames: [UUID: String] = [:]

        for document in documents {
            let sourceName = document.name
            for seq in document.sequences {
                sourceNames[seq.id] = sourceName
            }
            allSequences.append(contentsOf: document.sequences)
            allAnnotations.append(contentsOf: document.annotations)
            mainSplitLogger.debug("displayMultiDocumentCollection: Added \(document.sequences.count) sequences from '\(document.name, privacy: .public)'")
        }

        mainSplitLogger.info("displayMultiDocumentCollection: Total \(allSequences.count) sequences from \(documents.count) documents, \(allAnnotations.count) annotations")

        guard !allSequences.isEmpty else {
            mainSplitLogger.warning("displayMultiDocumentCollection: No sequences found in any document")
            return
        }

        viewerController.displayFASTACollection(
            sequences: allSequences,
            annotations: allAnnotations,
            sourceNames: sourceNames,
            durableSourceURLs: documents.map(\.url)
        )
        recordUITestEvent("viewport.collection.displayed sequences=\(allSequences.count)")
        mainSplitLogger.info("displayMultiDocumentCollection: Displayed collection with \(allSequences.count) sequences from \(documents.count) files")
    }

    @objc func handleDocumentLoaded(_ notification: Notification) {
        guard notification.userInfo?["sessionID"] as? UUID == projectSession.id,
              let document = notification.userInfo?["document"] as? LoadedDocument,
              projectSession.documents.contains(where: { $0.id == document.id }) else { return }
        DocumentManager.shared.refreshMirror(ifOwnedBy: projectSession)

        mainSplitLogger.info("handleDocumentLoaded: Document '\(document.name, privacy: .public)' was loaded")

        // With the filesystem-backed sidebar model:
        // - Files inside the project are shown via FileSystemWatcher (no manual add needed)
        // - Files outside the project can optionally be shown in "Open Documents"
        // Only outside-project files are added to Open Documents; project files
        // are surfaced by FileSystemWatcher.
        if let projectURL = sidebarController.currentProjectURL {
            if ProjectSession.contains(document.url, in: projectURL) {
                // File is inside project - FileSystemWatcher will handle sidebar refresh
                mainSplitLogger.debug("handleDocumentLoaded: File is inside project, sidebar updated via FileSystemWatcher")
                return
            }
        }

        // File is outside project - add to "Open Documents" section (legacy behavior)
        sidebarController.addLoadedDocument(document,
            select: notification.userInfo?["makeActive"] as? Bool ?? false, notify: false)
    }

    @objc func handleProjectOpened(_ notification: Notification) {
        // In multi-window mode, only the active main window should react to
        // DocumentManager's global project-opened notification.
        if notification.userInfo?["sessionID"] as? UUID != projectSession.id {
            mainSplitLogger.debug("handleProjectOpened: Ignoring notification for non-active window")
            return
        }

        guard let project = notification.userInfo?["project"] as? ProjectFile else {
            mainSplitLogger.warning("handleProjectOpened: No project in notification")
            return
        }

        guard projectSession.project === project else { return }
        applyProjectSessionState()
    }

    public func applyProjectSessionState(restoring snapshot: ProjectWindowSnapshot? = nil) {
        invalidateDisplayRequest()
        guard let project = projectSession.project else {
            sidebarController.closeProject()
            viewerController?.showNoSequenceSelected()
            onProjectOpenWarningStateChanged?(projectSession.openWarningState)
            return
        }

        let projectName = project.url.deletingPathExtension().lastPathComponent
        view.window?.title = "\(projectName) - \(LungfishAppIdentity.current.fullName)"
        sidebarController.openProject(at: project.url, asyncScan: true)
        sidebarController.setProjectCatalog(projectSession.documents)

        if let firstDoc = projectSession.activeDocument ?? projectSession.documents.first {
            if firstDoc.projectSequenceID != nil { loadProjectDocument(firstDoc) }
            else { viewerController?.displayDocument(firstDoc) }
        } else {
            viewerController?.showNoSequenceSelected()
        }

        onProjectOpenWarningStateChanged?(projectSession.openWarningState)

        if let snapshot { applyProjectWindowSnapshot(snapshot) }
    }

    /// One restoration authority for accepted native and filesystem-backed roots.
    func applyProjectWindowSnapshot(_ snapshot: ProjectWindowSnapshot) {
        sidebarController.applyRestoredState(
            selectedURL: snapshot.selectedSidebarURL,
            expandedURLs: snapshot.expandedSidebarURLs,
            searchText: snapshot.sidebarSearchText
        )
        setSidebarVisible(!snapshot.sidebarCollapsed, animated: false)
        setInspectorVisible(!snapshot.inspectorCollapsed, animated: false, source: "window-state-restore")
        applyRestoredPaneWidths(
            sidebarWidth: snapshot.sidebarWidth,
            inspectorWidth: snapshot.inspectorWidth
        )
        if let tab = snapshot.inspectorTab {
            inspectorController?.restoreSelectedTabIdentifier(tab)
        }
        if let content = snapshot.activeContent {
            restoreActiveContentState(content)
        }
    }

    func restoreActiveContentState(_ state: RestorableContentState) {
        guard let url = state.url else { return }
        let storedID = state.payload["projectSequenceID"].flatMap(UUID.init(uuidString:))
        let restoredDocument = projectSession.documents.first { document in
            if let storedID { return document.projectSequenceID == storedID }
            return state.kind != "projectSequence" && document.url.standardizedFileURL == url.standardizedFileURL
                && (state.payload["sourceKind"] != "external" || document.projectSequenceID == nil)
        }
        if let document = restoredDocument {
            if document.projectSequenceID != nil { loadProjectDocument(document) }
            else { viewerController?.displayDocument(document) }
            projectSession.setActiveDocument(document)
            DocumentManager.shared.refreshMirror(ifOwnedBy: projectSession)
            return
        }
        if state.kind == "projectSequence" {
            viewerController?.clearViewport(statusMessage: "Saved project sequence is unavailable")
            inspectorController?.clearSelection()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            viewerController?.restoreContentState(state)
            return
        }

        switch url.pathExtension.lowercased() {
        case "lungfishref":
            displayReferenceBundleViewportFromSidebar(at: url)
        case MultipleSequenceAlignmentBundle.directoryExtension:
            displayMultipleSequenceAlignmentBundleFromSidebar(at: url)
        case MHCAmpliconReferenceBundle.directoryExtension:
            displayMHCReferenceBundleFromSidebar(at: url)
        case "lungfishtree":
            displayPhylogeneticTreeBundleFromSidebar(at: url)
        case FASTQBundle.directoryExtension:
            loadFASTQDatasetInBackground(sourceURL: url)
        case TwelveSAmpliconResultBundle.directoryExtension:
            displayTwelveSAmpliconResultBundleFromSidebar(at: url)
        default:
            loadGenomicsFileInBackground(url: url)
        }
    }

    func applyRestoredPaneWidths(sidebarWidth: Double?, inspectorWidth: Double?) {
        guard sidebarWidth != nil || inspectorWidth != nil else { return }
        withProgrammaticShellResizeSuppression {
            ensureShellWidthConstraints()

            if let sidebarWidth, !sidebarItem.isCollapsed {
                let width = min(max(CGFloat(sidebarWidth), sidebarMinWidth), sidebarMaxWidth)
                sidebarWidthCoordinator.noteProgrammaticWidth(width)
                sidebarWidthConstraint?.constant = width
                shellLayoutCoordinator.recordUserSidebarWidth(width)
            }

            if let inspectorWidth, !inspectorItem.isCollapsed {
                let width = min(max(CGFloat(inspectorWidth), inspectorMinWidth), inspectorMaxWidth)
                inspectorWidthConstraint?.constant = width
                shellLayoutCoordinator.recordUserInspectorWidth(width)
            }

            splitView.adjustSubviews()
            view.layoutSubtreeIfNeeded()
        }
        sidebarWidthCoordinator.finishProgrammaticWidth()
    }

    func canWriteProjectOutputs(workflowName: String) -> Bool {
        guard projectSession.isReadOnlyRecommended else { return true }
        ProjectWriteGatePresenter.presentBlockedWrite(workflowName: workflowName, on: view.window)
        return false
    }

    public func captureProjectWindowSnapshot(
        id: UUID,
        projectURL: URL,
        windowOrdinal: Int,
        windowOrder: Int,
        windowTitleSuffix: String?,
        frame: CodableWindowFrame?
    ) -> ProjectWindowSnapshot {
        var activeContent = viewerController?.restorableContentState()
        // A pending native hydration has selected a source even while the old
        // viewport remains visible. Persist that existing display identity so
        // recovery cannot turn the previous rendering into the new selection.
        if let identity = activeContentSelectionIdentity, identity.kind == "projectSequence",
           let sequenceID = identity.resultID.flatMap(UUID.init(uuidString:)),
           let selected = projectSession.documents.first(where: { $0.projectSequenceID == sequenceID }),
           activeContent?.payload["projectSequenceID"] != sequenceID.uuidString {
            activeContent = RestorableContentState(kind: "projectSequence", url: selected.url,
                payload: ["projectSequenceID": sequenceID.uuidString])
        }
        return ProjectWindowSnapshot(
            id: id,
            projectURL: projectURL,
            windowOrdinal: windowOrdinal,
            windowOrder: windowOrder,
            windowTitleSuffix: windowTitleSuffix,
            frame: frame,
            isFullScreen: view.window?.styleMask.contains(.fullScreen) == true,
            selectedSidebarURL: sidebarController.selectedFileURL,
            expandedSidebarURLs: sidebarController.expandedItemURLsForPersistence(),
            sidebarSearchText: sidebarController.searchTextForPersistence(),
            activeContent: activeContent,
            inspectorTab: inspectorController?.restorableSelectedTabIdentifier(),
            sidebarCollapsed: sidebarItem.isCollapsed,
            inspectorCollapsed: inspectorItem.isCollapsed,
            sidebarWidth: sidebarWidthConstraint.map { Double($0.constant) },
            inspectorWidth: inspectorWidthConstraint.map { Double($0.constant) },
            operationsPanelFilter: nil,
            operationsPanelVisible: false
        )
    }

    @objc func handleSidebarFileDropped(_ notification: Notification) {
        mainSplitLogger.info("handleSidebarFileDropped: Notification received!")
        guard shouldAcceptScopedNotification(notification) else {
            mainSplitLogger.debug("handleSidebarFileDropped: Ignoring drop notification from another project window scope")
            return
        }
        guard shouldHandleSidebarFileDropNotification(from: notification.object) else {
            mainSplitLogger.debug("handleSidebarFileDropped: Ignoring drop notification from another project window")
            return
        }

        // Support both new "urls" array format and legacy single "url" format
        let allURLs: [URL]
        if let urls = notification.userInfo?["urls"] as? [URL] {
            allURLs = urls
        } else if let url = notification.userInfo?["url"] as? URL {
            allURLs = [url]
        } else {
            mainSplitLogger.warning("handleSidebarFileDropped: No URLs in notification userInfo")
            return
        }
        guard canWriteProjectOutputs(workflowName: "File import") else {
            let requestID = notification.userInfo?["requestID"] as? String
            for url in allURLs {
                NotificationCenter.default.post(
                    name: .sidebarFileDropCompleted,
                    object: self,
                    userInfo: [
                        "requestID": requestID ?? "",
                        "url": url,
                        "success": false,
                        NotificationUserInfoKey.windowStateScope: windowStateScope
                    ]
                )
            }
            return
        }
        let requestID = notification.userInfo?["requestID"] as? String

        mainSplitLogger.info("handleSidebarFileDropped: Processing \(allURLs.count) dropped file(s)")

        // Get project URL from either the sidebar (new model) or DocumentManager (legacy)
        guard let projectURL = projectSession.projectURL ?? sidebarController.currentProjectURL else {
            let message = "Open a project before importing files."
            for url in allURLs {
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: message)
            }
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = "No Project Open"
                alert.informativeText = message
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
            return
        }

        let zipImportBatch: LGEZipImportBatch
        do {
            zipImportBatch = try LGEZipImportResolver().resolve(urls: allURLs, projectURL: projectURL)
        } catch {
            let errorMessage = error.localizedDescription
            for url in allURLs {
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
            }
            return
        }

        for failure in zipImportBatch.failures {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: failure.sourceURL,
                success: false,
                error: failure.message
            )
        }

        let importPlan = makeSidebarImportPlan(for: zipImportBatch.sourceURLs)
        let sourceURLs = importPlan.sourceURLs

        mainSplitLogger.info(
            "handleSidebarFileDropped: Expanded to \(sourceURLs.count) import source(s); autoDisplay=\(importPlan.shouldAutoDisplayImportedContent)"
        )

        guard !sourceURLs.isEmpty else {
            mainSplitLogger.warning("handleSidebarFileDropped: No importable sources found after expansion")
            zipImportBatch.cleanup()
            return
        }

        // Determine destination - use the new filesystem-backed project URL
        let destinationItem = notification.userInfo?["destination"] as? SidebarItem

        // Determine the target directory based on the destination item
        let targetDir: URL = {
            if let destItem = destinationItem, destItem.type == .folder, let folderURL = destItem.url {
                return folderURL
            }
            return projectURL
        }()

        // Partition URLs into FASTQ files, ONT directories, and other files
        var fastqURLs: [URL] = []
        var otherURLs: [URL] = []

        for url in sourceURLs {
            if SidebarProjectScanner.isNativePackage(url) {
                otherURLs.append(url)
            } else if isONTDirectory(url) {
                importONTDirectoryInBackground(sourceURL: url, projectURL: targetDir, requestID: requestID)
            } else if SequencingReadImportSource.isSupported(url) {
                fastqURLs.append(url)
            } else {
                otherURLs.append(url)
            }
        }

        // FASTQ files: group into R1/R2 pairs and present import config sheet
        if !fastqURLs.isEmpty {
            let pairs = groupFASTQByPairs(fastqURLs)
            presentFASTQImportSheet(pairs: pairs, projectDirectory: targetDir, requestID: requestID)
        }

        // Non-FASTQ files: copy to project as before
        if !otherURLs.isEmpty {
            Task { @MainActor [weak self, zipImportBatch] in
                defer { zipImportBatch.cleanup() }
                guard let self else { return }
                for url in otherURLs {
                    await self.importNonFASTQFile(
                        url: url,
                        projectURL: projectURL,
                        targetDir: targetDir,
                        destinationItem: destinationItem,
                        requestID: requestID,
                        displayAfterImport: importPlan.shouldAutoDisplayImportedContent
                    )
                }
            }
        } else {
            zipImportBatch.cleanup()
        }
    }
}
