// SidebarViewController+ItemActions.swift - One availability rule for the sidebar's row commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

// MARK: - Availability

extension SidebarViewController {

    /// The commands that apply to `items`, in context-menu order, grouped
    /// into the sections a separator divides.
    ///
    /// This is the one rule behind three surfaces: the context menu lists
    /// exactly these, Selection > Sidebar Item enables exactly these while
    /// the outline has focus, and each row's accessibility actions are the
    /// single-item subset. Two commands read a bundle's manifest to decide
    /// (Delete Variant Tracks, Reassemble); `includingManifestChecks: false`
    /// skips them, which the row actions use so configuring a cell never
    /// touches the disk.
    func availableSidebarItemActions(
        for items: [SidebarItem],
        includingManifestChecks: Bool = true
    ) -> [[SidebarItemAction]] {
        guard !items.isEmpty else { return [] }

        let hasFiles = items.contains {
            $0.type != .group
                && $0.type != .project
                && $0.type != .folder
                && !$0.type.isBundle
                && $0.type != .batchGroup
        }
        let hasFolders = items.contains { $0.type == .folder || $0.type == .project }
        let hasGroups = items.contains { $0.type == .group }
        let hasDeletable = items.contains { item in
            if item.type == .group || item.type == .project { return false }
            if item.type == .batchGroup { return item.url != nil }
            return true
        }
        let hasBundles = items.contains { $0.type == .referenceBundle }
        let hasFASTQBundles = items.contains { $0.type == .fastqBundle }
        let mergeSelectionKind = BundleMergeSelection.detectKind(for: items)
        let soleItem = items.count == 1 ? items.first : nil

        var sections: [[SidebarItemAction]] = []

        let ownedProjectURL = (view.window?.windowController as? MainWindowController)?.projectSession.projectURL
        if Self.canManageProjectStorage(
            selectedItems: items,
            currentProjectURL: projectURL,
            ownedProjectURL: ownedProjectURL
        ) {
            sections.append([.manageProjectStorage])
        }

        // Reference-shaped bundles export sequences; reference bundles merge.
        var exportSection: [SidebarItemAction] = []
        if items.contains(where: { $0.type.bundleCapabilities.canExportSequences }) {
            exportSection.append(.exportSequences)
            if mergeSelectionKind == .reference {
                exportSection.append(.mergeIntoNewBundle)
            }
        }
        sections.append(exportSection)

        if let soleItem, soleItem.type.bundleCapabilities.canExportAlignment, soleItem.url != nil {
            sections.append([.exportAlignment])
        }

        // The baseline bundle commands every bundle kind supports.
        if let soleItem, soleItem.type.isBundle {
            let capabilities = soleItem.type.bundleCapabilities
            var bundleSection: [SidebarItemAction] = []
            if capabilities.canOpen { bundleSection.append(.openBundle) }
            if capabilities.canShowPackageContents { bundleSection.append(.showPackageContents) }
            if capabilities.canGetBundleInfo { bundleSection.append(.getBundleInfo) }
            // Import Sample Metadata stays scoped to the two kinds its
            // handler supports.
            if hasBundles || hasFASTQBundles { bundleSection.append(.importSampleMetadata) }
            sections.append(bundleSection)

            if includingManifestChecks, let url = soleItem.url {
                var manifestSection: [SidebarItemAction] = []
                if bundleHasVariantTracks(url) { manifestSection.append(.deleteVariantTracks) }
                if bundleHasAssemblyProvenance(url) { manifestSection.append(.reassemble) }
                sections.append(manifestSection)
            }
        }

        if hasFASTQBundles {
            var fastqSection: [SidebarItemAction] = [.exportAsFASTQ]
            if mergeSelectionKind == .fastq { fastqSection.append(.mergeIntoNewBundle) }
            fastqSection.append(.cloneMetadataFrom)
            sections.append(fastqSection)
        }

        if let soleItem, soleItem.type == .classificationResult {
            sections.append([.copyClassificationCommand])
        }

        if soleItem != nil, hasFiles {
            sections.append([.open])
        }

        if (soleItem != nil && hasFolders) || projectURL != nil {
            sections.append([.newFolder])
        }

        if let soleItem, hasFolders, soleItem.url != nil,
           soleItem.children.contains(where: { $0.type == .fastqBundle }) {
            sections.append([.editFolderMetadata, .exportFolderMetadata, .importFolderMetadata])
        }

        var locateSection: [SidebarItemAction] = []
        if !hasGroups { locateSection.append(.showInFinder) }
        if !hasGroups, soleItem != nil { locateSection.append(.copyPath) }
        if let soleItem, soleItem.type.bundleCapabilities.canShowInInspector {
            locateSection.append(.showInInspector)
        }
        sections.append(locateSection)

        if let soleItem, !hasGroups, hasSiblings(soleItem) {
            sections.append([.selectSiblings])
        }

        var editSection: [SidebarItemAction] = []
        if !hasGroups, soleItem != nil { editSection.append(.rename) }
        if !hasGroups, hasFiles || hasFolders { editSection.append(.duplicate) }
        sections.append(editSection)

        if hasDeletable {
            sections.append([.moveToTrash])
        }

        return sections.filter { !$0.isEmpty }
    }

