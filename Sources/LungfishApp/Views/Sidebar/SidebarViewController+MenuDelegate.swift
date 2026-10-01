// SidebarViewController+MenuDelegate.swift - NSMenuDelegate context menus & file operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Get clicked row
        let clickedRow = outlineView.clickedRow

        // If clicked on a row that's not selected, select it first
        if clickedRow >= 0 && !outlineView.selectedRowIndexes.contains(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let items = selectedItems()

        // Check if clicked on empty space (no row)
        let clickedOnEmptySpace = clickedRow < 0

        guard !items.isEmpty || clickedOnEmptySpace else {
            // No selection and not on empty space - show minimal menu
            let noSelectionItem = NSMenuItem(title: "No Selection", action: nil, keyEquivalent: "")
            noSelectionItem.isEnabled = false
            menu.addItem(noSelectionItem)
            return
        }

        // If clicked on empty space with a project open, show New Folder option
        if clickedOnEmptySpace && projectURL != nil {
            let newFolderItem = SidebarItemAction.newFolder.makeContextMenuItem(
                target: self,
                action: SidebarItemAction.newFolder.menuSelector,
                representedObject: Self.emptySpaceNewFolderMarker
            )
            menu.addItem(newFolderItem)
            return
        }

        // If no items selected (shouldn't happen at this point, but safety check)
        guard !items.isEmpty else { return }

        populateContextMenu(menu, for: items)
    }

    /// Builds the context-menu items for a selection. Split out of
    /// `menuNeedsUpdate` so tests can exercise real menu construction
    /// without depending on `NSOutlineView.clickedRow`, which only reflects
    /// real mouse events and can't be set programmatically. Mirrors the
    /// `FASTACollectionViewController.testUpdateContextMenu` test-seam
    /// pattern used elsewhere in this codebase.
    ///
    /// Every command comes from ``SidebarItemAction``, the one list the
    /// Selection > Sidebar Item menu and the rows' accessibility actions are
    /// also built from, so the three surfaces offer the same commands under
    /// the same titles. "Move to" stays a submenu of destinations.
    private func populateContextMenu(_ menu: NSMenu, for items: [SidebarItem]) {
        let sections = availableSidebarItemActions(for: items)
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0, !menu.items.isEmpty, !(menu.items.last?.isSeparatorItem ?? true) {
                menu.addItem(.separator())
            }
            for action in section {
                if action == .moveToTrash, let moveTo = moveToSubmenuItem(for: items) {
                    menu.addItem(moveTo)
                    menu.addItem(.separator())
                }
                menu.addItem(contextMenuItem(for: action, items: items))
            }
        }
    }

    /// The context-menu item for `action` on `items`: the shared title, with
    /// the selection count for the commands Finder also counts, sent to
    /// the same handler the menu bar reaches through the responder chain.
    private func contextMenuItem(for action: SidebarItemAction, items: [SidebarItem]) -> NSMenuItem {
        switch action {
        case .manageProjectStorage:
            let item = action.makeContextMenuItem(
                target: self,
                action: #selector(contextMenuManageProjectStorage(_:))
            )
            item.identifier = NSUserInterfaceItemIdentifier(ProjectStorageAccessibilityID.sidebarCommand)
            item.setAccessibilityLabel("Manage project storage")
            return item
        case .exportSequences:
            // File > Export > Sequences handles it through the responder chain.
            let item = action.makeContextMenuItem(target: nil, action: action.menuSelector)
            item.title = action.contextTitle(selectionCount: items.filter { $0.type.bundleCapabilities.canExportSequences }.count)
            return item
        case .exportAsFASTQ:
            let item = action.makeContextMenuItem(target: self, action: action.menuSelector)
            item.title = action.contextTitle(selectionCount: items.filter { $0.type == .fastqBundle }.count)
            return item
        case .moveToTrash:
            let item = action.makeContextMenuItem(target: self, action: action.menuSelector)
            item.title = action.contextTitle(selectionCount: items.count)
            return item
        default:
            return action.makeContextMenuItem(target: self, action: action.menuSelector)
        }
    }

    private func moveToSubmenuItem(for items: [SidebarItem]) -> NSMenuItem? {
        let hasGroups = items.contains { $0.type == .group }
        guard !hasGroups, projectURL != nil else { return nil }
        let submenu = buildMoveToSubmenu(for: items)
        guard !submenu.items.isEmpty else { return nil }
        let moveToItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        moveToItem.submenu = submenu
        return moveToItem
    }

    /// Test-only seam: builds the real context menu for an explicit item
    /// selection, bypassing `NSOutlineView.clickedRow` (which only reflects
    /// real mouse-down events in a live window and can't be driven headlessly
    /// in unit tests).
    func testContextMenuItems(for items: [SidebarItem]) -> [NSMenuItem] {
        let menu = NSMenu()
        populateContextMenu(menu, for: items)
        return menu.items
    }

    @objc func openSelectedSidebarItem(_ sender: Any?) {
        openSelectedSidebarItemOrBundle()
    }

    @objc func openSelectedSidebarBundle(_ sender: Any?) {
        openSelectedSidebarItemOrBundle()
    }

    private func openSelectedSidebarItemOrBundle() {
        let items = selectedItems()
        guard let item = items.first, item.type != .group && item.type != .project && item.type != .batchGroup else { return }

        sidebarLogger.info("openSelectedSidebarItem: Opening '\(item.title, privacy: .public)'")
        handleSelectionChange(
            [item],
            source: "openSelectedSidebarItem"
        )
    }

    @objc func contextMenuManageProjectStorage(_ sender: Any?) {
        // Forward a view so AppDelegate resolves and permanently captures the
        // exact originating window rather than a mutable global controller.
        (NSApp.delegate as? AppDelegate)?.manageProjectStorage(view)
    }

    static func canManageProjectStorage(
        selectedItems: [SidebarItem],
        currentProjectURL: URL?,
        ownedProjectURL: URL?
    ) -> Bool {
        guard selectedItems.count == 1,
              let root = selectedItems.first,
              root.type == .project,
              let rootURL = root.url,
              let currentProjectURL,
              let ownedProjectURL else {
            return false
        }
        let canonicalRoot =
            ProjectSessionRegistry.canonicalProjectURL(rootURL)
        return canonicalRoot
            == ProjectSessionRegistry.canonicalProjectURL(currentProjectURL)
            && canonicalRoot
                == ProjectSessionRegistry.canonicalProjectURL(
                    ownedProjectURL
                )
    }

    /// Result of resolving a merge-target destination directory for a
    /// "Merge into New Bundle" selection: either the deepest common parent
    /// directory of every selected item's URL, or a user-facing reason the
    /// merge cannot proceed (surfaced via an alert instead of a silent
    /// no-op — see `contextMenuMergeIntoNewBundle`).
    enum MergeDestinationResolution: Equatable {
        case resolved(URL)
        case missingURLs(titles: [String])
        case noCommonParent
    }

    /// Pure, testable pre-flight check used by `contextMenuMergeIntoNewBundle`
    /// before it commits to presenting the merge confirmation sheet.
    static func resolveMergeDestination(for items: [SidebarItem]) -> MergeDestinationResolution {
        let missingURLItems = items.filter { $0.url == nil }
        guard missingURLItems.isEmpty else {
            return .missingURLs(titles: missingURLItems.map(\.title))
        }
        let selectedURLs = items.compactMap(\.url)
        guard let destinationDirectory = deepestCommonParent(for: selectedURLs) else {
            return .noCommonParent
        }
        return .resolved(destinationDirectory)
    }

    @objc func mergeSelectedSidebarItemsIntoNewBundle(_ sender: Any?) {
        let items = selectedItems()
        guard let mergeKind = BundleMergeSelection.detectKind(for: items) else { return }

        let selectedURLs = items.compactMap(\.url)
        let destinationDirectory: URL
        switch Self.resolveMergeDestination(for: items) {
        case .resolved(let resolvedDirectory):
            destinationDirectory = resolvedDirectory
        case .missingURLs(let titles):
            // At least one selected item has no URL (e.g. a stale/virtual
            // sidebar item). The menu item was shown because
            // BundleMergeSelection.detectKind passed on type alone, so
            // clicking it must not silently do nothing — tell the user
            // which item(s) can't be merged instead.
            let missingURLTitles = titles.joined(separator: ", ")
            sidebarLogger.error("contextMenuMergeIntoNewBundle: Missing URL for item(s): \(missingURLTitles, privacy: .public)")
            presentMergeIntoNewBundleFailure(
                message: "The following selected item(s) have no file location and cannot be merged: \(missingURLTitles)."
            )
            return
        case .noCommonParent:
            sidebarLogger.error("contextMenuMergeIntoNewBundle: Could not determine a common parent directory for the selected items")
            presentMergeIntoNewBundleFailure(
                message: "Could not determine a common folder to create the merged bundle in."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Merge into New Bundle"
        alert.informativeText = Self.mergeDialogInformativeText(for: mergeKind)
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = Self.suggestedMergedBundleName(for: items)
        alert.accessoryView = textField

        guard let window = view.window ?? NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let bundleName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleName.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    let mergedURL: URL
                    switch mergeKind {
                    case .fastq:
                        mergedURL = try await FASTQBundleMergeService.merge(
                            sourceBundleURLs: selectedURLs,
                            outputDirectory: destinationDirectory,
                            bundleName: bundleName
                        )
                    case .reference:
                        mergedURL = try await ReferenceBundleMergeService.merge(
                            sourceBundleURLs: selectedURLs,
                            outputDirectory: destinationDirectory,
                            bundleName: bundleName
                        )
                    }

                    await self.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)?.value
                    _ = self.selectItem(forURL: mergedURL)
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    /// Shows an alert for a "Merge into New Bundle" pre-flight failure
    /// (before the merge itself is even attempted) — e.g. a selected item
    /// has no URL, or the selection has no common parent folder.
    private func presentMergeIntoNewBundleFailure(message: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Merge Selected Items"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Shows the internal contents of a bundle in Finder (like "Show Package Contents" in macOS).
    @objc func showSelectedSidebarPackageContents(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type.bundleCapabilities.canShowPackageContents, let url = item.url else { return }

        sidebarLogger.info("contextMenuShowBundleContents: Showing contents of '\(item.title, privacy: .public)'")

        // Open the bundle directory in Finder to show its internal structure
        NSWorkspace.shared.open(url)
    }

    /// Shows bundle metadata info in an alert dialog.
    @objc func getSelectedSidebarBundleInfo(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type.bundleCapabilities.canGetBundleInfo, let url = item.url else { return }

        sidebarLogger.info("contextMenuGetBundleInfo: Getting info for '\(item.title, privacy: .public)'")

        // Try to load the bundle manifest
        let manifestURL = url.appendingPathComponent("manifest.json")

        Task { @MainActor in
            var infoText = "Bundle: \(item.title)\n"
            infoText += "Location: \(url.path)\n\n"

            if FileManager.default.fileExists(atPath: manifestURL.path) {
                do {
                    // Read off the main actor; this menu action just builds an
                    // info string and shows an alert, so no supersession guard
                    // is needed.
                    let data = try await AsyncFileReader.readData(manifestURL)
                    if let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Extract key info from manifest
                        if let name = manifest["name"] as? String {
                            infoText += "Name: \(name)\n"
                        }
                        if let identifier = manifest["identifier"] as? String {
                            infoText += "Identifier: \(identifier)\n"
                        }
                        if let description = manifest["description"] as? String {
                            infoText += "Description: \(description)\n"
                        }
                        if let formatVersion = manifest["formatVersion"] as? String {
                            infoText += "Format Version: \(formatVersion)\n"
                        }

                        // Source info
                        if let source = manifest["source"] as? [String: Any] {
                            infoText += "\nSource:\n"
                            if let organism = source["organism"] as? String {
                                infoText += "  Organism: \(organism)\n"
                            }
                            if let assembly = source["assembly"] as? String {
                                infoText += "  Assembly: \(assembly)\n"
                            }
                        }

                        // Genome info
                        if let genome = manifest["genome"] as? [String: Any] {
                            infoText += "\nGenome:\n"
                            if let totalLength = genome["totalLength"] as? Int {
                                infoText += "  Total Length: \(totalLength.formatted()) bp\n"
                            }
                            if let chromosomes = genome["chromosomes"] as? [[String: Any]] {
                                infoText += "  Chromosomes: \(chromosomes.count)\n"
                            }
                        }

                        // Track counts
                        if let annotations = manifest["annotations"] as? [[String: Any]] {
                            infoText += "\nAnnotation Tracks: \(annotations.count)\n"
                        }
                        if let variants = manifest["variants"] as? [[String: Any]] {
                            infoText += "Variant Tracks: \(variants.count)\n"
                        }
                        if let tracks = manifest["tracks"] as? [[String: Any]] {
                            infoText += "Signal Tracks: \(tracks.count)\n"
                        }
                    }
                } catch {
                    infoText += "Error reading manifest: \(error.localizedDescription)\n"
                    sidebarLogger.error("contextMenuGetBundleInfo: Failed to read manifest - \(error.localizedDescription, privacy: .public)")
                }
            } else {
                infoText += "No manifest.json found in bundle.\n"
            }

            // Show info alert
            let alert = NSAlert()
            alert.messageText = "Bundle Info"
            alert.informativeText = infoText
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")

            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: nil)
            }

        }
    }

    @objc func importSampleMetadataForSelectedSidebarBundle(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .referenceBundle || item.type == .fastqBundle),
              let bundleURL = item.url else { return }

        sidebarLogger.info("contextMenuImportSampleMetadata: Importing metadata into '\(item.title, privacy: .public)'")
        guard canWriteSidebarProjectOutputs(workflowName: "Sample metadata import", targetURL: bundleURL) else {
            return
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.presentMetadataImportPanel(
            for: bundleURL,
            presentingWindow: view.window,
            routeContext: OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
        )
    }

    @objc func editSelectedSidebarFolderMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        sidebarLogger.info("contextMenuEditFolderMetadata: Opening metadata editor for '\(item.title, privacy: .public)'")
        guard canWriteSidebarProjectOutputs(workflowName: "Folder metadata edit", targetURL: folderURL) else {
            return
        }

        let editorSheet = FolderMetadataEditorSheet(folderURL: folderURL, windowStateScope: windowStateScope)
        guard let window = view.window else { return }

        window.contentViewController?.presentAsSheet(editorSheet)
    }

    @objc func exportSelectedSidebarFolderMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        sidebarLogger.info("contextMenuExportProjectMetadata: Exporting metadata from '\(item.title, privacy: .public)'")

        let sheet = MetadataExportSheet(folderURL: folderURL)
        guard let window = view.window else { return }
        window.contentViewController?.presentAsSheet(sheet)
    }

    @objc func importSelectedSidebarFolderMetadata(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              (item.type == .folder || item.type == .project),
              let folderURL = item.url else { return }

        sidebarLogger.info("contextMenuImportProjectMetadata: Importing metadata into '\(item.title, privacy: .public)'")
        guard canWriteSidebarProjectOutputs(workflowName: "Project metadata import", targetURL: folderURL) else {
            return
        }

        let sheet = MetadataImportSheet(folderURL: folderURL, windowStateScope: windowStateScope)
        guard let window = view.window else { return }
        window.contentViewController?.presentAsSheet(sheet)
    }

    /// Checks if a bundle URL has variant tracks by reading its manifest.
    func bundleHasVariantTracks(_ bundleURL: URL) -> Bool {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return false }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data) else { return false }
        return !manifest.variants.isEmpty
    }

    @objc func deleteSelectedSidebarVariantTracks(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let bundleURL = item.url else { return }
        guard canWriteSidebarProjectOutputs(workflowName: "Variant track deletion", targetURL: bundleURL) else {
            return
        }

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data),
              !manifest.variants.isEmpty else { return }

        let tracks = manifest.variants
        let trackNames = tracks.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Delete Variant Tracks?"
        alert.informativeText = "This will permanently delete \(tracks.count) variant track\(tracks.count == 1 ? "" : "s") (\(trackNames)) and their database files from the bundle. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()
        alert.alertStyle = .critical

        guard let window = self.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDeleteVariantTracks(bundleURL: bundleURL, manifest: manifest)
        }
    }

    private func performDeleteVariantTracks(bundleURL: URL, manifest: BundleManifest) {
        // `manifest` here is only used to confirm the user's alert was answered
        // against tracks that existed when the menu was opened. The actual
        // mutation below re-reads the manifest fresh from disk immediately
        // before writing, so a track added or changed in the meantime (by
        // another operation) is not silently discarded — see FEA-01.
        let tracks = manifest.variants
        guard !tracks.isEmpty else { return }
        guard canWriteSidebarProjectOutputs(workflowName: "Variant track deletion", targetURL: bundleURL) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var deletedFiles: [String] = []
            var errors: [String] = []
            var warnings: [String] = []

            func removeFile(_ url: URL, label: String, critical: Bool) {
                guard fm.fileExists(atPath: url.path) else { return }
                do {
                    try fm.removeItem(at: url)
                    deletedFiles.append(label)
                } catch {
                    let msg = "Failed to delete \(label): \(error.localizedDescription)"
                    if critical {
                        errors.append(msg)
                    } else {
                        warnings.append(msg)
                    }
                }
            }

            func validatedBundleMemberURL(_ relativePath: String, field: String, critical: Bool) -> URL? {
                do {
                    return try BundleManifest.validatedBundleMemberURL(
                        for: relativePath,
                        in: bundleURL,
                        field: field
                    )
                } catch {
                    let msg = "Refusing to delete unsafe bundle path \(relativePath): \(error.localizedDescription)"
                    if critical {
                        errors.append(msg)
                    } else {
                        warnings.append(msg)
                    }
                    return nil
                }
            }

            for track in tracks {
                // A database-backed track (every imported VCF) has no variant
                // file beside its database: `path` is the database itself, or
                // a legacy `.bcf` placeholder that was never written, and
                // `indexPath` is empty. Only a track with a distinct payload
                // file needs it removed here.
                let databaseBacked = VCFBundleVariantImport.isDatabaseBackedTrack(track)

                // Delete BCF file
                if !databaseBacked, !track.path.isEmpty,
                   let bcfURL = validatedBundleMemberURL(
                    track.path,
                    field: "variants[\(track.id)].path",
                    critical: true
                ) {
                    removeFile(bcfURL, label: track.path, critical: true)
                }

                // Delete CSI index file
                if !databaseBacked, !track.indexPath.isEmpty,
                   let csiURL = validatedBundleMemberURL(
                    track.indexPath,
                    field: "variants[\(track.id)].indexPath",
                    critical: true
                ) {
                    removeFile(csiURL, label: track.indexPath, critical: true)
                }

                // Delete SQLite variant database
                if let dbPath = track.databasePath,
                   let dbURL = validatedBundleMemberURL(
                       dbPath,
                       field: "variants[\(track.id)].databasePath",
                       critical: true
                   ) {
                    removeFile(dbURL, label: dbPath, critical: true)
                    // WAL/SHM are transient journal files — warn but don't block
                    let walURL = dbURL.appendingPathExtension("wal")
                    let shmURL = dbURL.appendingPathExtension("shm")
                    removeFile(walURL, label: "\(dbPath).wal", critical: false)
                    removeFile(shmURL, label: "\(dbPath).shm", critical: false)
                }
            }

            // Re-read the manifest fresh from disk immediately before writing,
            // rather than reusing the menu-time snapshot, so a track added or
            // changed by another operation in the meantime is not lost.
            // `removingAllVariantTracks()` round-trips every other field
            // (alignments, warnings, browserSummary, originBundlePath,
            // recordStore, metadata) unchanged via BundleManifest.copy — see FEA-01.
            do {
                let currentManifest = try BundleManifest.load(from: bundleURL)
                let updatedManifest = currentManifest.removingAllVariantTracks()
                try updatedManifest.save(to: bundleURL)
            } catch {
                errors.append("Failed to write manifest.json: \(error.localizedDescription)")
            }

            let finalDeletedCount = deletedFiles.count
            let finalErrors = errors
            let finalWarnings = warnings
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    for w in finalWarnings {
                        sidebarLogger.warning("performDeleteVariantTracks: \(w, privacy: .public)")
                    }

                    if finalErrors.isEmpty {
                        sidebarLogger.info("performDeleteVariantTracks: Deleted \(finalDeletedCount) files from bundle")
                        NotificationCenter.default.post(
                            name: .bundleVariantTracksDeleted,
                            object: nil,
                            userInfo: [NotificationUserInfoKey.bundleURL: bundleURL]
                        )
                    }

                    if !finalErrors.isEmpty {
                        sidebarLogger.error("performDeleteVariantTracks: Completed with \(finalErrors.count) error(s)")
                        let alert = NSAlert()
                        alert.messageText = "Variant Track Deletion Completed with Errors"
                        alert.informativeText = finalErrors.joined(separator: "\n")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = self.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    func bundleHasAssemblyProvenance(_ bundleURL: URL) -> Bool {
        let provenanceURL = bundleURL.appendingPathComponent("assembly/provenance.json")
        return FileManager.default.fileExists(atPath: provenanceURL.path)
    }

    @objc func reassembleSelectedSidebarBundle(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, item.type == .referenceBundle, let bundleURL = item.url else { return }

        let assemblyDir = bundleURL.appendingPathComponent("assembly")
        guard let provenance = try? AssemblyProvenance.load(from: assemblyDir) else {
            sidebarLogger.error("contextMenuReassemble: Failed to load provenance from \(bundleURL.lastPathComponent)")
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Cannot Reassemble"
            alert.informativeText = "\(item.title)'s assembly provenance file is missing or corrupted, so the original assembly inputs and tool settings could not be recovered."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window {
                alert.beginSheetModal(for: window)
            }
            return
        }

        // Try to locate original input files from provenance
        let inputFiles = provenance.inputs.compactMap { record -> URL? in
            if let originalPath = record.originalPath {
                let originalURL = URL(fileURLWithPath: originalPath)
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
            }

            // Look for files relative to current project
            if let projectURL = self.projectURL {
                let candidates = [
                    projectURL.appendingPathComponent(record.filename),
                    projectURL.appendingPathComponent("FASTQ").appendingPathComponent(record.filename),
                    projectURL.appendingPathComponent("Reads").appendingPathComponent(record.filename),
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }
            return nil
        }

        guard let window = self.view.window else { return }
        let outputDir = bundleURL.deletingLastPathComponent()
        let initialTool = AssemblyTool(
            rawValue: provenance.assembler.lowercased()
                .replacingOccurrences(of: " ", with: "")
        ) ?? .spades

        AssemblySheetPresenter.present(
            from: window,
            inputFiles: inputFiles,
            outputDirectory: outputDir,
            initialTool: initialTool,
            routeContext: OperationRouteContext(
                projectURL: projectURL,
                windowStateScope: windowStateScope
            ),
            onCancel: nil
        )
    }

    @objc func showSelectedSidebarItemInFinder(_ sender: Any?) {
        let items = selectedItems()
        let urls = items.compactMap { $0.url }

        guard !urls.isEmpty else { return }

        sidebarLogger.info("contextMenuShowInFinder: Revealing \(urls.count) items in Finder")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func copySelectedSidebarItemPath(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first, let url = item.url else { return }

        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)

        sidebarLogger.info("contextMenuCopyPath: Copied path '\(url.path, privacy: .public)'")
    }

    /// Copies the classification command(s) to the system clipboard.
    ///
    /// Loads provenance or config from the classification result directory
    /// and builds a shell-ready command string for kraken2 (and bracken,
    /// if profiling was performed).
    @objc func copySelectedSidebarClassificationCommand(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first,
              item.type == .classificationResult,
              let url = item.url else { return }

        guard let command = ClassificationResult.copyableCommandString(from: url) else {
            sidebarLogger.warning("contextMenuCopyClassificationCommand: Failed to build command for '\(item.title, privacy: .public)'")
            return
        }

        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)

        sidebarLogger.info("contextMenuCopyClassificationCommand: Copied command for '\(item.title, privacy: .public)'")
    }

    /// Posts a notification to show the selected bundle in the inspector.
    @objc func showSelectedRowInInspector(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first else { return }

        sidebarLogger.info("contextMenuShowInInspector: Showing '\(item.title, privacy: .public)' in inspector")

        // Post notification to show inspector with Document tab
        var userInfo: [AnyHashable: Any] = [NotificationUserInfoKey.inspectorTab: "document"]
        if let windowStateScope {
            userInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        }
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: userInfo
        )
    }

    /// Marks the "New Folder" item of the empty-space context menu, which
    /// creates at the project root whatever is selected.
    static let emptySpaceNewFolderMarker = "sidebar-empty-space-new-folder"

    /// Where New Folder creates: the project root for the empty-space
    /// context item, otherwise inside the selected folder or project, or
    /// the project root when a file is selected. Nil without a project.
    func newFolderParentURL(clickedEmptySpace: Bool) -> URL? {
        if clickedEmptySpace {
            if projectURL == nil { sidebarLogger.warning("contextMenuNewFolder: No project open") }
            return projectURL
        }
        if let item = selectedItems().first, item.type == .folder || item.type == .project, let url = item.url {
            return url
        }
        if projectURL == nil { sidebarLogger.warning("contextMenuNewFolder: No valid location to create folder") }
        return projectURL
    }

    @objc func newFolderInSidebar(_ sender: Any?) {
        // From the menu bar or a row's accessibility action there is no
        // click, so the selection decides; the empty-space context item
        // marks itself.
        let clickedEmptySpace = (sender as? NSMenuItem)?.representedObject as? String == Self.emptySpaceNewFolderMarker
        guard let parentURL = newFolderParentURL(clickedEmptySpace: clickedEmptySpace) else { return }

        sidebarLogger.info("contextMenuNewFolder: Creating new folder in '\(parentURL.lastPathComponent, privacy: .public)'")

        // Show dialog for folder name
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = "untitled folder"
        textField.selectText(nil)
        alert.accessoryView = textField

        guard let window = view.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let folderName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.createFolder(named: folderName, in: parentURL)
                }
            }
        }
    }

    private func createFolder(named name: String, in parentURL: URL) {
        guard canWriteSidebarProjectOutputs(workflowName: "Folder creation", targetURL: parentURL) else {
            return
        }
        var folderURL = parentURL.appendingPathComponent(name, isDirectory: true)

        // Handle duplicate names
        var counter = 1
        while FileManager.default.fileExists(atPath: folderURL.path) {
            counter += 1
            folderURL = parentURL.appendingPathComponent("\(name) \(counter)", isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            sidebarLogger.info("createFolder: Created '\(folderURL.lastPathComponent, privacy: .public)'")
            // Immediately refresh sidebar for instant feedback
            requestReloadFromFilesystem()
        } catch {
            sidebarLogger.error("createFolder: Failed - \(error.localizedDescription, privacy: .public)")

            let alert = NSAlert()
            alert.messageText = "Create Folder Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc func renameSelectedSidebarItem(_ sender: Any?) {
        let items = selectedItems()
        guard let item = items.first else { return }

        sidebarLogger.info("contextMenuRename: Renaming '\(item.title, privacy: .public)'")

        // Show rename dialog
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = item.url?.deletingPathExtension().lastPathComponent ?? item.title
        alert.accessoryView = textField

        guard let window = view.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }

            self?.performRename(item: item, newName: newName)
        }
    }

    private func performRename(item: SidebarItem, newName: String) {
        guard let url = item.url else {
            // Item has no URL, just update the title (legacy behavior)
            item.title = newName
            reloadOutlineView()
            return
        }
        guard canWriteSidebarProjectOutputs(workflowName: "Sidebar rename", targetURL: url) else {
            return
        }

        // Construct new URL with same extension
        let fileExtension = url.pathExtension
        let newFilename = fileExtension.isEmpty ? newName : "\(newName).\(fileExtension)"
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            rehydrateScientificProvenance(from: url, to: newURL)
            rewriteAnalysisManifestReferencesIfNeeded(from: url, to: newURL)
            sidebarLogger.info("performRename: Renamed to '\(newFilename, privacy: .public)'")
            // Immediately refresh sidebar for instant feedback
            requestReloadFromFilesystem()
        } catch {
            sidebarLogger.error("performRename: Failed - \(error.localizedDescription, privacy: .public)")

            let alert = NSAlert()
            alert.messageText = "Rename Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc func duplicateSelectedSidebarItems(_ sender: Any?) {
        let items = selectedItems()
        sidebarLogger.info("contextMenuDuplicate: Duplicating \(items.count) items")
        guard canWriteSidebarProjectOutputs(
            workflowName: "Sidebar duplicate",
            targetURL: items.first?.url
        ) else {
            return
        }

        for item in items {
            guard let url = item.url else { continue }

            // Generate unique name
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 1
            var newURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName) copy.\(ext)")

            while FileManager.default.fileExists(atPath: newURL.path) {
                counter += 1
                newURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName) copy \(counter).\(ext)")
            }

            do {
                try FileManager.default.copyItem(at: url, to: newURL)
                rehydrateScientificProvenance(from: url, to: newURL)
                sidebarLogger.info("contextMenuDuplicate: Created '\(newURL.lastPathComponent, privacy: .public)'")
            } catch {
                sidebarLogger.error("contextMenuDuplicate: Failed - \(error.localizedDescription, privacy: .public)")
            }
        }
        // Immediately refresh sidebar for instant feedback
        requestReloadFromFilesystem()
    }
    // MARK: - FASTQ Export

    /// Exports a FASTQ bundle to a standalone FASTQ file via NSSavePanel.
    @objc func exportSelectedSidebarAlignment(_ sender: Any?) {
        guard let url = selectedItems().first(where: { $0.type.bundleCapabilities.canExportAlignment })?.url else { return }
        guard let viewer = (view.window?.windowController as? MainWindowController)?
            .mainSplitViewController?.viewerController else { return }
        viewer.presentMSAAlignmentExportSheet(bundleURL: url)
    }

    @objc func exportSelectedSidebarItemsAsFASTQ(_ sender: Any?) {
        // Delegate to the AppDelegate's exportFASTQ which handles single and multi-selection
        NSApp.sendAction(#selector(FileMenuActions.exportFASTQ(_:)), to: nil, from: sender)
    }

    // MARK: - Clone Metadata

    @objc func cloneMetadataForSelectedSidebarBundle(_ sender: Any?) {
        let targetItems = selectedItems().filter { $0.type == .fastqBundle }
        guard !targetItems.isEmpty else { return }
        guard canWriteSidebarProjectOutputs(
            workflowName: "Metadata cloning",
            targetURL: targetItems.first?.url
        ) else {
            return
        }

        // Find all FASTQ bundles in the same parent folder as potential sources
        guard let parentURL = targetItems.first?.url?.deletingLastPathComponent() else { return }
        let targetURLs = Set(targetItems.compactMap { $0.url })

        let fm = FileManager.default
        let allBundles: [URL]
        do {
            allBundles = try fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "lungfishfastq" && !targetURLs.contains($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return
        }

        guard !allBundles.isEmpty else { return }

        // Build a picker menu as an alert with a popup button
        let alert = NSAlert()
        alert.messageText = "Clone Metadata From"
        alert.informativeText = "Select a sample to copy metadata from. All fields except sample name will be copied."
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24), pullsDown: false)
        for bundle in allBundles {
            let name = bundle.deletingPathExtension().lastPathComponent
            popUp.addItem(withTitle: name)
            popUp.lastItem?.representedObject = bundle
        }
        alert.accessoryView = popUp

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard response == .alertFirstButtonReturn,
                          let sourceURL = popUp.selectedItem?.representedObject as? URL else {
                        return
                    }

                    // Load source metadata
                    let sourceName = sourceURL.deletingPathExtension().lastPathComponent
                    let sourceCSV = FASTQBundleCSVMetadata.load(from: sourceURL)
                    let sourceMeta: FASTQSampleMetadata
                    if let csv = sourceCSV {
                        sourceMeta = FASTQSampleMetadata(from: csv, fallbackName: sourceName)
                    } else {
                        sourceMeta = FASTQSampleMetadata(sampleName: sourceName)
                    }

                    // Apply to each target bundle
                    for targetURL in targetURLs {
                        let targetName = targetURL.deletingPathExtension().lastPathComponent
                        let cloned = sourceMeta.cloned(withName: targetName)
                        let legacyCSV = cloned.toLegacyCSV()
                        try? FASTQBundleCSVMetadata.save(legacyCSV, to: targetURL)
                    }

                    // Post notification to refresh the inspector if needed
                    NotificationCenter.default.post(
                        name: .sampleMetadataDidChange,
                        object: self,
                        userInfo: self?.windowScopedUserInfo([:]) ?? [:]
                    )
                }
            }
        }
    }

    // MARK: - Move To Submenu

    /// Builds a submenu with available folder destinations for moving items
    private func buildMoveToSubmenu(for items: [SidebarItem]) -> NSMenu {
        let submenu = NSMenu()

        guard let projectURL = projectURL else { return submenu }

        // Get URLs of items being moved (to exclude them from destinations)
        let movingURLs = Set(items.compactMap { $0.url?.standardizedFileURL })

        // Add project root as a destination
        let projectRootItem = NSMenuItem(title: projectURL.lastPathComponent + " (Root)", action: #selector(contextMenuMoveToFolder(_:)), keyEquivalent: "")
        projectRootItem.target = self
        projectRootItem.representedObject = projectURL
        submenu.addItem(projectRootItem)

        submenu.addItem(NSMenuItem.separator())

        // Recursively find all folders in the project
        let folders = Self.moveMenuFolderDestinations(
            from: rootItems,
            excludingURLs: Array(movingURLs)
        )

        for folder in folders {
            // Create relative path for display
            let relativePath = folder.path.replacingOccurrences(of: projectURL.path + "/", with: "")
            let menuItem = NSMenuItem(title: relativePath, action: #selector(contextMenuMoveToFolder(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = folder
            submenu.addItem(menuItem)
        }

        return submenu
    }

    static func moveMenuFolderDestinations(
        from rootItems: [SidebarItem],
        excludingURLs movingURLs: [URL]
    ) -> [URL] {
        let movingURLs = movingURLs.map(\.standardizedFileURL)
        var destinations: [URL] = []

        var pendingItems = Array(rootItems.reversed())
        while let item = pendingItems.popLast() {
            let itemType = item.type
            let itemURL = item.url?.standardizedFileURL
            let itemChildren = item.children

            if let itemURL {
                var excluded = false
                for movingURL in movingURLs where sidebarMoveMenuURL(movingURL, covers: itemURL) {
                    excluded = true
                    break
                }
                if excluded {
                    continue
                }
            }

            if (itemType == .folder || itemType == .project), let itemURL {
                destinations.append(itemURL)
            }

            if !itemType.isBundle, !itemChildren.isEmpty {
                for child in itemChildren.reversed() {
                    pendingItems.append(child)
                }
            }
        }

        return destinations
    }

    nonisolated private static func sidebarMoveMenuURL(_ ancestor: URL, covers descendant: URL) -> Bool {
        let ancestorPath = ancestor.standardizedFileURL.path
        let descendantPath = descendant.standardizedFileURL.path
        if ancestorPath == descendantPath { return true }
        let normalizedAncestor = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return descendantPath.hasPrefix(normalizedAncestor)
    }

    @objc private func contextMenuMoveToFolder(_ sender: NSMenuItem) {
        guard let destinationURL = sender.representedObject as? URL else {
            sidebarLogger.warning("contextMenuMoveToFolder: No destination URL")
            return
        }
        guard canWriteSidebarProjectOutputs(workflowName: "Sidebar move", targetURL: destinationURL) else {
            return
        }

        let items = selectedItems()
        sidebarLogger.info("contextMenuMoveToFolder: Moving \(items.count) items to '\(destinationURL.lastPathComponent, privacy: .public)'")

        var failedItems: [(SidebarItem, Error)] = []

        for item in items {
            guard let sourceURL = item.url else { continue }

            // Skip if trying to move into itself or a child
            if destinationURL.path.hasPrefix(sourceURL.path) {
                sidebarLogger.warning("contextMenuMoveToFolder: Cannot move '\(item.title, privacy: .public)' into itself or a subdirectory")
                continue
            }

            // Skip if already in the destination
            if sourceURL.deletingLastPathComponent().standardizedFileURL == destinationURL.standardizedFileURL {
                sidebarLogger.debug("contextMenuMoveToFolder: '\(item.title, privacy: .public)' is already in destination")
                continue
            }

            let destURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                // Check for existing file with same name
                let finalURL: URL
                if FileManager.default.fileExists(atPath: destURL.path) {
                    // Generate unique name
                    var uniqueURL = destURL
                    var counter = 1
                    let baseName = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension

                    while FileManager.default.fileExists(atPath: uniqueURL.path) {
                        counter += 1
                        let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
                        uniqueURL = destinationURL.appendingPathComponent(newName)
                    }

                    finalURL = uniqueURL
                } else {
                    finalURL = destURL
                }
                try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                rehydrateScientificProvenance(from: sourceURL, to: finalURL)
                rewriteAnalysisManifestReferencesIfNeeded(from: sourceURL, to: finalURL)
                sidebarLogger.info("contextMenuMoveToFolder: Moved '\(item.title, privacy: .public)' to '\(finalURL.lastPathComponent, privacy: .public)'")
            } catch {
                sidebarLogger.error("contextMenuMoveToFolder: Failed to move '\(item.title, privacy: .public)' - \(error.localizedDescription, privacy: .public)")
                failedItems.append((item, error))
            }
        }

        // Refresh sidebar
        requestReloadFromFilesystem()

        // Show error if some items failed
        if !failedItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items could not be moved"
            alert.informativeText = failedItems.map { "\($0.0.title): \($0.1.localizedDescription)" }.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }
}
