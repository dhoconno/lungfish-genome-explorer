// TwelveSAmpliconResultViewController+SavedBlast.swift - The saved BLAST search of the unresolved selection comes back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

extension TwelveSAmpliconResultViewController {
    /// The project the App saves this viewer's searches under. With none, a scan reads the project that holds the result.
    public var savedBlastSearchProject: (@MainActor () -> URL?)? {
        get { savedBlastRestorer.savedSearchProject }
        set { savedBlastRestorer.savedSearchProject = newValue }
    }

    /// Names the operation that carries the run the pane is waiting for, so a cancelled run cannot block a saved search.
    public func trackBlastRun(operationID: UUID) {
        savedBlastRestorer.trackRun(operationID: operationID)
    }

    /// A run's result, shown only when the sequences selected are still the ones it was sent for. Otherwise it stays on
    /// disk and comes back when those sequences are selected, so no verdict shows over another selection.
    public func landBlastResults(_ result: BlastVerificationResult, recordURL: URL?, run: UUID?) {
        guard savedBlastRestorer.runLands(operationID: run) else {
            if !savedBlastRestorer.isRunActive, ensureBlastDrawer().showsASearchInProgress { ensureBlastDrawer().showEmpty() }
            return
        }
        showBlastResults(result, recordURL: recordURL)
        updateBlastRerunRule()
    }

    /// Re-run BLAST sends the sequences selected, or else those listed, so with neither it greys and says why (RERUN-SILENT).
    func updateBlastRerunRule() {
        guard let drawer = blastDrawerContainer?.blastResultsTab else { return }
        drawer.setRerunRule(enabled: !selectedUnresolvedRows().isEmpty, reason: ClassifierActionWords.selectRowToVerify)
    }

    /// Shows a search that has gone out and has no result.
    package func showBlastWaiting(_ search: BlastLiveSearch) {
        ensureBlastDrawer().showWaiting(search)
        openBlastDrawerIfNeeded()
    }

    /// Looks for the saved search of the sequences a BLAST would send now (Phase 3.1 lane REOPEN2), the selected unresolved
    /// rows or, with none selected, every row showing. A search matches on its bundle and the IDs and sequences its query
    /// holds, in any order, since its lineage names no sample, taxon or contig and an ID is only a rank in its run, which a
    /// re-run at the same path gives to another sequence. The Targets list has no search. This viewer has no
    /// control that opens a closed pane, so a restore opens it, since a result nobody can reach would not close the gap.
    func scheduleSavedBlastRestore() {
        let sequences = selectedUnresolvedRows().map {
            BlastSavedSearchRow.QuerySequence(id: $0.sequenceID, sequence: $0.sequence)
        }
        let row = result.flatMap { BlastSavedSearchRow.twelveSSelection(sequences: sequences, bundleURL: $0.bundleURL) }
        savedBlastRestorer.searchPane = { [weak self] in
            self?.openBlastDrawerIfNeeded()
            return self?.ensureBlastDrawer()
        }
        savedBlastRestorer.select(row) { [weak self] result, recordURL in
            guard let self else { return }
            self.ensureBlastDrawer().showResults(result, recordURL: recordURL)
            self.openBlastDrawerIfNeeded()
        }
    }
}
