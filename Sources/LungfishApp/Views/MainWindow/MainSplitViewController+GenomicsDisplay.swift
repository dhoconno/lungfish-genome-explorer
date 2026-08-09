// MainSplitViewController+GenomicsDisplay.swift - Genomics viewport display routing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    /// Navigates to a related metagenomics analysis from TaxTriage cross-links.
    ///
    /// Called when the user clicks a "View Kraken2" or "View EsViritu" button
    /// in the TaxTriage action bar. Routes to the appropriate display method.
    ///
    /// - Parameters:
    ///   - type: The analysis type ("kraken2" or "esviritu").
    ///   - url: The result directory URL.
    func navigateToRelatedAnalysis(type: String, url: URL) {
        mainSplitLogger.info("navigateToRelatedAnalysis: type=\(type, privacy: .public), url=\(url.lastPathComponent, privacy: .public)")
        routeClassifierDisplay(url: url)
    }

    /// Display genomics file - cache-first, then load via DocumentManager.
    func displayGenomicsFile(url: URL) {
        // FASTQ bundles use the streaming statistics dashboard
        if FASTQBundle.isBundleURL(url) {
            loadFASTQDatasetInBackground(sourceURL: url)
            return
        }

        // Naked FASTQ files in the project: auto-bundle in place, then display the bundle
        if FASTQBundle.isFASTQFileURL(url),
           !FASTQBundle.isBundleURL(url.deletingLastPathComponent()) {
            guard canWriteProjectOutputs(workflowName: "FASTQ import") else {
                loadFASTQDatasetInBackground(sourceURL: url)
                return
            }
            let parentDir = url.deletingLastPathComponent()
            let baseName = FASTQBundle.deriveBaseName(from: url)
            let bundleURL = parentDir.appendingPathComponent("\(baseName).\(FASTQBundle.directoryExtension)")

            // If bundle already exists (e.g. from a previous partial import), just display it
            if FASTQBundle.isBundleURL(bundleURL) {
                loadFASTQDatasetInBackground(sourceURL: bundleURL)
                return
            }

            do {
                _ = try FASTQAutoBundleWorkflow.wrapNakedFASTQ(sourceURL: url, bundleURL: bundleURL)
                mainSplitLogger.info("displayGenomicsFile: Auto-bundled naked FASTQ \(url.lastPathComponent) → \(bundleURL.lastPathComponent)")
                sidebarController.requestReloadFromFilesystem()
                loadFASTQDatasetInBackground(sourceURL: bundleURL)
            } catch {
                mainSplitLogger.error("displayGenomicsFile: Failed to auto-bundle FASTQ: \(error)")
                // Fall back to displaying naked file
                loadFASTQDatasetInBackground(sourceURL: url)
            }
            return
        }

        // FASTQ file inside a bundle — just display it
        if FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil {
            loadFASTQDatasetInBackground(sourceURL: url)
            return
        }

        cancelFASTQLoadIfNeeded(hideProgress: true, reason: "displaying non-FASTQ file \(url.lastPathComponent)")

        if url.pathExtension.lowercased() == "bam",
           let viewerBundleURL = Self.ontGenotypingViewerBundleURL(forRawBAM: url),
           FileManager.default.fileExists(atPath: viewerBundleURL.path) {
            displayReferenceBundleViewportFromSidebar(at: viewerBundleURL)
            return
        }

        // Standalone VCF files use the auto-ingestion pipeline
        if Self.isVCFFile(url) {
            loadVCFFilesInBackground(urls: [url])
            return
        }

        // Check if already loaded
        if let existingDocument = DocumentManager.shared.documents.first(where: { $0.url == url }) {
            let isFullyLoaded = !existingDocument.sequences.isEmpty || !existingDocument.annotations.isEmpty

            if isFullyLoaded {
                mainSplitLogger.info("displayGenomicsFile: Document cached, displaying directly")
                viewerController.displayDocument(existingDocument)
                projectSession.setActiveDocument(existingDocument)
                DocumentManager.shared.setActiveDocument(existingDocument)
                return
            }
        }

        // Not cached - load via DocumentManager using GCD wrapper
        loadGenomicsFileInBackground(url: url)
    }

    static func ontGenotypingViewerBundleURL(forRawBAM url: URL) -> URL? {
        let filename = url.lastPathComponent
        let directory = url.deletingLastPathComponent()

        if filename.hasSuffix(".md.sorted.bam") {
            let stem = String(filename.dropLast(".md.sorted.bam".count))
            return directory.appendingPathComponent("\(stem).mapped.lungfishref", isDirectory: true)
        }

        if filename.hasSuffix(".retained.demuxed.bam") {
            let stem = String(filename.dropLast(".retained.demuxed.bam".count))
            return directory.appendingPathComponent("\(stem).retained-demux.lungfishref", isDirectory: true)
        }

        return nil
    }

    static func genotypeResultWorkbookURL(forBundle url: URL) -> URL? {
        guard ONTGenotypeResultBundle.isBundleURL(url),
              let workbookURL = try? ONTGenotypeResultBundle.currentWorkbookURL(for: url),
              FileManager.default.fileExists(atPath: workbookURL.path) else {
            return nil
        }
        return workbookURL
    }

    /// Returns true if the URL points to a FASTQ file (by extension).
    func isFASTQFile(_ url: URL) -> Bool {
        FASTQBundle.isBundleURL(url) || FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil
    }

    /// Returns true if the URL points to a VCF file (by extension).
    static func isVCFFile(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        return checkURL.pathExtension.lowercased() == "vcf"
    }

    /// Loads one or more standalone VCF files into a single auto-ingested bundle.
    func loadVCFFilesInBackground(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard canWriteProjectOutputs(workflowName: "VCF import") else { return }
        let fileCount = urls.count
        mainSplitLogger.info("loadVCFFilesInBackground: Auto-ingesting \(fileCount) VCF file(s)")

        guard let viewerController = self.viewerController else {
            mainSplitLogger.warning("loadVCFFilesInBackground: Viewer controller not available")
            return
        }

        guard let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url else {
            mainSplitLogger.error("loadVCFFilesInBackground: No active project; refusing non-project bundle import")
            let alert = NSAlert()
            alert.messageText = "No Active Project"
            alert.informativeText = "Open or create a project first. VCF imports are saved as .lungfishref bundles inside the active project."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let defaultBundleName: String = {
            let base = urls.first?.deletingPathExtension().deletingPathExtension().lastPathComponent ?? "VCF Variants"
            let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "VCF Variants" : normalized
        }()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bundleSelection = await self.promptForVCFBundleName(
                defaultName: defaultBundleName,
                projectDirectory: projectURL
            ) else {
                mainSplitLogger.info("loadVCFFilesInBackground: User cancelled VCF import bundle naming")
                return
            }

            let label = fileCount == 1
                ? "Importing VCF file\u{2026}"
                : "Importing \(fileCount) VCF files\u{2026}"
            viewerController.showProgress(label)

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let result = try await VCFAutoIngestor.ingest(
                        vcfURLs: urls,
                        outputDirectory: projectURL,
                        preferredBundleName: bundleSelection.bundleName,
                        replaceExistingBundle: bundleSelection.replaceExisting,
                        progressHandler: { progress, message in
                            DispatchQueue.main.async { [weak viewerController] in
                                MainActor.assumeIsolated {
                                    viewerController?.showProgress(message)
                                }
                            }
                        }
                    )

                    mainSplitLogger.info("loadVCFFilesInBackground: Bundle created at \(result.bundleURL.lastPathComponent, privacy: .public) with \(result.variantCount) variants from \(fileCount) file(s)")

                    let bundleURL = result.bundleURL
                    DispatchQueue.main.async { [weak self, weak viewerController] in
                        MainActor.assumeIsolated {
                            viewerController?.hideProgress()
                            self?.displayReferenceBundleViewportFromSidebar(at: bundleURL)
                        }
                    }

                    if !result.ncbiAccessions.isEmpty || result.inferredReference.accession != nil {
                        let assemblyName = result.inferredReference.assembly ?? "reference"
                        mainSplitLogger.info("loadVCFFilesInBackground: Starting background reference download for \(assemblyName, privacy: .public)")
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.downloadReferenceForNakedBundle(
                                    inferredRef: result.inferredReference,
                                    ncbiAccessions: result.ncbiAccessions,
                                    bundleURL: result.bundleURL
                                )
                            }
                        }
                    }

                } catch {
                    let errorMessage = "\(error)"
                    DispatchQueue.main.async { [weak viewerController] in
                        MainActor.assumeIsolated {
                            viewerController?.hideProgress()
                            mainSplitLogger.error("loadVCFFilesInBackground: Failed - \(errorMessage)")

                            let alert = NSAlert()
                            alert.messageText = "Failed to Import VCF Files"
                            alert.informativeText = errorMessage
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = viewerController?.view.window ?? NSApp.keyWindow {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct VCFBundleSelection {
        let bundleName: String
        let replaceExisting: Bool
    }

    private func promptForVCFBundleName(defaultName: String, projectDirectory: URL) async -> VCFBundleSelection? {
        let alert = NSAlert()
        alert.messageText = "Name Imported Variant Bundle"
        alert.informativeText = "This bundle will be saved inside the active project:\n\(projectDirectory.path)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: defaultName)
        textField.placeholderString = "Bundle Name"
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        guard let window = self.view.window ?? NSApp.keyWindow else { return nil }
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = trimmed.isEmpty ? defaultName : trimmed
        let targetURL = projectDirectory.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        return VCFBundleSelection(
            bundleName: bundleName,
            replaceExisting: FileManager.default.fileExists(atPath: targetURL.path)
        )
    }

    /// Silently downloads reference genome for a naked (variant-only) bundle.
    ///
    /// Tries two strategies in order:
    /// 1. NCBI Assembly search (gives full genome FASTA + GFF3 annotations)
    /// 2. GenBank nucleotide fetch by accession (fallback for single-contig organisms)
    ///
    /// On completion, updates the bundle's manifest with genome info
    /// and reloads the bundle in the viewer.
    func downloadReferenceForNakedBundle(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL
    ) {
        guard canWriteProjectOutputs(workflowName: "Reference download") else { return }
        let assemblyName = inferredRef.assembly ?? ncbiAccessions.first ?? "Reference"

        let downloadID = DownloadCenter.shared.start(
            title: "\(assemblyName) Reference",
            detail: "Searching NCBI\u{2026}",
            routeContext: operationRouteContext
        )

        Task.detached { [weak self] in
            do {
                let tempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "ref-", contextURL: bundleURL)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                // Strategy 1: Try NCBI Assembly search
                let tempBundleURL = try await Self.tryAssemblyDownload(
                    inferredRef: inferredRef,
                    outputDirectory: tempDir,
                    downloadID: downloadID
                )

                if let sourceBundleURL = tempBundleURL {
                    // Assembly download succeeded — merge into naked bundle
                    try Self.mergeGenomeIntoBundle(
                        sourceBundleURL: sourceBundleURL,
                        targetBundleURL: bundleURL
                    )
                } else if let firstAccession = ncbiAccessions.first {
                    // Strategy 2: Fall back to GenBank nucleotide fetch
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
                    }

                    let genBankVM = GenBankBundleDownloadViewModel()
                    let genBankBundleURL = try await genBankVM.downloadAndBuild(
                        accession: firstAccession,
                        outputDirectory: tempDir
                    ) { progress, message in
                        let scaledProgress = 0.15 + progress * 0.8
                        mainSplitPerformOnMainRunLoop {
                            _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                        }
                    }

                    try Self.mergeGenomeIntoBundle(
                        sourceBundleURL: genBankBundleURL,
                        targetBundleURL: bundleURL
                    )
                } else {
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(id: downloadID, detail: "No reference found for '\(assemblyName)'")
                    }
                    return
                }

                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.complete(id: downloadID, detail: "Reference genome added to bundle")
                }

                mainSplitLogger.info("downloadReferenceForNakedBundle: Genome merged into \(bundleURL.lastPathComponent, privacy: .public)")

                // Reload the bundle in the viewer after the downloaded reference is merged.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.displayReferenceBundleViewportFromSidebar(at: bundleURL)
                    }
                }

            } catch {
                let errorMessage = "\(error)"
                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                }
                mainSplitLogger.error("downloadReferenceForNakedBundle: Failed - \(errorMessage)")
            }
        }
    }

    /// Attempts to download reference via NCBI Assembly search.
    /// Returns the temp bundle URL on success, or nil if no assembly found.
    private nonisolated static func tryAssemblyDownload(
        inferredRef: ReferenceInference.Result,
        outputDirectory: URL,
        downloadID: UUID
    ) async throws -> URL? {
        guard let assembly = inferredRef.assembly else { return nil }

        let searchTerm: String
        if let accession = inferredRef.accession {
            searchTerm = accession
        } else {
            searchTerm = "\(inferredRef.organism ?? assembly)[Organism] AND \(assembly)[Assembly Name]"
        }

        let ncbi = NCBIService()

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI Assembly for \(assembly)\u{2026}")
        }

        let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
        guard !ids.isEmpty else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly found for '\(searchTerm, privacy: .public)', will try GenBank fallback")
            return nil
        }

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info\u{2026}")
        }

        let summaries = try await ncbi.assemblyEsummary(ids: ids)
        guard let assemblySummary = summaries.first else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly summary for ids=\(ids, privacy: .public), will try GenBank fallback")
            return nil
        }

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files\u{2026}")
        }

        let viewModel = GenomeDownloadViewModel()
        let bundleURL = try await viewModel.downloadAndBuild(
            assembly: assemblySummary,
            outputDirectory: outputDirectory
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            mainSplitPerformOnMainRunLoop {
                _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
            }
        }

        return bundleURL
    }

    /// Merges genome files from a fully-built temp bundle into a naked (variant-only) bundle.
    private nonisolated static func mergeGenomeIntoBundle(sourceBundleURL: URL, targetBundleURL: URL) throws {
        let fm = FileManager.default

        // Load source manifest to get genome info and annotation tracks
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)

        // Copy genome directory (remove existing first, ignore if absent)
        let sourceGenomeDir = sourceBundleURL.appendingPathComponent("genome")
        let targetGenomeDir = targetBundleURL.appendingPathComponent("genome")
        try? fm.removeItem(at: targetGenomeDir)
        try fm.copyItem(at: sourceGenomeDir, to: targetGenomeDir)

        // Copy annotation files (remove existing first, ignore if absent)
        let sourceAnnoDir = sourceBundleURL.appendingPathComponent("annotations")
        let targetAnnoDir = targetBundleURL.appendingPathComponent("annotations")
        try? fm.removeItem(at: targetAnnoDir)
        if fm.fileExists(atPath: sourceAnnoDir.path) {
            try fm.copyItem(at: sourceAnnoDir, to: targetAnnoDir)
        }

        // Update target manifest: add genome + annotations from source, keep existing variants
        let targetManifest = try BundleManifest.load(from: targetBundleURL)
        let updatedManifest = BundleManifest(
            formatVersion: targetManifest.formatVersion,
            name: sourceManifest.name.isEmpty ? targetManifest.name : sourceManifest.name,
            identifier: targetManifest.identifier,
            description: targetManifest.description,
            createdDate: targetManifest.createdDate,
            modifiedDate: Date(),
            source: sourceManifest.source,
            genome: sourceManifest.genome,
            annotations: sourceManifest.annotations,
            variants: targetManifest.variants,
            alignments: targetManifest.alignments,
            metadata: targetManifest.metadata
        )
        try updatedManifest.save(to: targetBundleURL)
    }

    /// Handles "Download Reference" from the VCF dashboard.
    ///
    /// Searches NCBI for the inferred assembly, downloads FASTA + GFF3,
    /// and builds a .lungfishref bundle via DownloadCenter.
    func downloadReferenceForVCF(_ inferredRef: ReferenceInference.Result, vcfURL: URL) {
        guard let assembly = inferredRef.assembly else {
            mainSplitLogger.warning("downloadReferenceForVCF: No assembly name in inferred reference")
            return
        }

        // Confirmation sheet
        let alert = NSAlert()
        alert.messageText = "Download Reference Genome"
        alert.informativeText = "Download the \(assembly) (\(inferredRef.organism ?? "")) reference genome from NCBI? This will create a bundle that can be used with your VCF file."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard let window = self.view.window ?? NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.performDownloadReferenceForVCF(inferredRef, assembly: assembly)
            }
        }
    }

    /// Continuation of downloadReferenceForVCF after user confirms the download.
    func performDownloadReferenceForVCF(_ inferredRef: ReferenceInference.Result, assembly: String) {
        guard canWriteProjectOutputs(workflowName: "Reference download") else { return }
        // Search term: use accession if available, otherwise assembly name
        let searchTerm: String
        if let accession = inferredRef.accession {
            searchTerm = accession
        } else {
            searchTerm = "\(inferredRef.organism ?? assembly)[Organism] AND \(assembly)[Assembly Name]"
        }

        let downloadID = DownloadCenter.shared.start(
            title: "\(assembly) Reference",
            detail: "Searching NCBI...",
            routeContext: operationRouteContext
        )

        Task.detached {
            do {
                let ncbi = NCBIService()

                // Search for the assembly
                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI for \(assembly)...")
                }

                let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
                guard !ids.isEmpty else {
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(id: downloadID, detail: "No assembly found for '\(assembly)'")
                    }
                    return
                }

                // Get assembly summary
                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info...")
                }

                let summaries = try await ncbi.assemblyEsummary(ids: ids)
                guard let assemblySummary = summaries.first else {
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(id: downloadID, detail: "No assembly details found")
                    }
                    return
                }

                // Download and build bundle
                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files...")
                }

                guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    throw DocumentLoadError.fileNotFound(URL(fileURLWithPath: NSHomeDirectory()))
                }
                let genomesDir = documentsDir
                    .appendingPathComponent("Genomes", isDirectory: true)
                try? FileManager.default.createDirectory(at: genomesDir, withIntermediateDirectories: true)

                let viewModel = GenomeDownloadViewModel()
                let bundleURL = try await viewModel.downloadAndBuild(
                    assembly: assemblySummary,
                    outputDirectory: genomesDir
                ) { progress, message in
                    // Map 0.15-0.95 range for download+build phase
                    let scaledProgress = 0.15 + progress * 0.8
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                    }
                }

                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.complete(id: downloadID, detail: "Bundle ready", bundleURLs: [bundleURL])
                }

                mainSplitLogger.info("downloadReferenceForVCF: Bundle built at \(bundleURL.path, privacy: .public)")
            } catch {
                let errorMessage = "\(error)"
                mainSplitPerformOnMainRunLoop {
                    _ = DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                }
                mainSplitLogger.error("downloadReferenceForVCF: Failed - \(errorMessage)")
            }
        }
    }
    /// computes statistics in a single streaming pass and caches them.
    func loadFASTQDatasetInBackground(sourceURL: URL) {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: standardizedSourceURL)?.standardizedFileURL
        let resolvedFASTQURLs: [URL]? = FASTQBundle.isBundleURL(standardizedSourceURL)
            ? FASTQBundle.resolveAllFASTQURLs(for: standardizedSourceURL)?.map(\.standardizedFileURL)
            : fastqURL.map { [$0] }
        let statisticsCacheURL: URL? = FASTQBundle.isBundleURL(standardizedSourceURL)
            && FASTQBundle.isMultiFileBundle(standardizedSourceURL)
            ? standardizedSourceURL
            : fastqURL
        let derivedManifest = FASTQBundle.isBundleURL(standardizedSourceURL)
            ? FASTQBundle.loadDerivedManifest(in: standardizedSourceURL)
            : nil
        mainSplitLogger.info("loadFASTQDatasetInBackground: Loading source '\(standardizedSourceURL.lastPathComponent, privacy: .public)'")

        guard let viewerController = self.viewerController else {
            mainSplitLogger.warning("loadFASTQDatasetInBackground: Viewer controller not available")
            return
        }

        // Cancel any previous FASTQ work before starting a new request.
        fastqLoadTask?.cancel()
        fastqLoadTask = nil
        fastqLoadGeneration &+= 1
        let generation = fastqLoadGeneration
        activeFASTQLoadURL = statisticsCacheURL ?? fastqURL
        activeFASTQSourceURL = standardizedSourceURL

        let isCurrentRequest: @MainActor () -> Bool = { [weak self] in
            guard let self = self else { return false }
            return self.fastqLoadGeneration == generation &&
                self.activeFASTQSourceURL?.standardizedFileURL == standardizedSourceURL
        }

        // Derived bundles use cached manifest stats (which reflect the true read count,
        // not the preview file's 1,000-read subset).
        if let derivedManifest {
            viewerController.displayFASTQDataset(
                statistics: derivedManifest.cachedStatistics,
                records: [],
                fastqURL: fastqURL,
                sraRunInfo: nil,
                enaReadRecord: nil,
                ingestionMetadata: derivedManifest.pairingMode.map {
                    IngestionMetadata(
                        isClumpified: true,
                        isCompressed: true,
                        pairingMode: $0,
                        qualityBinning: nil,
                        originalFilenames: [],
                        ingestionDate: derivedManifest.createdAt,
                        originalSizeBytes: nil
                    )
                },
                fastqSourceURL: standardizedSourceURL,
                fastqDerivativeManifest: derivedManifest,
                onRunOperation: { [weak self] request in
                    try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                }
            )
            return
        }

        guard let fastqURL, let resolvedFASTQURLs, !resolvedFASTQURLs.isEmpty else {
            mainSplitLogger.error("loadFASTQDatasetInBackground: No FASTQ payload or derivative manifest for '\(standardizedSourceURL.path, privacy: .public)'")
            return
        }

        // Check for cached metadata. ONT imports also have a demux manifest
        // beside their barcode bundles, so use it as an immediate display
        // fallback when the dedicated metadata sidecar is absent.
        let demuxSummaryMeta = FASTQBundle.isBundleURL(standardizedSourceURL)
            ? DemultiplexManifest.cachedFASTQMetadata(forBundle: standardizedSourceURL)
            : nil
        let bundleDisplayMeta = FASTQBundle.isBundleURL(standardizedSourceURL)
            ? FASTQMetadataStore.load(for: standardizedSourceURL)
            : nil
        let cachedStatisticsMeta = statisticsCacheURL.flatMap {
            FASTQMetadataStore.load(for: $0)
        } ?? bundleDisplayMeta ?? demuxSummaryMeta
        let displayMeta = cachedStatisticsMeta
            ?? FASTQMetadataStore.load(for: fastqURL)
            ?? bundleDisplayMeta
            ?? demuxSummaryMeta
        if let cachedStats = cachedStatisticsMeta?.computedStatistics {
            mainSplitLogger.info("loadFASTQDatasetInBackground: Using cached statistics (\(cachedStats.readCount) reads)")
            viewerController.displayFASTQDataset(
                statistics: cachedStats,
                records: [],
                fastqURL: fastqURL,
                sraRunInfo: displayMeta?.sraRunInfo,
                enaReadRecord: displayMeta?.enaReadRecord,
                ingestionMetadata: displayMeta?.ingestion,
                fastqSourceURL: standardizedSourceURL,
                fastqDerivativeManifest: derivedManifest,
                onRunOperation: { [weak self] request in
                    try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                }
            )
            mainSplitLogger.info("loadFASTQDatasetInBackground: Displayed from cache without read table scan")
            return
        }

        let shouldWriteFASTQStatisticsCache = !projectSession.isReadOnlyRecommended
        viewerController.showProgress("Computing FASTQ statistics...")

        fastqLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let statsResult = try await FASTQStatisticsService.compute(
                    for: resolvedFASTQURLs,
                    progress: { count in
                        guard !Task.isCancelled else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard isCurrentRequest(), !Task.isCancelled else { return }
                                viewerController.showProgress(
                                    "Computing FASTQ statistics... \(count) reads processed"
                                )
                            }
                        }
                    }
                )
                let statistics = statsResult.statistics
                try Task.checkCancellation()

                // Cache the computed statistics for next time.
                // Skip stale/deleted targets so we don't write sidecars into removed paths.
                if let statisticsCacheURL,
                   FileManager.default.fileExists(atPath: statisticsCacheURL.path),
                   shouldWriteFASTQStatisticsCache {
                    var metadata = cachedStatisticsMeta ?? displayMeta ?? PersistedFASTQMetadata()
                    metadata.computedStatistics = statistics
                    metadata.seqkitStats = statsResult.seqkitMetadata
                    FASTQMetadataStore.save(metadata, for: statisticsCacheURL)
                } else if !shouldWriteFASTQStatisticsCache {
                    mainSplitLogger.debug("loadFASTQDatasetInBackground: Project is read-only, skipping FASTQ statistics sidecar save")
                } else {
                    mainSplitLogger.debug("loadFASTQDatasetInBackground: FASTQ deleted before cache write, skipping sidecar save")
                }

                let sraRunInfo = displayMeta?.sraRunInfo
                let enaReadRecord = displayMeta?.enaReadRecord
                let ingestionMeta = displayMeta?.ingestion
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, isCurrentRequest() else { return }
                        self.fastqLoadTask = nil
                        viewerController.hideProgress()
                        viewerController.displayFASTQDataset(
                            statistics: statistics,
                            records: [],
                            fastqURL: fastqURL,
                            sraRunInfo: sraRunInfo,
                            enaReadRecord: enaReadRecord,
                            ingestionMetadata: ingestionMeta,
                            fastqSourceURL: standardizedSourceURL,
                            fastqDerivativeManifest: derivedManifest,
                            onRunOperation: { [weak self] request in
                                try await self?.runFASTQOperation(request, sourceURL: standardizedSourceURL)
                            }
                        )
                        mainSplitLogger.info("loadFASTQDatasetInBackground: Dashboard displayed with \(statistics.readCount) total reads")
                    }
                }
            } catch is CancellationError {
                mainSplitLogger.debug("loadFASTQDatasetInBackground: Statistics computation cancelled (gen=\(generation))")
            } catch {
                let errorMessage = "\(error)"
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, isCurrentRequest() else { return }
                        self.fastqLoadTask = nil
                        viewerController.hideProgress()
                        mainSplitLogger.error("loadFASTQDatasetInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Analyze FASTQ File"
                        alert.informativeText = errorMessage
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

    func runFASTQOperation(_ request: FASTQDerivativeRequest, sourceURL: URL) async throws {
        guard canWriteProjectOutputs(workflowName: request.operationLabel) else {
            throw CancellationError()
        }
        let inputURLs = selectedFASTQOperationSources(fallback: sourceURL)
        let sourceBundleURLs = try inputURLs.map(resolveFASTQOperationSourceBundle(from:))

        // Resolve the FASTQ path for CLI command display.
        // For bundles, use the bundle path as the representative input.
        let displayInputPath = sourceBundleURLs.first?.path ?? sourceURL.path
        let displayOutputPath = "<derived>"
        let cliCmd = request.cliCommand(inputPath: displayInputPath, outputPath: displayOutputPath)

        // Register with OperationCenter for visibility in the Operations panel
        let opTitle = "FASTQ: \(request.operationLabel)"
        let startTime = Date()
        let opID: UUID = OperationCenter.shared.start(
            title: opTitle,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCmd,
            routeContext: operationRouteContext
        )
        OperationCenter.shared.log(id: opID, level: .info, message: "Starting \(request.operationLabel)")
        if sourceBundleURLs.count > 1 {
            OperationCenter.shared.log(
                id: opID, level: .info,
                message: "Batch mode: \(sourceBundleURLs.count) input bundles"
            )
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.viewerController.updateFASTQOperationStatus("Running FASTQ/FASTA operation...")
            }
        }

        do {
            let derivedURLs: [URL]
            let failureCount: Int

            if sourceBundleURLs.count > 1 {
                let commonParentDirectory = sharedFASTQOperationParentDirectory(for: sourceBundleURLs)
                let batchResult = try await FASTQDerivativeService.shared.createBatchDerivative(
                    from: sourceBundleURLs,
                    request: request,
                    commonParentDirectory: commonParentDirectory,
                    progress: { [weak self] fraction, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.viewerController.updateFASTQOperationStatus(message)
                                _ = OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )
                derivedURLs = batchResult.outputBundleURLs
                failureCount = batchResult.failures.count
                if !batchResult.failures.isEmpty {
                    for failure in batchResult.failures {
                        OperationCenter.shared.log(
                            id: opID, level: .warning,
                            message: "Failed: \(failure.inputURL.lastPathComponent) - \(failure.error)"
                        )
                    }
                }
            } else if let sourceBundleURL = sourceBundleURLs.first {
                let derivedURL = try await FASTQDerivativeService.shared.createDerivative(
                    from: sourceBundleURL,
                    request: request,
                    progress: { [weak self] message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.viewerController.updateFASTQOperationStatus(message)
                                _ = OperationCenter.shared.update(id: opID, progress: -1, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )
                derivedURLs = [derivedURL]
                failureCount = 0
            } else {
                derivedURLs = []
                failureCount = 0
            }

            if derivedURLs.isEmpty && sourceBundleURLs.count > 1 && failureCount > 0 {
                throw FASTQDerivativeError.emptyResult
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let doneDetail: String
            if failureCount > 0 {
                doneDetail = "Done (\(derivedURLs.count) produced, \(failureCount) failed) in \(String(format: "%.1f", elapsed))s"
            } else {
                doneDetail = "Done in \(String(format: "%.1f", elapsed))s"
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    OperationCenter.shared.log(
                        id: opID, level: .info,
                        message: "Completed in \(String(format: "%.1f", elapsed))s"
                    )
                    _ = OperationCenter.shared.complete(id: opID, detail: doneDetail)
                    if let last = derivedURLs.last {
                        self.refreshSidebarAndSelectDerivedURL(last)
                    } else {
                        self.sidebarController.requestReloadFromFilesystem()
                    }
                    self.requestInspectorDocumentModeAfterDownload()
                }
            }
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.log(
                        id: opID, level: .info,
                        message: "Cancelled after \(String(format: "%.1f", elapsed))s"
                    )
                    _ = OperationCenter.shared.fail(
                        id: opID,
                        detail: "Cancelled by user"
                    )
                }
            }
            throw CancellationError()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let errorDesc = error.localizedDescription
            let errorDetail: String
            if let derivativeError = error as? FASTQDerivativeError {
                errorDetail = derivativeError.errorDescription ?? "\(error)"
            } else {
                errorDetail = "\(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.log(
                        id: opID, level: .error,
                        message: "Failed after \(String(format: "%.1f", elapsed))s: \(errorDesc)"
                    )
                    _ = OperationCenter.shared.fail(
                        id: opID,
                        detail: "Failed after \(String(format: "%.1f", elapsed))s",
                        errorMessage: errorDesc,
                        errorDetail: errorDetail
                    )
                }
            }
            throw error
        }
    }

    func runFASTQOperationLaunchRequest(
        _ request: FASTQOperationLaunchRequest,
        preferredOutputDirectory: URL? = nil
    ) {
        if case .assemble(let assemblyRequest, _) = request {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let warning = await AssemblyRuntimePreflight.warningMessage(for: assemblyRequest) {
                    AssemblyRuntimePreflight.presentWarning(
                        message: warning,
                        for: assemblyRequest.tool,
                        on: self.view.window ?? NSApp.keyWindow
                    )
                    return
                }
                self.runFASTQOperationLaunchRequestValidated(
                    request,
                    preferredOutputDirectory: preferredOutputDirectory
                )
            }
            return
        }

        runFASTQOperationLaunchRequestValidated(request, preferredOutputDirectory: preferredOutputDirectory)
    }

    /// - Returns: the `OperationCenter` operation ID this call registered
    ///   for the SINGLE request it actually dispatched, or `nil` when this
    ///   call only fanned out into further recursive calls (`.savont`/
    ///   `.assemble` batch splits) or returned early before registering any
    ///   operation (a write-guard rejection or destination-directory
    ///   creation failure). `@discardableResult` because every pre-existing
    ///   call site (the two in `runFASTQOperationLaunchRequest`, and the
    ///   `.savont` fan-out's own recursive call, which stays intentionally
    ///   unserialized -- see the `.assemble` fan-out's comment below for why)
    ///   ignores it; only the new sequential `.assemble` fan-out driver reads
    ///   it, to poll the just-started child's terminal state before
    ///   dispatching the next one.
    ///
    /// - Parameter precomputedAssemblyBatchSampleDirectory: BG4
    ///   (batch-results-grouping spec §3). When non-nil, this call is one
    ///   child of an `.assemble` batch fan-out and this URL is its own
    ///   already-created sample directory under one shared
    ///   `Analyses/<tool>-batch-<timestamp>/` root (precomputed by
    ///   `independentAssembleLaunchRequests`, in original-bundle-list order,
    ///   BEFORE any child was dispatched). A non-nil value here WINS over
    ///   the per-child `createAnalysisDirectory` fallback used for single
    ///   runs -- see the `.assemble` branch below. Deliberately a SEPARATE
    ///   parameter from `preferredOutputDirectory` (which single, non-batch
    ///   `.assemble` runs already receive non-nil, pointing at the parent
    ///   `Analyses/` folder rather than a final per-run directory): reusing
    ///   that parameter for this purpose would have made every
    ///   dialog-launched single assembly run skip `createAnalysisDirectory`
    ///   too and write straight into `Analyses/`, which is NOT this
    ///   change's intent.
    @discardableResult
    func runFASTQOperationLaunchRequestValidated(
        _ request: FASTQOperationLaunchRequest,
        preferredOutputDirectory: URL? = nil,
        precomputedAssemblyBatchSampleDirectory: URL? = nil
    ) -> UUID? {
        let currentProjectURL = sidebarController.currentProjectURL?.standardizedFileURL
        let destinationRoot = preferredOutputDirectory?.standardizedFileURL
            ?? currentProjectURL?.appendingPathComponent("Analyses", isDirectory: true)
            ?? request.primaryInputURL?.deletingLastPathComponent().standardizedFileURL
            ?? FileManager.default.temporaryDirectory

        if outputDirectoryWritesIntoCurrentProject(destinationRoot) {
            guard canWriteProjectOutputs(workflowName: request.operationDisplayTitle) else { return nil }
        }

        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            mainSplitLogger.error("runFASTQOperationLaunchRequest: Failed to create destination root: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if case .savont(let batchRequest) = request,
           batchRequest.inputURLs.count > 1 {
            let independentRequests = request.independentSavontLaunchRequests(
                outputDirectory: destinationRoot
            )
            guard independentRequests.count == batchRequest.inputURLs.count else {
                mainSplitLogger.error(
                    "runFASTQOperationLaunchRequest: Failed to prepare independent Savont operations"
                )
                return nil
            }
            // Intentionally CONCURRENT (unlike the .assemble fan-out below):
            // Savont clustering is a lightweight per-sample operation with a
            // modest, fixed resource footprint, so N simultaneous Savont
            // clusterings is an accepted resource profile -- unlike N
            // simultaneous SPAdes/MEGAHIT assemblers, each of which can be
            // configured with wizard-level threads/memoryGB approaching the
            // whole machine's budget on its own.
            for independentRequest in independentRequests {
                runFASTQOperationLaunchRequestValidated(
                    independentRequest,
                    preferredOutputDirectory: destinationRoot
                )
            }
            return nil
        }

        // Per-bundle short-read assembly (MB-2): a pooled `.assemble`
        // request selected via the wizard's `.perBundle` picker mode
        // (outputMode == .perInput) with N>1 bundle URLs is split into N
        // independent requests here. Each recursive call below still gets
        // its OWN analysis directory, its OWN OperationCenter operation, and
        // its OWN Task.detached (unchanged from review round 1, point 4:
        // one bundle's failure still never aborts or discards another
        // bundle's completed work). `.combined` mode has no picker option
        // this round (see AssemblyWizardSheet.multiBundleRunPolicy) and
        // stays a single pooled request that falls through to the unsplit
        // path below.
        //
        // UNLIKE the `.savont` fan-out immediately above, this dispatch is
        // SEQUENTIAL (review round 2, Important finding): a full de novo
        // assembler run is a heavyweight, long-running, resource-hungry
        // operation whose thread/memory budget is set at the WHOLE-request
        // level by the wizard (potentially most of the machine's cores/RAM
        // for a single run) -- N of those running simultaneously is a much
        // worse resource profile than N lightweight Savont clusterings, and
        // was exactly the concurrency problem the C2/MB-1 mapping fix (F5)
        // rejected for the analogous N-simultaneous-mappers case. Each
        // child is still dispatched through the SAME single-op path below
        // (own opID, own analysis directory, own Task.detached, so its
        // success/failure/progress is independently tracked and one
        // bundle's failure cannot abort or discard another's completed
        // work) -- only the DISPATCH of child k+1 is gated on child k's
        // operation reaching a terminal state, via `awaitOperationTerminal`
        // polling `OperationCenter.shared.items`.
        if case .assemble(let batchAssemblyRequest, let assembleOutputMode) = request,
           assembleOutputMode == .perInput,
           batchAssemblyRequest.inputURLs.count > 1 {
            // BG4 (spec §3): precomputes ONE shared batch directory plus one
            // sample directory per bundle, in `batchAssemblyRequest
            // .inputURLs` order, BEFORE any child below is dispatched --
            // each returned request's own `AssemblyRunRequest
            // .outputDirectory` already carries its sample directory
            // (`nil` `currentProjectURL` or directory-creation failure falls
            // back to leaving it unset, exactly the pre-BG4 behavior).
            let independentRequests = request.independentAssembleLaunchRequests(
                outputDirectory: destinationRoot,
                projectURL: currentProjectURL
            )
            guard independentRequests.count == batchAssemblyRequest.inputURLs.count else {
                mainSplitLogger.error(
                    "runFASTQOperationLaunchRequest: Failed to prepare independent Assembly operations"
                )
                return nil
            }
            // Every child's precomputed sample directory (if any) is its own
            // `AssemblyRunRequest.outputDirectory`, set by
            // `independentAssembleLaunchRequests` above. Read up front
            // (rather than only inside the loop) so the shared batch
            // directory -- each sample directory's parent -- is known for
            // the empty-batch cleanup after the loop, regardless of how far
            // the loop gets before a cancellation.
            let precomputedSampleDirectories: [URL?] = independentRequests.map { independentRequest in
                guard case .assemble(let childAssemblyRequest, _) = independentRequest else { return nil }
                return childAssemblyRequest.outputDirectory
            }
            let batchDirectory = precomputedSampleDirectories.first.flatMap { $0 }?.deletingLastPathComponent()
            Task { @MainActor [weak self] in
                for (independentRequest, precomputedSampleDirectory) in zip(independentRequests, precomputedSampleDirectories) {
                    // `break`, NOT `return` (BG4 review fix): `return` here
                    // would exit this whole `Task` closure, jumping PAST the
                    // post-loop empty-batch cleanup below -- if the
                    // controller deallocates mid-batch, the batch directory
                    // and its still-empty precomputed sample directories
                    // would be orphaned on disk forever. `break` falls
                    // through to cleanup instead, matching BG3's mapping
                    // fan-out driver (`AppDelegate+ToolsMenu.swift`'s
                    // `runManagedMapping`) exactly. The cleanup call below
                    // does not need `self` -- it only touches the captured
                    // `batchDirectory` value and the static
                    // `AnalysesFolder` helper -- so it still runs correctly
                    // even after `self` is gone.
                    guard let self else { break }
                    // Threaded through as a DEDICATED parameter, never as
                    // `preferredOutputDirectory` (see that parameter's doc
                    // comment above for why conflating the two would break
                    // single-run behavior).
                    if let opID = self.runFASTQOperationLaunchRequestValidated(
                        independentRequest,
                        preferredOutputDirectory: destinationRoot,
                        precomputedAssemblyBatchSampleDirectory: precomputedSampleDirectory
                    ) {
                        await self.awaitOperationTerminal(id: opID)
                    }
                }

                // Empty-batch cleanup (spec §6): only after every child has
                // reached a terminal state (the sequential loop above has
                // just finished, whether by completion, cancellation, or the
                // controller deallocating mid-batch). Deliberately does NOT
                // reference `self` -- only the captured `batchDirectory`
                // value and the static `AnalysesFolder` helper -- so cleanup
                // still runs even when the loop above exited via `break`
                // because `self` was already nil.
                // `removeBatchDirectoryIfEffectivelyEmpty` is itself a pure
                // disk-content check -- a no-op when any child left real
                // output behind -- so it is safe to call unconditionally
                // here rather than tracking child success/failure. `nil`
                // when `independentAssembleLaunchRequests` had no project to
                // root a batch directory in (or failed to create one): there
                // is then no shared batch directory to clean up, exactly the
                // pre-BG4 behavior.
                if let batchDirectory {
                    AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)
                }
            }
            return nil
        }

        let workingDirectory: URL
        if case .assemble = request,
           let precomputedAssemblyBatchSampleDirectory {
            // BG4 (spec §3): a non-nil precomputed batch sample directory
            // WINS over the `createAnalysisDirectory` fallback below -- it
            // was already created by `independentAssembleLaunchRequests`
            // under one shared `Analyses/<tool>-batch-<timestamp>/` root, so
            // reusing it verbatim is what groups all of a batch's children
            // together instead of each child creating its own sibling
            // single-run directory. The pattern match (without binding --
            // the directory is already fully resolved) stays so this branch
            // only ever fires for `.assemble` requests, matching the
            // fallback branch immediately below.
            workingDirectory = precomputedAssemblyBatchSampleDirectory
        } else if case .assemble(let assemblyRequest, _) = request,
           let currentProjectURL {
            do {
                workingDirectory = try AnalysesFolder.createAnalysisDirectory(
                    tool: assemblyRequest.tool.rawValue,
                    in: currentProjectURL
                )
            } catch {
                mainSplitLogger.error("runFASTQOperationLaunchRequest: Failed to create analysis directory: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } else if request.outputMode == .groupedResult || request.isDemultiplexRequest {
            workingDirectory = uniqueFASTQOperationOutputDirectory(
                in: destinationRoot,
                request: request
            )
        } else {
            workingDirectory = destinationRoot
        }

        let executionService = FASTQOperationExecutionService(
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destinationRoot)
        )
        let cliCommand: String? = try? {
            let invocation = try executionService.buildInvocation(for: request)
            return OperationCenter.buildCLICommand(
                subcommand: invocation.subcommand,
                args: invocation.arguments
            )
        }()

        let inputDisplayName = request.independentOperationInputDisplayName
        let attributedDisplayTitle = inputDisplayName.map {
            "\(request.operationDisplayTitle) — \($0)"
        } ?? request.operationDisplayTitle
        let opTitle = "FASTQ: \(attributedDisplayTitle)"
        let startTime = Date()
        let opID: UUID = OperationCenter.shared.start(
            title: opTitle,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCommand,
            routeContext: operationRouteContext
        )
        OperationCenter.shared.log(id: opID, level: .info, message: "Starting \(attributedDisplayTitle)")

        viewerController.updateFASTQOperationStatus("Running FASTQ/FASTA operation...")

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result: FASTQOperationExecutionResult
                if AppUITestConfiguration.current.isEnabled,
                   AppUITestConfiguration.current.backendMode == .deterministic,
                   case .assemble(let assemblyRequest, let outputMode) = request {
                    let uiTestRequest = assemblyRequest.replacingOutputDirectory(with: workingDirectory)
                    try AppUITestAssemblyBackend.writeResult(for: uiTestRequest)
                    result = FASTQOperationExecutionResult(
                        resolvedRequest: .assemble(request: uiTestRequest, outputMode: outputMode),
                        executedInvocations: [],
                        importedURLs: [workingDirectory],
                        groupedContainerURL: outputMode == .groupedResult ? workingDirectory : nil
                    )
                } else {
                    result = try await executionService.execute(
                        request: request,
                        workingDirectory: workingDirectory,
                        progress: { [weak self] fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    self?.viewerController.updateFASTQOperationStatus(message)
                                    _ = OperationCenter.shared.updateWithLog(
                                        id: opID,
                                        progress: fraction,
                                        detail: message
                                    )
                                }
                            }
                        }
                    )
                }
                let elapsed = Date().timeIntervalSince(startTime)
                let completionTarget = result.groupedContainerURL ?? result.importedURLs.last

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "Completed in \(String(format: "%.1f", elapsed))s"
                        )
                        let completionDetail = "Done in \(String(format: "%.1f", elapsed))s"
                        if case .savont = result.resolvedRequest {
                            _ = OperationCenter.shared.complete(
                                id: opID,
                                detail: completionDetail,
                                outputURLs: result.importedURLs
                            )
                        } else {
                            _ = OperationCenter.shared.complete(
                                id: opID,
                                detail: completionDetail
                            )
                        }
                        if let completionTarget {
                            self.recordUITestEvent(
                                "fastq.operation.completed target=\(completionTarget.lastPathComponent)"
                            )
                            self.refreshSidebarAndSelectDerivedURL(completionTarget)
                            switch result.resolvedRequest {
                            case .assemble:
                                self.displayAssemblyAnalysisFromSidebar(at: completionTarget)
                            case .map:
                                self.displayMappingAnalysisFromSidebar(at: completionTarget)
                            default:
                                break
                            }
                        } else {
                            self.sidebarController.requestReloadFromFilesystem()
                        }
                        self.requestInspectorDocumentModeAfterDownload()
                    }
                }
            } catch is CancellationError {
                let elapsed = Date().timeIntervalSince(startTime)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "Cancelled after \(String(format: "%.1f", elapsed))s"
                        )
                        _ = OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
                    }
                }
            } catch {
                let elapsed = Date().timeIntervalSince(startTime)
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .error,
                            message: "Failed after \(String(format: "%.1f", elapsed))s: \(errorDesc)"
                        )
                        _ = OperationCenter.shared.fail(
                            id: opID,
                            detail: "Failed after \(String(format: "%.1f", elapsed))s",
                            errorMessage: errorDesc,
                            errorDetail: "\(error)"
                        )
                    }
                }
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        return opID
    }

    /// Polls `center.items` until the item with `id` reaches a terminal
    /// (`!isActive`) state, or is no longer present at all (a finished item
    /// can be trimmed out of the list by `OperationCenter`'s retention
    /// limit; its absence is treated as terminal, since only
    /// already-finished items are ever trimmed). Used exclusively to
    /// serialize the `.assemble` per-bundle fan-out (review round 2):
    /// dispatching child k+1 only after child k's own operation has
    /// completed, cancelled, or failed, while still letting each child run
    /// through its own independent `Task.detached` (so its failure is
    /// isolated and does not abort the remaining children).
    ///
    /// `center` defaults to `OperationCenter.shared` for production call
    /// sites; tests inject an isolated `OperationCenter()` instance
    /// (matching this file's/`OperationRoutingTests`' existing pattern for
    /// every other `OperationCenter`-touching behavioral test) so they can
    /// drive `start`/`complete`/`fail` deterministically without touching
    /// global state shared with other tests.
    ///
    /// Polling (rather than a Combine subscription on `center.changes`) is
    /// deliberate: this gates between multi-minute assembler runs, not
    /// fine-grained realtime UI updates, so a short fixed poll interval
    /// adds negligible latency while avoiding any
    /// subscription-lifetime/cancellable-management complexity for a
    /// one-shot "wait until terminal" check.
    func awaitOperationTerminal(
        id: UUID,
        center: OperationCenter = .shared,
        pollInterval: Duration = .milliseconds(200)
    ) async {
        while true {
            guard let item = center.items.first(where: { $0.id == id }) else {
                return
            }
            if !item.state.isActive {
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    func outputDirectoryWritesIntoCurrentProject(_ outputDirectory: URL) -> Bool {
        guard let currentProjectURL = sidebarController.currentProjectURL?.standardizedFileURL else {
            return false
        }
        let projectPath = currentProjectURL.resolvingSymlinksInPath().path
        let outputPath = outputDirectory.resolvingSymlinksInPath().path
        return outputPath == projectPath || outputPath.hasPrefix(projectPath + "/")
    }

    func selectedFASTQOperationSources(fallback sourceURL: URL) -> [URL] {
        let selected = sidebarController.selectedItems().compactMap { item -> URL? in
            guard let url = item.url?.standardizedFileURL else { return nil }
            if FASTQBundle.isBundleURL(url) { return url }
            if FASTQBundle.resolvePrimaryFASTQURL(for: url) != nil { return url }
            return nil
        }
        if selected.isEmpty {
            return [sourceURL.standardizedFileURL]
        }

        var deduped: [URL] = []
        var seen: Set<String> = []
        for url in selected {
            let key = url.path
            guard seen.insert(key).inserted else { continue }
            deduped.append(url)
        }
        return deduped
    }

    func resolveFASTQOperationSourceBundle(from url: URL) throws -> URL {
        let standardizedSourceURL = url.standardizedFileURL
        if FASTQBundle.isBundleURL(standardizedSourceURL) {
            return standardizedSourceURL
        }
        if standardizedSourceURL.deletingLastPathComponent().pathExtension.lowercased() == FASTQBundle.directoryExtension {
            return standardizedSourceURL.deletingLastPathComponent()
        }
        throw FASTQDerivativeError.sourceMustBeBundle
    }

    func sharedFASTQOperationParentDirectory(for bundleURLs: [URL]) -> URL? {
        guard let firstParent = bundleURLs.first?.deletingLastPathComponent().standardizedFileURL else {
            return nil
        }
        let allShareParent = bundleURLs.dropFirst().allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == firstParent
        }
        return allShareParent ? firstParent : nil
    }

    func uniqueFASTQOperationOutputDirectory(
        in parentDirectory: URL,
        request: FASTQOperationLaunchRequest,
        preferredFolderName: String? = nil
    ) -> URL {
        let stem: String
        if let preferredFolderName,
           !preferredFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stem = FASTQDemultiplexOutputFolderName.sanitize(preferredFolderName)
        } else {
            let baseName = request.operationDisplayTitle
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            stem = baseName.isEmpty ? "fastq-operation" : baseName
        }

        var candidate = parentDirectory.appendingPathComponent(stem, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parentDirectory.appendingPathComponent("\(stem)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    func refreshSidebarAndSelectDerivedURL(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let containingDirectory = standardizedURL.deletingLastPathComponent()
        let currentProject = sidebarController.currentProjectURL?.standardizedFileURL

        let targetRoot: URL
        if let currentProject, isURL(standardizedURL, inside: currentProject) {
            targetRoot = currentProject
        } else if let activeProject = DocumentManager.shared.activeProject?.url.standardizedFileURL,
                  isURL(standardizedURL, inside: activeProject) {
            targetRoot = activeProject
        } else {
            targetRoot = containingDirectory
        }

        mainSplitLogger.info("refreshSidebarAndSelectDerivedURL: derived='\(standardizedURL.path, privacy: .public)' targetRoot='\(targetRoot.path, privacy: .public)'")
        if currentProject != targetRoot {
            mainSplitLogger.info("refreshSidebarAndSelectDerivedURL: Rebasing sidebar project root to '\(targetRoot.path, privacy: .public)'")
            sidebarController.openProject(at: targetRoot)
        } else {
            sidebarController.reloadFromFilesystem()
        }

        let selected = sidebarController.selectItem(forURL: standardizedURL)
        if !selected {
            mainSplitLogger.warning("refreshSidebarAndSelectDerivedURL: Could not select derived output '\(standardizedURL.path, privacy: .public)' after reload")
            recordUITestEvent("sidebar.selection.failed \(standardizedURL.lastPathComponent)")
            return
        }
        recordUITestEvent("sidebar.selection.succeeded \(standardizedURL.lastPathComponent)")

        // Programmatic post-run selections happen while the FASTQ viewport still owns
        // focus, so the normal sidebar selection callback can be intentionally ignored.
        if hasActiveSidebarChildViewport,
           let selectedItem = sidebarController.selectedItems().first,
           selectedItem.url?.standardizedFileURL == standardizedURL {
            displayContent(for: selectedItem)
        }
    }

    /// Returns true when `url` is inside `directory` using resolved paths.
    func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }

    func requestInspectorDocumentModeAfterDownload() {
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.inspectorTab: "document",
                NotificationUserInfoKey.windowStateScope: windowStateScope
            ]
        )
    }

    func displayImportedProjectFile(at url: URL) {
        refreshSidebarAndSelectDerivedURL(url)
        guard let selectedItem = sidebarController.selectedItems().first,
              selectedItem.url?.standardizedFileURL == url.standardizedFileURL else {
            return
        }
        displayContent(for: selectedItem)
    }

    /// Loads a genomics file in the background using structured concurrency.
    func loadGenomicsFileInBackground(url: URL) {
        mainSplitLogger.info("loadGenomicsFileInBackground: Loading '\(url.lastPathComponent, privacy: .public)'")

        // Guard that controllers are available
        guard let viewerController = self.viewerController,
              let sidebarController = self.sidebarController else {
            mainSplitLogger.warning("loadGenomicsFileInBackground: Controllers not available")
            return
        }

        // Capture the current selection generation so we can discard stale results
        let generation = self.selectionGeneration

        viewerController.showProgress("Loading \(url.lastPathComponent)...")

        // Use detached task for background loading without inheriting actor context.
        // UI callbacks use GCD main queue + MainActor.assumeIsolated (not await MainActor.run)
        // because the cooperative executor doesn't reliably schedule from Task.detached.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)

                // Update UI via GCD main queue (guaranteed to drain)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        // Check generation counter — if the user has selected something else
                        // while we were loading, discard this result
                        guard let self = self, self.selectionGeneration == generation else {
                            mainSplitLogger.info("loadGenomicsFileInBackground: Discarding stale result for '\(url.lastPathComponent, privacy: .public)' (generation moved on)")
                            viewerController.hideProgress()
                            return
                        }
                        viewerController.hideProgress()
                        viewerController.displayDocument(document)
                        self.projectSession.setActiveDocument(document)
                        sidebarController.refreshItem(for: url)
                        mainSplitLogger.info("loadGenomicsFileInBackground: Loaded and displayed")
                    }
                }
            } catch {
                let errorMessage = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, self.selectionGeneration == generation else {
                            viewerController.hideProgress()
                            return
                        }
                        viewerController.hideProgress()
                        mainSplitLogger.error("loadGenomicsFileInBackground: Failed - \(errorMessage)")

                        let alert = NSAlert()
                        alert.messageText = "Failed to Open File"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window ?? NSApp.keyWindow {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }
}
