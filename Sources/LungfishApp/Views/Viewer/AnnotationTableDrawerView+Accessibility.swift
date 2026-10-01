// AnnotationTableDrawerView+Accessibility.swift - Keyboard and AX routes to the drawer's row commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The row commands the drawer last derived for one row, shared by every
/// cell of that row. The table asks for a row's cells one column at a time,
/// so building the row's context menu once per row instead of once per cell
/// keeps the install cheap while scrolling a large variant set.
struct AnnotationDrawerRowCommandCache {
    let key: String
    let names: [String]
    let selectors: [Selector]
}

/// Every command a drawer row's context menu offers, reachable without a
/// mouse.
///
/// The context menu is the source of truth. A row's cell accessibility
/// actions are its enabled commands (one submenu level flattened), named
/// exactly as the menu names them, and performing one rebuilds the menu for
/// the row the cell shows at that moment and sends the matching item. The
/// menu bar reaches the same commands for the selected row through
/// ``ResultRowMenuActions`` (Selection > Table Row) and
/// ``AnnotationEditingMenuActions`` (Sequence > Edit and Delete Annotation),
/// validated against the selection.
extension AnnotationTableDrawerView: NSMenuItemValidation, ResultRowMenuActions, AnnotationEditingMenuActions {

    // MARK: - Row context menu as data

    /// Builds the context menu a right-click on `row` would show, with no
    /// clicked column, so column filter items are left out.
    func buildRowContextMenu(_ menu: NSMenu, row: Int) {
        if activeTab == .samples {
            guard row >= 0, row < displayedSamples.count else { return }
            buildSampleContextMenu(menu, row: row, clickedColumn: -1)
            return
        }
        guard activeTab != .variants || activeVariantSubtab != .genotypes,
              row >= 0, row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        if annotation.isVariant {
            buildVariantContextMenu(menu, annotation: annotation)
        } else {
            buildAnnotationContextMenu(menu, annotation: annotation)
        }
    }

    /// The enabled commands of `row`'s context menu, in menu order.
    func rowCommandItems(for row: Int) -> [NSMenuItem] {
        let menu = NSMenu()
        menu.autoenablesItems = false
        buildRowContextMenu(menu, row: row)
        return AccessibilityMenuMirror.flattenedItems(of: menu)
    }

