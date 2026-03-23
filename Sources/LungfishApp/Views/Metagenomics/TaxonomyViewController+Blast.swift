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
    }

    // MARK: - Testing Accessors

    /// Returns the BLAST results drawer tab for testing.
    var testBlastResultsTab: BlastResultsDrawerTab? {
        taxaCollectionsDrawerView?.blastResultsTab
    }
}
