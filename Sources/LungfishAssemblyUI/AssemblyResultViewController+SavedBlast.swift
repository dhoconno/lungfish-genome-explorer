// AssemblyResultViewController+SavedBlast.swift - The saved BLAST search of the selected contigs comes back to the pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension AssemblyResultViewController {
    /// Names the operation that carries the run the pane is waiting for, so a cancelled run cannot block a saved search.
    public func trackBlastRun(operationID: UUID) {
        savedBlastRestorer.trackRun(operationID: operationID)
    }

    /// Looks for the saved search of the selected contigs (Phase 3.1 lane REOPEN2). A search matches on its result and its
    /// contig list in any order. It names no sample, and no taxon, since a request here never has one. The plan saves
    /// under the result folder, so that is the folder scanned. This viewer has no control that opens a closed pane, so
    /// a restore opens it, since a result nobody can reach would not close the gap.
    func scheduleSavedBlastRestore() {
        let resultURL = currentResult?.outputDirectory
        let row = resultURL.flatMap { BlastSavedSearchRow.assemblySelection(contigs: selectedContigNames, resultURL: $0) }
        savedBlastRestorer.select(row, searchingIn: resultURL) { [weak self] result, recordURL in
            guard let self else { return }
            self.ensureBlastDrawer().showResults(result, recordURL: recordURL)
            self.openBlastDrawerIfNeeded()
        }
    }
}
