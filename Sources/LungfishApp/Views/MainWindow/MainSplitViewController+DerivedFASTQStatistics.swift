// MainSplitViewController+DerivedFASTQStatistics.swift - Shows a derived bundle's statistics, measuring uncounted ones
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishOperations

extension MainSplitViewController {

    /// Shows a derived bundle's stored statistics, which reflect every read and not the preview's subset. Statistics
    /// that were not counted (`FASTQStatisticsDisplayRules.storedStatisticsToShow`) are measured from the bundle's
    /// reads, materialized into a temporary folder outside the project, and the result is kept in memory for the
    /// session, because a view writes nothing into the project.
    func displayDerivedFASTQDataset(
        _ manifest: FASTQDerivedBundleManifest,
        sourceURL: URL,
        fastqURL: URL?,
        viewerController: ViewerViewController,
        isCurrentRequest: @escaping @MainActor () -> Bool
    ) {
        let ingestion = manifest.pairingMode.map {
            IngestionMetadata(
                isClumpified: true, isCompressed: true, pairingMode: $0, qualityBinning: nil,
                originalFilenames: [], ingestionDate: manifest.createdAt, originalSizeBytes: nil
            )
        }
        let show: @MainActor (FASTQDatasetStatistics) -> Void = { statistics in
            viewerController.displayFASTQDataset(
                statistics: statistics, records: [], fastqURL: fastqURL, sraRunInfo: nil, enaReadRecord: nil,
                ingestionMetadata: ingestion, fastqSourceURL: sourceURL, fastqDerivativeManifest: manifest
            )
        }
        if let stored = FASTQStatisticsDisplayRules.storedStatisticsToShow(manifest.cachedStatistics) {
            show(stored)
            return
        }

        viewerController.showProgress(FASTQStatisticsDisplayRules.measuringWords(for: manifest.name))
        fastqLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-derived-statistics-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let statistics = try await DerivedFASTQStatisticsStore.statistics(for: manifest, in: sourceURL) { bundle in
                    let reads = try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                        fromBundle: bundle, tempDirectory: folder, progress: nil
                    )
                    return try await DerivedFASTQStatisticsStore.measureReads(at: reads, progress: { count in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            guard isCurrentRequest() else { return }
                            viewerController.showProgress(
                                FASTQStatisticsDisplayRules.measuringProgressWords(
                                    for: manifest.name, readsCounted: count
                                )
                            )
                        }
                    })
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, isCurrentRequest() else { return }
                    self.fastqLoadTask = nil
                    viewerController.hideProgress()
                    show(statistics)
                }
            } catch is CancellationError {
                mainSplitLogger.debug("displayDerivedFASTQDataset: measuring cancelled")
            } catch {
                let reason = error.localizedDescription
                await MainActor.run {
                    guard let self, isCurrentRequest() else { return }
                    self.fastqLoadTask = nil
                    viewerController.hideProgress()
                    mainSplitLogger.error("displayDerivedFASTQDataset: measuring failed - \(reason, privacy: .public)")
                    let alert = NSAlert()
                    let words = FASTQStatisticsDisplayRules.measuringFailureWords(for: manifest.name, reason: reason)
                    alert.messageText = words.title
                    alert.informativeText = words.detail
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.applyLungfishBranding()
                    if let window = self.view.window ?? NSApp.keyWindow {
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }
}
