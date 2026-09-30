// AnnotationTableDrawerView+Export.swift - CSV/TSV table export
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore

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
            // Copy matches the 1-based closed value the cell shows.
            let displayStart = GenomicCoordinateDisplay.displayStart(annotation.start)
            return numberFormatter.string(from: NSNumber(value: displayStart)) ?? "\(displayStart)"
        case Self.endColumn:
            let displayEnd = GenomicCoordinateDisplay.displayEnd(annotation.end)
            return numberFormatter.string(from: NSNumber(value: displayEnd)) ?? "\(displayEnd)"
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

        return Self.mergedColumnPreferences(
            saved: ColumnPrefsKey.load(tab: tabName)?.columns,
            tableColumns: tableView.tableColumns.map { (id: $0.identifier.rawValue, title: $0.title) }
        )
    }

    /// Merges saved column preferences with the table's live columns.
    ///
    /// A live column the saved list has never seen, such as Variant Track in a
    /// layout saved before that column existed, goes right after the live column
    /// before it. Appending it instead put it at the bottom of the popover, and the
    /// next toggle moved it to the far right of the table.
    static func mergedColumnPreferences(
        saved: [ColumnPreference]?,
        tableColumns: [(id: String, title: String)]
    ) -> [ColumnPreference] {
        guard let saved else {
            return tableColumns.enumerated().map { i, col in
                ColumnPreference(id: col.id, title: col.title, isVisible: true, order: i)
            }
        }
        var columns = saved.sorted { $0.order < $1.order }
        for (i, col) in tableColumns.enumerated() where !columns.contains(where: { $0.id == col.id }) {
            let insertionIndex: Int
            if i > 0, let previous = columns.firstIndex(where: { $0.id == tableColumns[i - 1].id }) {
                insertionIndex = previous + 1
            } else {
                insertionIndex = 0
            }
            columns.insert(ColumnPreference(id: col.id, title: col.title, isVisible: true, order: 0), at: insertionIndex)
        }
        for i in columns.indices {
            columns[i].order = i
        }
        return columns
    }

    /// Applies column visibility and ordering from preferences.
    private func applyColumnPreferences(_ prefs: [ColumnPreference]) {
        let visiblePrefs = prefs.filter(\.isVisible).sorted { $0.order < $1.order }
        let visibleIds = Set(visiblePrefs.map(\.id))

        // A column shown again is no longer in the table. Rebuild the tab's columns,
        // which re-adds every column and applies the preferences just saved.
        let liveIds = Set(tableView.tableColumns.map(\.identifier.rawValue))
        let tableBuiltFromPreferences = !(activeTab == .variants && activeVariantSubtab == .genotypes)
        if tableBuiltFromPreferences, !visibleIds.isSubset(of: liveIds) {
            configureColumnsForTab(activeTab)
            tableView.reloadData()
            return
        }

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
