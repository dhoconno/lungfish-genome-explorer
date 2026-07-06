// MainSplitViewController+MultiDocument.swift - Project session and document coordination
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    /// Handles multiple sidebar items being selected.
    ///
    /// This method collects sequences from all selected documents and displays them
    /// stacked in the viewer using multi-sequence support.
    ///
    /// - Parameter items: Array of selected sidebar items
    func handleMultipleItemsSelected(_ items: [SidebarItem]) {
        // Filter to only sequence-type items that can be displayed
        let displayableItems = items.filter { item in
            item.type == .sequence || item.type == .annotation || item.type == .alignment
        }

        guard !displayableItems.isEmpty else {
            mainSplitLogger.debug("handleMultipleItemsSelected: No displayable items in selection")
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
        var placeholderDocuments: [(LoadedDocument, URL, DocumentType)] = []
        var unregisteredURLs: [(URL, DocumentType)] = []

        for item in displayableItems {
            if let url = item.url {
                if let existingDoc = DocumentManager.shared.documents.first(where: { $0.url == url }) {
                    // Check if fully loaded
                    let isFullyLoaded = !existingDoc.sequences.isEmpty || !existingDoc.annotations.isEmpty
                    if isFullyLoaded {
                        fullyLoadedDocuments.append(existingDoc)
                    } else if let docType = DocumentType.detect(from: url) {
                        placeholderDocuments.append((existingDoc, url, docType))
                    }
                } else if let docType = DocumentType.detect(from: url) {
                    unregisteredURLs.append((url, docType))
                }
            } else if let doc = DocumentManager.shared.documents.first(where: { $0.name == item.title }) {
                fullyLoadedDocuments.append(doc)
            }
        }

        let needsLoading = !placeholderDocuments.isEmpty || !unregisteredURLs.isEmpty

        // If we have documents to load, do it asynchronously
        if needsLoading {
            multiDocumentLoadTask?.cancel()
            multiDocumentLoadTask = nil
            let generation = selectionGeneration

            // Use a regular Task (not detached) to maintain MainActor isolation
            multiDocumentLoadTask = Task { @MainActor [weak self] in
                guard let self = self else { return }

                let totalToLoad = placeholderDocuments.count + unregisteredURLs.count
                self.viewerController.showProgress("Loading \(totalToLoad) documents...")

                // Start with already-loaded documents
                var loadedDocs = fullyLoadedDocuments

                // Load placeholder documents via DocumentLoader
                for (existingDoc, url, docType) in placeholderDocuments {
                    guard !Task.isCancelled, self.selectionGeneration == generation else {
                        mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before lazy load")
                        self.multiDocumentLoadTask = nil
                        return
                    }

                    do {
                        let result = try await DocumentLoader.loadFile(at: url, type: docType)
                        guard !Task.isCancelled, self.selectionGeneration == generation else {
                            mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load after lazy load")
                            self.multiDocumentLoadTask = nil
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
                    guard !Task.isCancelled, self.selectionGeneration == generation else {
                        mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before document load")
                        self.multiDocumentLoadTask = nil
                        return
                    }

                    do {
                        let document = try await DocumentManager.shared.loadDocument(at: url)
                        guard !Task.isCancelled, self.selectionGeneration == generation else {
                            mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load after document load")
                            self.multiDocumentLoadTask = nil
                            return
                        }
                        loadedDocs.append(document)
                        mainSplitLogger.debug("handleMultipleItemsSelected: Loaded '\(document.name, privacy: .public)'")
                    } catch {
                        mainSplitLogger.error("handleMultipleItemsSelected: Failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                guard !Task.isCancelled, self.selectionGeneration == generation else {
                    mainSplitLogger.info("handleMultipleItemsSelected: Discarding stale multi-select load before collection display")
                    self.multiDocumentLoadTask = nil
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
            sourceNames: sourceNames
        )
        recordUITestEvent("viewport.collection.displayed sequences=\(allSequences.count)")
        mainSplitLogger.info("displayMultiDocumentCollection: Displayed collection with \(allSequences.count) sequences from \(documents.count) files")
    }

    @objc func handleDocumentLoaded(_ notification: Notification) {
        guard let document = notification.userInfo?["document"] as? LoadedDocument else {
            mainSplitLogger.warning("handleDocumentLoaded: No document in notification")
            return
        }

        mainSplitLogger.info("handleDocumentLoaded: Document '\(document.name, privacy: .public)' was loaded")

        // With the filesystem-backed sidebar model:
        // - Files inside the project are shown via FileSystemWatcher (no manual add needed)
        // - Files outside the project can optionally be shown in "Open Documents"
        // Only outside-project files are added to Open Documents; project files
        // are surfaced by FileSystemWatcher.
        if let projectURL = sidebarController.currentProjectURL {
            let docPath = document.url.standardizedFileURL.path
            let projectPath = projectURL.standardizedFileURL.path
            if docPath.hasPrefix(projectPath) {
                // File is inside project - FileSystemWatcher will handle sidebar refresh
                mainSplitLogger.debug("handleDocumentLoaded: File is inside project, sidebar updated via FileSystemWatcher")
                return
            }
        }

        // File is outside project - add to "Open Documents" section (legacy behavior)
        sidebarController.addLoadedDocument(document)
    }

    @objc func handleProjectOpened(_ notification: Notification) {
        // In multi-window mode, only the active main window should react to
        // DocumentManager's global project-opened notification.
        if AppDelegate.shared?.mainWindowController?.mainSplitViewController !== self {
            mainSplitLogger.debug("handleProjectOpened: Ignoring notification for non-active window")
            return
        }

        guard let project = notification.userInfo?["project"] as? ProjectFile else {
            mainSplitLogger.warning("handleProjectOpened: No project in notification")
            return
        }

        mainSplitLogger.info("handleProjectOpened: Project '\(project.name, privacy: .public)' was opened")

        // Update window title to reflect the project name
        let projectName = project.url.deletingPathExtension().lastPathComponent
        view.window?.title = "\(projectName) \u{2014} Lungfish Genome Explorer"

        // Use the new filesystem-backed sidebar model
        // This will scan the project directory and set up file watching
        sidebarController.openProject(at: project.url)

        // Display the first document if available, otherwise show empty state
        let documents = DocumentManager.shared.documents
        if let firstDoc = documents.first {
            viewerController?.hideProgress()
            viewerController?.displayDocument(firstDoc)
            mainSplitLogger.info("handleProjectOpened: Displaying first document '\(firstDoc.name, privacy: .public)'")
        } else {
            // Empty project - show clear "No sequence selected" state
            viewerController?.showNoSequenceSelected()
            mainSplitLogger.info("handleProjectOpened: Empty project, showing 'No sequence selected' state")
        }

        let warningState = notification.userInfo?["openWarningState"] as? ProjectOpenWarningState
            ?? DocumentManager.shared.activeProjectOpenWarningState
        onProjectOpenWarningStateChanged?(warningState)
    }

    public func applyProjectSessionState(restoring snapshot: ProjectWindowSnapshot? = nil) {
        guard let project = projectSession.project else {
            sidebarController.closeProject()
            viewerController?.showNoSequenceSelected()
            onProjectOpenWarningStateChanged?(projectSession.openWarningState)
            return
        }

        let projectName = project.url.deletingPathExtension().lastPathComponent
        view.window?.title = "\(projectName) - Lungfish Genome Explorer"
        sidebarController.openProject(at: project.url)

        if let firstDoc = projectSession.activeDocument ?? projectSession.documents.first {
            viewerController?.hideProgress()
            viewerController?.displayDocument(firstDoc)
        } else {
            viewerController?.showNoSequenceSelected()
        }

        onProjectOpenWarningStateChanged?(projectSession.openWarningState)

        guard let snapshot else { return }
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
        if let document = projectSession.documents.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) {
            viewerController?.hideProgress()
            viewerController?.displayDocument(document)
            projectSession.setActiveDocument(document)
            DocumentManager.shared.setActiveDocument(document)
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
        ProjectWindowSnapshot(
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
            activeContent: viewerController?.restorableContentState(),
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
        let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url

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
            if let projectURL {
                if let destItem = destinationItem, destItem.type == .folder, let folderURL = destItem.url {
                    return folderURL
                }
                return projectURL
            }
            return sourceURLs[0].deletingLastPathComponent()
        }()

        // Partition URLs into FASTQ files, ONT directories, and other files
        var fastqURLs: [URL] = []
        var otherURLs: [URL] = []

        for url in sourceURLs {
            if isONTDirectory(url) {
                importONTDirectoryInBackground(sourceURL: url, projectURL: targetDir, requestID: requestID)
            } else if FASTQBundle.isFASTQFileURL(url) {
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
