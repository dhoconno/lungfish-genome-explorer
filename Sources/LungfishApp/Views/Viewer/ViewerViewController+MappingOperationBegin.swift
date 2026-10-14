// ViewerViewController+MappingOperationBegin.swift - Operations panel registration for mapping viewport launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow
import LungfishCore
import LungfishIO
import SwiftUI

/// The begin helpers for the launches in the baselined
/// ViewerViewController+Mapping.swift (finding R4). Each one registers a row
/// through `OperationReporting` and calls `launch` only when the row started,
/// so a test can check the row and its command without touching
/// `OperationCenter.shared`. They live here, not beside their launch sites, so
/// the baselined file does not grow (scripts/ratchets/file-size.sh).
extension ViewerViewController {
    /// Registers the alignment consensus row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle.
    ///
    /// cli-parity-gap: alignment-consensus. No lungfish-cli command calls a
    /// consensus from a BAM or CRAM alignment. The closest is `msa consensus`,
    /// which reads a `.lungfishmsa` bundle. The row records no command. It
    /// used to record a `Lungfish.app alignment consensus` description, which
    /// does not parse, so the row's log names the scope and region instead.
    @discardableResult
    static func beginAlignmentConsensusGenerationOperation(
        region: ResolvedAlignmentRegion,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Generate Alignment Consensus",
            detail: "Calling evidence-only consensus…",
            operationType: .export,
            cliCommand: nil
        )
        switch result {
        case .started(let operationID):
            reporter.log(
                id: operationID,
                level: .info,
                message: "Consensus scope \(region.scope.rawValue), region \(region.contig):\(region.start)-\(region.end), reference fill never"
            )
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the overlapping-reads row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle and records the
    /// `lungfish-cli extract reads --by-region` command for the configuration
    /// the run uses.
    @discardableResult
    static func beginOverlappingReadsExtractionOperation(
        annotationName: String,
        config: BAMRegionExtractionConfig,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract Overlapping Reads",
            detail: "Extracting reads overlapping \(annotationName)…",
            operationType: .taxonomyExtraction,
            cliCommand: overlappingReadsExtractionCLICommand(config: config)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli extract reads --by-region` command that reproduces a
    /// run of `ReadExtractionService.extractByBAMRegion` with this
    /// configuration. The run writes `<outputBaseName>.fastq` in the output
    /// directory, so the command names that file in `-o`. The annotation
    /// action sets no map quality, flag or read group filter, and its
    /// duplicate exclusion is the command's default, so the command needs no
    /// option for them. The run passes the mapping's index, and the command
    /// names none because the CLI finds the BAM's companion index, the same
    /// file. The shared service hands each coordinate region, such as
    /// `chr1:11-25`, to samtools as given, so the run and the command write
    /// the same reads, the ones that overlap the annotation's blocks.
    static func overlappingReadsExtractionCLICommand(config: BAMRegionExtractionConfig) -> String {
        var args = ["--by-region", "--bam", config.bamURL.path]
        for region in config.regions {
            args += ["--region", region]
        }
        let outputName = "\(ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)).fastq"
        args += ["-o", config.outputDirectory.appendingPathComponent(outputName).path]
        return OperationCenter.buildCLICommand(subcommand: "extract reads", args: args)
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

        let coordinator = AlignmentScientificActionCoordinator()
        Self.beginAlignmentConsensusGenerationOperation(region: exportRequest.region) { operationID in
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

    func finishConsensusWorkflow(operationID: UUID, cancellation: Bool) {
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
}

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
