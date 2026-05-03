// ViewerViewController+Nvd.swift - NVD result display extension
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

private let nvdDisplayLogger = Logger(subsystem: "com.lungfish", category: "NvdDisplay")

// MARK: - ViewerViewController NVD Display Extension

extension ViewerViewController {
    private nonisolated static func suggestedName(from fastaRecords: [String], fallback: String) -> String {
        if let firstHeader = fastaRecords.first?
            .split(whereSeparator: \.isNewline)
            .first?
            .dropFirst()
            .split(separator: " ")
            .first {
            return String(firstHeader)
        }
        return fallback
    }

    /// Displays the NVD result viewer in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook, other
    /// metagenomics viewers) and adds the pre-configured
    /// `NvdResultViewController` as a child view controller filling the
    /// content area.
    ///
    /// Follows the exact same child-VC pattern as ``displayNaoMgsResult(_:)``.
    ///
    /// - Parameter controller: A pre-configured `NvdResultViewController`.
    public func displayNvdResult(_ controller: NvdResultViewController) {
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
        hideAlignmentTreeBundleViews()
        contentMode = .metagenomics

        addChild(controller)

        // Wire BLAST verification callback.
        // NVD submits a single contig sequence rather than multiple reads.
        controller.onBlastVerification = { [weak controller] hit, sequence in
            let contigName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
            // Use the classification name for concordance checking, not the contig name
            let classificationName = hit.adjustedTaxidName.isEmpty ? contigName : hit.adjustedTaxidName
            let taxIdInt = Int(hit.adjustedTaxid) ?? 0
            nvdDisplayLogger.info(
                "BLAST verification requested for \(contigName, privacy: .public) (\(classificationName, privacy: .public)), taxId=\(taxIdInt, privacy: .public)"
            )

            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: ["--taxid", "\(taxIdInt)"]
            )
            let opID = OperationCenter.shared.start(
                title: "BLAST \(contigName) \u{2014} \(classificationName)",
                detail: "Preparing BLAST verification\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

            let blastController = controller
            let task = Task.detached {
                do {
                    let blastService = BlastService.shared

                    let trimmedSequence = sequence.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedSequence.isEmpty else {
                        throw BlastServiceError.noSequences
                    }

                    let sequences: [(id: String, sequence: String)] = [(id: hit.qseqid, sequence: trimmedSequence)]

                    let request = BlastVerificationRequest(
                        taxonName: classificationName,
                        taxId: taxIdInt,
                        sequences: sequences,
                        database: "core_nt",
                        entrezQuery: nil  // No entrez filter for NVD
                    )

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.1,
                                detail: "Submitting contig to NCBI BLAST\u{2026}"
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
        controller.onRunOperationRequested = { [weak self] fastaRecords in
            self?.presentFASTAOperationDialog(
                records: fastaRecords,
                suggestedName: Self.suggestedName(from: fastaRecords, fallback: "nvd-contig")
            )
        }
        controller.onExtractSequenceRequested = { [weak self] fastaRecords, suggestedName in
            self?.presentFASTASequenceExtractionDialog(records: fastaRecords, suggestedName: suggestedName)
        }
        controller.onExportFASTARequested = { [weak self] fastaRecords in
            self?.exportFASTARecords(
                fastaRecords,
                suggestedName: "\(Self.suggestedName(from: fastaRecords, fallback: "nvd-contig")).fa"
            )
        }
        controller.onCreateBundleRequested = { [weak self] fastaRecords in
            self?.createReferenceBundle(
                from: fastaRecords,
                suggestedName: Self.suggestedName(from: fastaRecords, fallback: "nvd-contig")
            )
        }

        // Hide normal genomic viewer components (same pattern as Taxonomy/EsViritu/TaxTriage/NAO-MGS).
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

    /// Hides the NVD result viewer if one is displayed and restores normal viewer components.
    public func hideNvdView() {
        for child in children where child is NvdResultViewController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        // Restore normal viewer components (only if no other metagenomics viewer is active).
        // hideTaxonomyView / hideEsVirituView / hideTaxTriageView / hideNaoMgsView each restore
        // these too, so this guard prevents double-restore when switching between metagenomics results.
        guard taxonomyViewController == nil,
              esVirituViewController == nil,
              taxTriageViewController == nil,
              !children.contains(where: { $0 is NaoMgsResultViewController }) else { return }

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
