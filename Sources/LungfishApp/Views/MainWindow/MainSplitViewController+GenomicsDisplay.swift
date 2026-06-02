// MainSplitViewController.swift - Three-panel split view controller
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

            // Wrap naked file into a bundle in place (no ingestion — it may already be ingested)
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                let destURL = bundleURL.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: destURL)
                // Move sidecar too if it exists
                let sidecarName = url.lastPathComponent + ".lungfish-meta.json"
                let sidecarURL = parentDir.appendingPathComponent(sidecarName)
                if fm.fileExists(atPath: sidecarURL.path) {
                    try fm.moveItem(at: sidecarURL, to: bundleURL.appendingPathComponent(sidecarName))
                }
                mainSplitLogger.info("displayGenomicsFile: Auto-bundled naked FASTQ \(url.lastPathComponent) → \(bundleURL.lastPathComponent)")
                sidebarController.reloadFromFilesystem()
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
                        DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
                    }

                    let genBankVM = GenBankBundleDownloadViewModel()
                    let genBankBundleURL = try await genBankVM.downloadAndBuild(
                        accession: firstAccession,
                        outputDirectory: tempDir
                    ) { progress, message in
                        let scaledProgress = 0.15 + progress * 0.8
                        mainSplitPerformOnMainRunLoop {
                            DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                        }
                    }

                    try Self.mergeGenomeIntoBundle(
                        sourceBundleURL: genBankBundleURL,
                        targetBundleURL: bundleURL
                    )
                } else {
                    mainSplitPerformOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No reference found for '\(assemblyName)'")
                    }
                    return
                }

                mainSplitPerformOnMainRunLoop {
                    DownloadCenter.shared.complete(id: downloadID, detail: "Reference genome added to bundle")
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
                    DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
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
            DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI Assembly for \(assembly)\u{2026}")
        }

        let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
        guard !ids.isEmpty else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly found for '\(searchTerm, privacy: .public)', will try GenBank fallback")
            return nil
        }

        mainSplitPerformOnMainRunLoop {
            DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info\u{2026}")
        }

        let summaries = try await ncbi.assemblyEsummary(ids: ids)
        guard let assemblySummary = summaries.first else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly summary for ids=\(ids, privacy: .public), will try GenBank fallback")
            return nil
        }

        mainSplitPerformOnMainRunLoop {
            DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files\u{2026}")
        }

        let viewModel = GenomeDownloadViewModel()
        let bundleURL = try await viewModel.downloadAndBuild(
            assembly: assemblySummary,
            outputDirectory: outputDirectory
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            mainSplitPerformOnMainRunLoop {
                DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
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
                    DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI for \(assembly)...")
                }

                let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
                guard !ids.isEmpty else {
                    mainSplitPerformOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No assembly found for '\(assembly)'")
                    }
                    return
                }

                // Get assembly summary
                mainSplitPerformOnMainRunLoop {
                    DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info...")
                }

                let summaries = try await ncbi.assemblyEsummary(ids: ids)
                guard let assemblySummary = summaries.first else {
                    mainSplitPerformOnMainRunLoop {
                        DownloadCenter.shared.fail(id: downloadID, detail: "No assembly details found")
                    }
                    return
                }

                // Download and build bundle
                mainSplitPerformOnMainRunLoop {
                    DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files...")
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
                        DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                    }
                }

                mainSplitPerformOnMainRunLoop {
                    DownloadCenter.shared.complete(id: downloadID, detail: "Bundle ready", bundleURLs: [bundleURL])
                }

                mainSplitLogger.info("downloadReferenceForVCF: Bundle built at \(bundleURL.path, privacy: .public)")
            } catch {
                let errorMessage = "\(error)"
                mainSplitPerformOnMainRunLoop {
                    DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
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
        let cachedStatisticsMeta = statisticsCacheURL.flatMap {
            FASTQMetadataStore.load(for: $0)
        } ?? demuxSummaryMeta
        let displayMeta = cachedStatisticsMeta ?? FASTQMetadataStore.load(for: fastqURL) ?? demuxSummaryMeta
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
                                OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
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
                                OperationCenter.shared.update(id: opID, progress: -1, detail: message)
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
                    OperationCenter.shared.complete(id: opID, detail: doneDetail)
                    if let last = derivedURLs.last {
                        self.refreshSidebarAndSelectDerivedURL(last)
                    } else {
                        self.sidebarController.reloadFromFilesystem()
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
                    OperationCenter.shared.fail(
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
                    OperationCenter.shared.fail(
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

    func runFASTQOperationLaunchRequestValidated(
        _ request: FASTQOperationLaunchRequest,
        preferredOutputDirectory: URL? = nil
    ) {
        let currentProjectURL = sidebarController.currentProjectURL?.standardizedFileURL
        let destinationRoot = preferredOutputDirectory?.standardizedFileURL
            ?? currentProjectURL?.appendingPathComponent("Analyses", isDirectory: true)
            ?? request.primaryInputURL?.deletingLastPathComponent().standardizedFileURL
            ?? FileManager.default.temporaryDirectory

        if outputDirectoryWritesIntoCurrentProject(destinationRoot) {
            guard canWriteProjectOutputs(workflowName: request.operationDisplayTitle) else { return }
        }

        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            mainSplitLogger.error("runFASTQOperationLaunchRequest: Failed to create destination root: \(error.localizedDescription, privacy: .public)")
            return
        }

        let workingDirectory: URL
        if case .assemble(let assemblyRequest, _) = request,
           let currentProjectURL {
            do {
                workingDirectory = try AnalysesFolder.createAnalysisDirectory(
                    tool: assemblyRequest.tool.rawValue,
                    in: currentProjectURL
                )
            } catch {
                mainSplitLogger.error("runFASTQOperationLaunchRequest: Failed to create analysis directory: \(error.localizedDescription, privacy: .public)")
                return
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
            return ([ "lungfish-cli", invocation.subcommand ] + invocation.arguments).joined(separator: " ")
        }()

        let opTitle = "FASTQ: \(request.operationDisplayTitle)"
        let startTime = Date()
        let opID: UUID = OperationCenter.shared.start(
            title: opTitle,
            detail: "Preparing...",
            operationType: .fastqOperation,
            cliCommand: cliCommand,
            routeContext: operationRouteContext
        )
        OperationCenter.shared.log(id: opID, level: .info, message: "Starting \(request.operationDisplayTitle)")

        viewerController.updateFASTQOperationStatus("Running FASTQ/FASTA operation...")

        Task.detached(priority: .userInitiated) { [weak self] in
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
                        workingDirectory: workingDirectory
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
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "Done in \(String(format: "%.1f", elapsed))s"
                        )
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
                            self.sidebarController.reloadFromFilesystem()
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
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
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
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: "Failed after \(String(format: "%.1f", elapsed))s",
                            errorMessage: errorDesc,
                            errorDetail: "\(error)"
                        )
                    }
                }
            }
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
        request: FASTQOperationLaunchRequest
    ) -> URL {
        let baseName = request.operationDisplayTitle
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = baseName.isEmpty ? "fastq-operation" : baseName

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
