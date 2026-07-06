// SidebarViewController+OutlineDataSource.swift - NSOutlineViewDataSource conformance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return displayItems.count
        }
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.children.count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return displayItems[index]
        }
        if let sidebarItem = item as? SidebarItem {
            return sidebarItem.children[index]
        }
        fatalError("Unexpected item type")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let sidebarItem = item as? SidebarItem {
            return !sidebarItem.children.isEmpty
        }
        return false
    }

    // MARK: - Drag Source

    /// Initiates a drag operation when user starts dragging an item
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        // Don't allow dragging groups
        if sidebarItem.type == .group {
            return nil
        }

        sidebarLogger.debug("pasteboardWriterForItem: Starting drag for '\(sidebarItem.title, privacy: .public)'")

        // Create a pasteboard item with the sidebar item's identifier
        let pasteboardItem = NSPasteboardItem()

        // Use the item's URL path as the identifier (or title if no URL)
        let identifier = sidebarItem.url?.path ?? sidebarItem.title
        pasteboardItem.setString(identifier, forType: sidebarItemPasteboardType)

        // Also provide file URL if available for external drops
        if let url = sidebarItem.url {
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        }

        return pasteboardItem
    }

    /// Allows the user to drag multiple items at once
    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        sidebarLogger.debug("draggingSession willBegin: Dragging \(draggedItems.count) items")
        session.draggingFormation = .stack
    }

    /// Called when dragging ends
    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        sidebarLogger.debug("draggingSession ended: operation=\(operation.rawValue)")
    }

    // MARK: - Drag Destination

    /// Called by NSOutlineView to update dragging items - required for proper drag feedback
    public func outlineView(_ outlineView: NSOutlineView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
        debugLog("updateDraggingItemsForDrag: Called")
    }

    /// Validates whether a drop is allowed at the proposed location
    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        debugLog("validateDrop: ENTERED METHOD")

        // Get the destination item
        let destinationItem = item as? SidebarItem

        debugLog("validateDrop: Called with destinationItem='\(destinationItem?.title ?? "nil")' type=\(String(describing: destinationItem?.type)) index=\(index)")

        // Determine if this is an internal drag
        let isInternalDrag = info.draggingPasteboard.availableType(from: [sidebarItemPasteboardType]) != nil
        debugLog("validateDrop: isInternalDrag=\(isInternalDrag)")

        if isInternalDrag {
            let sourceIdentifier = info.draggingPasteboard.string(forType: sidebarItemPasteboardType)
            let hasLocalSource = sourceIdentifier.flatMap { findItem(byPath: $0) } != nil

            guard Self.internalDropDestinationURL(projectURL: projectURL, destinationItem: destinationItem) != nil else {
                return []
            }

            // Cross-window drags carry the internal type, but source items aren't
            // in this sidebar model. Treat these as copy imports.
            if !hasLocalSource {
                sidebarLogger.debug("validateDrop: Internal type from another window - COPY import")
                return .copy
            }

            // Check for Control key to copy, otherwise move
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.control) || modifiers.contains(.option) {
                sidebarLogger.debug("validateDrop: Internal drag - COPY")
                return .copy
            } else {
                sidebarLogger.debug("validateDrop: Internal drag - MOVE")
                return .move
            }
        } else {
            // External file drop - accept anywhere in the sidebar
            debugLog("validateDrop: External file drag detected")

            // For external files, retarget to the project root or accept at root level
            // This ensures drops anywhere in the sidebar are accepted
            if let dest = destinationItem {
                debugLog("validateDrop: External file over '\(dest.title)' type=\(String(describing: dest.type))")

                // If dropping on a specific container, accept there
                if dest.type == .folder || dest.type == .project || dest.type == .group {
                    debugLog("validateDrop: External file - ACCEPTING into container '\(dest.title)'")
                    return .copy
                }

                // If dropping on a file item, retarget to its parent container
                // The drop will still work - we just need to return .copy
                debugLog("validateDrop: External file over non-container - ACCEPTING (will use project root)")
                return .copy
            }

            // Drop at root level - accept it
            debugLog("validateDrop: External file - ACCEPTING at root level")
            return .copy
        }
    }

    /// Logs debug info for drag-and-drop troubleshooting
    private func debugLog(_ message: String) {
        sidebarLogger.debug("SidebarVC: \(message, privacy: .public)")
    }

    /// Performs the actual drop operation
    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        debugLog("acceptDrop: CALLED!")
        let pasteboard = info.draggingPasteboard
        let destinationItem = item as? SidebarItem
        debugLog("acceptDrop: destinationItem='\(destinationItem?.title ?? "nil")'")

        // Log all available pasteboard types
        let types = pasteboard.types ?? []
        debugLog("acceptDrop: Available pasteboard types: \(types.map { $0.rawValue }.joined(separator: ", "))")

        // Check if this is an internal drag
        let hasInternalType = pasteboard.availableType(from: [sidebarItemPasteboardType]) != nil
        debugLog("acceptDrop: hasInternalType=\(hasInternalType)")

        if hasInternalType {
            let identifiers = Self.draggedItemIdentifiers(from: pasteboard)
            debugLog("acceptDrop: Internal drag detected with \(identifiers.count) identifier(s)")

            // Find the source item by its identifier
            let sourceItems = identifiers.compactMap { findItem(byPath: $0) }
            if !sourceItems.isEmpty,
               let destinationURL = Self.internalDropDestinationURL(projectURL: projectURL, destinationItem: destinationItem) {
                // Check modifier keys for copy vs move
                let modifiers = NSEvent.modifierFlags
                let isCopy = modifiers.contains(.control) || modifiers.contains(.option)

                if isCopy {
                    // Copy the item
                    return copyItems(sourceItems, toFolderURL: destinationURL, at: index)
                } else {
                    // Move the item
                    return moveItems(sourceItems, toFolderURL: destinationURL, at: index)
                }
            }

            // Cross-window drags include our internal type but the source item
            // is not present in this window's sidebar model; fall through to the
            // external file URL path so the file is copied into this project.
            sidebarLogger.debug("acceptDrop: Internal identifier not resolvable in this sidebar; falling back to file URL import")
        }

        // External file drop
        debugLog("acceptDrop: Attempting to read file URLs from pasteboard")

        // Try reading with NSURL class
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            debugLog("acceptDrop: SUCCESS - got \(fileURLs.count) file URLs")
            for (i, url) in fileURLs.enumerated() {
                debugLog("acceptDrop: URL[\(i)] = \(url.path)")
            }

            sidebarLogger.info("acceptDrop: Posting notification for \(fileURLs.count) files")
            NotificationCenter.default.post(
                name: .sidebarFileDropped,
                object: self,
                userInfo: ["urls": fileURLs, "destination": destinationItem as Any]
            )
            return true
        }

        // Fallback: try reading file URLs directly from pasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            sidebarLogger.info("acceptDrop: Fallback - found \(urls.count) URLs")
            let fileURLs = urls.filter { $0.isFileURL }
            sidebarLogger.info("acceptDrop: Fallback - \(fileURLs.count) are file URLs")

            if !fileURLs.isEmpty {
                sidebarLogger.info("acceptDrop: Fallback posting notification for \(fileURLs.count) files")
                NotificationCenter.default.post(
                    name: .sidebarFileDropped,
                    object: self,
                    userInfo: ["urls": fileURLs, "destination": destinationItem as Any]
                )
                return true
            }
        }

        debugLog("acceptDrop: FAILED - No file URLs found in pasteboard")
        return false
    }

    // MARK: - Selection Helpers

    static func draggedItemIdentifiers(from pasteboard: NSPasteboard) -> [String] {
        var identifiers: [String] = []
        var seen = Set<String>()

        for item in pasteboard.pasteboardItems ?? [] {
            guard let identifier = item.string(forType: sidebarItemPasteboardType),
                  !seen.contains(identifier) else {
                continue
            }
            identifiers.append(identifier)
            seen.insert(identifier)
        }

        if identifiers.isEmpty,
           let identifier = pasteboard.string(forType: sidebarItemPasteboardType) {
            identifiers.append(identifier)
        }

        return identifiers
    }

    /// Returns all currently selected sidebar items
    public func selectedItems() -> [SidebarItem] {
        var items: [SidebarItem] = []
        outlineView.selectedRowIndexes.forEach { row in
            if let item = outlineView.item(atRow: row) as? SidebarItem {
                items.append(item)
            }
        }
        return items
    }

    /// Returns the URL of the first selected sidebar item that has a file URL.
    public var selectedFileURL: URL? {
        selectedItems().first(where: { $0.url != nil })?.url
    }

    static func suggestedMergedBundleName(for items: [SidebarItem]) -> String {
        let trimmedTitle = items.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? "Merged Bundle" : "\(trimmedTitle) merged"
    }

    static func mergeDialogInformativeText(for mergeKind: BundleMergeSelectionKind) -> String {
        switch mergeKind {
        case .fastq:
            return "Enter a name for the merged FASTQ bundle:"
        case .reference:
            return "Enter a name for the merged sequence-only reference bundle. Bundles with annotations, variants, tracks, or alignments are rejected rather than partially merged."
        }
    }

    static func deepestCommonParent(for urls: [URL]) -> URL? {
        let parentComponents = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var sharedComponents = parentComponents.first else { return nil }

        for components in parentComponents.dropFirst() {
            while sharedComponents.count > 1 && !components.starts(with: sharedComponents) {
                sharedComponents.removeLast()
            }
        }

        guard sharedComponents.count > 1 else { return nil }

        var result = URL(fileURLWithPath: sharedComponents[0], isDirectory: true)
        for component in sharedComponents.dropFirst() {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result.standardizedFileURL
    }

    static func internalDropDestinationURL(projectURL: URL?, destinationItem: SidebarItem?) -> URL? {
        if let destinationItem {
            guard destinationItem.type == .folder || destinationItem.type == .project else {
                return nil
            }
            return destinationItem.url?.standardizedFileURL
        }

        return projectURL?.standardizedFileURL
    }

    // MARK: - Select All Siblings

    /// Selects all sibling items of the currently selected item in the outline view.
    /// Triggered by Cmd+Shift+A. Useful for batch-selecting all barcodes at the same level.
    public func selectAllSiblings() {
        guard let selectedItem = selectedItems().first else { return }

        // Find the parent — siblings are the parent's children (or rootItems if top-level)
        let siblings: [SidebarItem]
        if let parent = findParent(of: selectedItem) {
            siblings = parent.children
        } else {
            // Top-level item — siblings are rootItems
            siblings = rootItems
        }

        guard siblings.count > 1 else { return }

        // Build row index set for all siblings
        var rowIndexes = IndexSet()
        for sibling in siblings {
            let row = outlineView.row(forItem: sibling)
            if row >= 0 {
                rowIndexes.insert(row)
            }
        }

        guard !rowIndexes.isEmpty else { return }
        outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        sidebarLogger.info("selectAllSiblings: Selected \(rowIndexes.count) sibling(s)")
    }

    // MARK: - Delete Operations

    /// Deletes the currently selected items, moving files to Trash
    @objc public func deleteSelectedItems() {
        let items = selectedItems()
        guard !items.isEmpty else {
            sidebarLogger.debug("deleteSelectedItems: No items selected")
            return
        }

        // Filter out items that shouldn't be deleted (groups, projects).
        // Batch groups WITH a URL (analysis batches in Analyses/) are deletable —
        // trashing the batch directory removes all component sample results.
        let deletableItems = items.filter { item in
            if item.type == .group || item.type == .project { return false }
            if item.type == .batchGroup { return item.url != nil }
            return true
        }

        guard !deletableItems.isEmpty else {
            sidebarLogger.debug("deleteSelectedItems: No deletable items in selection")
            return
        }
        guard canWriteSidebarProjectOutputs(
            workflowName: "Sidebar delete",
            targetURL: deletableItems.first?.url
        ) else {
            return
        }

        guard let window = view.window else { return }
        presentProgressiveDeleteConfirmation(items: deletableItems, in: window)
    }

    private func presentProgressiveDeleteConfirmation(items deletableItems: [SidebarItem], in window: NSWindow) {
        guard let projectURL else {
            presentDeleteConfirmation(items: deletableItems, impact: nil, in: window)
            return
        }

        let selectedURLs = deletableItems.compactMap(\.url)
        guard !selectedURLs.isEmpty else {
            presentDeleteConfirmation(items: deletableItems, impact: nil, in: window)
            return
        }

        let progressAlert = NSAlert()
        progressAlert.alertStyle = .informational
        progressAlert.messageText = "Checking Dependencies"
        progressAlert.informativeText = "Looking for project items that depend on the selected item\(deletableItems.count == 1 ? "" : "s")."
        progressAlert.addButton(withTitle: "Cancel")

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        progressAlert.accessoryView = progressIndicator

        var didCancel = false
        var didAdvanceToConfirmation = false
        let impactTask = Task.detached(priority: .userInitiated) {
            ProjectDeletionPlanner().impact(ofDeleting: selectedURLs, in: projectURL)
        }

        progressAlert.beginSheetModal(for: window) { _ in
            if !didAdvanceToConfirmation {
                didCancel = true
                impactTask.cancel()
            }
        }

        Task { @MainActor [weak self] in
            let impact = await impactTask.value
            let shouldPresentConfirmation = self != nil
                && !didCancel
                && self?.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
            if shouldPresentConfirmation {
                didAdvanceToConfirmation = true
            }
            let sheetWindow = progressAlert.window
            if sheetWindow.sheetParent === window {
                window.endSheet(sheetWindow)
            }
            guard let self,
                  shouldPresentConfirmation else {
                return
            }

            self.presentDeleteConfirmation(items: deletableItems, impact: impact, in: window)
        }
    }

    private func presentDeleteConfirmation(
        items deletableItems: [SidebarItem],
        impact: ProjectDeletionImpact?,
        in window: NSWindow
    ) {
        let itemCount = deletableItems.count
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let impact, impact.hasDependents {
            let presentation = ProjectDeletionDependencyListPresentation(
                dependentURLs: impact.dependentURLs,
                projectURL: projectURL
            )
            let dependentCount = presentation.count
            let selectedText = itemCount == 1
                ? "\"\(deletableItems[0].title)\""
                : "\(itemCount) selected items"
            let preview = presentation.previewLines.joined(separator: "\n")
            let overflow = presentation.overflowLine.map { "\n\($0)" } ?? ""

            alert.messageText = "Move Items With Dependencies to Trash?"
            alert.informativeText = """
            Moving \(selectedText) to the Trash will break provenance for \(dependentCount) dependent project item\(dependentCount == 1 ? "" : "s").

            Dependent items:
            \(preview)\(overflow)
            """
            alert.addButton(withTitle: "Move All to Trash")
            alert.addButton(withTitle: "Move Selected Only")
            if presentation.isTruncated {
                alert.addButton(withTitle: "Show Full List")
            }
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.applyLungfishDestructiveStyle()
            if alert.buttons.count > 1 {
                alert.buttons[1].applyLungfishDestructiveStyle()
            }
        } else {
            let message = itemCount == 1
                ? "Are you sure you want to move \"\(deletableItems[0].title)\" to the Trash?"
                : "Are you sure you want to move \(itemCount) items to the Trash?"

            alert.messageText = "Move to Trash"
            alert.informativeText = message
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.applyLungfishDestructiveStyle()
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if let impact, impact.hasDependents {
                let presentation = ProjectDeletionDependencyListPresentation(
                    dependentURLs: impact.dependentURLs,
                    projectURL: self.projectURL
                )
                switch response {
                case .alertFirstButtonReturn:
                    self.performDelete(items: deletableItems, includingDependentURLs: impact.dependentURLs)
                case .alertSecondButtonReturn:
                    self.performDelete(items: deletableItems)
                case .alertThirdButtonReturn where presentation.isTruncated:
                    self.showFullDeletionDependencyList(presentation, in: window) {
                        self.presentDeleteConfirmation(items: deletableItems, impact: impact, in: window)
                    }
                default:
                    return
                }
            } else {
                guard response == .alertFirstButtonReturn else { return }
                self.performDelete(items: deletableItems)
            }
        }
    }

    private func showFullDeletionDependencyList(
        _ presentation: ProjectDeletionDependencyListPresentation,
        in window: NSWindow,
        completion: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Affected Project Items"
        alert.informativeText = """
        These \(presentation.count) dependent project item\(presentation.count == 1 ? "" : "s") would have broken provenance if the selected item or items are moved to the Trash by themselves.
        """
        alert.addButton(withTitle: "Back")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.string = presentation.fullListText
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.beginSheetModal(for: window) { _ in
            completion()
        }
    }

    /// Performs the actual deletion of items
    private func performDelete(items: [SidebarItem], includingDependentURLs dependentURLs: [URL] = []) {
        sidebarLogger.info("performDelete: Deleting \(items.count) selected item(s) and \(dependentURLs.count) dependent URL(s)")
        guard canWriteSidebarProjectOutputs(
            workflowName: "Sidebar delete",
            targetURL: items.first?.url
        ) else {
            return
        }

        let deleteSignpost = PerfSignpost.sidebar.begin("Sidebar.Delete")
        defer { PerfSignpost.sidebar.end("Sidebar.Delete", deleteSignpost) }

        let planner = ProjectDeletionPlanner()
        let selectedItemsByPath = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, SidebarItem)? in
                guard let url = item.url else { return nil }
                return (url.standardizedFileURL.path, item)
            }
        )
        let deletionURLs = ProjectDeletionPlanner.topLevelURLsForDeletion(
            items.compactMap(\.url) + dependentURLs
        )
        let deletedItems = deletionURLs.compactMap { url in
            selectedItemsByPath[url.standardizedFileURL.path] ?? findItem(byPath: url.standardizedFileURL.path)
        }
        var failedItems: [(String, Error)] = []
        // Items whose row(s) we must remove from the outline once trashing succeeds.
        // Collected here rather than removed inline so a single surgical
        // removeItems(at:inParent:) pass (or one reload fallback) covers them all,
        // and so the (parent, index) mapping is computed against a stable model.
        var itemsToRemoveFromOutline: [SidebarItem] = []

        // Paired with end() below; do not add an early return between here and it,
        // or the interval leaks and the trace is silently wrong.
        let trashSignpost = PerfSignpost.sidebar.begin("Delete.FilesystemTrash")
        for url in deletionURLs {
            let item = selectedItemsByPath[url.standardizedFileURL.path] ?? findItem(byPath: url.standardizedFileURL.path)
            let label = item?.title ?? url.lastPathComponent
            let sidecars = planner.existingCompanionSidecarURLs(for: url)

            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                sidebarLogger.info("performDelete: Trashed file \(url.path, privacy: .public)")
            } catch {
                // If the object is already gone (e.g. removed by Finder, or a
                // race where macOS moved it for us), that is not a user-facing
                // failure: there is nothing left to delete.
                if Self.isAlreadyDeletedError(error) {
                    sidebarLogger.debug("performDelete: Object already removed, skipping \(url.path, privacy: .public)")
                } else {
                    sidebarLogger.error("performDelete: Failed to trash \(url.path, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    failedItems.append((label, error))
                    continue  // Don't remove from sidebar if file deletion failed
                }
            }
            removeAnalysisManifestReferencesIfNeeded(forDeleted: url)

            for sidecarURL in sidecars {
                // macOS moves an AppleDouble companion (._<name>) to Trash
                // alongside its paired object, so by the time we reach it the
                // companion may already be gone. Re-check existence and skip
                // silently rather than surfacing a spurious "doesn't exist"
                // alert to the user.
                guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
                    sidebarLogger.debug("performDelete: Companion sidecar already removed, skipping \(sidecarURL.path, privacy: .public)")
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil)
                    sidebarLogger.info("performDelete: Trashed companion sidecar \(sidecarURL.path, privacy: .public)")
                } catch {
                    // Tolerate a TOCTOU race: the companion may vanish between
                    // the existence check and the trash call. Only genuinely
                    // unexpected errors (permissions, etc.) are surfaced.
                    if Self.isAlreadyDeletedError(error) {
                        sidebarLogger.debug("performDelete: Companion sidecar already removed, skipping \(sidecarURL.path, privacy: .public)")
                    } else {
                        sidebarLogger.error("performDelete: Failed to trash sidecar \(sidecarURL.path, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                        failedItems.append((sidecarURL.lastPathComponent, error))
                    }
                }
            }

            if let item {
                itemsToRemoveFromOutline.append(item)
            }
        }
        PerfSignpost.sidebar.end("Delete.FilesystemTrash", trashSignpost)

        // Paired with end() below; do not add an early return between here and it.
        let modelSignpost = PerfSignpost.sidebar.begin("Delete.ModelMutation")
        for item in items where item.url == nil {
            itemsToRemoveFromOutline.append(item)
        }

        // Surgical removal of just the deleted rows instead of a full teardown/rebuild.
        // Falls back to reloadOutlineView() when surgical removal cannot be done safely
        // (filter active, deleting a parent together with a descendant, or an item no
        // longer in the tree) — applySurgicalRemoval mutates the model on success and
        // reports false to request the fallback.
        if !applySurgicalRemoval(of: itemsToRemoveFromOutline) {
            removeItemsFromSidebarForReloadFallback(itemsToRemoveFromOutline)
            reloadOutlineView()
        }

        PerfSignpost.sidebar.end("Delete.ModelMutation", modelSignpost)

        // Show error if some items failed
        if !failedItems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items could not be deleted"
            alert.informativeText = failedItems.map { "\($0.0): \($0.1.localizedDescription)" }.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }

        // Post notification about deletion
        let notifySignpost = PerfSignpost.sidebar.begin("Delete.Notify")
        defer { PerfSignpost.sidebar.end("Delete.Notify", notifySignpost) }
        NotificationCenter.default.post(
            name: .sidebarItemsDeleted,
            object: self,
            userInfo: windowScopedUserInfo(["items": deletedItems.isEmpty ? items : deletedItems])
        )
    }

    /// Returns `true` when `error` indicates the target file no longer exists,
    /// i.e. it was already deleted (by Finder, another agent, or because macOS
    /// moved an AppleDouble companion to Trash alongside its parent). Such an
    /// error must be treated as success, not surfaced to the user.
    ///
    /// Recognizes `NSCocoaErrorDomain` `NSFileNoSuchFileError` (4) and
    /// `NSPOSIXErrorDomain` `ENOENT` (2), including when wrapped as an
    /// underlying error.
    static func isAlreadyDeletedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if matchesNoSuchFile(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           matchesNoSuchFile(underlying) {
            return true
        }
        return false
    }

    private static func matchesNoSuchFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        return false
    }

    // MARK: - Surgical row removal

    /// A grouped set of rows to remove from the outline: the `parent` under which the
    /// rows live (`nil` for top-level `rootItems`) and the `IndexSet` of child indices
    /// occupied in that parent's children (computed against the PRE-mutation model).
    struct SurgicalRemovalGroup {
        let parent: SidebarItem?
        let indices: IndexSet
    }

    /// Computes the grouped (parent, indices) removals for `items`, or returns `nil`
    /// when surgical removal cannot be performed safely and the caller must fall back
    /// to a full `reloadData()`.
    ///
    /// Fallback (`nil`) is returned when:
    ///   - a filter is active (`isFiltered`): the outline reads `filteredRootItems`, a
    ///     detached copy, so indices computed against `rootItems` would not match;
    ///   - any item being deleted is a descendant of another item also being deleted
    ///     (removing the ancestor already removes the descendant — asking the outline
    ///     to also remove the descendant row would corrupt its bookkeeping);
    ///   - an item cannot be located in the tree at all.
    ///
    /// Indices are computed against the current (pre-removal) model. NSOutlineView's
    /// `removeItems(at:inParent:)` interprets its `IndexSet` against the same pre-removal
    /// state, so the caller must update the model to match INSIDE begin/endUpdates,
    /// removing high indices first within each parent so earlier removals do not shift
    /// the indices of later ones.
    static func surgicalRemovalPlan(
        for items: [SidebarItem],
        rootItems: [SidebarItem],
        isFiltered: Bool
    ) -> [SurgicalRemovalGroup]? {
        guard !isFiltered else { return nil }
        guard !items.isEmpty else { return [] }

        let deletionSet = Set(items.map(ObjectIdentifier.init))

        // Locate each item's parent and index within the tree.
        func findParent(of target: SidebarItem, in siblings: [SidebarItem], parent: SidebarItem?) -> SidebarItem? {
            for item in siblings {
                if item === target { return parent }
                if let found = findParent(of: target, in: item.children, parent: item) {
                    return found
                }
            }
            return nil
        }

        // Reject deleting an item whose ancestor is also being deleted.
        func hasAncestorInDeletionSet(_ item: SidebarItem) -> Bool {
            var current = findParent(of: item, in: rootItems, parent: nil)
            while let parent = current {
                if deletionSet.contains(ObjectIdentifier(parent)) { return true }
                current = findParent(of: parent, in: rootItems, parent: nil)
            }
            return false
        }

        var indicesByParent: [ObjectIdentifier?: IndexSet] = [:]
        var parentByKey: [ObjectIdentifier?: SidebarItem?] = [:]

        for item in items {
            if hasAncestorInDeletionSet(item) { return nil }

            let parent = findParent(of: item, in: rootItems, parent: nil)
            let siblings = parent?.children ?? rootItems
            guard let index = siblings.firstIndex(where: { $0 === item }) else {
                // Item not present in the tree: cannot map to a row safely.
                return nil
            }

            let key = parent.map(ObjectIdentifier.init)
            parentByKey[key] = parent
            indicesByParent[key, default: IndexSet()].insert(index)
        }

        return indicesByParent.map { key, indices in
            SurgicalRemovalGroup(parent: parentByKey[key] ?? nil, indices: indices)
        }
    }

    /// Surgically removes `items` from both the model and the outline, avoiding a full
    /// `reloadData()`. Returns `true` if the surgical path ran; `false` if the caller
    /// must fall back to `reloadOutlineView()`.
    ///
    /// The model is mutated INSIDE `begin/endUpdates`, removing the highest index first
    /// within each parent so earlier removals don't shift later indices, keeping the
    /// model and the outline's index-based `removeItems` in agreement.
    @discardableResult
    func applySurgicalRemoval(of items: [SidebarItem]) -> Bool {
        guard let plan = Self.surgicalRemovalPlan(
            for: items,
            rootItems: rootItems,
            isFiltered: filteredRootItems != nil
        ) else {
            return false
        }
        guard !plan.isEmpty else { return true }

        outlineView.beginUpdates()
        for group in plan {
            // Remove from the model high-to-low so lower indices stay valid.
            for index in group.indices.sorted(by: >) {
                if let parent = group.parent {
                    guard index < parent.children.count else { continue }
                    parent.children.remove(at: index)
                } else {
                    guard index < rootItems.count else { continue }
                    rootItems.remove(at: index)
                }
            }
            outlineView.removeItems(
                at: group.indices,
                inParent: group.parent,
                withAnimation: .slideUp
            )
        }
        outlineView.endUpdates()

        // A full reloadOutlineView() also recomputes the recommended width; keep that
        // behavior on the surgical path (removed rows can shorten the widest label).
        postPreferredSidebarWidthIfNeeded()
        return true
    }

    /// Removes an item from the sidebar hierarchy (without touching the file)
    private func removeItemFromSidebar(_ item: SidebarItem) {
        if let parent = findParent(of: item) {
            parent.children.removeAll { $0 === item }
            sidebarLogger.debug("removeItemFromSidebar: Removed '\(item.title, privacy: .public)' from parent '\(parent.title, privacy: .public)'")
        } else {
            // Item is at root level
            rootItems.removeAll { $0 === item }
            sidebarLogger.debug("removeItemFromSidebar: Removed '\(item.title, privacy: .public)' from root")
        }
    }

    /// Fallback removal used when `applySurgicalRemoval` declines the fast path.
    /// Filtered outlines contain detached copies, so resolve URL-backed rows to the
    /// canonical root-model item before mutating `rootItems`.
    func removeItemsFromSidebarForReloadFallback(_ items: [SidebarItem]) {
        for item in items {
            let modelItem = modelItemMatching(item) ?? item
            removeItemFromSidebar(modelItem)
        }
    }

    private func modelItemMatching(_ item: SidebarItem) -> SidebarItem? {
        guard let url = item.url else { return item }
        return findItem(byPath: url.standardizedFileURL.path) ?? findItem(byPath: url.path)
    }

    // MARK: - Drag Helper Methods

    /// Finds a sidebar item by its URL path
    private func findItem(byPath path: String) -> SidebarItem? {
        func search(in items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.url?.path == path || item.url?.standardizedFileURL.path == path || item.title == path {
                    return item
                }
                if let found = search(in: item.children) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootItems)
    }

    /// Finds the parent of a sidebar item
    private func findParent(of targetItem: SidebarItem) -> SidebarItem? {
        func search(in items: [SidebarItem], parent: SidebarItem?) -> SidebarItem? {
            for item in items {
                if item === targetItem {
                    return parent
                }
                if let found = search(in: item.children, parent: item) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootItems, parent: nil)
    }

    /// Moves an item from its current location to a new destination
    private func moveItem(_ sourceItem: SidebarItem, to destination: SidebarItem, at index: Int) -> Bool {
        moveItems([sourceItem], to: destination, at: index)
    }

    /// Moves multiple items from their current locations to a new destination.
    private func moveItems(_ sourceItems: [SidebarItem], to destination: SidebarItem, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        if sourceItems.count == 1 {
            sidebarLogger.info("moveItem: Moving '\(sourceItems[0].title, privacy: .public)' to '\(destination.title, privacy: .public)'")
        } else {
            sidebarLogger.info("moveItems: Moving \(sourceItems.count) items to '\(destination.title, privacy: .public)'")
        }

        guard let destFolderURL = destination.url else {
            sidebarLogger.warning("moveItems: Missing URL for destination")
            return false
        }

        return moveItems(sourceItems, toFolderURL: destFolderURL.standardizedFileURL, at: index)
    }

    private func moveItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        guard canWriteSidebarProjectOutputs(
            workflowName: "Sidebar move",
            targetURL: destFolderURL
        ) else {
            return false
        }

        var movedCount = 0
        for sourceItem in sourceItems {
            guard let sourceURL = sourceItem.url else {
                sidebarLogger.warning("moveItems: Missing URL for source '\(sourceItem.title, privacy: .public)'")
                continue
            }

            let standardizedSourceURL = sourceURL.standardizedFileURL
            let standardizedDestinationFolderURL = destFolderURL.standardizedFileURL

            if standardizedDestinationFolderURL == standardizedSourceURL ||
                standardizedDestinationFolderURL.path.hasPrefix(standardizedSourceURL.path + "/") {
                sidebarLogger.warning("moveItems: Cannot move '\(sourceItem.title, privacy: .public)' into itself or a descendant")
                continue
            }

            if standardizedSourceURL.deletingLastPathComponent() == standardizedDestinationFolderURL {
                sidebarLogger.debug("moveItems: '\(sourceItem.title, privacy: .public)' is already in destination")
                movedCount += 1
                continue
            }

            var destURL = standardizedDestinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destURL.path) {
                destURL = uniqueDestinationURL(for: sourceURL, in: standardizedDestinationFolderURL)
            }

            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                rehydrateScientificProvenance(from: sourceURL, to: destURL)
                rewriteAnalysisManifestReferencesIfNeeded(from: sourceURL, to: destURL)
                movedCount += 1
                sidebarLogger.info("moveItems: File moved from \(sourceURL.path, privacy: .public) to \(destURL.path, privacy: .public)")
            } catch {
                sidebarLogger.error("moveItems: Failed to move \(sourceURL.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }

        if movedCount > 0 {
            requestReloadFromFilesystem()
        }
        return movedCount == sourceItems.count
    }

    /// Copies an item to a new destination
    private func copyItem(_ sourceItem: SidebarItem, to destination: SidebarItem, at index: Int) -> Bool {
        copyItems([sourceItem], to: destination, at: index)
    }

    /// Copies multiple items to a new destination.
    private func copyItems(_ sourceItems: [SidebarItem], to destination: SidebarItem, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        if sourceItems.count == 1 {
            sidebarLogger.info("copyItem: Copying '\(sourceItems[0].title, privacy: .public)' to '\(destination.title, privacy: .public)'")
        } else {
            sidebarLogger.info("copyItems: Copying \(sourceItems.count) items to '\(destination.title, privacy: .public)'")
        }

        guard let destFolderURL = destination.url else {
            sidebarLogger.warning("copyItems: Missing URL for destination")
            return false
        }

        return copyItems(sourceItems, toFolderURL: destFolderURL.standardizedFileURL, at: index)
    }

    private func copyItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool {
        guard !sourceItems.isEmpty else { return false }
        guard canWriteSidebarProjectOutputs(
            workflowName: "Sidebar copy",
            targetURL: destFolderURL
        ) else {
            return false
        }

        var copiedCount = 0
        for sourceItem in sourceItems {
            guard let sourceURL = sourceItem.url else {
                sidebarLogger.warning("copyItems: Missing URL for source '\(sourceItem.title, privacy: .public)'")
                continue
            }

            let destURL = uniqueDestinationURL(for: sourceURL, in: destFolderURL.standardizedFileURL, copyStyle: true)

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                rehydrateScientificProvenance(from: sourceURL, to: destURL)
                copiedCount += 1
                sidebarLogger.info("copyItems: File copied to \(destURL.path, privacy: .public)")
            } catch {
                sidebarLogger.error("copyItems: Failed to copy \(sourceURL.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }

        if copiedCount > 0 {
            requestReloadFromFilesystem()
        }
        return copiedCount == sourceItems.count
    }

    private func uniqueDestinationURL(for sourceURL: URL, in destinationFolderURL: URL, copyStyle: Bool = false) -> URL {
        var destURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: destURL.path) else {
            return destURL
        }

        var counter = copyStyle ? 1 : 2
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension

        while FileManager.default.fileExists(atPath: destURL.path) {
            let suffix: String
            if copyStyle {
                suffix = counter > 1 ? "_copy_\(counter)" : "_copy"
                counter += 1
            } else {
                suffix = " \(counter)"
                counter += 1
            }
            let newName = fileExtension.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(fileExtension)"
            destURL = destinationFolderURL.appendingPathComponent(newName)
        }

        return destURL
    }
}
