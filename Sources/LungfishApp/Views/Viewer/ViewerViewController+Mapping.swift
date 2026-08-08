// ViewerViewController+Mapping.swift - Mapping result display for ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let mappingDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerMapping")

extension ViewerViewController {
    func display(_ route: ViewerDisplayRoute) throws {
        switch route {
        case .referenceBundle(let input):
            try displayReferenceBundleViewport(input)
        }
    }

    var activeMappingViewportController: ReferenceBundleViewportController? {
        if let mappingResultController {
            return mappingResultController
        }
        if let referenceBundleViewportController,
           referenceBundleViewportController.currentInput?.kind == .mappingResult {
            return referenceBundleViewportController
        }
        return nil
    }

    func presentMappingConsensusExtraction() {
        guard let controller = activeMappingViewportController else {
            NSSound.beep()
            return
        }

        Task { [weak self] in
            do {
                let payload = try await controller.buildConsensusExportPayload()
                self?.presentFASTASequenceExtractionDialog(
                    records: payload.records,
                    suggestedName: payload.suggestedName
                )
            } catch {
                mappingDisplayLogger.error(
                    "presentMappingConsensusExtraction failed: \(error.localizedDescription, privacy: .public)"
                )
                NSSound.beep()
            }
        }
    }

    func fetchMappingConsensusSequence(_ request: MappingConsensusExportRequest) async throws -> String {
        try await viewerView.fetchConsensusSequenceForExport(request: request)
    }

    func reloadMappingViewerBundleIfDisplayed() throws {
        try activeMappingViewportController?.reloadViewerBundleForInspectorChanges()
    }

    public func displayMappingResult(_ result: MappingResult) {
        displayMappingResult(result, resultDirectoryURL: nil)
    }

    public func displayMappingResult(_ result: MappingResult, resultDirectoryURL: URL?) {
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
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .mapping

        let controller = MappingResultViewController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let mappingView = controller.view
        mappingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mappingView)

        NSLayoutConstraint.activate([
            mappingView.topAnchor.constraint(equalTo: view.topAnchor),
            mappingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mappingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mappingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        view.layoutSubtreeIfNeeded()
        controller.configure(result: result, resultDirectoryURL: resultDirectoryURL)
        mappingView.layoutSubtreeIfNeeded()
        mappingResultController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        mappingDisplayLogger.info(
            "displayMappingResult: Showing \(result.mapper.displayName, privacy: .public) result"
        )
    }

    func displayReferenceBundleViewport(_ input: ReferenceBundleViewportInput) throws {
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
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .mapping

        let controller = ViewerDisplayRouteFactory.makeReferenceBundleViewportController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let referenceView = controller.view
        referenceView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(referenceView)

        NSLayoutConstraint.activate([
            referenceView.topAnchor.constraint(equalTo: view.topAnchor),
            referenceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            referenceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            referenceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        do {
            try controller.configure(input: input)
        } catch {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            throw error
        }

        referenceBundleViewportController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        mappingDisplayLogger.info(
            "displayReferenceBundleViewport: Showing \(input.documentTitle, privacy: .public)"
        )
    }

    public func hideMappingView() {
        if let controller = mappingResultController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            mappingResultController = nil
        }

        if let controller = referenceBundleViewportController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            referenceBundleViewportController = nil
        }

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }

    func mappingZoomRegion(for annotation: SequenceAnnotation) -> GenomicRegion? {
        guard activeMappingViewportController?.currentResult != nil else { return nil }
        guard let provider = currentBundleDataProvider,
              let chromosome = annotation.chromosome,
              let chromosomeInfo = provider.chromosomeInfo(named: chromosome) else {
            return nil
        }

        return MappingAnnotationActionCoordinator.zoomRegion(
            for: annotation,
            chromosomeLength: Int(chromosomeInfo.length)
        )
    }

    func zoomToMappingAnnotation(_ annotation: SequenceAnnotation) {
        guard let region = mappingZoomRegion(for: annotation),
              let provider = currentBundleDataProvider,
              let chromosomeInfo = provider.chromosomeInfo(named: region.chromosome) else {
            return
        }

        navigateToChromosomeAndPosition(
            chromosome: chromosomeInfo.name,
            chromosomeLength: Int(chromosomeInfo.length),
            start: region.start,
            end: region.end
        )
    }

    func mappingExtractionConfiguration(for annotation: SequenceAnnotation) -> BAMRegionExtractionConfig? {
        guard let result = activeMappingViewportController?.currentResult else { return nil }
        let outputDirectory = result.bamURL.deletingLastPathComponent().appendingPathComponent(
            "annotation-extractions",
            isDirectory: true
        )
        return MappingAnnotationActionCoordinator.extractionConfiguration(
            for: annotation,
            mappingResult: result,
            outputDirectory: outputDirectory
        )
    }

    func mappingZoomUnavailableReason(for annotation: SequenceAnnotation) -> String? {
        guard activeMappingViewportController?.currentResult != nil else { return nil }
        guard annotation.chromosome != nil else {
            return "annotation chromosome is unavailable"
        }
        guard let provider = currentBundleDataProvider else {
            return "reference bundle is unavailable"
        }
        guard provider.chromosomeInfo(named: annotation.chromosome!) != nil else {
            return "annotation chromosome is not present in the reference bundle"
        }
        return nil
    }

    func mappingExtractionUnavailableReason(for annotation: SequenceAnnotation) -> String? {
        guard activeMappingViewportController?.currentResult != nil else { return nil }
        guard annotation.chromosome != nil else {
            return "annotation chromosome is unavailable"
        }
        guard !MappingAnnotationActionCoordinator.samtoolsRegions(for: annotation).isEmpty else {
            return "annotation has no extractable blocks"
        }
        return nil
    }

    func extractOverlappingReads(from annotation: SequenceAnnotation) {
        guard let config = mappingExtractionConfiguration(for: annotation) else { return }

        let command = "# Extract Overlapping Reads for annotation '\(annotation.name)' (samtools region extraction; see output provenance for replay details)"
        let opID = OperationCenter.shared.start(
            title: "Extract Overlapping Reads",
            detail: "Extracting reads overlapping \(annotation.name)…",
            operationType: .taxonomyExtraction,
            cliCommand: command
        )

        let runner = overlappingReadsExtractionRunner
        let annotationName = annotation.name
        let task = Task { [weak self] in
            do {
                let result = try await runner(config)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "Extracted \(result.readCount) read\(result.readCount == 1 ? "" : "s") overlapping \(annotationName)",
                        outputURLs: result.fastqURLs
                    )
                }}
            } catch {
                mappingDisplayLogger.error("extractOverlappingReads failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(
                        id: opID,
                        detail: "Extract Overlapping Reads failed",
                        errorMessage: error.localizedDescription
                    )
                    self?.presentExtractOverlappingReadsFailureAlert(error)
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        activeOverlappingReadsExtractionTask = task
    }

    private func presentExtractOverlappingReadsFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Extract Overlapping Reads Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(ExtractOverlappingReadsWarning(
                title: alert.messageText,
                message: alert.informativeText
            ))
        }
    }
}

/// Presentable wrapper so `presentExtractOverlappingReadsFailureAlert` can surface
/// a failure via `NSApp.presentError` when no window is available for a sheet,
/// mirroring `AnnotationDrawerWarning` in `ViewerViewController+AnnotationDrawer.swift`.
private struct ExtractOverlappingReadsWarning: LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var recoverySuggestion: String? { message }
}
