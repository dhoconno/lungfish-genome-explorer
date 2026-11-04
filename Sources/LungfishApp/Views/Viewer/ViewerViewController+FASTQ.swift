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

    /// Displays the FASTQ dataset dashboard in place of the normal sequence viewer, through the surface host.
    ///
    /// - Returns: Whether the dashboard opened. When it did not, the status line says why, and a route that has not
    ///   cleared the Inspector clears it.
    @discardableResult
    public func displayFASTQDataset(
        statistics: FASTQDatasetStatistics,
        records: [FASTQRecord],
        fastqURL: URL? = nil,
        sraRunInfo: SRARunInfo? = nil,
        enaReadRecord: ENAReadRecord? = nil,
        ingestionMetadata: IngestionMetadata? = nil,
        fastqSourceURL: URL? = nil,
        fastqDerivativeManifest: FASTQDerivedBundleManifest? = nil
    ) -> Bool {
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
        do {
            _ = try showSurface(
                .bundle(.fastq),
                input: FASTQDatasetSurface.Input(
                    dashboard: controller,
                    statistics: statistics,
                    records: records,
                    fastqURL: fastqURL,
                    sourceURL: fastqSourceURL,
                    derivativeManifest: fastqDerivativeManifest
                ),
                as: FASTQDatasetSurface.self
            )
        } catch {
            logger.error("displayFASTQDataset: \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: surfaceFailureWords(
                "Unable to open the FASTQ dataset.",
                error,
                orElse: "Select the item again. If it still does not open, import the reads again."
            ))
            return false
        }

        // Sync any existing drawer demux config into the new controller
        syncDemuxConfigToController()
        currentFASTQDatasetURL = fastqURL

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
        return true
    }

    /// Removes the FASTQ dataset dashboard and restores normal viewer components.
    public func hideFASTQDatasetView() {
        clearSurface(ifShowing: .bundle(.fastq))
    }

    /// What the dashboard leaves on the viewer goes with it. The surface calls this on every removal.
    func releaseFASTQDashboardState() {
        teardownFASTQMetadataDrawer()
        currentFASTQDatasetURL = nil
    }
}
