// TaxonomyViewController+Blast.swift - BLAST verification integration for taxonomy view
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let blastVCLogger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyBlast")

// MARK: - TaxonomyViewController BLAST Extension

extension TaxonomyViewController {

    // MARK: - Public API

    /// Starts a new BLAST display run.
    ///
    /// BLAST progress callbacks are delivered asynchronously and may arrive
    /// after the final result callback. Clearing the previous result at the
    /// beginning of a run lets loading/failure states show for new work while
    /// still allowing completed results to ignore stale progress from the run
    /// that just finished.
    @discardableResult
    public func beginBlastVerification(for node: TaxonNode) -> UUID {
        let runID = UUID()
        currentBlastRunID = runID
        lastBlastNode = node
        lastBlastSampleId = owningSampleId(for: node)
        lastBlastResult = nil
        lastBlastRecordURL = nil
        isBlastRunInFlight = true
        return runID
    }

    /// Shows the newest saved verification of `node` in the BLAST Results tab.
    ///
    /// Saved verifications live in `<result>/blast-verifications/`, the
    /// folders `blast submit` writes since Phase 2.12 and the archive files
    /// of the route before it (``newestSavedBlastVerification(forTaxId:in:)``).
    /// Nothing changes while a run is in
    /// flight or when the drawer already shows this row's search. A row is a
    /// sample and a taxon (``blastPaneShowsSearch(of:)``). A row with no saved
    /// verification shows nothing, so the pane no longer keeps the verdict of
    /// the row picked before it (lane ROWPANE). The drawer is not opened or switched: the
    /// saved result is waiting in the BLAST Results tab when the user opens it.
    ///
    /// - Returns: The restored result, or `nil` when nothing was restored.
    @discardableResult
    func restoreSavedBlastVerification(for node: TaxonNode?) -> BlastVerificationResult? {
        guard let node, !blastRunIsActive, !blastPaneShowsSearch(of: node) else { return nil }
        guard let directory = blastVerificationDirectoryResolver?(node),
              let saved = Self.newestSavedBlastVerification(forTaxId: node.taxId, in: directory) else {
            emptyBlastPaneOfOtherRow()
            return nil
        }
        applyRestoredBlastVerification(saved.result, recordURL: saved.recordURL, for: node, from: directory)
        return saved.result
    }

    /// The selection path's form of ``restoreSavedBlastVerification(for:)`` (Phase 2.12 lane 12.33, review Fix 6 of
    /// lane 12.10). Selecting a taxon lists and decodes every saved search under the result, a cost that grows with
    /// each search saved and is paid for every taxon selected, so the scan runs off the main actor. The result
    /// applies on the main actor only while the same three conditions hold that the synchronous form checks first
    /// (no run in flight, this row still selected, the drawer not already showing its search). A selection that moved on
    /// or a run that began meanwhile drops the result. That check is the stale guard, so no task handle is stored.
    /// A scan that finds no saved search empties a pane that shows another row's verdict (lane ROWPANE).
    ///
    /// - Returns: The task that scans and applies, which tests await, or `nil` when nothing was scheduled.
    @discardableResult
    func scheduleSavedBlastVerificationRestore(for node: TaxonNode?, force: Bool = false) -> Task<Void, Never>? {
        guard let node, !blastRunIsActive, force || !blastPaneShowsSearch(of: node) else { return nil }
        guard let directory = blastVerificationDirectoryResolver?(node) else {
            emptyBlastPaneOfOtherRow()
            return nil
        }
        let sample = owningSampleId(for: node)
        return Task { @MainActor [weak self] in
            let saved = await Self.savedBlastVerificationOffMain(forTaxId: node.taxId, in: directory)
            let live = await Self.liveBlastSearchOffMain(forTaxId: node.taxId, sample: sample, in: directory)
            guard let self,
                  !self.blastRunIsActive,
                  self.selectedTaxonNode === node,
                  force || !self.blastPaneShowsSearch(of: node) else {
                return
            }
            if let live {
                // A search with no result has no taxon in the pane's result, so the row is kept here (ROWPANE-UX R4).
                self.lastBlastResult = nil
                self.lastBlastRecordURL = nil
                self.lastBlastNode = node
                self.lastBlastSampleId = sample
                self.taxaCollectionsDrawerView?.blastResultsTab.showWaiting(live, subjectLine: BlastSearchPaneState.sampleLine(sample))
                return
            }
            guard saved?.recordURL != self.lastBlastRecordURL || saved == nil else { return }
            guard let saved else {
                self.emptyBlastPaneOfOtherRow()
                return
            }
            self.applyRestoredBlastVerification(saved.result, recordURL: saved.recordURL, for: node, from: directory)
        }
    }

