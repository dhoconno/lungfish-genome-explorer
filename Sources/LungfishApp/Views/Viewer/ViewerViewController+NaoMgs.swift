// ViewerViewController+NaoMgs.swift - NAO-MGS result display extension
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let naoMgsDisplayLogger = Logger(subsystem: "com.lungfish", category: "NaoMgsDisplay")

// MARK: - ViewerViewController NAO-MGS Display Extension

extension ViewerViewController {

    /// Displays the NAO-MGS result viewer in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook, other
    /// metagenomics viewers) and adds the pre-configured
    /// `NaoMgsResultViewController` as a child view controller filling the
    /// content area.
    ///
    /// Follows the exact same child-VC pattern as ``displayTaxonomyResult(_:)``.
    ///
    /// - Parameter controller: A pre-configured `NaoMgsResultViewController`.
    public func displayNaoMgsResult(_ controller: NaoMgsResultViewController) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()
        hideMappingView()
        contentMode = .metagenomics

        addChild(controller)

        // Wire BLAST verification callback.
        controller.onBlastVerification = { [weak controller] summary, readCount, reads in
            let selectedReadCount = min(50, max(1, readCount))
            let taxonName = summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name
            naoMgsDisplayLogger.info(
                "BLAST verification requested for \(taxonName, privacy: .public), readCount=\(selectedReadCount, privacy: .public), availableReads=\(reads.count, privacy: .public)"
            )

            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: ["--taxid", "\(summary.taxId)"]
            )
            let opID = OperationCenter.shared.start(
                title: "BLAST \(taxonName)",
                detail: "Preparing BLAST verification\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

            let blastController = controller
            let task = Task.detached {
                do {
                    let blastService = BlastService.shared
                    let allReads = reads.compactMap { hit -> (id: String, sequence: String)? in
                        let sequence = hit.readSequence.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !sequence.isEmpty else { return nil }
                        return (id: hit.seqId, sequence: sequence)
                    }

                    guard !allReads.isEmpty else {
                        throw BlastServiceError.noSequences
                    }

                    let longestCount = min(5, selectedReadCount / 4)
                    let strategy = SubsampleStrategy.mixed(
                        longest: longestCount,
                        random: selectedReadCount - longestCount
                    )
                    let subsampled = blastService.subsampleReads(from: allReads, strategy: strategy)

                    guard !subsampled.isEmpty else {
                        throw BlastServiceError.noSequences
                    }

                    let request = BlastVerificationRequest(
                        taxonName: taxonName,
                        taxId: summary.taxId,
                        sequences: subsampled,
                        database: "core_nt",
                        entrezQuery: "txid\(summary.taxId)[Organism:exp]"
                    )

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

        // Hide normal genomic viewer components (same pattern as Taxonomy/EsViritu/TaxTriage).
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let resultView = controller.view
        resultView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultView)

        NSLayoutConstraint.activate([
            resultView.topAnchor.constraint(equalTo: view.topAnchor),
            resultView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Hides the NAO-MGS result viewer if one is displayed and restores normal viewer components.
    public func hideNaoMgsView() {
        for child in children where child is NaoMgsResultViewController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        // Restore normal viewer components (only if no other metagenomics viewer is active).
        // hideTaxonomyView / hideEsVirituView / hideTaxTriageView each restore these too,
        // so this guard prevents double-restore when switching between metagenomics results.
        guard taxonomyViewController == nil,
              esVirituViewController == nil,
              taxTriageViewController == nil else { return }

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
