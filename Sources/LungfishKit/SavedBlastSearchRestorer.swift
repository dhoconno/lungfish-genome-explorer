// SavedBlastSearchRestorer.swift - Brings a saved BLAST search back when a selection is the one it was sent for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The saved-search rules of `ClassifierResultActions`, for a viewer whose selection is a contig or a set of sequences and
/// which does not use that component (Phase 3.1 lane REOPEN2, for Assembly and 12S).
///
/// The scan runs off the main actor. A scan that returns after the selection moved or a run began is dropped, a run in
/// flight is not replaced, the newest search wins, and a selection with no search leaves the pane as it is. A search that
/// waits at NCBI reads as waiting (BLAST-WAITING-NOT-ON-ROW), and news of a search scans again, so a late result reaches its
/// selection. The viewer shows what `present` and ``searchPane`` hand it.
@MainActor
public final class SavedBlastSearchRestorer: NSObject {
    /// The scan for the selection's saved search, which tests await.
    public private(set) var restoreTask: Task<Void, Never>?
    /// The selection whose saved search the pane shows, nil once a run's own words or result replace it.
    public private(set) var restoredRow: BlastSavedSearchRow?
    /// The record file the pane's result was read from, when one holds it.
    public private(set) var shownRecordURL: URL?
    /// The project whose `blast-verifications` folder a submit plan saves under, as the App knows it. With none, or when
    /// it gives nil, a scan with no folder of its own reads the project that holds the selection's result.
    public var savedSearchProject: (@MainActor () -> URL?)?
    /// The pane a search with no record shows in, opened as the viewer opens it.
    public var searchPane: (@MainActor () -> BlastResultsDrawerTab?)?

    private var selectedRow: BlastSavedSearchRow?
    private var lastDirectory: URL?
    private var lastPresent: (@MainActor (BlastVerificationResult, URL) -> Void)?
    private var isRunInFlight = false
    private var runOperationID: UUID?
    /// The selection each run began on, so that its result lands only there. Nil when none was known.
    private var runRows: [UUID: BlastSavedSearchRow?] = [:]

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(blastSearchChanged), name: BlastSearchNews.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(operationStateChanged), name: .operationStateChanged, object: nil)
    }

    /// The pane's Cancel, which the row's Cancel answers (BLAST-PANE-CANCEL-DEAD).
    public func cancelRun() {
        guard let runOperationID else { return }
        OperationCenter.shared.cancel(id: runOperationID)
    }

    /// A Cancel tells the pane nothing else, so this takes the pane off the spinner of the run that ended.
    @objc private func operationStateChanged() {
        guard runOperationID != nil, !runIsActive(), let pane = searchPane?(), pane.showsASearchInProgress else { return }
        pane.showEmpty()
    }

    /// Tells the restorer the selection changed. `row` is the selection's key, nil when there is nothing to look for.
    /// `directory` is the folder whose `blast-verifications` the selection's plan saves under, for a viewer whose plan
    /// does not save under the project. Nothing starts while a run is in flight or when the pane already shows this
    /// selection's search.
    public func select(
        _ row: BlastSavedSearchRow?,
        searchingIn directory: URL? = nil,
        present: @escaping @MainActor (BlastVerificationResult, URL) -> Void
    ) {
        restoreTask?.cancel()
        restoreTask = nil
        selectedRow = row
        guard let row else { return }
        lastDirectory = directory
        lastPresent = present
        guard !runIsActive(), restoredRow != row else { return }
        scan(row, force: false)
    }

    private func scan(_ row: BlastSavedSearchRow, force: Bool) {
        let folder = lastDirectory ?? savedSearchProject?()
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            let found = await Self.newestSearch(of: row, in: folder)
            guard let self,
                  let found,
                  !Task.isCancelled,
                  self.selectedRow == row,
                  !self.runIsActive(),
                  force || self.restoredRow != row else {
                return
            }
            switch found {
            case .saved(let record, let url):
                guard self.shownRecordURL != url else { return }
                self.restoredRow = row
                self.shownRecordURL = url
                self.lastPresent?(record.result, url)
            case .live(let search):
                self.restoredRow = row
                self.shownRecordURL = nil
                self.searchPane?()?.showWaiting(search)
            case .sourceReplaced(let folder):
                self.restoredRow = row
                self.shownRecordURL = nil
                self.searchPane?()?.showWaiting(BlastSearchPaneState.sourceReplaced(folder: folder))
            }
        }
    }

    /// A search changed on disk, wherever it began, so the selection is looked up again.
    @objc private func blastSearchChanged() {
        guard let selectedRow, !runIsActive() else { return }
        scan(selectedRow, force: true)
    }

    /// A run's progress is showing in the pane.
    public func runBegan() {
        isRunInFlight = true
        restoredRow = nil
        shownRecordURL = nil
    }

    /// Names the operation that carries the run the pane is waiting for. A Cancel tells the pane nothing, so the run
    /// counts as running only while its operation is active, and a cancelled run cannot block a saved search.
    public func trackRun(operationID: UUID) {
        isRunInFlight = true
        runOperationID = operationID
        runRows[operationID] = .some(selectedRow)
    }

    /// Whether the result of the run `operationID` belongs on the selection now. A run or a selection with no known key
    /// names nothing, so it lands. Asking takes the run off the list.
    public func runLands(operationID: UUID?) -> Bool {
        guard let operationID, let row = runRows.removeValue(forKey: operationID), let row, let selectedRow else { return true }
        return row == selectedRow
    }

    /// A run ended, with its result read from `recordURL` or with its failure's words in the pane.
    public func runEnded(shownRecord recordURL: URL?) {
        isRunInFlight = false
        runOperationID = nil
        restoredRow = nil
        shownRecordURL = recordURL
    }

    /// Whether a run's operation is still active.
    public var isRunActive: Bool { runIsActive() }

    private func runIsActive() -> Bool {
        guard isRunInFlight else { return false }
        guard let runOperationID else { return true }
        if OperationCenter.shared.activeItems.contains(where: { $0.id == runOperationID }) { return true }
        isRunInFlight = false
        self.runOperationID = nil
        return false
    }

    @concurrent nonisolated private static func newestSearch(
        of row: BlastSavedSearchRow,
        in folder: URL?
    ) async -> BlastRowSearch? {
        guard let folder = folder ?? BlastVerificationArchive.savedSearchProject(ofResult: row.sourceResultURL) else {
            return nil
        }
        return BlastVerificationArchive.newestSearch(in: folder) { lineage, url in
            row.isSource(of: lineage, recordAt: url)
        }
    }
}
