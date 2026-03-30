// ViewerViewController+TaxTriage.swift - TaxTriage result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds TaxTriage clinical triage result display to ViewerViewController,
// following the same child-VC pattern as displayEsVirituResult / displayTaxonomyResult.

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

/// Logger for TaxTriage display operations.
private let taxTriageLogger = Logger(subsystem: "com.lungfish.app", category: "ViewerTaxTriage")


// MARK: - ViewerViewController TaxTriage Display Extension

extension ViewerViewController {

    /// Displays the TaxTriage clinical triage browser in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, taxonomy, EsViritu, QuickLook)
    /// and the normal viewer components, then adds ``TaxTriageResultViewController`` as a
    /// child view controller filling the content area.
    ///
    /// Wires callbacks for BLAST verification and re-run.
    ///
    /// Follows the exact same child-VC pattern as ``displayEsVirituResult(_:config:)``.
    ///
    /// - Parameters:
    ///   - result: The TaxTriage pipeline result to display.
    ///   - config: The config used for this run (optional, for provenance/re-run).
    ///   - sampleId: Optional sample ID to pre-select in the per-sample filter.
    public func displayTaxTriageResult(_ result: TaxTriageResult, config: TaxTriageConfig? = nil, sampleId: String? = nil) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        contentMode = .metagenomics

        let controller = TaxTriageResultViewController()
        controller.preselectedSampleId = sampleId
        addChild(controller)

