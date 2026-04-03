// ViewerViewController+EsViritu.swift - EsViritu result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds EsViritu viral detection result display to ViewerViewController,
// following the same child-VC pattern as displayTaxonomyResult / displayFASTACollection.

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

/// Logger for EsViritu display operations.
private let esVirituLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerEsViritu")


// MARK: - ViewerViewController EsViritu Display Extension

extension ViewerViewController {

    /// Displays the EsViritu viral detection browser in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, taxonomy, QuickLook) and the
    /// normal viewer components, then adds ``EsVirituResultViewController`` as a child
    /// view controller filling the content area.
    ///
    /// Wires callbacks for BLAST verification, read extraction, and re-run.
    ///
    /// Follows the exact same child-VC pattern as ``displayTaxonomyResult(_:)``.
    ///
    /// - Parameters:
    ///   - result: The parsed EsViritu result to display.
    ///   - config: The config used for this run (optional, for provenance/re-run).
    public func displayEsVirituResult(_ result: LungfishIO.EsVirituResult, config: EsVirituConfig? = nil) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        contentMode = .metagenomics

        let controller = EsVirituResultViewController()
        addChild(controller)

        // Hide annotation drawer and FASTQ metadata drawer
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let esView = controller.view
        esView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(esView)

        NSLayoutConstraint.activate([
            esView.topAnchor.constraint(equalTo: view.topAnchor),
            esView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            esView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            esView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result, config: config)

        // Wire BLAST verification callback.
        //
        // Preferred path: extract unique mapped reads from the EsViritu BAM for
        // the selected accessions, subsample to the user-selected count, then
        // submit through our native BlastService pipeline.
        //
        // Fallback 1: submit consensus sequence from final_consensus.fasta.
        // If neither read nor consensus data is available, fail in-app.
        let capturedConfig = config
        controller.onBlastVerification = { [weak controller] detection, readCount, accessions, bamURL, bamIndexURL in
            let selectedReadCount = min(50, max(1, readCount))
            esVirituLogger.info("BLAST verification requested for \(detection.name, privacy: .public) (\(detection.accession, privacy: .public)), readCount=\(selectedReadCount, privacy: .public), accessions=\(accessions.count, privacy: .public)")

            let esBlastCliCmd = "# lungfish blast verify --accession \(detection.accession) (CLI command not yet available \u{2014} use GUI)"
            let opID = OperationCenter.shared.start(
                title: "BLAST \(detection.name)",
                detail: "Extracting unique reads\u{2026}",
                operationType: .blastVerification,
                cliCommand: esBlastCliCmd
            )

            let virusName = detection.name
            let accession = detection.accession
            let consensusURL = capturedConfig?.outputDirectory
                .appendingPathComponent("\(capturedConfig?.sampleName ?? "sample")_final_consensus.fasta")
            let blastController = controller

            let task = Task.detached {
                do {
                    let blastService = BlastService.shared
                    var request: BlastVerificationRequest?

                    // Preferred path: unique mapped reads from BAM for selected accessions.
                    if let bamURL, let bamIndexURL, !accessions.isEmpty {
                        let provider = AlignmentDataProvider(
                            alignmentPath: bamURL.path,
                            indexPath: bamIndexURL.path
                        )

                        var readMap: [String: String] = [:]  // readName -> sequence
                        for targetAccession in accessions {
                            if Task.isCancelled { break }
                            let reads = (try? await provider.fetchReads(
                                chromosome: targetAccession,
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
                            let longestCount = min(5, selectedReadCount / 4)
                            let strategy = SubsampleStrategy.mixed(
                                longest: longestCount,
                                random: selectedReadCount - longestCount
                            )
                            let subsampled = blastService.subsampleReads(
                                from: allReads,
                                strategy: strategy
                            )

                            esVirituLogger.info("BAM extraction: \(readMap.count, privacy: .public) unique reads, subsampled to \(subsampled.count, privacy: .public)")
                            request = BlastVerificationRequest(
                                taxonName: virusName,
                                taxId: 0,
                                sequences: subsampled,
                                database: "core_nt",
                                maxTargetSeqs: 5
                            )
                        }
                    }

                    // Fallback 1: consensus sequence from EsViritu output.
                    if request == nil,
                       let consensusURL,
                       let consensusData = try? String(contentsOf: consensusURL, encoding: .utf8) {
                        let lines = consensusData.components(separatedBy: .newlines)
                        var capturing = false
                        var seqLines: [String] = []
                        for line in lines {
                            if line.hasPrefix(">") {
                                if capturing { break }
                                if line.contains(accession) {
                                    capturing = true
                                }
                            } else if capturing {
                                seqLines.append(line)
                            }
                        }

                        let consensusSequence = seqLines.joined()
                        if consensusSequence.count >= 50 {
                            esVirituLogger.info("Falling back to consensus-sequence BLAST query for \(accession, privacy: .public)")
                            request = BlastVerificationRequest(
                                taxonName: virusName,
                                taxId: 0,
                                sequences: [(id: accession, sequence: consensusSequence)],
                                database: "core_nt",
                                maxTargetSeqs: 5
                            )
                        }
                    }

                    // Fail in-app if we cannot build a query.
                    guard let request, !request.sequences.isEmpty else {
                        throw BlastServiceError.noSequences
                    }

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
                                        id: opID, progress: fraction, detail: message
                                    )
                                    let lower = message.lowercased()
                                    if lower.contains("waiting") {
                                        blastController?.showBlastLoading(phase: .waiting, requestId: nil)
                                    } else if lower.contains("parsing") {
                                        blastController?.showBlastLoading(phase: .parsing, requestId: nil)
                                    } else {
                                        blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                                    }
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
                            // Auto-show BLAST results in the EsViritu result VC
                            blastController?.showBlastResults(blastResult)
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(id: opID, detail: errorDesc)
                            blastController?.showBlastFailure(errorDesc)
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        }

        // Wire read extraction callback
        controller.onExtractReads = { detection in
            esVirituLogger.info("Read extraction requested for \(detection.name, privacy: .public) (\(detection.accession, privacy: .public), \(detection.readCount) reads)")
            // TODO: Wire to extraction pipeline when available
        }

        // Wire assembly read extraction callback
        controller.onExtractAssemblyReads = { assembly in
            esVirituLogger.info("Assembly read extraction requested for \(assembly.name, privacy: .public) (\(assembly.assembly, privacy: .public), \(assembly.totalReads) reads)")
            // TODO: Wire to extraction pipeline when available
        }

        // Wire re-run callback
        controller.onReRun = { [weak self] in
            guard let self, let window = self.view.window else { return }
            esVirituLogger.info("Re-run requested")

            // Present the wizard sheet with the original input files
            let inputFiles = config?.inputFiles ?? []
            guard !inputFiles.isEmpty else {
                esVirituLogger.warning("Cannot re-run: no input files in config")
                return
            }

            let wizardSheet = EsVirituWizardSheet(
                inputFiles: inputFiles,
                onRun: { [weak window] newConfigs in
                    guard let window else { return }
                    if let sheetWindow = window.attachedSheet {
                        window.endSheet(sheetWindow)
                    }
                    if let first = newConfigs.first {
                        esVirituLogger.info("Re-run with new config: \(first.sampleName, privacy: .public)")
                    }
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
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            sheetWindow.contentViewController = NSHostingController(rootView: wizardSheet)
            window.beginSheet(sheetWindow)
        }

        esVirituViewController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        esVirituLogger.info("displayEsVirituResult: Showing browser with \(result.detections.count) detections, \(result.assemblies.count) assemblies")
    }

    /// Removes the EsViritu result browser and restores normal viewer components.
    public func hideEsVirituView() {
        guard let controller = esVirituViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        esVirituViewController = nil

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
