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
        // EsViritu identifies viruses by iterative read mapping (not k-mer
        // classification), so we use the consensus FASTA from the EsViritu
        // output directory as the BLAST query. If the consensus is available,
        // we submit it through our native BlastService pipeline; otherwise
        // we open the NCBI BLAST web page with the accession.
        let capturedConfig = config
        controller.onBlastVerification = { [weak controller] detection in
            esVirituLogger.info("BLAST verification requested for \(detection.name, privacy: .public) (\(detection.accession, privacy: .public))")

            // Try to read the consensus FASTA for this detection
            let consensusURL = capturedConfig?.outputDirectory
                .appendingPathComponent("\(capturedConfig?.sampleName ?? "sample")_final_consensus.fasta")

            var consensusSequence: String?
            if let consensusURL,
               let consensusData = try? String(contentsOf: consensusURL, encoding: .utf8) {
                // Find the sequence for this accession in the multi-FASTA
                let lines = consensusData.components(separatedBy: .newlines)
                var capturing = false
                var seqLines: [String] = []
                for line in lines {
                    if line.hasPrefix(">") {
                        if capturing { break }
                        if line.contains(detection.accession) {
                            capturing = true
                        }
                    } else if capturing {
                        seqLines.append(line)
                    }
                }
                if !seqLines.isEmpty {
                    consensusSequence = seqLines.joined()
                }
            }

            if let seq = consensusSequence, seq.count >= 50 {
                // Native BLAST: submit consensus sequence
                let opID = OperationCenter.shared.start(
                    title: "BLAST \(detection.name)",
                    detail: "Submitting consensus to NCBI BLAST\u{2026}",
                    operationType: .blastVerification
                )

                let accession = detection.accession
                let virusName = detection.name
                nonisolated(unsafe) let capturedSeq = seq

                let task = Task {
                    do {
                        let blastService = BlastService.shared
                        let request = BlastVerificationRequest(
                            taxonName: virusName,
                            taxId: 0,
                            sequences: [(id: accession, sequence: capturedSeq)],
                            database: "core_nt",
                            maxTargetSeqs: 5
                        )

                        let blastResult = try await blastService.verify(
                            request: request,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        OperationCenter.shared.update(
                                            id: opID, progress: fraction, detail: message
                                        )
                                    }
                                }
                            }
                        )

                        nonisolated(unsafe) let capturedBlastResult = blastResult
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let controller else { return }
                                OperationCenter.shared.complete(
                                    id: opID,
                                    detail: "\(capturedBlastResult.verifiedCount)/\(capturedBlastResult.readResults.count) verified"
                                )
                                // Auto-show BLAST results in the EsViritu result VC
                                controller.showBlastResults(capturedBlastResult)
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
            } else {
                // No consensus available — open NCBI BLAST web
                let encodedAccession = detection.accession
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? detection.accession
                if let url = URL(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi?PAGE_TYPE=BlastSearch&QUERY=\(encodedAccession)") {
                    NSWorkspace.shared.open(url)
                }
            }
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
