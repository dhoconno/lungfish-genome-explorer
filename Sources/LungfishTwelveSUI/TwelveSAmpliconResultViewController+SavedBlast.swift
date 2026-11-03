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

    /// Looks for the saved search of the sequences a BLAST would send now (Phase 3.1 lane REOPEN2), the selected unresolved
    /// rows or, with none selected, every row showing. A search matches on its bundle and the IDs its query holds, in any
    /// order, since its lineage names no sample, taxon or contig. The Targets list has no search. This viewer has no
    /// control that opens a closed pane, so a restore opens it, since a result nobody can reach would not close the gap.
    func scheduleSavedBlastRestore() {
        let row = result.flatMap {
            BlastSavedSearchRow.twelveSSelection(sequenceIDs: selectedUnresolvedRows().map(\.sequenceID), bundleURL: $0.bundleURL)
        }
        savedBlastRestorer.select(row) { [weak self] result, recordURL in
            guard let self else { return }
            self.ensureBlastDrawer().showResults(result, recordURL: recordURL)
            self.openBlastDrawerIfNeeded()
        }
    }
}
