// MultipleSequenceAlignmentViewController+ViewMemory.swift - The alignment viewer keeps its view for each bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The multiple sequence alignment adopts view memory as the 12S template does (`TwelveSSurface+ViewMemory.swift`): one
// struct holds the view fields, the surface conforms to `ViewMemoryAdopting`, and the restore applies each field by its
// rule. The host restores after the surface's load, which has read the whole alignment, and before the install, so the
// first frame is the kept view and no change of a person's can come first (VS A2). Nothing here reads or writes the
// bundle's own `.viewstate.json`, which its creation writes under the manifest checksums (VS A5), and nothing here
// starts a tool, a write into the bundle or a search (VS S4).

import AppKit
import LungfishIO
import LungfishKit

/// The view the alignment viewer keeps for one bundle.
///
/// Each field and its class (VS B2 to B9):
/// - `columnWidth` is the zoom, nil while the columns fit the view. Presentation, restored on any key, and centred on
///   the restored selection.
/// - `colorScheme` is the toolbar's colour scheme. Presentation, restored on any key.
/// - `findText` is the toolbar's find field. A find moves the selection and hides no row or column, so it is no count
///   filter of VS B6. Presentation, restored on any key, and the restore runs no find.
/// - `bottomPaneOpen` and `bottomPaneTab` are the bottom pane. Presentation, restored on any key through the pane's own
///   show, hide and tab, which store no choice, since a restore is no pick.
/// - `selection` holds rows by their row id (VS B4). Whole rows restore by identity on any key, a row that is gone is
///   dropped and the line says so. A block of rows and columns is a coordinate selection and restores only on an equal
///   data key, dropped otherwise and never clamped (VS B3). It is nil while the selection is the one the open makes,
///   so the open's own pick is never kept as a person's (VS S3).
///
/// Not kept: the residue display and the reference row, which only the Inspector shows and which it resets at each
/// open (`InspectorViewController+PublicAPI.swift`), the numbering and consensus options, also the Inspector's, the
/// variable sites switch, which hides columns and would need the line of VS B6, and the scroll, since the zoom centres
/// on the restored selection.
struct MultipleSequenceAlignmentViewState: ViewMemoryState {
    static var kind: String { SurfaceKind.bundle(.multipleSequenceAlignment).description }
    static var schemaVersion: Int { 1 }

    /// The selected rows by row id, the active row, and the alignment columns (0-based) of a block, nil for whole rows.
    struct Selection: Codable, Sendable, Equatable {
        var rowIDs: [String]
        var activeRowID: String?
        var columns: ClosedRange<Int>?
    }

    var columnWidth: Double?
    var colorScheme: Int
    var findText: String
    var bottomPaneOpen: Bool
    var bottomPaneTab: Int
    var selection: Selection?

    var selectionCount: Int { selection?.rowIDs.count ?? 0 }

    func withoutSelection() -> MultipleSequenceAlignmentViewState {
        var view = self
        view.selection = nil
        return view
    }
}

extension MultipleSequenceAlignmentSurface: ViewMemoryAdopting {
    /// Reads where the bundle lives and its data key once, off the main actor, after the load's alignment read has
    /// committed, so a capture and a restore read only memory (SWIFT 2).
    func readViewMemoryIdentity(at url: URL, manifest: MultipleSequenceAlignmentBundle.Manifest?) async {
        let read = await Task.detached(priority: .userInitiated) {
            (item: ViewMemoryItem.read(at: url), dataKey: MultipleSequenceAlignmentSurface.viewMemoryDataKey(of: manifest))
        }.value
        viewMemoryItem = read.item
        viewMemoryDataKey = read.dataKey
    }

