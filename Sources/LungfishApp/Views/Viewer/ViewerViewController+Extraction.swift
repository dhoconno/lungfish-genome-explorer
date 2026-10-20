// ViewerViewController+Extraction.swift - Sequence extraction context menu actions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

private let extractionLogger = Logger(subsystem: LogSubsystem.app, category: "Extraction")

// MARK: - SequenceViewerView Extraction Actions

extension SequenceViewerView {

    /// Adds extraction menu items to an annotation context menu.
    func addExtractionMenuItems(to menu: NSMenu, for annotation: SequenceAnnotation) {
        menu.addItem(NSMenuItem.separator())

        // Copy as FASTA
        let copyFASTAItem = NSMenuItem(
            title: "Copy as FASTA",
            action: #selector(copyAnnotationAsFASTA(_:)),
            keyEquivalent: ""
        )
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        menu.addItem(copyFASTAItem)

        // Copy Translation as FASTA (CDS only)
        if annotation.type == .cds {
            let copyProteinItem = NSMenuItem(
                title: "Copy Translation as FASTA",
                action: #selector(copyAnnotationTranslationAsFASTA(_:)),
                keyEquivalent: ""
            )
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            menu.addItem(copyProteinItem)
        }

        // Extract Sequence...
        let extractItem = NSMenuItem(
            title: "Extract Sequence\u{2026}",
            action: #selector(extractAnnotationSequence(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)
    }

    /// Adds extraction menu items to a visible-region context menu.
    func addSelectionExtractionMenuItems(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        // Copy as FASTA
        let copyFASTAItem = NSMenuItem(
            title: "Copy Visible Region as FASTA",
            action: #selector(copySelectionAsFASTA(_:)),
            keyEquivalent: ""
        )
        copyFASTAItem.target = self
        menu.addItem(copyFASTAItem)

        // Extract Sequence...
        let extractItem = NSMenuItem(
            title: "Extract Visible Region\u{2026}",
            action: #selector(extractSelectionSequence(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        menu.addItem(extractItem)
    }

    // MARK: - Annotation FASTA Actions

    @objc func copyAnnotationAsFASTA(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        copyAnnotationAsFASTAImpl(annotation)
    }

    func copyAnnotationAsFASTAImpl(_ annotation: SequenceAnnotation) {
        guard let provider = makeSequenceProvider(for: annotation) else {
            NSSound.beep()
            return
        }

        let chromLength = chromosomeLengthForAnnotation(annotation)

        let request = ExtractionRequest.defaultAnnotationRequest(for: annotation)

        do {
            let result = try SequenceExtractor.extract(
                request: request,
                sequenceProvider: provider,
                chromosomeLength: chromLength
            )
            let fasta = SequenceExtractor.formatFASTA(result)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(fasta, forType: .string)
            extractionLogger.info("Copied FASTA for '\(annotation.name)' (\(result.nucleotideSequence.count) bp) to clipboard")
        } catch {
            extractionLogger.error("Failed to extract sequence for FASTA: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc func runAnnotationFASTAOperation(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        runAnnotationFASTAOperationImpl(annotation)
    }

    func presentAnnotationSequenceExtractionDialog(_ annotations: [SequenceAnnotation]) {
        let records = annotations.compactMap { annotation -> String? in
            guard let provider = makeSequenceProvider(for: annotation) else { return nil }
            let chromLength = chromosomeLengthForAnnotation(annotation)
            let request = ExtractionRequest.defaultAnnotationRequest(for: annotation)
            do {
                let result = try SequenceExtractor.extract(
                    request: request,
                    sequenceProvider: provider,
                    chromosomeLength: chromLength
                )
                return SequenceExtractor.formatFASTA(result)
            } catch {
                extractionLogger.error("Failed to prepare annotation extraction for '\(annotation.name)': \(error.localizedDescription)")
                return nil
            }
        }
        guard !records.isEmpty else {
            NSSound.beep()
            return
        }
        let suggestedName = annotations.count == 1 ? annotations[0].name : "selected-annotations"
        viewController?.presentFASTASequenceExtractionDialog(records: records, suggestedName: suggestedName)
    }

    func runAnnotationFASTAOperationImpl(_ annotation: SequenceAnnotation) {
        guard let provider = makeSequenceProvider(for: annotation) else {
            NSSound.beep()
            return
        }

        let chromLength = chromosomeLengthForAnnotation(annotation)
        let request = ExtractionRequest.defaultAnnotationRequest(for: annotation)

        do {
            let result = try SequenceExtractor.extract(
                request: request,
                sequenceProvider: provider,
                chromosomeLength: chromLength
            )
            viewController?.presentFASTAOperationDialog(
                records: [SequenceExtractor.formatFASTA(result)],
                suggestedName: annotation.name
            )
        } catch {
            extractionLogger.error("Failed to prepare annotation for FASTQ/FASTA operation: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc func copyAnnotationTranslationAsFASTA(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        copyAnnotationTranslationAsFASTAImpl(annotation)
    }

    func copyAnnotationTranslationAsFASTAImpl(_ annotation: SequenceAnnotation) {
        guard let provider = makeSequenceProvider(for: annotation) else {
            NSSound.beep()
            return
        }

        let chromLength = chromosomeLengthForAnnotation(annotation)

        let request = ExtractionRequest.defaultAnnotationRequest(for: annotation)

        do {
            let result = try SequenceExtractor.extract(
                request: request,
                sequenceProvider: provider,
                chromosomeLength: chromLength
            )
            guard let proteinFASTA = SequenceExtractor.formatProteinFASTA(result) else {
                extractionLogger.warning("No protein sequence available for '\(annotation.name)'")
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(proteinFASTA, forType: .string)
            extractionLogger.info("Copied protein FASTA for '\(annotation.name)' to clipboard")
        } catch {
            extractionLogger.error("Failed to extract translation for FASTA: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    // MARK: - Selection FASTA Action

    @objc func copySelectionAsFASTA(_ sender: Any?) {
        guard let region = currentVisibleViewportRegion() else {
            NSSound.beep()
            return
        }
        let chromLength = region.chromosomeLength
        let provider = makeRegionSequenceProvider()

        let request = ExtractionRequest(
            source: .region(chromosome: region.chromosome, start: region.start, end: region.end)
        )

        do {
            let result = try SequenceExtractor.extract(
                request: request,
                sequenceProvider: provider,
                chromosomeLength: chromLength
            )
            let fasta = SequenceExtractor.formatFASTA(result)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(fasta, forType: .string)
            extractionLogger.info("Copied visible-region FASTA (\(result.nucleotideSequence.count) bp) to clipboard")
        } catch {
            extractionLogger.error("Failed to extract visible region for FASTA: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    // MARK: - Extract Sheet Actions

    @objc func extractAnnotationSequence(_ sender: NSMenuItem?) {
        guard let annotation = sender?.representedObject as? SequenceAnnotation else { return }
        presentAnnotationSequenceExtractionDialog([annotation])
    }

    @objc func extractSelectionSequence(_ sender: Any?) {
        guard let region = currentVisibleViewportRegion() else {
            NSSound.beep()
            return
        }
        presentExtractionSheet(
            for: .region(chromosome: region.chromosome, start: region.start, end: region.end)
        )
    }

    /// Returns the currently visible viewport interval for region-based extraction.
    private func currentVisibleViewportRegion() -> (chromosome: String, start: Int, end: Int, chromosomeLength: Int)? {
        guard let frame = viewController?.referenceFrame else { return nil }
        let start = max(0, Int(frame.start))
        let end = max(start + 1, Int(ceil(frame.end)))
        return (frame.chromosome, start, end, frame.sequenceLength)
    }

    /// Presents the extraction configuration sheet for the given source.
    func presentExtractionSheet(for source: ExtractionRequest.Source) {
        guard let window = self.window else { return }
        if window.attachedSheet != nil { return }

        let sourceName: String
        let sourceType: String
        let isDiscontiguous: Bool
        let isCDS: Bool
        let strand: Strand

        switch source {
        case .region(let chrom, let start, let end):
            // 1-based inclusive, matching the ruler and the FASTA header the extractor writes.
            sourceName = GenomicRegion.plainDisplayString(chromosome: chrom, start: start, end: end)
            sourceType = "Region"
            isDiscontiguous = false
            isCDS = false
            strand = .unknown

        case .annotation(let annotation):
            sourceName = annotation.name
            sourceType = annotation.type.rawValue
            isDiscontiguous = annotation.isDiscontinuous
            isCDS = annotation.type == .cds
            strand = annotation.strand
        }

        let sheetWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var configView = ExtractionConfigurationView(
            sourceName: sourceName,
            sourceType: sourceType,
            isDiscontiguous: isDiscontiguous,
            isCDS: isCDS,
            strand: strand
        )

        configView.onExtract = { [weak self, weak sheetWindow] config in
            guard let sheetWindow else { return }
            window.endSheet(sheetWindow)
            self?.performExtraction(source: source, config: config)
        }

        configView.onCancel = { [weak sheetWindow] in
            guard let sheetWindow else { return }
            window.endSheet(sheetWindow)
        }

        sheetWindow.contentViewController = NSHostingController(rootView: configView)
        window.beginSheet(sheetWindow)
    }

    // MARK: - Extraction Execution

    private func performExtraction(source: ExtractionRequest.Source, config: ExtractionConfiguration) {
        let provider: SequenceExtractor.SequenceProvider
        let chromLength: Int

        switch source {
        case .annotation(let annotation):
            guard let p = makeSequenceProvider(for: annotation) else {
                NSSound.beep()
                return
            }
            provider = p
            chromLength = chromosomeLengthForAnnotation(annotation)

        case .region:
            provider = makeRegionSequenceProvider()
            guard let frame = viewController?.referenceFrame else { return }
            chromLength = frame.sequenceLength
        }

        let request = ExtractionRequest(
            source: source,
            flank5Prime: config.flank5Prime,
            flank3Prime: config.flank3Prime,
            reverseComplement: config.reverseComplement,
            concatenateExons: config.concatenateExons
        )

        do {
            let result = try SequenceExtractor.extract(
                request: request,
                sequenceProvider: provider,
                chromosomeLength: chromLength
            )

            switch config.outputMode {
            case .clipboardNucleotide:
                let fasta = SequenceExtractor.formatFASTA(result)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(fasta, forType: .string)
                extractionLogger.info("Copied nucleotide FASTA (\(result.nucleotideSequence.count) bp) to clipboard")

            case .clipboardProtein:
                guard let proteinFASTA = SequenceExtractor.formatProteinFASTA(result) else {
                    extractionLogger.warning("No protein sequence available")
                    NSSound.beep()
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(proteinFASTA, forType: .string)
                extractionLogger.info("Copied protein FASTA to clipboard")

            case .newBundle:
                let visibleFilter = computeVisibleSampleFilter()
                createExtractionBundle(
                    from: result,
                    request: request,
                    bundleName: config.bundleName,
                    sampleFilter: visibleFilter
                )
            }
        } catch {
            extractionLogger.error("Extraction failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    func createExtractionBundle(
        from result: LungfishCore.ExtractionResult,
        request: ExtractionRequest,
        bundleName: String,
        sampleFilter: Set<String>? = nil
    ) {
        let outputDir = extractionsDirectory()
        let projectURL = ProjectTempDirectory.findProjectRoot(outputDir)
        guard canWriteExtractionProjectOutputs(
            projectURL: projectURL,
            workflowName: "Sequence extraction"
        ) else { return }
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
        guard let bundle = currentReferenceBundle else {
            createExtractionBundleFromDocument(
                from: result, request: request, bundleName: bundleName, outputDir: outputDir,
                projectURL: projectURL, routeContext: routeContext
            )
            return
        }

        // The region extraction runs `extract sequence --bundle` (2.11 A48 M2), which reads the
        // source bundle's annotation and variant tracks itself, keeps the samples the viewer shows,
        // stages the new bundle and publishes it under the name chosen here.
        let outputBundleURL = SequenceExtractionBundleBuilder.uniqueBundleURL(
            for: result,
            desiredBundleName: bundleName,
            in: outputDir
        )
        let arguments = SequenceExtractionPipeline.cliArguments(
            source: request.source,
            flank5Prime: request.flank5Prime,
            flank3Prime: request.flank3Prime,
            reverseComplement: request.reverseComplement,
            concatenateExons: request.concatenateExons,
            sourceBundleURL: bundle.url,
            bundleName: bundleName,
            sampleFilter: sampleFilter,
            outputBundleURL: outputBundleURL
        )
        extractionLogger.info("createExtractionBundle: source=\(bundle.url.path), outputBundle=\(outputBundleURL.path)")
        Self.beginExtractionBundleOperation(
            sourceName: result.sourceName,
            arguments: arguments,
            routeContext: routeContext
        ) { itemId in
            Self.launchExtractionBundle(arguments: arguments, outputBundleURL: outputBundleURL, itemId: itemId)
        }
    }

    /// Runs `arguments` on `CLIBundleBuildRunner` for the row `itemId`. The row completes with the
    /// bundle the command's `complete` line names, a cancel the runner acknowledged on the row ends it
    /// Cancelled with no alert, and a failure fails it with the alert. A failure that published nothing
    /// also removes `stagedInput`, the folder of the FASTA the run read, since a failed run writes no
    /// record that names it. A success and a cancel keep it, because their records name it.
    private static func launchExtractionBundle(
        arguments: [String], outputBundleURL: URL, itemId: UUID, stagedInput: URL? = nil
    ) {
        Task { @MainActor in
            do {
                let run = try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: itemId)
                let bundleURL = run.outputs.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? outputBundleURL
                extractionLogger.info("createExtractionBundle: SUCCESS -> \(bundleURL.path)")
                _ = DownloadCenter.shared.complete(id: itemId, detail: run.message ?? "Bundle ready", bundleURLs: [bundleURL])
            } catch is CancellationError {
                // The runner acknowledged the cancel on the row, and the command published nothing.
            } catch {
                if let stagedInput {
                    StagedSequenceInput.discard(stagedInput, unlessPublishedAt: outputBundleURL)
                }
                failExtractionBundle(itemId: itemId, description: error.localizedDescription, detail: "\(error)")
            }
        }
    }

    /// Builds the bundle of a viewer with no reference bundle on `extract sequence` (2.12 lane 12.12,
    /// A48-GAP). Before the row begins, the sequence the viewer shows is written as a FASTA under the
    /// project's `.tmp/` (`StagedSequenceInput`), which stays for the record that names it. The row then
    /// records `extract sequence <staged FASTA> <region> --name=<name> --source-document <document> -o
    /// <bundle>`. A failure to write starts no row and shows the alert. A GenBank document's annotations
    /// are not carried, as before, and the record says so (R-B3).
    private func createExtractionBundleFromDocument(
        from result: LungfishCore.ExtractionResult,
        request: ExtractionRequest,
        bundleName: String,
        outputDir: URL,
        projectURL: URL?,
        routeContext: OperationRouteContext
    ) {
        guard let sequence else {
            NSSound.beep()
            return
        }
        let documentURL = viewController?.currentDocument.flatMap { document -> URL? in
            guard document.projectSequenceID == nil, document.url.isFileURL,
                  FileManager.default.fileExists(atPath: document.url.path) else { return nil }
            return document.url
        }
        let outputBundleURL = SequenceExtractionBundleBuilder.uniqueBundleURL(
            for: result, desiredBundleName: bundleName, in: outputDir
        )
        let record = StagedSequenceInput.Record(name: sequence.name, bases: sequence.asString())
        Task { @MainActor in
            let inputURL: URL
            do {
                inputURL = try await StagedSequenceInput.writeFASTA(
                    [record], fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: projectURL
                )
            } catch {
                Self.failExtractionBundle(itemId: nil, description: error.localizedDescription, detail: "\(error)")
                return
            }
            let arguments = SequenceExtractionPipeline.cliFASTAArguments(
                source: request.source,
                flank5Prime: request.flank5Prime,
                flank3Prime: request.flank3Prime,
                reverseComplement: request.reverseComplement,
                concatenateExons: request.concatenateExons,
                inputURL: inputURL,
                sequenceName: sequence.name,
                sourceDocumentURL: documentURL,
                bundleName: bundleName,
                outputBundleURL: outputBundleURL
            )
            extractionLogger.info("createExtractionBundle: input=\(inputURL.path), outputBundle=\(outputBundleURL.path)")
            Self.beginExtractionBundleOperation(
                sourceName: result.sourceName, arguments: arguments, routeContext: routeContext
            ) { itemId in
                Self.launchExtractionBundle(
                    arguments: arguments, outputBundleURL: outputBundleURL, itemId: itemId,
                    stagedInput: inputURL.deletingLastPathComponent()
                )
            }
        }
    }

    /// Fails the row, when one began, with the error's words and shows them in an alert over the key window.
    private static func failExtractionBundle(itemId: UUID?, description: String, detail: String) {
        extractionLogger.error("Bundle creation failed: \(detail)")
        if let itemId {
            _ = DownloadCenter.shared.fail(id: itemId, detail: "Failed: \(description)")
        }
        let alert = NSAlert()
        alert.messageText = "Bundle Creation Failed"
        alert.informativeText = description
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Registers the row for building a bundle from an extracted sequence and,
    /// only when it starts, calls `launch` with the operation ID. The row locks
    /// no bundle. `arguments` is the `lungfish-cli` argv the route runs,
    /// `extract sequence --bundle` with a reference bundle (2.11 A48 M2) or
    /// `extract sequence <staged FASTA>` without one (2.12 lane 12.12), and the
    /// row records that command.
    @discardableResult
    static func beginExtractionBundleOperation(
        sourceName: String,
        arguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extracting \(sourceName)",
            detail: "Preparing...",
            operationType: .bundleBuild,
            cliCommand: OperationCenter.buildCLICommand(subcommand: "extract sequence", args: Array(arguments.dropFirst(2))),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Computes the set of visible sample names from the current variant tracks
    /// and sample display state. Returns `nil` if there are no hidden samples
    /// (i.e. all samples should be included).
    private func computeVisibleSampleFilter() -> Set<String>? {
        guard sampleDisplayState.hiddenSamples.isEmpty == false,
              let bundle = currentReferenceBundle else {
            return nil
        }

        // Collect all sample names across variant tracks
        var allSamples: [String] = []
        var seen = Set<String>()
        for trackId in bundle.variantTrackIds {
            guard let trackInfo = bundle.variantTrack(id: trackId),
                  let dbPath = trackInfo.databasePath,
                  let dbURL = try? bundle.memberURL(
                      for: dbPath,
                      field: "variants[\(trackId)].databasePath"
                  ) else { continue }
            guard let db = try? VariantDatabase(url: dbURL) else { continue }
            for name in db.sampleNames() where seen.insert(name).inserted {
                allSamples.append(name)
            }
        }

        guard !allSamples.isEmpty else { return nil }

        let visible = sampleDisplayState.visibleSamples(from: allSamples)
        // If all samples are visible, return nil (no filtering needed)
        guard visible.count < allSamples.count else { return nil }
        return Set(visible)
    }

    /// Returns the directory for saved extraction bundles.
    private func extractionsDirectory() -> URL {
        if let projectURL = projectURLForCurrentViewerOutput() {
            return projectURL.appendingPathComponent("Extractions", isDirectory: true)
        }
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let workingURL = appDelegate.getWorkingDirectoryURL() {
            return workingURL.appendingPathComponent("Extractions", isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Lungfish Extractions", isDirectory: true)
    }

    private func projectURLForCurrentViewerOutput() -> URL? {
        if let currentBundleURL = viewController?.currentBundleURL,
           let projectURL = ProjectTempDirectory.findProjectRoot(currentBundleURL) {
            return projectURL
        }
        if let referenceBundleURL = currentReferenceBundle?.url,
           let projectURL = ProjectTempDirectory.findProjectRoot(referenceBundleURL) {
            return projectURL
        }
        return nil
    }

    private func canWriteExtractionProjectOutputs(projectURL: URL?, workflowName: String) -> Bool {
        if let viewController {
            return viewController.canWriteProjectOutputs(projectURL: projectURL, workflowName: workflowName)
        }
        return AppDelegate.shared?.canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: windowStateScope,
            workflowName: workflowName,
            presentingWindow: window
        ) ?? true
    }

    // MARK: - Sequence Provider Helpers

    /// Creates a sequence provider for an annotation (bundle mode or single-sequence mode).
    func makeSequenceProvider(for annotation: SequenceAnnotation) -> SequenceExtractor.SequenceProvider? {
        if let bundle = currentReferenceBundle {
            return ClampedSequenceProvider(bundle: bundle).extractionProvider
        } else if let seq = sequence {
            return { _, start, end in
                let clampedStart = max(0, start)
                let clampedEnd = min(seq.length, end)
                guard clampedStart < clampedEnd else { return nil }
                return seq[clampedStart..<clampedEnd]
            }
        }
        return nil
    }

    /// Creates a sequence provider for region-based extraction.
    func makeRegionSequenceProvider() -> SequenceExtractor.SequenceProvider {
        if let bundle = currentReferenceBundle {
            return ClampedSequenceProvider(bundle: bundle).extractionProvider
        } else if let seq = sequence {
            return { _, start, end in
                let clampedStart = max(0, start)
                let clampedEnd = min(seq.length, end)
                guard clampedStart < clampedEnd else { return nil }
                return seq[clampedStart..<clampedEnd]
            }
        }
        return { _, _, _ in nil }
    }

    /// Returns the chromosome length for an annotation.
    func chromosomeLengthForAnnotation(_ annotation: SequenceAnnotation) -> Int {
        if let bundle = currentReferenceBundle {
            let chromName = annotation.chromosome ?? bundle.firstChromosomeName ?? ""
            if let chromInfo = bundle.chromosome(named: chromName) {
                return Int(chromInfo.length)
            }
        }
        if let seq = sequence {
            return seq.length
        }
        return annotation.end
    }
}
