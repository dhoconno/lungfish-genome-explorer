// AnnotationTableDrawerView+Menus.swift - NSMenuDelegate and the context menus of the annotation drawer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

// MARK: - NSMenuDelegate

extension AnnotationTableDrawerView: NSMenuDelegate {

    static func supportsTranslationMenu(for type: String) -> Bool {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "cds" || normalized == "mat_peptide"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let targetRow: Int
        if tableView.clickedRow >= 0 {
            targetRow = tableView.clickedRow
        } else {
            // Keyboard-invoked context menu (or tests) may not have a clicked row.
            targetRow = tableView.selectedRow
        }

        // Samples tab context menu
        if activeTab == .samples {
            let targetColumn = tableView.clickedColumn
            guard targetRow >= 0, targetRow < displayedSamples.count else {
                if targetColumn >= 0 {
                    buildSampleColumnHeaderContextMenu(menu, column: targetColumn)
                    return
                }
                buildSampleGlobalContextMenu(menu)
                return
            }
            buildSampleContextMenu(menu, row: targetRow, clickedColumn: targetColumn)
            return
        }

        // Genotype subtab: show column header context menu on header right-click
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            if tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
                buildGenotypeColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            }
            return
        }

        if activeTab == .variants && tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
            buildVariantColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            return
        }

        if activeTab == .annotations && tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
            buildAnnotationColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            return
        }

        guard targetRow >= 0, targetRow < displayedAnnotations.count else {
            if activeTab == .annotations {
                buildAnnotationGlobalContextMenu(menu)
            }
            return
        }

        let annotation = displayedAnnotations[targetRow]

        if annotation.isVariant {
            buildVariantContextMenu(menu, annotation: annotation)
        } else {
            buildAnnotationContextMenu(menu, annotation: annotation)
        }
    }

    func buildAnnotationGlobalContextMenu(_ menu: NSMenu) {
        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = searchIndex?.hasDatabaseBackend ?? true
        menu.addItem(addItem)
    }

    func buildAnnotationContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
        let isCDS = Self.supportsTranslationMenu(for: annotation.type)
        let selectedAnnotations = selectedAnnotationResults(fallback: annotation)
        let selectedCount = max(1, selectedAnnotations.count)

        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyNameAction(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        copyMenu.addItem(copyNameItem)

        let copyCoordsItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyCoordinatesAction(_:)), keyEquivalent: "")
        copyCoordsItem.target = self
        copyCoordsItem.representedObject = annotation
        copyMenu.addItem(copyCoordsItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copySequenceAction(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        copyMenu.addItem(copySeqItem)

        let copyRevCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyReverseComplementAction(_:)), keyEquivalent: "")
        copyRevCompItem.target = self
        copyRevCompItem.representedObject = annotation
        copyMenu.addItem(copyRevCompItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyFASTAItem = NSMenuItem(title: "Copy as FASTA", action: #selector(copyAsFASTAAction(_:)), keyEquivalent: "")
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        copyMenu.addItem(copyFASTAItem)

        if isCDS {
            let copyProteinItem = NSMenuItem(title: "Copy Translation as FASTA", action: #selector(copyTranslationAsFASTAAction(_:)), keyEquivalent: "")
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            copyMenu.addItem(copyProteinItem)
        }

        // Copy Translation (raw amino acids, only for CDS with stored translation)
        let translation = isCDS ? lookupTranslation(for: annotation) : nil
        if isCDS {
            copyMenu.addItem(NSMenuItem.separator())
            let copyTransItem = NSMenuItem(title: "Copy Translation", action: #selector(copyTranslationAction(_:)), keyEquivalent: "")
            copyTransItem.target = self
            copyTransItem.representedObject = annotation
            if translation == nil {
                copyTransItem.isEnabled = false
                copyTransItem.toolTip = "No translation data available for this annotation"
            }
            copyMenu.addItem(copyTransItem)
        }

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        // --- Extract ---
        let extractTitle = selectedCount > 1 ? "Extract \(selectedCount) Sequences\u{2026}" : "Extract Sequence\u{2026}"
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(extractSequenceAction(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        // --- Editing ---
        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = allowsAnnotationEditing && (searchIndex?.hasDatabaseBackend ?? true)
        menu.addItem(addItem)

        let editItem = NSMenuItem(title: "Edit Annotation\u{2026}", action: #selector(editAnnotationAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = annotation
        editItem.isEnabled = allowsAnnotationEditing && selectedCount == 1 && annotation.annotationRowId != nil
        menu.addItem(editItem)

        let editableAnnotations = selectedAnnotations.filter { $0.annotationRowId != nil }
        let editableTrackIDs = Set(editableAnnotations.map(\.trackId))
        let deleteCount = editableAnnotations.count
        let deleteTitle = deleteCount > 1 ? "Delete \(deleteCount) Selected Annotations\u{2026}" : "Delete Annotation\u{2026}"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedAnnotationsAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        deleteItem.isEnabled = allowsAnnotationEditing && deleteCount > 0 && editableTrackIDs.count == 1
        if deleteCount == 0 {
            deleteItem.toolTip = "Only SQLite-backed annotation rows can be deleted."
        } else if editableTrackIDs.count > 1 {
            deleteItem.toolTip = "Delete annotations from one annotation track at a time."
        }
        menu.addItem(deleteItem)

        let relatedItem = NSMenuItem(title: "Select Related Gene Features", action: #selector(selectRelatedGeneFeaturesAction(_:)), keyEquivalent: "")
        relatedItem.target = self
        relatedItem.representedObject = annotation
        relatedItem.isEnabled = ["gene", "mRNA", "transcript", "exon", "CDS"].contains(annotation.type)
        menu.addItem(relatedItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showInInspectorAction(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        // --- Variant cross-reference (only if variant data exists) ---
        if totalVariantCount > 0 {
            menu.addItem(NSMenuItem.separator())
            let variantItem = NSMenuItem(title: "Show Overlapping Variants", action: #selector(showOverlappingVariantsAction(_:)), keyEquivalent: "")
            variantItem.target = self
            variantItem.representedObject = annotation
            menu.addItem(variantItem)
        }
    }

    func buildVariantContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyIdItem = NSMenuItem(title: "Copy Variant ID", action: #selector(copyNameAction(_:)), keyEquivalent: "")
        copyIdItem.target = self
        copyIdItem.representedObject = annotation
        copyMenu.addItem(copyIdItem)

        let copyCoordsItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyCoordinatesAction(_:)), keyEquivalent: "")
        copyCoordsItem.target = self
        copyCoordsItem.representedObject = annotation
        copyMenu.addItem(copyCoordsItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyRefAltItem = NSMenuItem(title: "Copy Ref/Alt", action: #selector(copyRefAltAction(_:)), keyEquivalent: "")
        copyRefAltItem.target = self
        copyRefAltItem.representedObject = annotation
        copyMenu.addItem(copyRefAltItem)

        let copyVCFLineItem = NSMenuItem(title: "Copy as VCF Line", action: #selector(copyAsVCFLineAction(_:)), keyEquivalent: "")
        copyVCFLineItem.target = self
        copyVCFLineItem.representedObject = annotation
        copyMenu.addItem(copyVCFLineItem)

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        let zoomItem = NSMenuItem(title: "Zoom to Variant", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showInInspectorAction(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        menu.addItem(NSMenuItem.separator())

        // --- Bookmark ---
        if let variantRowId = annotation.variantRowId {
            let isBookmarked = bookmarkedVariantKeys.contains(bookmarkKey(trackId: annotation.trackId, variantRowId: variantRowId))
            let bookmarkTitle = isBookmarked ? "Remove Bookmark" : "Bookmark Variant"
            let bookmarkItem = NSMenuItem(title: bookmarkTitle, action: #selector(contextBookmarkToggle(_:)), keyEquivalent: "")
            bookmarkItem.target = self
            bookmarkItem.representedObject = annotation
            menu.addItem(bookmarkItem)
        }

        if hasBookmarks {
            let exportBookmarksItem = NSMenuItem(title: "Export Bookmarked Variants\u{2026}", action: #selector(exportBookmarkedVariants(_:)), keyEquivalent: "")
            exportBookmarksItem.target = self
            menu.addItem(exportBookmarksItem)
        }

        menu.addItem(NSMenuItem.separator())

        // --- Filter by Type ---
        let filterTypeItem = NSMenuItem(title: "Filter to \(annotation.type) Only", action: #selector(filterToTypeAction(_:)), keyEquivalent: "")
        filterTypeItem.target = self
        filterTypeItem.representedObject = annotation
        menu.addItem(filterTypeItem)

        menu.addItem(NSMenuItem.separator())

        // --- Delete ---
        let selectedCount = commandSelectionIndexes.count
        let deleteTitle = selectedCount > 1 ? "Delete \(selectedCount) Selected Variants\u{2026}" : "Delete Selected Variant\u{2026}"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedVariantsAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        let deleteAllItem = NSMenuItem(title: "Delete All Variants\u{2026}", action: #selector(deleteAllVariantsAction(_:)), keyEquivalent: "")
        deleteAllItem.target = self
        menu.addItem(deleteAllItem)
    }

    func annotationFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.nameColumn.rawValue: return "name"
        case Self.trackIdColumn.rawValue: return "track_id"
        case Self.trackNameColumn.rawValue: return "track_name"
        case Self.typeColumn.rawValue: return "type"
        case Self.chromosomeColumn.rawValue: return "chromosome"
        case Self.startColumn.rawValue: return "start"
        case Self.endColumn.rawValue: return "end"
        case Self.sizeColumn.rawValue: return "size"
        case Self.strandColumn.rawValue: return "strand"
        default:
            if columnId.hasPrefix("attr_") { return columnId }
            return nil
        }
    }

    func addAnnotationColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applyAnnotationColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc func applyAnnotationColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        annotationColumnFilterClauses.append(ColumnFilterClause(key: key, op: op, value: value))
        refreshAnnotationColumnFilters()
    }

    @objc func promptAnnotationColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Annotation Column Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !value.isEmpty else { return }
            self.annotationColumnFilterClauses.append(ColumnFilterClause(key: key, op: op, value: value))
            self.refreshAnnotationColumnFilters()
        }
    }

    @objc func clearAnnotationColumnFilters(_ sender: Any?) {
        annotationColumnFilterClauses.removeAll()
        refreshAnnotationColumnFilters()
    }

    func refreshAnnotationColumnFilters() {
        if activeTab == .annotations, searchIndex?.hasDatabaseBackend == true {
            updateDisplayedAnnotations()
        } else {
            applyAnnotationColumnFiltersFromBase()
        }
    }

    func buildAnnotationColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        let tableColumn = tableView.tableColumns[column]
        guard let key = annotationFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else { return }
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title

        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = searchIndex?.hasDatabaseBackend ?? true
        menu.addItem(addItem)
        menu.addItem(NSMenuItem.separator())

        addColumnSizingMenuItems(menu, tableColumn: tableColumn)
        menu.addItem(NSMenuItem.separator())

        if isAnnotationFilterNumericKey(key) {
            for (title, op) in [
                ("Filter \(displayName) Equals...", "="),
                ("Filter \(displayName) >=...", ">="),
                ("Filter \(displayName) >...", ">"),
                ("Filter \(displayName) <=...", "<="),
                ("Filter \(displayName) <...", "<"),
            ] {
                let item = NSMenuItem(title: title, action: #selector(promptAnnotationColumnFilterAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        } else {
            for (title, op) in [
                ("Filter \(displayName) Contains...", "~"),
                ("Filter \(displayName) Equals...", "="),
                ("Filter \(displayName) Begins With...", "^="),
                ("Filter \(displayName) Ends With...", "$="),
            ] {
                let item = NSMenuItem(title: title, action: #selector(promptAnnotationColumnFilterAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        addAnnotationColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addAnnotationColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Annotation Column Filters", action: #selector(clearAnnotationColumnFilters(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    func variantFilterKey(forColumnIdentifier columnId: String) -> String? {
        if let definition = Self.variantColumnDefs.first(where: { $0.0.rawValue == columnId }) {
            return definition.4
        }
        return columnId.hasPrefix("info_") ? columnId : nil
    }

    func isVariantFilterNumericKey(_ key: String) -> Bool {
        switch key {
        case "position", "quality", "samples":
            return true
        default:
            if key.hasPrefix("info_") {
                let infoKey = String(key.dropFirst(5))
                return isNumericInfoKey(infoKey)
            }
            return false
        }
    }

    func addVariantColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applyVariantColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc func applyVariantColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        variantColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
        let normalizedKey = key.hasPrefix("info_") ? String(key.dropFirst(5)) : key
        if searchIndex?.variantFormatOverlaySnapshot.allProjectedKeys.contains(normalizedKey) == true {
            updateDisplayedAnnotations()
        } else {
            applyVariantColumnFiltersFromBase()
        }
    }

    @objc func promptVariantColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Variant Column Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !value.isEmpty else { return }
            self.variantColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
            let normalizedKey = key.hasPrefix("info_") ? String(key.dropFirst(5)) : key
            if self.searchIndex?.variantFormatOverlaySnapshot.allProjectedKeys.contains(normalizedKey) == true {
                self.updateDisplayedAnnotations()
            } else {
                self.applyVariantColumnFiltersFromBase()
            }
        }
    }

    @objc func clearVariantColumnFilters(_ sender: Any?) {
        let hadProjectedFilter = variantColumnFilterClauses.contains { clause in
            let key = clause.key.hasPrefix("info_") ? String(clause.key.dropFirst(5)) : clause.key
            return searchIndex?.variantFormatOverlaySnapshot.allProjectedKeys.contains(key) == true
        }
        variantColumnFilterClauses.removeAll()
        if hadProjectedFilter { updateDisplayedAnnotations() }
        else { applyVariantColumnFiltersFromBase() }
    }

    func buildVariantColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        let tableColumn = tableView.tableColumns[column]
        addColumnSizingMenuItems(menu, tableColumn: tableColumn)

        guard let key = variantFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else { return }
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title

        menu.addItem(NSMenuItem.separator())
        let ascendingItem = NSMenuItem(
            title: "Sort \(displayName) Ascending",
            action: #selector(sortVariantColumnAscending(_:)),
            keyEquivalent: ""
        )
        ascendingItem.target = self
        ascendingItem.representedObject = tableColumn.identifier.rawValue
        menu.addItem(ascendingItem)
        let descendingItem = NSMenuItem(
            title: "Sort \(displayName) Descending",
            action: #selector(sortVariantColumnDescending(_:)),
            keyEquivalent: ""
        )
        descendingItem.target = self
        descendingItem.representedObject = tableColumn.identifier.rawValue
        menu.addItem(descendingItem)
        menu.addItem(NSMenuItem.separator())

        if isVariantFilterNumericKey(key) {
            let equalsItem = NSMenuItem(
                title: "Filter \(displayName) Equals\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            equalsItem.target = self
            equalsItem.representedObject = ["key": key, "op": "="]
            menu.addItem(equalsItem)

            let gteItem = NSMenuItem(
                title: "Filter \(displayName) \u{2265}\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            gteItem.target = self
            gteItem.representedObject = ["key": key, "op": ">="]
            menu.addItem(gteItem)

            let gtItem = NSMenuItem(
                title: "Filter \(displayName) >\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            gtItem.target = self
            gtItem.representedObject = ["key": key, "op": ">"]
            menu.addItem(gtItem)

            let lteItem = NSMenuItem(
                title: "Filter \(displayName) \u{2264}\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            lteItem.target = self
            lteItem.representedObject = ["key": key, "op": "<="]
            menu.addItem(lteItem)

            let ltItem = NSMenuItem(
                title: "Filter \(displayName) <\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            ltItem.target = self
            ltItem.representedObject = ["key": key, "op": "<"]
            menu.addItem(ltItem)
        } else {
            let containsItem = NSMenuItem(
                title: "Filter \(displayName) Contains\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            containsItem.target = self
            containsItem.representedObject = ["key": key, "op": "~"]
            menu.addItem(containsItem)

            let equalsItem = NSMenuItem(
                title: "Filter \(displayName) Equals\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            equalsItem.target = self
            equalsItem.representedObject = ["key": key, "op": "="]
            menu.addItem(equalsItem)

            let beginsWithItem = NSMenuItem(
                title: "Filter \(displayName) Begins With\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            beginsWithItem.target = self
            beginsWithItem.representedObject = ["key": key, "op": "^="]
            menu.addItem(beginsWithItem)

            let endsWithItem = NSMenuItem(
                title: "Filter \(displayName) Ends With\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            endsWithItem.target = self
            endsWithItem.representedObject = ["key": key, "op": "$="]
            menu.addItem(endsWithItem)
        }

        menu.addItem(NSMenuItem.separator())
        addVariantColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addVariantColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Variant Column Filters", action: #selector(clearVariantColumnFilters(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc func sortVariantColumnAscending(_ sender: NSMenuItem) {
        setVariantColumnSort(sender, ascending: true)
    }

    @objc func sortVariantColumnDescending(_ sender: NSMenuItem) {
        setVariantColumnSort(sender, ascending: false)
    }

    private func setVariantColumnSort(_ sender: NSMenuItem, ascending: Bool) {
        guard let identifier = sender.representedObject as? String,
              let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == identifier }),
              let prototype = column.sortDescriptorPrototype,
              let key = prototype.key else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
    }

    /// The operation center owns bundle exclusion until the synchronous durable
    /// worker has committed or rolled back. Only immutable inputs enter the worker.
    @discardableResult
    func runVariantStorageMutation<Value: Sendable>(
        title: String, bundleURL: URL, command: [String], center: OperationCenter = .shared,
        work: @escaping @Sendable () throws -> Value,
        publish: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never>? {
        guard let source = searchIndex else { return nil }
        let owner = window?.windowController as? MainWindowController
        let session = owner?.projectSession
        let generation = session?.documentGeneration
        let sourceWindow = window
        let scope = windowStateScope
        let route = OperationRouteContext(
            projectURL: session?.projectURL ?? owner?.mainSplitViewController?.sidebarController?.currentProjectURL
                ?? ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: scope)
        var task: Task<Void, Never>?
        Self.beginVariantStorageMutationOperation(title: title, bundleURL: bundleURL, command: command, routeContext: route, reporter: center) { operationID in
            variantStorageOperationID = operationID
            task = Task { @MainActor [weak self] in
                defer {
                    if self?.variantStorageOperationID == operationID {
                        self?.variantStorageOperationID = nil
                        self?.variantStorageMutationTask = nil
                    }
                }
                do {
                    let result = try await Task.detached(priority: .userInitiated, operation: work).value
                    center.complete(id: operationID, detail: "Data and provenance updated")
                    guard let self, self.searchIndex === source, self.window === sourceWindow,
                          self.windowStateScope == scope, session?.documentGeneration == generation else { return }
                    publish(result)
                } catch {
                    center.fail(id: operationID, detail: "Stored data update failed", errorMessage: error.localizedDescription)
                    annotationDrawerLogger.error("Stored data update failed: \(error.localizedDescription)")
                }
            }
            variantStorageMutationTask = task
        }
        return task
    }
}
