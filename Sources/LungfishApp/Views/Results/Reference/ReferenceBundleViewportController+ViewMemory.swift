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
        case .mappingResult:
            return ReferenceViewportMemory(focused: focused, table: contigTableView.captureViewMemory(), reads: shownReadFilters)
        case .directBundle:
            return ReferenceViewportMemory(focused: focused, table: sequenceTableView.captureViewMemory(), reads: shownReadFilters)
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
        // The read filters restore on an equal data key only; else the view and the block start at the defaults and the
        // line says "filters" (VS B6). Through the block's path, under the no-hash flag the caller holds (BIO R2).
        if let reads = memory.reads, !(dataChanged && reads == .defaults) {
            applyRestoredReadFilters(dataChanged ? .defaults : reads)
            if dataChanged { loss.insert(.filters) }
        }
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
        if sender.clickedRow >= 0 { notePersonsPick() }
        pickRestoredRow(at: sender.clickedRow)
    }

    /// Runs the list's own selection or row fill, so a selection change it sends notes no person's pick (VS-MAP-RACE).
    /// A row fill is one: `BatchTableView.configure(rows:)` sends the kept selection again when the rows of a list
    /// that still holds it are configured again, on a return in the same viewport or the Inspector's reload (SWIFT B1).
    /// A nested own call leaves the flag as it found it, so the outer call stays own to its end (SWIFT SF-1).
    func asOwnSelection(_ work: () -> Void) {
        let was = selectsOwnRow
        selectsOwnRow = true
        defer { selectsOwnRow = was }
        work()
    }

    /// Selects a row as the list's own open, refresh or reselect does (`refreshSelection`, `refreshSequenceSelection`,
    /// a `preferredSelectionName` open), so the selection change it sends notes no person's pick (VS-MAP-RACE).
    func selectOwnRow(_ row: Int, in table: NSTableView) {
        asOwnSelection { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    /// A person's pick of a row: a selection change the list did not make itself (a click or a keyboard move), the
    /// click on the restored row, or a test's selection, which stands for a click. Before the late restore lands it is
    /// a change under VS A2 even on the list's own first row (VS-MAP-RACE). It runs after the row's display, which may
    /// start the visit.
    func notePersonsPick() {
        guard !selectsOwnRow else { return }
        embeddedViewerController.noteViewMemoryPick()
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
    /// The cue a restored row shows while its alignment evidence waits for the person's click (VS-MAP-2 item 6),
    /// row 7 of section 1 of `VS-WORDS-decisions.md`. It names the list, which focused mode hides.
    static let alignmentEvidenceCue = "Click the selected row in the list to load its alignment evidence."
}

/// The read filters a reference or mapping view keeps (VS B6): the confidence, the two consensus quality limits and the
/// flags the duplicate, secondary and supplementary toggles set. They restore on an equal data key only. The read group
/// filter is not kept, since a restored row applies its own sample's groups (VS B4).
struct ReferenceReadFilters: Codable, Sendable, Equatable {
    var minMapQ: Int
    var consensusMinMapQ: Int
    var consensusMinBaseQ: Int
    var excludeFlags: UInt16

    /// The values a bundle opens with, the block's declared defaults (`resetDepthFilters`).
    static let defaults = ReferenceReadFilters(minMapQ: 0, consensusMinMapQ: 0, consensusMinBaseQ: 0, excludeFlags: 0xD04)

    /// Word 5a while the filters hide reads the defaults show, 5c while they only show more, none at the defaults.
    var lineForm: ViewMemoryFilterLineForm? {
        let excludesMore = excludeFlags & ~Self.defaults.excludeFlags != 0
        if minMapQ > 0 || consensusMinMapQ > 0 || consensusMinBaseQ > 0 || excludesMore {
            return .hiddenWithoutCount(kind: "Read", noun: "reads")
        }
        return self == .defaults ? nil : .changesValues
    }

    /// The keys the Inspector's block sends for these filters (`makeReadDisplaySettingsPayload`).
    var payload: [AnyHashable: Any] {
        [NotificationUserInfoKey.minMapQ: minMapQ, NotificationUserInfoKey.consensusMinMapQ: consensusMinMapQ,
         NotificationUserInfoKey.consensusMinBaseQ: consensusMinBaseQ, NotificationUserInfoKey.excludeFlags: excludeFlags]
    }
}

extension ReferenceBundleViewportController {
    /// The read filters the viewer shows now, which Extract and the consensus read too (`currentAlignmentFilters`).
    var shownReadFilters: ReferenceReadFilters? {
        guard let view = embeddedViewerController.viewerView else { return nil }
        return ReferenceReadFilters(
            minMapQ: view.minMapQSetting, consensusMinMapQ: view.consensusMinMapQSetting,
            consensusMinBaseQ: view.consensusMinBaseQSetting, excludeFlags: view.excludeFlagsSetting)
    }

    /// Applies restored read filters as the Inspector's block would, and shows the same values in the block, so the
    /// store and the block's carry never disagree (VS B6). The caller holds the no-hash flag (VS-MAP BIO R2).
    func applyRestoredReadFilters(_ filters: ReferenceReadFilters) {
        var next = parent
        while let controller = next, !(controller is MainSplitViewController) { next = controller.parent }
        if let block = (next as? MainSplitViewController)?.inspectorController.readStyleSectionViewModel {
            block.minMapQ = Double(filters.minMapQ)
            block.consensusMinMapQ = Double(filters.consensusMinMapQ)
            block.consensusMinBaseQ = Double(filters.consensusMinBaseQ)
            block.showSecondary = filters.excludeFlags & 0x100 == 0
            block.showDuplicates = filters.excludeFlags & 0x400 == 0
            block.showSupplementary = filters.excludeFlags & 0x800 == 0
        }
        applyEmbeddedReadDisplaySettings(filters.payload)
    }

    /// The viewer takes read display settings from the block or a restore, with the row's action context cleared, since
    /// the context is a snapshot of the filters. A person's change ends the filter line once the filters differ from
    /// those it spoke of, and the visit takes the list as it stands, so a leave keeps it.
    /// Returns true when these settings name no track and change no filter the context holds (the shown filters and
    /// `currentAlignmentFilters()`, the read groups with them). Such an apply, inside or outside the restore, clears no
    /// context, cancels no context task and installs none (VS-MAP-RACE item 2), so a restore that keeps the row and
    /// the filters keeps the context the open or the click built. It covers the echo too: the block's `.onChange`
    /// handlers send a restore's own filters back one SwiftUI pass after it, outside its no-hash window, and that must
    /// start no evidence hash and keep the cue (VS S4, SWIFT-EVIDENCE-HASH, BIO SF-1).
    @discardableResult
    func applyReadDisplaySettingsToViewer(_ userInfo: [AnyHashable: Any]) -> Bool {
        let namesTrack = userInfo.keys.contains(NotificationUserInfoKey.visibleAlignmentTrackID as AnyHashable)
        let before = (shownReadFilters, currentAlignmentFilters())
        embeddedViewerController.applyReadDisplaySettings(userInfo)
        let unchanged = !namesTrack && (shownReadFilters, currentAlignmentFilters()) == before
        if !unchanged { clearAlignmentActionContext() }
        guard !embeddedViewerController.isRestoringViewportMemory else { return unchanged }
        if let line = filterLineView, shownReadFilters != embeddedViewerController.viewMemory?.restoredReads {
            line.removeFromSuperview()
            embeddedViewerController.view.topAnchor.constraint(equalTo: detailContentContainer.topAnchor).isActive = true
        }
        _ = embeddedViewerController.captureViewerMemory()
        return unchanged
    }

    private var filterLineView: ViewMemoryFilterLineView? {
        detailContentContainer.subviews.lazy.compactMap { $0 as? ViewMemoryFilterLineView }.first
    }

    /// The in-view line (word 5a) for restored read filters, nil while none shows.
    var readFilterLine: ViewMemoryFilterLineView? { filterLineView.flatMap { $0.isHidden ? nil : $0 } }

    /// After a restore, or the block's carry, the viewport says that filters from the last visit hide reads (VS B6).
    /// The line sits in flow above the viewer and moves it down (LESSONS 4).
    func showReadFilterLineIfKept() {
        guard let filters = shownReadFilters, let form = filters.lineForm else { return }
        let line = filterLineView ?? {
            let line = ViewMemoryFilterLineView()
            let detailView = embeddedViewerController.view
            detailContentContainer.addSubview(line)
            detailContentContainer.constraints.first {
                $0.firstItem === detailView && $0.firstAttribute == .top && $0.secondItem === detailContentContainer
            }?.isActive = false
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: detailContentContainer.topAnchor),
                line.leadingAnchor.constraint(equalTo: detailContentContainer.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: detailContentContainer.trailingAnchor),
                detailView.topAnchor.constraint(equalTo: line.bottomAnchor),
            ])
            return line
        }()
        embeddedViewerController.viewMemory?.restoredReads = filters
        line.showRestored(form)
    }

    /// Reset View (VS U3): the list, the mode and the read filters as the open showed them, through the same paths a
    /// restore takes, and the filter line goes, since no kept filter stays (VS-MAP-2 UX ruling 5, BIO R9).
    func resetViewportMemory(to opening: ReferenceViewportMemory) {
        // The block's carry over a switch is not the open's: a bundle opens at the defaults, and the store's entry is
        // the one source of a kept filter (VS B6), so Reset View returns the defaults.
        var start = opening
        start.reads = .defaults
        _ = restoreViewportMemory(start, dataChanged: false)
        if let line = filterLineView {
            line.removeFromSuperview()
            embeddedViewerController.view.topAnchor.constraint(equalTo: detailContentContainer.topAnchor).isActive = true
        }
        embeddedViewerController.viewMemory?.restoredReads = nil
    }

    var selectedRowAwaitsItsContext: Bool {
        guard embeddedViewerController.alignmentActionContext == nil, alignmentActionContextTask == nil else { return false }
        switch currentInput?.kind {
        case .mappingResult: return currentSelectedContig() != nil
        case .directBundle: return currentSelectedSequence() != nil
        case nil: return false
        }
    }

    /// A context task that starts ends the cue in the consensus row, the Inspector and the alerts (VS-MAP-2 item 6).
    /// So does a clear outside the restore: a pick of a row with no evidence to load clears the context and starts no
    /// task, and a click on it loads nothing the cue could name (BIO SF-1).
    func alignmentActionContextTaskDidChange() {
        guard alignmentActionContextTask != nil || !embeddedViewerController.isRestoringViewportMemory else { return }
        embeddedViewerController.viewMemory?.contextWithheld = false
        embeddedViewerController.viewerView?.needsDisplay = true
        onConsensusActionStateChanged?()
    }
}
