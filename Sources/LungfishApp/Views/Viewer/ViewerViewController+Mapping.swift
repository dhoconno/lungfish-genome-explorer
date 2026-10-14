// ViewerViewController+Mapping.swift - Mapping result display for ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import SwiftUI
import os.log

private let mappingDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerMapping")

extension ViewerViewController {
    /// Capture the originating session before presenting an async destination
    /// sheet; later focus changes cannot retarget this scientific action.
    private func alignmentOperationRouteContext() -> OperationRouteContext {
        let windowController = view.window?.windowController as? MainWindowController
        let split = windowController?.mainSplitViewController ?? (parent as? MainSplitViewController)
        let session = windowController?.projectSession ?? split?.projectSession
        return OperationRouteContext(
            projectURL: session?.projectURL ?? split?.sidebarController?.currentProjectURL,
            windowStateScope: session?.windowStateScope ?? windowStateScope)
    }

    /// Starts a selected-region action exclusively from immutable full-viewer
    /// evidence; missing evidence/selection is reported instead of ignored.
    func extractReadsInSelectedAlignmentRegion() {
        guard let context = alignmentActionContext else {
            presentExtractionFailureAlert(title: "Extract Selected Region Failed", message: AlignmentScientificActionError.contextUnavailable.localizedDescription)
            return
        }
        guard let selection = explicitAlignmentSelection else {
            presentExtractionFailureAlert(title: "Extract Selected Region Failed", message: "Select a non-empty region first.")
            return
        }
        let region = ResolvedAlignmentRegion(scope: .selectedRegion, contig: selection.contig, start: selection.start, end: selection.end)
        let routeContext = alignmentOperationRouteContext()
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await resolveAlignmentExtractionDestination(
                    context: context,
                    outputBaseName: "selected-region"
                )
                launchAlignmentRegionExtraction(
                    context: context,
                    region: region,
                    destination: destination,
                    outputBaseName: "selected-region",
                    routeContext: routeContext
                )
            } catch AlignmentScientificActionError.destinationCancelled {
                return
            } catch {
                presentExtractionFailureAlert(title: "Extract Selected Region Failed", message: error.localizedDescription)
            }
        }
    }
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
        activeMappingViewportController?.activeSequenceViewerController.presentAlignmentConsensusGeneration()
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
        // The same document can be announced again without the user choosing
        // anything new (a sidebar refresh, a repeated selection event, a
        // window-level relayout that re-routes the selection). Rebuilding the
        // viewport then would drop focus mode, the selected contig, the shown
        // region and the drawer tab, so an unchanged input keeps the live one.
        if let existing = referenceBundleViewportController,
           contentMode == .mapping,
           existing.parent === self,
           existing.view.superview === view,
           existing.currentInput == input {
            mappingDisplayLogger.info(
                "displayReferenceBundleViewport: \(input.documentTitle, privacy: .public) is already displayed, keeping viewport state"
            )
            return
        }

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

        let runner = overlappingReadsExtractionRunner
        let annotationName = annotation.name
        Self.beginOverlappingReadsExtractionOperation(annotationName: annotationName, config: config) { opID in
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
                        guard OperationCenter.shared.fail(
                            id: opID,
                            detail: "Extract Overlapping Reads failed",
                            errorMessage: error.localizedDescription
                        ) else { return }
                        self?.presentExtractOverlappingReadsFailureAlert(error)
                    }}
                }
            }
            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            activeOverlappingReadsExtractionTask = task
        }
    }

    private func presentExtractOverlappingReadsFailureAlert(_ error: Error) {
        presentExtractionFailureAlert(
            title: "Extract Overlapping Reads Failed",
            message: error.localizedDescription
        )
    }

    // MARK: - Extract Selected Reads (read-track multi-select)

    /// Extracts the given reads' ORIGINAL (unaligned) records — the "Extract
    /// Reads… (original reads)" action from the read-track right-click menu.
    /// Cloned from ``extractOverlappingReads(from:)``'s OperationCenter
    /// integration template.
    ///
    /// Resolves source FASTQs when possible (currently always unresolvable
    /// for a mapping-result viewport, since `MappingResult` retains no FASTQ
    /// bundle reference) and falls back to BAM-derived extraction
    /// (`ReadExtractionService.extractByReadIDsFromBAM`) against the
    /// mapping's own BAM. Records provenance (`source-fastq` | `bam-derived`)
    /// in the completion message; the selection may span multiple contigs,
    /// so the distinct contig set is logged.
    func extractSelectedReads(_ reads: [AlignedRead]) {
        guard let context = alignmentActionContext else {
            presentExtractionFailureAlert(title: "Extract Selected Reads Failed", message: AlignmentScientificActionError.contextUnavailable.localizedDescription)
            return
        }
        guard !reads.isEmpty else {
            presentExtractionFailureAlert(title: "Extract Selected Reads Failed", message: AlignmentScientificActionError.emptySelection.localizedDescription)
            return
        }
        let outputBaseName = "\(ExtractionBundleNaming.sanitizeFilename(context.presentationLabel))_selected_\(Set(reads.map(\.name)).count)reads"
        let routeContext = alignmentOperationRouteContext()
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await resolveAlignmentExtractionDestination(
                    context: context,
                    outputBaseName: outputBaseName
                )
                launchSelectedReadsExtraction(
                    context: context,
                    records: reads,
                    destination: destination,
                    outputBaseName: outputBaseName,
                    routeContext: routeContext
                )
            } catch AlignmentScientificActionError.destinationCancelled {
                return
            } catch {
                presentExtractionFailureAlert(title: "Extract Selected Reads Failed", message: error.localizedDescription)
            }
        }
    }

    private func resolveAlignmentExtractionDestination(
        context: AlignmentActionContext,
        outputBaseName: String
    ) async throws -> AlignmentReadExtractionPublicationDestination {
        let window: NSWindow?
        switch context.outputCapability {
        case .projectDerivedRoot:
            window = nil
        case .userSelectedDestination:
            guard let hostWindow = view.window else {
                throw AlignmentScientificActionError.destinationUnavailable(
                    "An application window is required to choose an extraction destination."
                )
            }
            window = hostWindow
        }
        return try await AlignmentScientificActionCoordinator().resolveDestination(
            for: context.outputCapability,
            outputBaseName: outputBaseName,
            userDestinationChooser: { [alignmentExtractionSavePanelPresenter] suggestedName in
                guard let window else { return nil }
                return await alignmentExtractionSavePanelPresenter.present(
                    suggestedName: "\(ExtractionBundleNaming.sanitizeFilename(suggestedName)).lungfishfastq",
                    on: window
                )
            }
        )
    }

    private func presentExtractSelectedReadsFailureAlert(_ error: Error) {
        presentExtractionFailureAlert(
            title: "Extract Selected Reads Failed",
            message: error.localizedDescription
        )
    }

    /// Presents an extraction-failure alert, routing through the injectable
    /// `extractionFailureAlertPresenter` when set (tests) and otherwise showing
    /// the real `NSAlert` sheet (or `NSApp.presentError` when no window hosts a
    /// sheet). Centralizing this keeps both extract paths off a live
    /// `beginSheetModal` in tests, which blocks under an attached WindowServer.
    func presentExtractionFailureAlert(title: String, message: String) {
        if let presenter = extractionFailureAlertPresenter {
            presenter(title, message)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(ExtractOverlappingReadsWarning(
                title: title,
                message: message
            ))
        }
    }

    /// Reports a "Copy as FASTA" skip count via the status bar (no blocking
    /// alert, per project convention — reuses the existing transient status
    /// label pattern).
    func reportReadCopySkip(skippedCount: Int, copiedCount: Int) {
        guard skippedCount > 0 else { return }
        let message: String
        if copiedCount > 0 {
            message = "Copied \(copiedCount) read\(copiedCount == 1 ? "" : "s") as FASTA (\(skippedCount) secondary/unaligned read\(skippedCount == 1 ? "" : "s") skipped)"
        } else {
            message = "No reads copied — \(skippedCount) selected read\(skippedCount == 1 ? "" : "s") had no alignable sequence (secondary alignment)"
        }
        statusBar.positionLabel.stringValue = message
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
