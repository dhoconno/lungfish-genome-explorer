// ViewerViewController+Extraction.swift - Sequence extraction context menu actions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let extractionLogger = Logger(subsystem: LogSubsystem.app, category: "Extraction")

private func scheduleExtractionOnMainRunLoop(_ block: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        block()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

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

        let request = ExtractionRequest(source: .annotation(annotation))

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

        let request = ExtractionRequest(source: .annotation(annotation))

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
        presentExtractionSheet(for: .annotation(annotation))
    }

    @objc func extractSelectionSequence(_ sender: Any?) {
        guard let region = currentVisibleViewportRegion() else { return }
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
            sourceName = "\(chrom):\(start)-\(end)"
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
                    bundleName: config.bundleName,
                    concatenateExons: config.concatenateExons,
                    sampleFilter: visibleFilter
                )
            }
        } catch {
            extractionLogger.error("Extraction failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    func createExtractionBundle(
        from result: ExtractionResult,
        bundleName: String,
        concatenateExons: Bool = false,
        sampleFilter: Set<String>? = nil
    ) {
        let sourceBundleName = currentReferenceBundle?.manifest.name
        let outputDir = extractionsDirectory()

        // Collect all annotation tracks with SQLite databases from the source bundle.
        var sourceAnnotationTracks: [SequenceExtractionPipeline.SourceAnnotationTrack] = []
        var sourceVariantTracks: [SequenceExtractionPipeline.SourceVariantTrack] = []
        var sourceBundleChromosomes: [ChromosomeInfo] = []
        if let bundle = currentReferenceBundle {
            sourceBundleChromosomes = bundle.manifest.genome?.chromosomes ?? []
            sourceAnnotationTracks = bundle.annotationTrackIds.compactMap { trackID in
                guard let trackInfo = bundle.annotationTrack(id: trackID),
                      let dbPath = trackInfo.databasePath else {
                    return nil
                }
                return SequenceExtractionPipeline.SourceAnnotationTrack(
                    id: trackInfo.id,
                    name: trackInfo.name,
                    databaseURL: bundle.url.appendingPathComponent(dbPath),
                    annotationType: trackInfo.annotationType
                )
            }

            // Collect variant tracks with SQLite databases
            sourceVariantTracks = bundle.variantTrackIds.compactMap { trackID in
                guard let trackInfo = bundle.variantTrack(id: trackID),
                      let dbPath = trackInfo.databasePath else {
                    return nil
                }
                return SequenceExtractionPipeline.SourceVariantTrack(
                    id: trackInfo.id,
                    name: trackInfo.name,
                    databaseURL: bundle.url.appendingPathComponent(dbPath),
                    variantType: trackInfo.variantType
                )
            }
        }

        extractionLogger.info("createExtractionBundle: outputDir=\(outputDir.path), bundleName=\(bundleName), annotationTracks=\(sourceAnnotationTracks.count), variantTracks=\(sourceVariantTracks.count), sourceChromosomes=\(sourceBundleChromosomes.count)")

        // Register with DownloadCenter on the main actor, then run bundle building in
        // a detached task. On completion we hop back to the main actor for import/refresh.
        let itemId = DownloadCenter.shared.start(
            title: "Extracting \(result.sourceName)",
            detail: "Preparing...",
            operationType: .bundleBuild
        )

        let capturedResult = result
        let capturedOutputDir = outputDir
        let capturedSourceBundleName = sourceBundleName
        let capturedSourceBundleChromosomes = sourceBundleChromosomes
        let capturedBundleName = bundleName
        let capturedSourceAnnotationTracks = sourceAnnotationTracks
        let capturedSourceVariantTracks = sourceVariantTracks
        let capturedSampleFilter = sampleFilter
        let capturedConcatenateExons = concatenateExons

        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: capturedOutputDir, withIntermediateDirectories: true
                )

                let pipeline = SequenceExtractionPipeline()
                let bundleURL = try await pipeline.buildBundle(
                    from: capturedResult,
                    outputDirectory: capturedOutputDir,
                    sourceBundleName: capturedSourceBundleName,
                    desiredBundleName: capturedBundleName,
                    sourceBundleChromosomes: capturedSourceBundleChromosomes,
                    sourceAnnotationTracks: capturedSourceAnnotationTracks,
                    sourceVariantTracks: capturedSourceVariantTracks,
                    sampleFilter: capturedSampleFilter,
                    isConcatenated: capturedConcatenateExons,
                    progressHandler: { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                DownloadCenter.shared.update(
                                    id: itemId,
                                    progress: progress,
                                    detail: message
                                )
                            }
                        }
                    }
                )

                let finalBundleURL = bundleURL
                scheduleExtractionOnMainRunLoop {
                    MainActor.assumeIsolated {
                        extractionLogger.info("createExtractionBundle: SUCCESS -> \(finalBundleURL.path)")
                        let bundleURLs = [finalBundleURL]

                        // Mark as complete for UI cards.
                        DownloadCenter.shared.complete(id: itemId, detail: "Bundle ready")

                        // Import through AppDelegate pipeline.
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.importReadyBundles(bundleURLs)

                            // Force immediate sidebar refresh/selection as an additional safety path.
                            if let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                                sidebar.reloadFromFilesystem()
                                _ = sidebar.selectItem(forURL: finalBundleURL)
                            }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                let errorStr = "\(error)"
                scheduleExtractionOnMainRunLoop {
                    MainActor.assumeIsolated {
                        extractionLogger.error("Bundle creation failed: \(errorStr)")
                        DownloadCenter.shared.fail(
                            id: itemId,
                            detail: "Failed: \(errorDesc)"
                        )
                        let alert = NSAlert()
                        alert.messageText = "Bundle Creation Failed"
                        alert.informativeText = errorDesc
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
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
                  let dbPath = trackInfo.databasePath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbPath)
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
        if let projectURL = DocumentManager.shared.activeProject?.url {
            return projectURL.appendingPathComponent("Extractions", isDirectory: true)
        }
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let workingURL = appDelegate.getWorkingDirectoryURL() {
            return workingURL.appendingPathComponent("Extractions", isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Lungfish Extractions", isDirectory: true)
    }

    // MARK: - Sequence Provider Helpers

    /// Creates a sequence provider for an annotation (bundle mode or single-sequence mode).
    func makeSequenceProvider(for annotation: SequenceAnnotation) -> SequenceExtractor.SequenceProvider? {
        if let bundle = currentReferenceBundle {
            return { chromosome, start, end in
                let region = GenomicRegion(chromosome: chromosome, start: start, end: end)
                return try? bundle.fetchSequenceSync(region: region)
            }
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
            return { chromosome, start, end in
                let region = GenomicRegion(chromosome: chromosome, start: start, end: end)
                return try? bundle.fetchSequenceSync(region: region)
            }
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
            let chromName = annotation.chromosome ?? bundle.chromosomeNames.first ?? ""
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
