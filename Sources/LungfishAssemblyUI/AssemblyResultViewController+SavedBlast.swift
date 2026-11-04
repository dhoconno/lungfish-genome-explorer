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

    /// A run's result, shown only when the contigs selected are still the ones it was sent for. Otherwise it stays on disk
    /// and comes back when those contigs are selected, so no verdict shows over another selection.
    public func landBlastResults(_ result: BlastVerificationResult, recordURL: URL?, run: UUID?) {
        guard savedBlastRestorer.runLands(operationID: run) else {
            if !savedBlastRestorer.isRunActive, ensureBlastDrawer().showsASearchInProgress { ensureBlastDrawer().showEmpty() }
            return
        }
        showBlastResults(result, recordURL: recordURL)
        updateBlastRerunRule()
    }

    /// Re-run BLAST sends the contigs selected now, so with none it greys and says why (RERUN-SILENT).
    func updateBlastRerunRule() {
        guard let drawer = blastDrawerContainer?.blastResultsTab else { return }
        drawer.setRerunRule(enabled: !selectedContigNames.isEmpty, reason: ClassifierActionWords.selectRowToVerify)
    }

    /// Shows a search that has gone out and has no result.
    package func showBlastWaiting(_ search: BlastLiveSearch) {
        ensureBlastDrawer().showWaiting(search)
        openBlastDrawerIfNeeded()
    }

    /// The selection changed, so an earlier restore must not finish (Phase 3.1 lane REOPEN2). The key of the new selection
    /// holds the bases of its contigs, which `showSelection` reads next, so this gives the restorer no key. A nil key
    /// cancels the earlier scan and leaves the pane, and the search it shows, as they are. `restoreSavedBlastSearch` then
    /// gives the restorer the key.
    func scheduleSavedBlastRestore() {
        savedBlastRestorer.select(nil, searchingIn: currentResult?.outputDirectory) { _, _ in }
    }

    /// Looks for the saved search of the selected contigs, once their FASTA has been read for the pane (lane REOPEN2, and
    /// lane REPLACED, ruling BIO-ASSEMBLY-REPLACED Fix E). A search matches on its result, its contig list in any order and
    /// the bases of those contigs, as its query copy holds them, so a result whose contigs file was replaced does not bring
    /// back the search of other bases under the same names. It names no sample, and no taxon, since a request here never
    /// has one. The plan saves under the result folder, so that is the folder scanned. This viewer has no control that
    /// opens a closed pane, so a restore opens it, since a result nobody can reach would not close the gap.
    ///
    /// The key is nil when fewer sequences came back than contigs were selected, when the contigs file changed on disk,
    /// and above the limit of one BLAST search. A search that cannot be shown to be the same does not come back.
    func restoreSavedBlastSearch(afterReading fastaTexts: [String]) {
        let resultURL = currentResult?.outputDirectory
        let withinLimit = selectedContigNames.count <= BlastSelectionLimit.maxContigs
        let row: BlastSavedSearchRow? = withinLimit && !contigsFileDiffersFromTheOneOpened
            ? resultURL.flatMap {
                BlastSavedSearchRow.assemblySelection(
                    contigs: selectedContigNames,
                    sequences: fastaTexts.flatMap(BlastSavedSearchRow.sequences(ofFASTA:)),
                    resultURL: $0
                )
            }
            : nil
        savedBlastRestorer.searchPane = { [weak self] in
            self?.openBlastDrawerIfNeeded()
            return self?.ensureBlastDrawer()
        }
        savedBlastRestorer.select(row, searchingIn: resultURL) { [weak self] result, recordURL in
            guard let self else { return }
            self.ensureBlastDrawer().showResults(result, recordURL: recordURL)
            self.openBlastDrawerIfNeeded()
            self.updateBlastRerunRule()
        }
    }
}