    /// True when `action` applies to the current selection.
    func canPerformSidebarItemAction(_ action: SidebarItemAction) -> Bool {
        availableSidebarItemActions(for: selectedItems()).contains { $0.contains(action) }
    }

    /// True while the sidebar outline is the key window's first responder,
    /// which is when the menu-bar chords (Cmd-Delete above all) may act on
    /// the selection rather than on a text field.
    var sidebarOutlineHasKeyboardFocus: Bool {
        guard let window = view.window, let outlineView else { return false }
        return window.firstResponder === outlineView
    }
}

// MARK: - Menu bar validation

extension SidebarViewController: NSMenuItemValidation {

    /// Selection > Sidebar Item and the shared Show in Inspector item reach
    /// the sidebar through the responder chain, so they are enabled only
    /// while the outline has keyboard focus and the selection supports the
    /// command. The context menu's own items are tied to the outline by
    /// construction and follow the selection alone. Anything else the
    /// sidebar answers (find, the Move to destinations) is always enabled.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action,
              let command = SidebarItemAction.command(for: action) else { return true }
        let isContextMenuItem = menuItem.menu?.delegate === self || menuItem.menu === outlineView?.menu
        if !isContextMenuItem, !sidebarOutlineHasKeyboardFocus { return false }
        return canPerformSidebarItemAction(command)
    }
}

// MARK: - Menu bar handlers

extension SidebarViewController: SidebarItemMenuActions {

    @objc public func moveSelectedSidebarItemsToTrash(_ sender: Any?) {
        deleteSelectedItems()
    }

    @objc public func selectSiblingSidebarItems(_ sender: Any?) {
        selectAllSiblings()
    }
}

// MARK: - Row accessibility actions

extension SidebarViewController {

    /// The accessibility custom actions of the row showing `item`: every
    /// single-item command the context menu would offer, named the same.
    ///
    /// The handlers resolve the item from `cellView` when they run, because
    /// the outline reuses cell views as it scrolls, and select its row first
    /// so the shared handlers act on it through `selectedItems()`.
    func accessibilityActions(for item: SidebarItem, cellView: NSView) -> [NSAccessibilityCustomAction] {
        availableSidebarItemActions(for: [item], includingManifestChecks: false)
            .flatMap { $0 }
            .map { action in
                action.makeAccessibilityAction { [weak self, weak cellView] in
                    guard let self, let cellView,
                          let current = AccessibilityCellActions.currentItem(of: cellView) as? SidebarItem
                    else { return }
                    self.performSidebarItemAction(action, on: current)
                }
            }
    }

    /// Selects `item` alone and runs `action` on it, the way choosing the
    /// context-menu item after a click would.
    func performSidebarItemAction(_ action: SidebarItemAction, on item: SidebarItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        switch action {
        case .manageProjectStorage:
            contextMenuManageProjectStorage(nil)
        case .exportSequences:
            NSApp.sendAction(action.menuSelector, to: nil, from: self)
        default:
            NSApp.sendAction(action.menuSelector, to: self, from: nil)
        }
    }
}
