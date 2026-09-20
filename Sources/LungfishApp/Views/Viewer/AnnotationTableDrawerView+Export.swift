// AnnotationTableDrawerView+Export.swift - CSV/TSV table export
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension AnnotationTableDrawerView {
    // MARK: - Export Action

    /// Shows a contextual export menu with scope and format options.
    @objc func showExportMenu(_ sender: Any?) {
        showScientificTableExportMenu(sender)
    }

    /// Extracts the display string for a given column/row, matching what the table shows.
    func cellValueString(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        if activeTab == .samples {
            return sampleCellValueString(for: identifier, row: row)
        }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            return genotypeCellValueString(for: identifier, row: row)
        }

        guard row < displayedAnnotations.count else { return "" }
        let annotation = displayedAnnotations[row]

        switch identifier {
        // Annotation columns
        case Self.nameColumn:
            return annotation.name
        case Self.typeColumn:
            return annotation.type
        case Self.chromosomeColumn:
            return annotation.chromosome
        case Self.startColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
        case Self.endColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
        case Self.sizeColumn:
            return formatSize(annotation.end - annotation.start)
        case Self.strandColumn:
            return annotation.strand

        // Variant columns
        case Self.variantIdColumn:
            return annotation.name
        case Self.variantTypeColumn:
            return annotation.type
        case Self.variantChromColumn:
            return annotation.chromosome
        case Self.positionColumn:
            let displayPos = annotation.start + 1
            return numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
        case Self.refColumn:
            return annotation.ref ?? ""
        case Self.altColumn:
            return annotation.alt ?? ""
        case Self.qualityColumn:
            if let q = annotation.quality {
                return q < 0 ? "." : String(format: "%.1f", q)
            }
            return "."
        case Self.filterColumn:
            return annotation.filter ?? "."
        case Self.samplesColumn:
            return "\(annotation.sampleCount ?? 0)"
        case Self.trackNameColumn:
            return annotationTrackName(for: annotation)
        case Self.trackIdColumn:
            return annotation.trackId
        case Self.callerSettingsColumn:
            return searchIndex?.variantCallerSettings(for: annotation.trackId) ?? "Not recorded"
        case Self.codingFeatureColumn:
            return variantCodingFeatureText(for: annotation)
        case Self.consequenceColumn:
            return variantConsequenceText(for: annotation)
        case Self.aaChangeColumn:
            return variantAAChangeText(for: annotation)
        case Self.sourceColumn:
            return annotation.sourceFile ?? ""

        default:
            if identifier.rawValue.hasPrefix("attr_") {
                let attributeKey = String(identifier.rawValue.dropFirst(5))
                return annotation.attributes?[attributeKey] ?? ""
            }
            // Dynamic INFO columns
            if identifier.rawValue.hasPrefix("info_") {
                let infoKey = String(identifier.rawValue.dropFirst(5))
                return annotation.infoDict?[infoKey] ?? ""
            }
            return ""
        }
    }

    /// Extracts the display string for a sample table cell.
    private func sampleCellValueString(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        guard row < displayedSamples.count else { return "" }
        let sample = displayedSamples[row]

        switch identifier {
        case Self.sampleVisibleColumn:
            return sample.isVisible ? "Yes" : "No"
        case Self.sampleNameColumn:
            return sample.name
        case Self.sampleSourceColumn:
            return sample.sourceFile
        default:
            if identifier.rawValue.hasPrefix("meta_") {
                let field = String(identifier.rawValue.dropFirst(5))
                return sample.metadata[field] ?? ""
            }
            return ""
        }
    }

    // MARK: - Column Configuration Popover

    /// Shows the column configuration popover anchored to the gear button.
    @objc func showColumnConfig(_ sender: Any?) {
        // Close existing popover if shown
        if let existing = columnConfigPopover, existing.isShown {
            existing.performClose(sender)
            return
        }

        let tabName = (activeTab == .variants && activeVariantSubtab == .genotypes)
            ? "variantGenotypes" : activeTab.prefsKey
        let currentColumns = buildColumnPreferenceList()

        let configView = ColumnConfigurationView(
            columns: currentColumns,
            tabName: tabName
        ) { [weak self] updatedColumns in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.applyColumnPreferences(updatedColumns)
                }
            }
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: configView)
        popover.show(relativeTo: columnConfigButton.bounds, of: columnConfigButton, preferredEdge: .maxY)
        columnConfigPopover = popover
    }

    /// Builds the current column preference list from the table's visible columns.
    private func buildColumnPreferenceList() -> [ColumnPreference] {
        let tabName = (activeTab == .variants && activeVariantSubtab == .genotypes)
            ? "variantGenotypes" : activeTab.prefsKey

        // Try loading saved preferences first
        if let saved = ColumnPrefsKey.load(tab: tabName) {
            // Merge: keep saved prefs but add any new columns discovered since last save
            let savedIds = Set(saved.columns.map(\.id))
            var columns = saved.columns
            let nextOrder = (columns.map(\.order).max() ?? -1) + 1

            // Check current table for any columns not in saved prefs (new INFO/meta columns)
            for (i, col) in tableView.tableColumns.enumerated() {
                let colId = col.identifier.rawValue
                if !savedIds.contains(colId) {
                    columns.append(ColumnPreference(
                        id: colId,
                        title: col.title,
                        isVisible: true,
                        order: nextOrder + i
                    ))
                }
            }
            return columns.sorted { $0.order < $1.order }
        }

        // No saved prefs — build from current table columns
        return tableView.tableColumns.enumerated().map { (i, col) in
            ColumnPreference(
                id: col.identifier.rawValue,
                title: col.title,
                isVisible: true,
                order: i
            )
        }
    }

    /// Applies column visibility and ordering from preferences.
    private func applyColumnPreferences(_ prefs: [ColumnPreference]) {
        let visiblePrefs = prefs.filter(\.isVisible).sorted { $0.order < $1.order }
        let visibleIds = Set(visiblePrefs.map(\.id))

        // Remove columns that should be hidden
        for col in tableView.tableColumns.reversed() {
            if !visibleIds.contains(col.identifier.rawValue) {
                tableView.removeTableColumn(col)
            }
        }

        // Reorder remaining columns to match preference order (re-query live on each iteration)
        for (targetIndex, pref) in visiblePrefs.enumerated() {
            guard let colIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == pref.id }) else {
                continue
            }
            if colIndex != targetIndex && targetIndex < tableView.tableColumns.count {
                tableView.moveColumn(colIndex, toColumn: targetIndex)
            }
        }
    }
}
