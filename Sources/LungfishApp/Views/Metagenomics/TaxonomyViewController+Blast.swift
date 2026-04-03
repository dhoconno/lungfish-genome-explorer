// TaxonomyViewController+Blast.swift - BLAST verification integration for taxonomy view
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

private let blastVCLogger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyBlast")

// MARK: - TaxonomyViewController BLAST Extension

extension TaxonomyViewController {

    // MARK: - Public API

    /// Shows BLAST verification results in the drawer's BLAST tab.
    ///
    /// If the drawer is not yet created, it is lazily instantiated. If the drawer
    /// is not open, it is toggled open. The drawer then switches to the BLAST tab
    /// and populates the results view.
    ///
    /// - Parameter result: The BLAST verification result to display.
    func showBlastResults(_ result: BlastVerificationResult) {
        lastBlastResult = result
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
    func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        ensureDrawerOpenOnBlastTab()
        taxaCollectionsDrawerView?.blastResultsTab.showLoading(phase: phase, requestId: requestId)
    }

    /// Shows BLAST failure state in the drawer.
    ///
    /// Opens the drawer (if needed), switches to the BLAST tab, and displays
    /// the failure message in place of the loading spinner.
    ///
    /// - Parameter message: User-facing error description.
    func showBlastFailure(message: String) {
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
            self.onBlastVerification?(node, result.totalReads)
        }

        blastTab.onOpenInBrowser = { url in
            NSWorkspace.shared.open(url)
        }

        blastTab.onCancelBlast = {
            // Cancel is handled via OperationCenter cancel callback;
            // the drawer's cancel button is informational only.
            blastVCLogger.info("BLAST cancel requested from drawer")
        }
    }

    // MARK: - Private Helpers

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

        // Update action bar button states
        actionBar.setBlastResultsActive(true)
        actionBar.setCollectionsDrawerOpen(false)
    }

    // MARK: - Testing Accessors

    /// Returns the BLAST results drawer tab for testing.
    var testBlastResultsTab: BlastResultsDrawerTab? {
        taxaCollectionsDrawerView?.blastResultsTab
    }
}