    /// Sends the command of `row`'s context menu whose action is `selector`
    /// (and, when given, whose title is `title`). Returns false when the row
    /// offers no such command right now.
    @discardableResult
    func performRowCommand(_ selector: Selector, title: String? = nil, on row: Int) -> Bool {
        let items = rowCommandItems(for: row)
        guard let item = items.first(where: { $0.action == selector && (title == nil || $0.title == title) })
            ?? items.first(where: { $0.action == selector }) else { return false }
        if selector == #selector(zoomToAnnotationAction(_:)) {
            // Zoom is the row's primary action: the same route as a
            // double-click and Return, which recentres through the delegate.
            activateRow(at: row)
            return true
        }
        AccessibilityMenuMirror.send(item)
        return true
    }

    /// Identifies the row's command set for the cache: the same row of the
    /// same tab with the same selection and bookmark state lists the same
    /// commands.
    private func rowCommandCacheKey(for row: Int) -> String {
        var parts = ["\(activeTab.rawValue)", "\(activeVariantSubtab.rawValue)", "\(row)", "\(tableView.selectedRowIndexes.count)"]
        if activeTab == .samples {
            parts.append(row < displayedSamples.count ? displayedSamples[row].name : "")
        } else if row < displayedAnnotations.count {
            let result = displayedAnnotations[row]
            parts.append(result.id.uuidString)
            if let variantRowId = result.variantRowId {
                parts.append(bookmarkedVariantKeys.contains(bookmarkKey(trackId: result.trackId, variantRowId: variantRowId)) ? "b" : "")
            }
        }
        return parts.joined(separator: "|")
    }

    /// The names and selectors of `row`'s commands, from the cache when the
    /// previous cell asked for the same row.
    func rowCommands(for row: Int) -> (names: [String], selectors: [Selector]) {
        let key = rowCommandCacheKey(for: row)
        if let cached = accessibilityRowCommandCache, cached.key == key {
            return (cached.names, cached.selectors)
        }
        let items = rowCommandItems(for: row)
        let cache = AnnotationDrawerRowCommandCache(key: key, names: items.map(\.title), selectors: items.compactMap(\.action))
        accessibilityRowCommandCache = cache
        return (cache.names, cache.selectors)
    }

    // MARK: - Cell actions

    /// Every cell of a row carries the row's context menu commands as
    /// accessibility custom actions, so VoiceOver and AX-driven automation
    /// reach what the mouse reaches. Genotype rows, which have no context
    /// menu, carry Zoom to Variant and Show in Inspector. Installed from the
    /// cell callback so reused cells always describe the row they show now,
    /// and every handler resolves the row again when it runs.
    func installAccessibilityActions(on cellView: NSView, row: Int) {
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            guard searchResult(forRow: row) != nil else {
                AccessibilityCellActions.install([], on: cellView)
                return
            }
            AccessibilityCellActions.install([
                AccessibilityCellActions.makeAction(name: "Zoom to Variant") { [weak self, weak cellView] in
                    guard let self, let cellView, let row = AccessibilityCellActions.currentRow(of: cellView) else { return }
                    self.activateRow(at: row)
                },
                AccessibilityCellActions.makeAction(name: "Show in Inspector") { [weak self, weak cellView] in
                    guard let self, let cellView, let row = AccessibilityCellActions.currentRow(of: cellView),
                          let current = self.searchResult(forRow: row) else { return }
                    self.showInInspector(current)
                },
            ], on: cellView)
            return
        }
        let commands = rowCommands(for: row)
        let actions = zip(commands.names, commands.selectors).map { name, selector in
            AccessibilityCellActions.makeAction(name: name) { [weak self, weak cellView] in
                guard let self, let cellView, let row = AccessibilityCellActions.currentRow(of: cellView) else { return }
                self.performRowCommand(selector, title: name, on: row)
            }
        }
        AccessibilityCellActions.install(actions, on: cellView)
    }

    // MARK: - Pull-down mirrors

    /// Lists the pull-downs' and pop-ups' items as custom actions on the
    /// buttons. Called after each menu is rebuilt, since the mirror is a
    /// snapshot. The export button computes its own mirror on demand.
    func installPullDownAccessibilityMirrors() {
        AccessibilityMenuMirror.install(on: profileButton)
        AccessibilityMenuMirror.install(on: sampleGroupPresetButton)
        AccessibilityMenuMirror.install(on: haploidModeButton)
    }

    // MARK: - Selection > Table Row and Sequence > Edit/Delete Annotation

    /// The single selected row's search result, for commands that act on
    /// one annotation or variant.
    private var singleSelectedResult: AnnotationSearchIndex.SearchResult? {
        guard tableView.numberOfSelectedRows == 1 else { return nil }
        return searchResult(forRow: tableView.selectedRow)
    }

    /// Whether the single selected row's context menu offers `selector` enabled.
    private func selectedRowOffers(_ selector: Selector) -> Bool {
        guard tableView.numberOfSelectedRows >= 1 else { return false }
        return rowCommandItems(for: tableView.selectedRow).contains { $0.action == selector }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(activateSelectedRow(_:)):
            return activeTab != .samples && tableView.numberOfSelectedRows == 1
        case #selector(copySelectedRowName(_:)):
            return singleSelectedResult != nil && selectedRowOffers(#selector(copyNameAction(_:)))
        case #selector(copySelectedRowSequence(_:)):
            return singleSelectedResult?.isVariant == false && selectedRowOffers(#selector(copySequenceAction(_:)))
        case #selector(copySelectedRowFASTA(_:)):
            return singleSelectedResult?.isVariant == false && selectedRowOffers(#selector(copyAsFASTAAction(_:)))
        case #selector(showSelectedRowInInspector(_:)):
            return singleSelectedResult != nil
        case #selector(extractSelectedRowsToNewBundle(_:)):
            return activeTab == .annotations
                && !selectedAnnotationResults().isEmpty && selectedRowOffers(#selector(extractSequenceAction(_:)))
        case #selector(editAnnotation(_:)):
            return activeTab == .annotations && singleSelectedResult != nil && selectedRowOffers(#selector(editAnnotationAction(_:)))
        case #selector(deleteAnnotation(_:)):
            return activeTab == .annotations && !selectedAnnotationResults().isEmpty
                && selectedRowOffers(#selector(deleteSelectedAnnotationsAction(_:)))
        default:
            return true
        }
    }

    @objc public func activateSelectedRow(_ sender: Any?) {
        guard tableView.numberOfSelectedRows == 1 else { return }
        activateRow(at: tableView.selectedRow)
    }

    @objc public func copySelectedRowName(_ sender: Any?) {
        guard singleSelectedResult != nil else { return }
        performRowCommand(#selector(copyNameAction(_:)), on: tableView.selectedRow)
    }

    @objc public func copySelectedRowSequence(_ sender: Any?) {
        guard singleSelectedResult != nil else { return }
        performRowCommand(#selector(copySequenceAction(_:)), on: tableView.selectedRow)
    }

    @objc public func copySelectedRowFASTA(_ sender: Any?) {
        guard singleSelectedResult != nil else { return }
        performRowCommand(#selector(copyAsFASTAAction(_:)), on: tableView.selectedRow)
    }

    @objc public func showSelectedRowInInspector(_ sender: Any?) {
        guard let result = singleSelectedResult else { return }
        showInInspector(result)
    }

    @objc public func extractSelectedRowsToNewBundle(_ sender: Any?) {
        guard tableView.selectedRow >= 0 else { return }
        performRowCommand(#selector(extractSequenceAction(_:)), on: tableView.selectedRow)
    }

    @objc public func editAnnotation(_ sender: Any?) {
        guard singleSelectedResult != nil else { return }
        performRowCommand(#selector(editAnnotationAction(_:)), on: tableView.selectedRow)
    }

    @objc public func deleteAnnotation(_ sender: Any?) {
        guard tableView.selectedRow >= 0 else { return }
        performRowCommand(#selector(deleteSelectedAnnotationsAction(_:)), on: tableView.selectedRow)
    }
}
