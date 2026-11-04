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
        // No route calls this display, so it says itself when the host did not show the dashboard.
        do {
            _ = try showSurface(
                .view(.vcfDataset),
                input: VCFDatasetSurface.Input(controller: controller, summary: summary, variants: variants),
                as: VCFDatasetSurface.self
            )
        } catch {
            logger.error("displayVCFDataset: \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: surfaceFailureWords(
                "Unable to open the VCF dataset.",
                error,
                orElse: "Open the VCF file again. If it still does not open, import it into a project."
            ))
            return
        }

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
        clearSurface(ifShowing: .view(.vcfDataset))
    }
}