    /// The newest thing on a taxon's row when that is a search with no result to show, off the main actor.
    @concurrent nonisolated static func liveBlastSearchOffMain(
        forTaxId taxId: Int,
        sample: String?,
        in directory: URL
    ) async -> BlastLiveSearch? {
        let found = BlastVerificationArchive.newestSearch(in: directory) { lineage, _ in
            lineage.taxId == taxId && (sample == nil || lineage.sample == nil || lineage.sample == sample)
        }
        if case .live(let search) = found { return search }
        return nil
    }

    /// Shows a search of the run `runID` that has gone out and has no result.
    package func showBlastWaiting(_ search: BlastLiveSearch, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID), lastBlastResult == nil else { return }
        ensureDrawerOpenOnBlastTab()
        taxaCollectionsDrawerView?.blastResultsTab.showWaiting(search, subjectLine: BlastSearchPaneState.sampleLine(lastBlastSampleId))
    }

    /// A search changed on disk, wherever it began, so the row picked is looked up again.
    @objc func blastSearchNewsArrived() {
        scheduleSavedBlastVerificationRestore(for: selectedTaxonNode, force: true)
    }

    /// The scan of a result's saved searches off the main actor.
    @concurrent nonisolated static func savedBlastVerificationOffMain(
        forTaxId taxId: Int,
        in directory: URL
    ) async -> (result: BlastVerificationResult, recordURL: URL)? {
        newestSavedBlastVerification(forTaxId: taxId, in: directory)
    }

    /// Whether the pane shows the search of `node`'s row. A row is a sample and a taxon, and a merged display lists one
    /// taxon under each sample, so the taxon alone does not name it (KRAKEN2-RESTORE-TAXID-ONLY).
    func blastPaneShowsSearch(of node: TaxonNode) -> Bool {
        lastBlastResult?.taxId == node.taxId && lastBlastSampleId == owningSampleId(for: node)
    }

    /// Empties the pane when it holds a verdict, since a row with no saved search shows nothing and never the verdict of
    /// the row picked before it (BLAST-STALE-PANE-TAXON-ONLY). A failure message names no verdict and stays.
    private func emptyBlastPaneOfOtherRow() {
        let inProgress = taxaCollectionsDrawerView?.blastResultsTab.showsASearchInProgress ?? false
        guard lastBlastResult != nil || inProgress else { return }
        lastBlastResult = nil
        lastBlastRecordURL = nil
        lastBlastNode = nil
        lastBlastSampleId = nil
        taxaCollectionsDrawerView?.blastResultsTab.showEmpty()
    }

    /// Shows a restored verification. The drawer is not opened or switched.
    private func applyRestoredBlastVerification(
        _ result: BlastVerificationResult,
        recordURL: URL,
        for node: TaxonNode,
        from directory: URL
    ) {
        lastBlastResult = result
        lastBlastRecordURL = recordURL
        lastBlastNode = node
        lastBlastSampleId = owningSampleId(for: node)
        taxaCollectionsDrawerView?.blastResultsTab.showResults(result, recordURL: recordURL, subject: lastBlastSampleId)
        blastVCLogger.info("Restored saved BLAST verification for txid\(node.taxId, privacy: .public) from \(directory.path, privacy: .public)")
    }

    /// The newest saved verification of `taxId` in `<directory>/blast-verifications/`. That is a `blast submit`
    /// record (`<folder>/blast-result.json`), which the Kraken2 row writes since Phase 2.12 lane 12.10, or a
    /// ``BlastVerificationArchive`` file, which the row wrote before and which older results still hold (ARCH 4).
    /// The search that completed last wins, as the archive orders its own files. The file it was read from comes
    /// with it, since the drawer's table export reads that file (ARCH ruling T5 of lane 12.33).
    nonisolated static func newestSavedBlastVerification(
        forTaxId taxId: Int,
        in directory: URL
    ) -> (result: BlastVerificationResult, recordURL: URL)? {
        let archived = BlastVerificationArchive.latestEntry(forTaxId: taxId, in: directory)
        let submitted = BlastVerificationArchive.newestSubmission(in: directory) { record, _ in
            (record.lineage.taxId ?? record.result.taxId) == taxId
        }
        guard let submitted else { return archived.map { ($0.record.result, $0.url) } }
        guard let archived,
              (archived.record.result.completedAt ?? archived.record.savedAt)
                > (submitted.record.result.completedAt ?? submitted.record.savedAt) else {
            return (submitted.record.result, submitted.url)
        }
        return (archived.record.result, archived.url)
    }

    /// Shows BLAST verification results in the drawer's BLAST tab.
    ///
    /// If the drawer is not yet created, it is lazily instantiated. If the drawer
    /// is not open, it is toggled open. The drawer then switches to the BLAST tab
    /// and populates the results view.
    ///
    /// - Parameters:
    ///   - result: The BLAST verification result to display.
    ///   - recordURL: The file the result was read from, which the drawer's table export reads. Nil for a result no
    ///     file holds.
    public func showBlastResults(_ result: BlastVerificationResult, recordURL: URL? = nil, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID) else {
            blastVCLogger.info("Ignoring stale BLAST result from an older run")
            return
        }
        lastBlastResult = result
        lastBlastRecordURL = recordURL
        isBlastRunInFlight = false
        ensureDrawerOpenOnBlastTab()

        // Switch to BLAST tab and show results
        taxaCollectionsDrawerView?.showBlastResults(result, recordURL: recordURL, subject: lastBlastSampleId)

        blastVCLogger.info(
            "Showing BLAST results for \(result.taxonName, privacy: .public): \(result.verifiedCount)/\(result.readResults.count) verified"
        )
    }

    /// Shows BLAST verification results in the drawer's BLAST tab.
    ///
    /// This is the primary entry point for displaying completed verification
    /// results. It opens the drawer if needed, switches to the BLAST tab,
    /// and populates the results table.
    ///
    /// - Parameter result: The BLAST verification result to display.
    func showBlastVerificationResults(_ result: BlastVerificationResult, recordURL: URL?) {
        showBlastResults(result, recordURL: recordURL)
    }

    /// Shows the BLAST loading state in the drawer.
    ///
    /// Opens the drawer (if needed), switches to the BLAST tab, and
    /// displays the loading spinner with the given phase.
    ///
    /// - Parameters:
    ///   - phase: The current BLAST job phase.
    ///   - requestId: The NCBI BLAST request ID, if available.
    public func showBlastLoading(phase: BlastJobPhase, requestId: String?, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID) else {
            blastVCLogger.info("Ignoring stale BLAST loading update from an older run")
            return
        }
        guard lastBlastResult == nil else {
            blastVCLogger.info("Ignoring stale BLAST loading update after results were displayed")
            return
        }
        ensureDrawerOpenOnBlastTab()
        taxaCollectionsDrawerView?.blastResultsTab.showLoading(
            phase: phase, requestId: requestId, subject: BlastSearchPaneState.sampleLine(lastBlastSampleId)
        )
    }

    /// Shows BLAST failure state in the drawer.
    ///
    /// Opens the drawer (if needed), switches to the BLAST tab, and displays
    /// the failure message in place of the loading spinner.
    ///
    /// - Parameter message: User-facing error description.
    public func showBlastFailure(message: String, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID) else {
            blastVCLogger.info("Ignoring stale BLAST failure from an older run")
            return
        }
        guard lastBlastResult == nil else {
            blastVCLogger.info("Ignoring stale BLAST failure update after results were displayed")
            return
        }
        isBlastRunInFlight = false
        ensureDrawerOpenOnBlastTab()
        taxaCollectionsDrawerView?.blastResultsTab.showFailure(message: message)
        blastVCLogger.error("BLAST verification failed: \(message, privacy: .public)")
    }

    // MARK: - Drawer Callback Wiring

    /// Wires the BLAST results tab callbacks (rerun, open in browser, cancel).
    ///
    /// Called from ``configureTaxaCollectionsDrawer()`` after the drawer is
    /// created. The callbacks route through the same ``onBlastVerification``
    /// path used by the initial BLAST request.
    func wireBlastDrawerCallbacks() {
        guard let drawer = taxaCollectionsDrawerView else { return }
        let blastTab = drawer.blastResultsTab
        NotificationCenter.default.addObserver(self, selector: #selector(blastSearchNewsArrived), name: BlastSearchNews.changed, object: nil)

        blastTab.onRerunBlast = { [weak self] in
            guard let self,
                  let node = self.lastBlastNode,
                  let result = self.lastBlastResult else { return }
            self.beginBlastVerification(for: node)
            self.onBlastVerification?(node, result.totalReads)
        }

        blastTab.onOpenInBrowser = { url in
            NSWorkspace.shared.open(url)
        }

        blastTab.onCancelBlast = { [weak self] in
            // Previously this only logged — the button looked like
            // it worked but the BLAST request kept running in the
            // background. Route to the same OperationCenter cancel callback
            // the Operations panel's own Cancel button uses.
            guard let operationID = self?.currentBlastOperationID else {
                blastVCLogger.info("BLAST cancel requested from drawer, but no active BLAST operation is tracked")
                return
            }
            blastVCLogger.info("BLAST cancel requested from drawer")
            OperationCenter.shared.cancel(id: operationID)
        }

        // A verification restored before the drawer existed is waiting.
        if let lastBlastResult, !blastRunIsActive {
            blastTab.showResults(lastBlastResult, recordURL: lastBlastRecordURL, subject: lastBlastSampleId)
        }
    }

    // MARK: - Private Helpers

    /// Whether a run started here is still waiting for results. A run whose
    /// operation was cancelled, or never reached the Operations panel,
    /// no longer counts, so it cannot block restoring saved verifications.
    var blastRunIsActive: Bool {
        guard isBlastRunInFlight else { return false }
        guard let operationID = currentBlastOperationID else { return true }
        return OperationCenter.shared.activeItems.contains { $0.id == operationID }
    }

    /// Ensures the drawer is created and open, with the BLAST tab selected.
    private func ensureDrawerOpenOnBlastTab() {
        // Ensure the drawer exists
        if taxaCollectionsDrawerView == nil {
            toggleTaxaCollectionsDrawer()
        }

        // Ensure the drawer is open
        if !isTaxaCollectionsDrawerOpen {
            toggleTaxaCollectionsDrawer()
        }

        // Switch to BLAST Results tab
        taxaCollectionsDrawerView?.switchToTab(.blastResults)

        // Update toggle button states. The bar's shared BLAST Results button reads on.
        collectionsToggleButton.state = .off
        resultActions.setBlastDrawerOpen(true)
    }

    /// Opens the drawer on its BLAST tab, or closes the drawer while it shows that tab, as the bar's BLAST Results
    /// button asks (lane K2). The drawer keeps its own BLAST pane, so `resultActions.blastDrawer` is not laid out.
    func blastResultsOpenChanged(_ open: Bool) {
        if open {
            ensureDrawerOpenOnBlastTab()
        } else if isTaxaCollectionsDrawerOpen {
            if taxaCollectionsDrawerView?.selectedTab == .blastResults {
                toggleTaxaCollectionsDrawer()
            } else {
                // The button read on but the drawer shows Collections, since a tab switch tells this controller
                // nothing. The click brings the BLAST tab forward, as the old toggle did.
                ensureDrawerOpenOnBlastTab()
            }
        }
    }

    private func isCurrentBlastRun(_ runID: UUID?) -> Bool {
        guard let runID else { return true }
        return currentBlastRunID == runID
    }

    // MARK: - Testing Accessors

    /// Returns the BLAST results drawer tab for testing.
    var testBlastResultsTab: BlastResultsDrawerTab? {
        taxaCollectionsDrawerView?.blastResultsTab
    }
}
