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
        guard !reads.isEmpty else { return }
        guard let result = activeMappingViewportController?.currentResult else { return }

        let readNames = Set(reads.map(\.name))
        let selectionCount = reads.count
        let contigs = Set(reads.map(\.chromosome)).sorted()
        let bundleName = activeMappingViewportController?.currentInput?.viewerBundleManifest?.name
            ?? result.bamURL.deletingPathExtension().lastPathComponent
        let sanitizedBundleName = ExtractionBundleNaming.sanitizeFilename(bundleName)
        let outputBaseName = "\(sanitizedBundleName)_selected_\(readNames.count)reads"
        let outputDirectory = result.bamURL.deletingLastPathComponent()
            .appendingPathComponent("selected-reads-extractions", isDirectory: true)

        let command = "# Extract Selected Reads (\(readNames.count) read name\(readNames.count == 1 ? "" : "s") from \(selectionCount) selected record\(selectionCount == 1 ? "" : "s") across contig(s) \(contigs.joined(separator: ", "))); see output provenance for replay details"
        let opID = OperationCenter.shared.start(
            title: "Extract Selected Reads",
            detail: "Extracting \(readNames.count) selected read\(readNames.count == 1 ? "" : "s")…",
            operationType: .taxonomyExtraction,
            cliCommand: command
        )
        OperationCenter.shared.log(
            id: opID,
            level: .info,
            message: "Selection spans contig(s): \(contigs.joined(separator: ", "))"
        )

        let runner = selectedReadsExtractionRunner
        let task = Task { [weak self] in
            do {
                let outcome = try await runner(readNames, result, outputDirectory, outputBaseName)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    OperationCenter.shared.log(
                        id: opID,
                        level: .info,
                        message: "Provenance: \(outcome.provenanceLabel)"
                    )
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: "Extracted \(outcome.readCount) record\(outcome.readCount == 1 ? "" : "s") for \(selectionCount) selected read\(selectionCount == 1 ? "" : "s") (\(outcome.provenanceLabel))",
                        outputURLs: outcome.outputURLs
                    )
                }}
            } catch {
                mappingDisplayLogger.error("extractSelectedReads failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(
                        id: opID,
                        detail: "Extract Selected Reads failed",
                        errorMessage: error.localizedDescription
                    )
                    self?.presentExtractSelectedReadsFailureAlert(error)
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        activeSelectedReadsExtractionTask = task
    }

    /// Default `selectedReadsExtractionRunner`: attempts source-FASTQ
    /// resolution first (structurally present for when `MappingResult` gains
    /// a retained FASTQ source reference), falling back to BAM-derived
    /// extraction against the mapping's own BAM when no source is resolvable.
    nonisolated static func defaultSelectedReadsExtraction(
        readNames: Set<String>,
        mappingResult: MappingResult,
        outputDirectory: URL,
        outputBaseName: String
    ) async throws -> SelectedReadsExtractionOutcome {
        // MappingResult retains no FASTQ bundle reference today, so source
        // resolution has nothing to resolve against; this always falls
        // through to the BAM-derived path. Structured as a guard (rather than
        // omitted) so a future MappingResult.sourceFASTQBundleURL-style field
        // only needs a resolver call inserted here, not a call-site change.
        let config = ReadIDBAMExtractionConfig(
            bamURL: mappingResult.bamURL,
            readIDs: readNames,
            outputDirectory: outputDirectory,
            outputBaseName: outputBaseName
        )
        let result = try await ReadExtractionService().extractByReadIDsFromBAM(config: config)
        return .bamDerived(result)
    }

    private func presentExtractSelectedReadsFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Extract Selected Reads Failed"
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
