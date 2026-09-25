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
    func beginBlastVerification(for node: TaxonNode) -> UUID {
        let runID = UUID()
        currentBlastRunID = runID
        lastBlastNode = node
        lastBlastResult = nil
        isBlastRunInFlight = true
        return runID
    }

    /// Shows the newest saved verification of `node` in the BLAST Results tab.
    ///
    /// Saved verifications live in `<result>/blast-verifications/` (see
    /// ``BlastVerificationArchive``). Nothing changes while a run is in
    /// flight, when the drawer already shows this taxon, or when the taxon
    /// has no saved verification. The drawer is not opened or switched: the
    /// saved result is waiting in the BLAST Results tab when the user opens it.
    ///
    /// - Returns: The restored result, or `nil` when nothing was restored.
    @discardableResult
    func restoreSavedBlastVerification(for node: TaxonNode?) -> BlastVerificationResult? {
        guard let node,
              !blastRunIsActive,
              lastBlastResult?.taxId != node.taxId,
              let directory = blastVerificationDirectoryResolver?(node),
              let record = BlastVerificationArchive.latest(forTaxId: node.taxId, in: directory) else {
            return nil
        }
        lastBlastResult = record.result
        lastBlastNode = node
        taxaCollectionsDrawerView?.blastResultsTab.showResults(record.result)
        blastVCLogger.info("Restored saved BLAST verification for txid\(node.taxId, privacy: .public) from \(directory.path, privacy: .public)")
        return record.result
    }

    /// Shows BLAST verification results in the drawer's BLAST tab.
    ///
    /// If the drawer is not yet created, it is lazily instantiated. If the drawer
    /// is not open, it is toggled open. The drawer then switches to the BLAST tab
    /// and populates the results view.
    ///
    /// - Parameter result: The BLAST verification result to display.
    func showBlastResults(_ result: BlastVerificationResult, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID) else {
            blastVCLogger.info("Ignoring stale BLAST result from an older run")
            return
        }
        lastBlastResult = result
        isBlastRunInFlight = false
        ensureDrawerOpenOnBlastTab()

        // Switch to BLAST tab and show results
        taxaCollectionsDrawerView?.showBlastResults(result)

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
    func showBlastVerificationResults(_ result: BlastVerificationResult) {
        showBlastResults(result)
    }

    /// Shows the BLAST loading state in the drawer.
    ///
    /// Opens the drawer (if needed), switches to the BLAST tab, and
    /// displays the loading spinner with the given phase.
    ///
    /// - Parameters:
    ///   - phase: The current BLAST job phase.
    ///   - requestId: The NCBI BLAST request ID, if available.
    func showBlastLoading(phase: BlastJobPhase, requestId: String?, runID: UUID? = nil) {
        guard isCurrentBlastRun(runID) else {
            blastVCLogger.info("Ignoring stale BLAST loading update from an older run")
            return
        }
        guard lastBlastResult == nil else {
            blastVCLogger.info("Ignoring stale BLAST loading update after results were displayed")
            return
        }
        ensureDrawerOpenOnBlastTab()
        taxaCollectionsDrawerView?.blastResultsTab.showLoading(phase: phase, requestId: requestId)
    }

    /// Shows BLAST failure state in the drawer.
    ///
    /// Opens the drawer (if needed), switches to the BLAST tab, and displays
    /// the failure message in place of the loading spinner.
    ///
    /// - Parameter message: User-facing error description.
    func showBlastFailure(message: String, runID: UUID? = nil) {
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
            // WFL-12: previously this only logged — the button looked like
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
            blastTab.showResults(lastBlastResult)
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

        // Update toggle button states
        blastResultsToggleButton.state = .on
        collectionsToggleButton.state = .off
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
