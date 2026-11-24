// ReferenceBundleViewportController+ViewMemory.swift - The reference and mapping viewport keeps its list and mode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane VS-MAP. The viewport's list (the sequence table of a reference, k08, or the contig table of a mapping result,
// k22) and its list or focused mode ride in the embedded viewer's record (`ReferenceViewerMemory.viewport`), so the
// item keeps one record with one writer, the viewer's visit (VS-REF Finding 5). The viewer asks for them when it keeps
// its view and hands them back after its settle, before it restores its place, so the kept place finds its sequence.

import AppKit
import LungfishIO
import LungfishKit

extension ReferenceBundleViewportController: ReferenceViewportMemoryOwner {
    func viewportShows(_ bundleURL: URL) -> Bool {
        currentInput?.renderedBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
    }

    /// The mode and the list the viewport shows now. It reads no file and no store.
    func captureViewportMemory() -> ReferenceViewportMemory? {
        let focused = presentationMode == .focusedDetail
        switch currentInput?.kind {
        case .mappingResult: return ReferenceViewportMemory(focused: focused, table: contigTableView.captureViewMemory())
        case .directBundle: return ReferenceViewportMemory(focused: focused, table: sequenceTableView.captureViewMemory())
        case nil: return nil
        }
    }

    /// Applies the kept list, then the kept mode, through the paths a person's picks take. A restored row is shown as a
    /// pick shows it, but its alignment action context, which hashes whole alignment files, waits until the person
    /// picks or clicks the row (SWIFT-EVIDENCE-HASH, VS S4). It starts nothing else.
    func restoreViewportMemory(_ memory: ReferenceViewportMemory, dataChanged: Bool) -> ViewMemoryLoss {
        let report: BatchTableRestoreReport
        let table: NSTableView
        switch currentInput?.kind {
        case .mappingResult:
            report = contigTableView.applyViewMemory(memory.table, dataChanged: dataChanged)
            table = contigTableView.tableView
        case .directBundle:
            report = sequenceTableView.applyViewMemory(memory.table, dataChanged: dataChanged)
            table = sequenceTableView.tableView
        case nil:
            return []
        }
        if memory.focused { enterFocusedDetailMode() } else { returnToListDetailMode() }
        // A click on the restored row counts as the pick that installs its action context.
        table.target = self
        table.action = #selector(viewMemoryRowClicked(_:))
        var loss: ViewMemoryLoss = []
        if report.filtersDropped { loss.insert(.filters) }
        if report.selection?.lostAny == true { loss.insert(.selection) }
        return loss
    }

    var viewMemoryRowsArePending: Bool { currentInput?.kind == .mappingResult && mappingRowsRefreshTask != nil }

    /// An open, and the mapping list's own row refresh for one track when it lands, select the list's first displayed
    /// row, or none while it shows none (`refreshSelection`, `refreshSequenceSelection`). All Alignments selects none
    /// when its rows land (`clearMappingSelectionAfterAllRebuild`), since each of its rows is another read predicate.
    /// So that selection is never a person's.
    var viewMemoryOwnSelection: [String] {
        let first: String? = switch currentInput?.kind {
        case .mappingResult where showsAllAlignments: nil
        case .mappingResult: contigTableView.displayedRows.first.flatMap { contigTableView.rowIdentity(for: $0) }
        case .directBundle: sequenceTableView.displayedRows.first.flatMap { sequenceTableView.rowIdentity(for: $0) }
        case nil: nil
        }
        return first.map { [$0] } ?? []
    }

    /// Whether the mapping list shows All Alignments: the result has alignment tracks and the viewer shows none of them
    /// alone, the one state in which `applyEmbeddedReadDisplaySettings` rebuilds the rows of every track.
    private var showsAllAlignments: Bool {
        embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting == nil
            && currentInput?.viewerBundleManifest?.alignments.isEmpty == false
    }

    /// Waits for the mapping list's own row refresh, and for any refresh that replaced it, to end.
    func viewMemoryRowsSettled() async {
        while let task = mappingRowsRefreshTask {
            await task.value
            if mappingRowsRefreshTask == task { return }
        }
    }

    @objc func viewMemoryRowClicked(_ sender: NSTableView) {
        pickRestoredRow(at: sender.clickedRow)
    }

    /// A click on the selected row while it has no alignment action context, as a restored row has none, is the
    /// person's pick of that row, and installs the context a pick installs (SWIFT-EVIDENCE-HASH). A row that has one,
    /// or whose context is being built, is left alone.
    func pickRestoredRow(at row: Int) {
        guard row >= 0, embeddedViewerController.alignmentActionContext == nil, alignmentActionContextTask == nil else {
            return
        }
        switch currentInput?.kind {
        case .mappingResult:
            guard row == contigTableView.tableView.selectedRow, let contig = currentSelectedContig(),
                  let bundleURL = currentInput?.renderedBundleURL else { return }
            installAlignmentActionContext(for: contig, bundleURL: bundleURL)
        case .directBundle:
            guard row == sequenceTableView.tableView.selectedRow, let record = currentSelectedSequence() else { return }
            installAlignmentActionContext(for: record)
        case nil:
            return
        }
    }
}

// MARK: - Restored read filters and the cue before the click (VS-MAP-2)

extension ViewMemoryWords {
    /// The cue a restored row shows while its alignment evidence waits for the person's click (VS-MAP-2 item 6,
    /// VS-MAP BIO SF-1 and R7(b)). Draft words until the UX review approves them as row 7 of the words table.
    static let alignmentEvidenceCue = "Click the selected row to load its alignment evidence."
}

extension ReferenceBundleViewportController {
    /// The in-view line (word 5a) for restored read filters, nil while none shows.
    var readFilterLine: ViewMemoryFilterLineView? { nil }
}