        // Hide annotation drawer and FASTQ metadata drawer
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let ttView = controller.view
        ttView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ttView)

        NSLayoutConstraint.activate([
            ttView.topAnchor.constraint(equalTo: view.topAnchor),
            ttView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ttView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ttView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result, config: config)

        // Wire BLAST verification callback.
        //
        // Preferred path: extract reads from the TaxTriage merged BAM via
        // AlignmentDataProvider (fast, uses organism→accession mapping already
        // resolved by TaxTriageResultViewController).
        //
        // Fallback 1: Kraken2 classification + source FASTQ extraction.
        // Fallback 2: Open NCBI BLAST web search.
        let capturedConfig = config
        controller.onBlastVerification = { [weak controller] organism, readCount, accessions, bamURL, bamIndexURL in
            let orgName = organism.name
            let taxId = organism.taxId ?? 0
            taxTriageLogger.info("BLAST verification requested for \(orgName, privacy: .public), readCount=\(readCount, privacy: .public), accessions=\(accessions?.count ?? 0, privacy: .public)")

            guard taxId > 0 else {
                // No taxId — fall back to NCBI BLAST web
                let encodedName = orgName
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgName
                if let url = URL(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi?PAGE_TYPE=BlastSearch&QUERY=\(encodedName)") {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            let blastCliCmd = OperationCenter.buildCLICommand(subcommand: "blast verify", args: [
                "--taxid", "\(taxId)",
            ])
            let opID = OperationCenter.shared.start(
                title: "BLAST \(orgName)",
                detail: "Extracting reads\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

            // Capture controller reference for MainActor callbacks within
            // the detached task. nonisolated(unsafe) is needed because a
            // @MainActor type cannot cross isolation boundaries. The controller
            // is only accessed within DispatchQueue.main.async + assumeIsolated.
            nonisolated(unsafe) let blastController = controller

            let task = Task.detached {
                do {
                    let blastService = BlastService.shared
                    var request: BlastVerificationRequest?

                    // --- Path 1: BAM-based extraction (preferred) ---
                    if let bamURL, let bamIndexURL,
                       let accessions, !accessions.isEmpty {
                        taxTriageLogger.info("Using BAM-based read extraction for \(accessions.count, privacy: .public) accession(s)")
                        let provider = AlignmentDataProvider(
                            alignmentPath: bamURL.path,
                            indexPath: bamIndexURL.path
                        )

                        // Fetch reads for all accessions, dedup by read name
                        var readMap: [String: String] = [:]  // readName → sequence
                        for accession in accessions {
                            if Task.isCancelled { break }
                            // Fetch unique mapped reads (exclude unmapped, secondary, supplementary, PCR dups)
                            let reads = (try? await provider.fetchReads(
                                chromosome: accession,
                                start: 0,
                                end: Int.max,
                                excludeFlags: 0xF04,
                                maxReads: 10_000
                            )) ?? []
                            for read in reads where !read.sequence.isEmpty && read.sequence != "*" {
                                if readMap[read.name] == nil {
                                    readMap[read.name] = read.sequence
                                }
                            }
                        }

                        if !readMap.isEmpty {
                            let allReads = readMap.map { (id: $0.key, sequence: $0.value) }
                            let longestCount = min(5, readCount / 4)
                            let strategy = SubsampleStrategy.mixed(
                                longest: longestCount,
                                random: readCount - longestCount
                            )
                            let subsampled = blastService.subsampleReads(
                                from: allReads,
                                strategy: strategy
                            )
                            taxTriageLogger.info("BAM extraction: \(readMap.count, privacy: .public) unique reads, subsampled to \(subsampled.count, privacy: .public)")

                            request = BlastVerificationRequest(
                                taxonName: orgName,
                                taxId: taxId,
                                sequences: subsampled,
                                entrezQuery: "txid\(taxId)[Organism:exp]"
                            )
                        }
                    }

                    // --- Path 2: Kraken2 + FASTQ fallback ---
                    if request == nil,
                       let sourceFile = capturedConfig?.samples.first?.fastq1 {
                        let outputDir = capturedConfig?.outputDirectory
                        let krakenFile = outputDir?
                            .appendingPathComponent("classification")
                            .appendingPathComponent("classification.kraken")

                        if let krakenFile, FileManager.default.fileExists(atPath: krakenFile.path) {
                            taxTriageLogger.info("Falling back to Kraken2 + FASTQ extraction")
                            nonisolated(unsafe) let capturedSource = sourceFile
                            var krakenRequest = try await blastService.buildVerificationRequest(
                                taxonName: orgName,
                                taxId: taxId,
                                targetTaxIds: Set([taxId]),
                                classificationOutputURL: krakenFile,
                                sourceURL: capturedSource,
                                readCount: readCount
                            )
                            // Enrich with entrezQuery for faster NCBI-side search
                            krakenRequest = BlastVerificationRequest(
                                taxonName: krakenRequest.taxonName,
                                taxId: krakenRequest.taxId,
                                sequences: krakenRequest.sequences,
                                entrezQuery: "txid\(taxId)[Organism:exp]"
                            )
                            request = krakenRequest
                        }
                    }

                    // --- Path 3: Web fallback ---
                    guard let request, !request.sequences.isEmpty else {
                        let encodedName = orgName
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgName
                        if let url = URL(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi?PAGE_TYPE=BlastSearch&QUERY=\(encodedName)") {
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    NSWorkspace.shared.open(url)
                                    OperationCenter.shared.complete(
                                        id: opID,
                                        detail: "Opened NCBI BLAST in browser"
                                    )
                                }
                            }
                        }
                        return
                    }

                    // Submit to NCBI BLAST API
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.1,
                                detail: "Submitting \(request.sequences.count) reads to NCBI BLAST\u{2026}"
                            )
                            blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                        }
                    }

                    let blastResult = try await blastService.verify(
                        request: request,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: fraction,
                                        detail: message
                                    )
                                }
                            }
                        }
                    )

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "\(blastResult.verifiedCount)/\(blastResult.readResults.count) verified"
                            )
                            blastController?.showBlastResults(blastResult)
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(id: opID, detail: errorDesc)
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        }

        // Wire re-run callback
        controller.onReRun = { [weak self] in
            guard let self, let window = self.view.window else { return }
            taxTriageLogger.info("Re-run requested")

            let initialFiles = config?.samples.flatMap { $0.allFiles } ?? []
            guard !initialFiles.isEmpty else {
                taxTriageLogger.warning("Cannot re-run: no input files in config")
                return
            }

            let wizardSheet = TaxTriageWizardSheet(
                initialFiles: initialFiles,
                onRun: { [weak window] newConfig in
                    guard let window else { return }
                    if let sheetWindow = window.attachedSheet {
                        window.endSheet(sheetWindow)
                    }
                    let sampleCount = newConfig.samples.count
                    taxTriageLogger.info("Re-run with \(sampleCount) samples")
                    // TODO: Wire to pipeline execution when available
                },
                onCancel: { [weak window] in
                    guard let window else { return }
                    if let sheetWindow = window.attachedSheet {
                        window.endSheet(sheetWindow)
                    }
                }
            )

            let sheetWindow = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheetWindow.contentViewController = NSHostingController(rootView: wizardSheet)
            window.beginSheet(sheetWindow)
        }

        // Wire related analyses navigation callback
        controller.onRelatedAnalysis = { [weak self] analysisType, url in
            guard let self else { return }
            taxTriageLogger.info("Related analysis navigation: \(analysisType, privacy: .public) at \(url.lastPathComponent, privacy: .public)")
            // Navigate via the main split view controller which knows how to open different result types
            if let mainSplit = self.parent as? MainSplitViewController {
                mainSplit.navigateToRelatedAnalysis(type: analysisType, url: url)
            }
        }

        taxTriageViewController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        let reportCount = result.reportFiles.count
        let metricsCount = result.metricsFiles.count
        taxTriageLogger.info("displayTaxTriageResult: Showing browser with \(reportCount) reports, \(metricsCount) metrics files")
    }

    /// Removes the TaxTriage result browser and restores normal viewer components.
    public func hideTaxTriageView() {
        guard let controller = taxTriageViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        taxTriageViewController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
