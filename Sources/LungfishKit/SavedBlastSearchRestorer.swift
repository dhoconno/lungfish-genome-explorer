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
/// flight is not replaced, a folder with no readable record is skipped, the newest record wins, and a selection with no
/// saved search leaves the pane as it is. The viewer shows what `present` hands it.
@MainActor
public final class SavedBlastSearchRestorer {
    /// The scan for the selection's saved search, which tests await.
    public private(set) var restoreTask: Task<Void, Never>?
    /// The selection whose saved search the pane shows, nil once a run's own words or result replace it.
    public private(set) var restoredRow: BlastSavedSearchRow?
    /// The record file the pane's result was read from, when one holds it.
    public private(set) var shownRecordURL: URL?
    /// The project whose `blast-verifications` folder a submit plan saves under, as the App knows it. With none, or when
    /// it gives nil, a scan with no folder of its own reads the project that holds the selection's result.
    public var savedSearchProject: (@MainActor () -> URL?)?

    private var selectedRow: BlastSavedSearchRow?
    private var isRunInFlight = false
    private var runOperationID: UUID?

    public init() {}

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
        guard let row, !runIsActive(), restoredRow != row else { return }
        let folder = directory ?? savedSearchProject?()
        restoreTask = Task { @MainActor [weak self] in
            let saved = await Self.newestSavedSearch(of: row, in: folder)
            guard let self,
                  let saved,
                  !Task.isCancelled,
                  self.selectedRow == row,
                  !self.runIsActive(),
                  self.restoredRow != row,
                  self.shownRecordURL != saved.url else {
                return
            }
            self.restoredRow = row
            self.shownRecordURL = saved.url
            present(saved.record.result, saved.url)
        }
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
    }

    /// A run ended, with its result read from `recordURL` or with its failure's words in the pane.
    public func runEnded(shownRecord recordURL: URL?) {
        isRunInFlight = false
        runOperationID = nil
        restoredRow = nil
        shownRecordURL = recordURL
    }

    private func runIsActive() -> Bool {
        guard isRunInFlight else { return false }
        guard let runOperationID else { return true }
        if OperationCenter.shared.activeItems.contains(where: { $0.id == runOperationID }) { return true }
        isRunInFlight = false
        self.runOperationID = nil
        return false
    }

    @concurrent nonisolated private static func newestSavedSearch(
        of row: BlastSavedSearchRow,
        in folder: URL?
    ) async -> (record: BlastSubmissionRecord, url: URL)? {
        guard let folder = folder ?? BlastVerificationArchive.savedSearchProject(ofResult: row.sourceResultURL) else {
            return nil
        }
        return BlastVerificationArchive.newestSubmission(in: folder) { record, url in
            row.isSource(of: record.lineage, recordAt: url)
        }
    }
}
