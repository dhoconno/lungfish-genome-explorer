// ViewerViewController+Taxonomy.swift - Taxonomy view display for ViewerViewController
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds taxonomy classification result display to ViewerViewController,
// following the same child-VC pattern as displayFASTACollection / displayFASTQDataset.

import AppKit
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for taxonomy display operations
private let taxonomyLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerTaxonomy")

// MARK: - ViewerViewController Taxonomy Display Extension

extension ViewerViewController {

    /// Displays the taxonomy classification browser in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook) and the
    /// normal viewer components, then adds `TaxonomyViewController` as a child
    /// view controller filling the content area.
    ///
    /// Follows the exact same child-VC pattern as ``displayFASTACollection(sequences:annotations:)``.
    ///
    /// - Parameter result: The classification result to display.
    public func displayTaxonomyResult(_ result: ClassificationResult) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()

        let controller = TaxonomyViewController()
        addChild(controller)

        // Hide annotation drawer so it doesn't overlap the taxonomy view
        annotationDrawerView?.isHidden = true

        let taxView = controller.view
        taxView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taxView)

        NSLayoutConstraint.activate([
            taxView.topAnchor.constraint(equalTo: view.topAnchor),
            taxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            taxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            taxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result)
        taxonomyViewController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        taxonomyLogger.info("displayTaxonomyResult: Showing browser with \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")
    }

    /// Removes the taxonomy classification browser and restores normal viewer components.
    public func hideTaxonomyView() {
        guard let controller = taxonomyViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        taxonomyViewController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
        annotationDrawerView?.isHidden = false
    }
}