    /// The data key of VS B1: one digest of the manifest's identifier and the checksums it records for the aligned rows
    /// and the row list. A new import or a rebuild at the same path changes it, an annotation edit does not. A manifest
    /// without either checksum gives no key, which never compares equal.
    nonisolated static func viewMemoryDataKey(of manifest: MultipleSequenceAlignmentBundle.Manifest?) -> String? {
        guard let manifest else { return nil }
        var checksums: [String: String] = [:]
        for path in ["alignment/primary.aligned.fasta", "metadata/rows.json"] {
            guard let checksum = manifest.checksums[path] else { return nil }
            checksums[path] = checksum
        }
        let key = ViewMemoryDataKey.payload(
            manifestIdentifier: manifest.identifier, recordID: nil, payloadChecksums: checksums)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(key)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureViewMemory() -> MultipleSequenceAlignmentViewState {
        guard let controller else {
            return MultipleSequenceAlignmentViewState(
                columnWidth: nil, colorScheme: 0, findText: "", bottomPaneOpen: false, bottomPaneTab: 0, selection: nil)
        }
        return MultipleSequenceAlignmentViewState(
            columnWidth: controller.fitsViewport ? nil : Double(controller.alignmentColumnWidth),
            colorScheme: controller.colorScheme.rawValue,
            findText: controller.searchField.stringValue,
            bottomPaneOpen: controller.bottomPane.isOpen,
            bottomPaneTab: controller.bottomPane.selectedTab.rawValue,
            selection: controller.isOpeningSelection ? nil : controller.capturedViewMemorySelection()
        )
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes, and starts nothing.
    /// Reset View hands back the starting view, whose nil selection puts back the open's own.
    func restoreViewMemory(_ state: MultipleSequenceAlignmentViewState, dataChanged: Bool) -> ViewMemoryLoss {
        guard let controller else { return [] }
        if let scheme = MultipleSequenceAlignmentColorScheme(rawValue: state.colorScheme), scheme != controller.colorScheme {
            controller.colorScheme = scheme
            controller.colorSchemeControl.selectedSegment = scheme.rawValue
            controller.configureCanvasViews()
        }
        controller.searchField.stringValue = state.findText
        if let tab = MSABottomPaneView.Tab(rawValue: state.bottomPaneTab) {
            controller.bottomPane.showKept(open: state.bottomPaneOpen, tab: tab)
        }
        let lost = controller.restoreViewMemorySelection(state.selection, dataChanged: dataChanged)
        // The zoom comes last, so it centres on the restored selection.
        if let width = state.columnWidth {
            if controller.fitsViewport || abs(CGFloat(width) - controller.alignmentColumnWidth) > 0.001 {
                controller.setAlignmentColumnWidth(CGFloat(width), centeredOnDisplayColumn: nil)
            }
        } else if !controller.fitsViewport {
            controller.zoomToFit()
        }
        return lost ? .selection : []
    }

    /// Tells the Inspector the selection and the window's drawer button the pane, through the viewer's own callbacks.
    /// At the install the route has not wired them yet and wires them itself, so this reaches them after a reset.
    func announceViewMemory() {
        controller?.notifySelectionStateIfAvailable()
        controller?.onBottomPaneStateChanged?()
    }
}

extension MultipleSequenceAlignmentViewController {
    /// The column the open selects in the first row, nil when the alignment has no column.
    private var openingColumn: Int? {
        guard let first = alignmentRows.first, !first.sequence.isEmpty else { return nil }
        return 0
    }

    /// Whether the selection is the one the open makes: the first row's first column, or none in an empty alignment.
    var isOpeningSelection: Bool {
        guard !alignmentRows.isEmpty else { return selectedRowIndices.isEmpty }
        let column = openingColumn
        return selectedRowIndices == IndexSet(integer: 0) && selectedRowIndex == 0 && !isWholeRowSelection
            && selectedAlignmentColumn == column && selectedAlignmentColumnRange == column.map { $0...$0 }
    }

    /// The selection by row id, never by index (VS B4).
    func capturedViewMemorySelection() -> MultipleSequenceAlignmentViewState.Selection {
        MultipleSequenceAlignmentViewState.Selection(
            rowIDs: selectedRowIndices.compactMap { rowIDsByIndex[safe: $0] },
            activeRowID: selectedRowIndex.flatMap { rowIDsByIndex[safe: $0] },
            columns: isWholeRowSelection ? nil : selectedAlignmentColumnRange
        )
    }

    /// Puts back a kept selection, or the open's own when `kept` is nil, and says whether any of it was lost. Whole
    /// rows come back by row id on any key. A block comes back only on an equal key and is never clamped (VS B3).
    func restoreViewMemorySelection(_ kept: MultipleSequenceAlignmentViewState.Selection?, dataChanged: Bool) -> Bool {
        guard let kept else {
            if !isOpeningSelection, let column = openingColumn {
                select(rowRange: 0...0, alignmentColumnRange: column...column)
            }
            return false
        }
        var indexOfRow: [String: Int] = [:]
        for (index, rowID) in rowIDsByIndex.enumerated() where indexOfRow[rowID] == nil {
            indexOfRow[rowID] = index
        }
        if let columns = kept.columns {
            guard !dataChanged else { return true }
            let rows = kept.rowIDs.compactMap { indexOfRow[$0] }
            let width = alignmentRows.first?.sequence.count ?? 0
            guard rows.count == kept.rowIDs.count, let low = rows.min(), let high = rows.max(), columns.lowerBound >= 0,
                  columns.upperBound < width else { return false }
            select(rowRange: low...high, alignmentColumnRange: columns)
            return false
        }
        let restore = ViewMemoryRules.keepIdentities(kept.rowIDs, existing: Set(rowIDsByIndex))
        let rows = IndexSet(restore.kept.compactMap { indexOfRow[$0] })
        // Word 2 says the data changed, so a loss is reported only when the data key changed (lesson 11).
        if rows.isEmpty, !kept.rowIDs.isEmpty { return dataChanged }
        let active = kept.activeRowID.flatMap { indexOfRow[$0] }.flatMap { rows.contains($0) ? $0 : nil }
        selectedRowIndices = rows
        selectedRowIndex = active ?? rows.first
        rowSelectionAnchor = selectedRowIndex
        isWholeRowSelection = true
        selectedAlignmentColumn = selectedAlignmentColumn ?? displayedColumns.first
        selectedAlignmentColumnRange = nil
        selectionAnchor = nil
        applySelectionToCanvasViews()
        refreshAnnotationDrawer()
        notifySelectionStateIfAvailable()
        return restore.lostAny && dataChanged
    }
}
