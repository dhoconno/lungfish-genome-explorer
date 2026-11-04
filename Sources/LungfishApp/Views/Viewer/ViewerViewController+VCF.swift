// ViewerViewController+VCF.swift - The VCF dataset dashboard of the viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

extension ViewerViewController {
    /// Displays a standalone VCF dataset dashboard in place of the sequence viewer.
    public func displayVCFDataset(
        summary: LungfishIO.VCFSummary,
        variants: [LungfishIO.VCFVariant],
        onDownloadReference: ((ReferenceInference.Result) -> Void)? = nil
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideMHCReferenceBundleView()
        hideAlignmentTreeBundleViews()

        let controller = VCFDatasetViewController()
        controller.onDownloadReferenceRequested = onDownloadReference
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(summary: summary, variants: variants)
        vcfDatasetController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        // Post notification
        NotificationCenter.default.post(
            name: .vcfDatasetLoaded,
            object: self,
            userInfo: windowScopedUserInfo(["summary": summary])
        )

        logger.info("displayVCFDataset: Showing dashboard with \(summary.variantCount) variants")
    }

    /// Removes the VCF dataset dashboard and restores normal viewer components.
    public func hideVCFDatasetView() {
        guard let controller = vcfDatasetController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        vcfDatasetController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }
}
