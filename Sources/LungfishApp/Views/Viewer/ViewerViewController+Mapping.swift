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

@MainActor
private final class AlignmentConsensusConfirmationGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: accepted)
    }
}

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
        let reporter = AlignmentScientificActionReporter.operationCenter(routeContext: alignmentOperationRouteContext())
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await resolveAlignmentExtractionDestination(
                    context: context,
                    outputBaseName: "selected-region"
                )
                activeSelectedReadsExtractionTask = AlignmentScientificActionCoordinator().launchRegion(
                    context: context,
                    region: region,
                    destination: destination,
                    outputBaseName: "selected-region",
                    reporter: reporter
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

    /// Shared evidence-only consensus action for mapping, direct reference,
    /// and detached classifier full viewers.
    func presentAlignmentConsensusGeneration() {
        if let priorOperationID = activeConsensusGenerationOperationID {
            OperationCenter.shared.cancel(id: priorOperationID)
            clearConsensusWorkflow(operationID: priorOperationID)
        }
        guard let context = alignmentActionContext else {
            presentExtractionFailureAlert(
                title: "Generate Consensus Failed",
                message: AlignmentScientificActionError.contextUnavailable.localizedDescription
            )
            return
        }
        let exportRequest: MappingConsensusExportRequest
        do {
            let region = try alignmentConsensusScope.resolve(
                in: context,
                selection: explicitAlignmentSelection
            )
            exportRequest = try MappingConsensusExportRequestBuilder.build(
                sampleName: context.identity.sampleID,
                context: context,
                region: region,
                consensusMode: viewerView.consensusModeSetting,
                useAmbiguity: viewerView.consensusUseAmbiguitySetting
            )
        } catch {
            presentExtractionFailureAlert(title: "Generate Consensus Failed", message: error.localizedDescription)
            return
        }

        let operationID = OperationCenter.shared.start(
            title: "Generate Alignment Consensus",
            detail: "Calling evidence-only consensus…",
            operationType: .export,
            cliCommand: "Lungfish.app alignment consensus --scope \(exportRequest.region.scope.rawValue) --region \(exportRequest.region.contig):\(exportRequest.region.start)-\(exportRequest.region.end) --reference-fill never"
        )
        let coordinator = AlignmentScientificActionCoordinator()
        activeConsensusGenerationOperationID = operationID
        let task = Task { @MainActor [weak self] in
            do {
                let generation = try await coordinator.generateConsensus(
                    context: context,
                    exportRequest: exportRequest
                )
                for record in generation.result.executionRecords {
                    OperationCenter.shared.log(
                        id: operationID,
                        level: record.exitStatus == 0 ? .info : .error,
                        message: "\(record.reproducibleCommand)\n\(record.stderr ?? "")"
                    )
                }
                guard let self else {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Originating viewer closed")
                    return
                }
                if generation.requiresAllLowDepthWarning {
                    guard let window = view.window else {
                        throw AlignmentScientificActionError.destinationUnavailable(
                            "An application window is required to confirm an all-N consensus."
                        )
                    }
                    guard await confirmAllLowDepthConsensus(
                        generation,
                        on: window,
                        operationID: operationID
                    ) else {
                        self.finishConsensusWorkflow(operationID: operationID, cancellation: true)
                        return
                    }
                }
                try Task.checkCancellation()
                presentAlignmentConsensusDestinationDialog(
                    generation,
                    coordinator: coordinator,
                    operationID: operationID
                )
            } catch is CancellationError {
                OperationCenter.shared.acknowledgeCancellation(id: operationID)
                self?.clearConsensusWorkflow(operationID: operationID)
            } catch {
                self?.logConsensusFailure(error, operationID: operationID)
                let accepted = OperationCenter.shared.fail(
                    id: operationID,
                    detail: "Alignment consensus failed",
                    errorMessage: error.localizedDescription
                )
                self?.clearConsensusWorkflow(operationID: operationID)
                guard accepted else { return }
                self?.presentExtractionFailureAlert(
                    title: "Generate Consensus Failed",
                    message: error.localizedDescription
                )
                self?.clearConsensusWorkflow(operationID: operationID)
            }
        }
        activeConsensusGenerationTask = task
        OperationCenter.shared.setCancelCallback(for: operationID) { task.cancel() }
    }

    private func confirmAllLowDepthConsensus(
        _ generation: AlignmentScientificActionCoordinator.ConsensusGeneration,
        on window: NSWindow,
        operationID: UUID
    ) async -> Bool {
        if let alignmentConsensusAllLowDepthConfirmation {
            return await alignmentConsensusAllLowDepthConfirmation(
                generation.allLowDepthWarningMessage,
                window
            )
        }
        guard window.attachedSheet == nil else { return false }
        return await presentAlignmentConsensusAllLowDepthConfirmation(
            message: generation.allLowDepthWarningMessage,
            on: window,
            operationID: operationID
        )
    }

    func presentAlignmentConsensusAllLowDepthConfirmation(
        message: String,
        on window: NSWindow,
        operationID: UUID
    ) async -> Bool {
        guard OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else { return false }
        return await withCheckedContinuation { continuation in
            let gate = AlignmentConsensusConfirmationGate(continuation)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Consensus Contains Only N"
            alert.informativeText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            OperationCenter.shared.setCancelCallback(for: operationID) { [weak window, weak alertWindow = alert.window] in
                DispatchQueue.main.async {
                    if let window, let alertWindow, window.attachedSheet === alertWindow {
                        window.endSheet(alertWindow, returnCode: .cancel)
                    }
                    gate.resolve(false)
                }
            }
            alert.beginSheetModal(for: window) { response in
                gate.resolve(response == .alertFirstButtonReturn)
            }
        }
    }

    private func presentAlignmentConsensusDestinationDialog(
        _ generation: AlignmentScientificActionCoordinator.ConsensusGeneration,
        coordinator: AlignmentScientificActionCoordinator,
        operationID: UUID
    ) {
        guard activeConsensusGenerationOperationID == operationID,
              OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else {
            OperationCenter.shared.acknowledgeCancellation(id: operationID)
            return
        }
        guard let window = view.window, window.attachedSheet == nil else {
            _ = OperationCenter.shared.fail(
                id: operationID,
                detail: "Consensus destination unavailable",
                errorMessage: "An application window is required to choose a consensus destination."
            )
            clearConsensusWorkflow(operationID: operationID)
            return
        }
        let model = FASTASequenceExtractionDialogModel(
            selectionCount: 1,
            suggestedName: generation.exportRequest.suggestedName
        )
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dialog = FASTASequenceExtractionDialog(
            model: model,
            onCancel: {
                OperationCenter.shared.cancel(id: operationID)
            },
            onPrimary: { [weak self, weak window, weak sheet] in
                guard let self, let window, let sheet else { return }
                _ = performConsensusDestinationPrimaryIfActive(operationID: operationID) {
                    if window.attachedSheet === sheet { window.endSheet(sheet) }
                    let requested = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = requested.isEmpty ? generation.exportRequest.suggestedName : requested
                    handleAlignmentConsensusDestination(
                        model.destination,
                        generation: generation,
                        coordinator: coordinator,
                        operationID: operationID,
                        suggestedName: name,
                        window: window
                    )
                }
            }
        )
        sheet.contentViewController = NSHostingController(rootView: dialog)
        // Generation has completed, so cancellation must now own the sheet
        // handoff rather than continuing to target the completed generation task.
        installConsensusDestinationCancellation(
            operationID: operationID,
            window: window,
            sheet: sheet
        )
        window.beginSheet(sheet)
    }

    func installConsensusDestinationCancellation(
        operationID: UUID,
        window: NSWindow?,
        sheet: NSWindow?
    ) {
        OperationCenter.shared.setCancelCallback(for: operationID) { [weak self, weak window, weak sheet] in
            DispatchQueue.main.async {
                if let window, let sheet, window.attachedSheet === sheet {
                    window.endSheet(sheet)
                }
                self?.clearConsensusWorkflow(operationID: operationID)
                OperationCenter.shared.acknowledgeCancellation(id: operationID)
            }
        }
    }

    /// Executes the destination sheet's primary action only while its exact
    /// Operation Center row is still running. `cancel(id:)` changes the row to
    /// `.cancelling` synchronously, closing the callback-dispatch race in which
    /// a primary click could otherwise start publication after cancellation.
    @discardableResult
    func performConsensusDestinationPrimaryIfActive(
        operationID: UUID,
        action: () -> Void
    ) -> Bool {
        guard activeConsensusGenerationOperationID == operationID,
              OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else {
            return false
        }
        action()
        return true
    }

    private func handleAlignmentConsensusDestination(
        _ destination: DialogDestination,
        generation: AlignmentScientificActionCoordinator.ConsensusGeneration,
        coordinator: AlignmentScientificActionCoordinator,
        operationID: UUID,
        suggestedName: String,
        window: NSWindow
    ) {
        guard activeConsensusGenerationOperationID == operationID,
              OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else {
            return
        }
        switch destination {
        case .clipboard:
            DefaultPasteboard().setString(generation.fastaRecord)
            OperationCenter.shared.log(id: operationID, level: .info, message: generation.summary)
            _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus copied to clipboard")
            clearConsensusWorkflow(operationID: operationID)
            let alert = NSAlert()
            alert.messageText = "Consensus Copied"
            alert.informativeText = generation.summary
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        case .bundle, .file:
            let ext = destination == .bundle ? "lungfishref" : "fasta"
            let task = Task { @MainActor [weak self] in
                guard let chosen = await self?.alignmentExtractionSavePanelPresenter.present(
                    suggestedName: "\(ExtractionBundleNaming.sanitizeFilename(suggestedName)).\(ext)",
                    on: window
                ) else {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                self?.clearConsensusWorkflow(operationID: operationID)
                    return
                }
                guard !Task.isCancelled else {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                self?.clearConsensusWorkflow(operationID: operationID)
                    return
                }
                let finalURL = self?.normalizedConsensusDestination(chosen, extension: ext) ?? chosen
                do {
                    let published = try await coordinator.publishConsensus(
                        generation,
                        destination: destination == .bundle ? .referenceBundle(finalURL) : .fasta(finalURL)
                    )
                    if destination == .bundle {
                        _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus reference bundle created", bundleURLs: [published.finalURL])
                    } else {
                        _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus FASTA saved", outputURLs: [published.finalURL, published.provenanceURL])
                    }
                    self?.clearConsensusWorkflow(operationID: operationID)
                } catch is CancellationError {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                    self?.clearConsensusWorkflow(operationID: operationID)
                } catch {
                    self?.logConsensusFailure(error, operationID: operationID)
                    let accepted = OperationCenter.shared.fail(id: operationID, detail: "Consensus publication failed", errorMessage: error.localizedDescription)
                    self?.clearConsensusWorkflow(operationID: operationID)
                    guard accepted else { return }
                    self?.presentExtractionFailureAlert(title: "Publish Consensus Failed", message: error.localizedDescription)
                    self?.clearConsensusWorkflow(operationID: operationID)
                }
            }
            activeConsensusGenerationTask = task
            OperationCenter.shared.setCancelCallback(for: operationID) { [weak window] in
                task.cancel()
                DispatchQueue.main.async {
                    if let window, let sheet = window.attachedSheet as? NSSavePanel {
                        window.endSheet(sheet, returnCode: .cancel)
                    }
                }
            }
        case .share:
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Originating viewer closed")
                    return
                }
                do {
                    try Task.checkCancellation()
                    let directory = try TempFileManager.shared.createRegisteredTempDirectory(prefix: "lungfish-consensus-share-")
                    var transferredToShareSession = false
                    defer {
                        if !transferredToShareSession {
                            TempFileManager.shared.unregisterSessionTempDirectory(directory)
                            try? FileManager.default.removeItem(at: directory)
                        }
                    }
                    let url = directory.appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(suggestedName)).fasta")
                    let published = try await coordinator.publishConsensus(generation, destination: .fasta(url))
                    try Task.checkCancellation()
                    guard OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else { throw CancellationError() }
                    let sessionID = UUID()
                    let session = AlignmentConsensusShareSession(
                        cleanup: {
                            TempFileManager.shared.unregisterSessionTempDirectory(directory)
                            try? FileManager.default.removeItem(at: directory)
                        },
                        finish: { [weak self] outcome in
                            self?.activeConsensusShareSessions[sessionID] = nil
                            switch outcome {
                            case .shared:
                                _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus shared")
                            case .cancelled:
                                OperationCenter.shared.acknowledgeCancellation(id: operationID)
                            case .failed(let message):
                                _ = OperationCenter.shared.fail(id: operationID, detail: "Consensus share failed", errorMessage: message)
                            }
                            self?.clearConsensusWorkflow(operationID: operationID)
                        }
                    )
                    activeConsensusShareSessions[sessionID] = session
                    transferredToShareSession = true
                    OperationCenter.shared.setCancelCallback(for: operationID) {
                        DispatchQueue.main.async { session.cancel() }
                    }
                    session.present(
                        items: [published.finalURL, published.provenanceURL],
                        relativeTo: view,
                        preferredEdge: .minY
                    )
                } catch is CancellationError {
                    finishConsensusWorkflow(operationID: operationID, cancellation: true)
                } catch {
                    logConsensusFailure(error, operationID: operationID)
                    let accepted = OperationCenter.shared.fail(id: operationID, detail: "Consensus share failed", errorMessage: error.localizedDescription)
                    clearConsensusWorkflow(operationID: operationID)
                    guard accepted else { return }
                    presentExtractionFailureAlert(title: "Share Consensus Failed", message: error.localizedDescription)
                    clearConsensusWorkflow(operationID: operationID)
                }
            }
            activeConsensusGenerationTask = task
            OperationCenter.shared.setCancelCallback(for: operationID) { task.cancel() }
        }
    }

    private func finishConsensusWorkflow(operationID: UUID, cancellation: Bool) {
        if cancellation { OperationCenter.shared.acknowledgeCancellation(id: operationID) }
        clearConsensusWorkflow(operationID: operationID)
    }

    private func clearConsensusWorkflow(operationID: UUID) {
        guard activeConsensusGenerationOperationID == operationID else { return }
        activeConsensusGenerationTask = nil
        activeConsensusGenerationOperationID = nil
    }

    private func normalizedConsensusDestination(_ url: URL, extension ext: String) -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.lowercased() != ext else { return normalized }
        return normalized.pathExtension.isEmpty
            ? normalized.appendingPathExtension(ext)
            : normalized.deletingPathExtension().appendingPathExtension(ext)
    }

    private func logConsensusFailure(_ error: Error, operationID: UUID) {
        let records: [AlignmentConsensusExecutionRecord]
        switch error {
        case let failure as AlignmentConsensusPublicationFailure:
            OperationCenter.shared.log(id: operationID, level: .error, message: failure.attempt.durableLogMessage)
            records = []
        case AlignmentFetchError.consensusExecutionFailed(let attached),
             AlignmentFetchError.consensusCoordinateMismatchWithRecords(let attached):
            records = attached
        default:
            records = []
        }
        for record in records {
            OperationCenter.shared.log(
                id: operationID,
                level: .error,
                message: "\(record.reproducibleCommand)\n\(record.stderr ?? "")"
            )
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
        let reporter = AlignmentScientificActionReporter.operationCenter(routeContext: alignmentOperationRouteContext())
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await resolveAlignmentExtractionDestination(
                    context: context,
                    outputBaseName: outputBaseName
                )
                activeSelectedReadsExtractionTask = AlignmentScientificActionCoordinator().launchSelectedReads(
                    context: context,
                    records: reads,
                    destination: destination,
                    outputBaseName: outputBaseName,
                    reporter: reporter
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
    private func presentExtractionFailureAlert(title: String, message: String) {
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

@MainActor
final class AlignmentConsensusShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    enum Outcome: Equatable { case shared, cancelled, failed(String) }

    private let cleanup: () -> Void
    private let finish: (Outcome) -> Void
    private var picker: NSSharingServicePicker?
    private var didFinish = false

    init(cleanup: @escaping () -> Void, finish: @escaping (Outcome) -> Void) {
        self.cleanup = cleanup
        self.finish = finish
    }

    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge) {
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            complete(.cancelled)
            return
        }
        service.delegate = self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        complete(.shared)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        complete(.failed(error.localizedDescription))
    }

    func cancel() {
        complete(.cancelled)
    }

    private func complete(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        picker = nil
        cleanup()
        finish(outcome)
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
