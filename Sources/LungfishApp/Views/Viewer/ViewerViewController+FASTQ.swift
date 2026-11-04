// ViewerViewController+FASTQ.swift - The FASTQ dataset dashboard of the viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

extension ViewerViewController {
    public func updateFASTQOperationStatus(_ message: String) {
        fastqDatasetController?.updateOperationStatus(message)
    }

    // MARK: - FASTQ Dataset Display

    /// Displays the FASTQ dataset dashboard in place of the normal sequence viewer.
    ///
    /// Hides the ruler, viewer, and header; adds the FASTQDatasetViewController
    /// as a child view controller filling the content area.
    public func displayFASTQDataset(
        statistics: FASTQDatasetStatistics,
        records: [FASTQRecord],
        fastqURL: URL? = nil,
        sraRunInfo: SRARunInfo? = nil,
        enaReadRecord: ENAReadRecord? = nil,
        ingestionMetadata: IngestionMetadata? = nil,
        fastqSourceURL: URL? = nil,
        fastqDerivativeManifest: FASTQDerivedBundleManifest? = nil
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
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
        contentMode = .fastq

        let controller = FASTQDatasetViewController()
        addChild(controller)

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        let dashBottomConstraint = dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashBottomConstraint,
        ])

        controller.configure(
            statistics: statistics,
            records: records,
            fastqURL: fastqURL,
            sourceURL: fastqSourceURL,
            derivativeManifest: fastqDerivativeManifest
        )
        controller.onLaunchFASTQOperationCategory = { category in
            let preferredInputURLs = [fastqSourceURL ?? fastqURL].compactMap { $0 }
            AppDelegate.shared?.showFASTQOperationsDialog(
                nil,
                initialCategory: category,
                preferredInputURLs: preferredInputURLs
            )
        }
        controller.onLaunchFASTQOperationTool = { toolID in
            let preferredInputURLs = [fastqSourceURL ?? fastqURL].compactMap { $0 }
            AppDelegate.shared?.showFASTQOperationsDialog(
                nil,
                initialCategory: toolID.categoryID,
                initialToolID: toolID,
                preferredInputURLs: preferredInputURLs
            )
        }
        controller.onOpenDemuxDrawer = { [weak self] in
            self?.openDemuxSetupDrawer()
        }
        controller.onOpenPrimerTrimDrawer = { [weak self] in
            self?.openPrimerTrimDrawer()
        }
        controller.onOpenDedupDrawer = { [weak self] in
            self?.openDedupDrawer()
        }
        controller.onStatisticsUpdated = { [weak self, weak controller] updatedStats in
            guard let self, let controller, self.fastqDatasetController === controller else { return }
            var updatedUserInfo: [String: Any] = ["statistics": updatedStats]
            if let sra = sraRunInfo { updatedUserInfo["sraRunInfo"] = sra }
            if let ena = enaReadRecord { updatedUserInfo["enaReadRecord"] = ena }
            if let ingestion = ingestionMetadata { updatedUserInfo["ingestionMetadata"] = ingestion }
            if let source = fastqSourceURL { updatedUserInfo["fastqSourceURL"] = source }
            if let derivative = fastqDerivativeManifest { updatedUserInfo["fastqDerivativeManifest"] = derivative }
            if let source = fastqSourceURL, FASTQBundle.isBundleURL(source) {
                updatedUserInfo["bundleURL"] = source
            }
            NotificationCenter.default.post(
                name: .fastqDatasetLoaded,
                object: self,
                userInfo: windowScopedUserInfo(updatedUserInfo)
            )
        }
        fastqDatasetController = controller
        fastqDashboardView = dashView
        fastqDashboardBottomConstraint = dashBottomConstraint
        // Sync any existing drawer demux config into the new controller
        syncDemuxConfigToController()
        currentFASTQDatasetURL = fastqURL

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        // Post notification for inspector (includes metadata if available)
        var userInfo: [String: Any] = ["statistics": statistics]
        if let sra = sraRunInfo { userInfo["sraRunInfo"] = sra }
        if let ena = enaReadRecord { userInfo["enaReadRecord"] = ena }
        if let ingestion = ingestionMetadata { userInfo["ingestionMetadata"] = ingestion }
        if let source = fastqSourceURL { userInfo["fastqSourceURL"] = source }
        if let derivative = fastqDerivativeManifest { userInfo["fastqDerivativeManifest"] = derivative }
        // Include the bundle URL so the inspector can load sample metadata
        if let source = fastqSourceURL, FASTQBundle.isBundleURL(source) {
            userInfo["bundleURL"] = source
        } else if let fastqURL {
            let parentDir = fastqURL.deletingLastPathComponent()
            if parentDir.pathExtension == "lungfishfastq" {
                userInfo["bundleURL"] = parentDir
            }
        }
        NotificationCenter.default.post(
            name: .fastqDatasetLoaded,
            object: self,
            userInfo: windowScopedUserInfo(userInfo)
        )

        if fastqMetadataDrawerView != nil {
            refreshFASTQMetadataDrawerContent()
        }

        logger.info("displayFASTQDataset: Showing dashboard with \(statistics.readCount) reads")
    }

    /// Removes the FASTQ dataset dashboard and restores normal viewer components.
    public func hideFASTQDatasetView() {
        guard let controller = fastqDatasetController else { return }
        teardownFASTQMetadataDrawer()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        fastqDatasetController = nil
        fastqDashboardView = nil
        fastqDashboardBottomConstraint = nil
        currentFASTQDatasetURL = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }
}
