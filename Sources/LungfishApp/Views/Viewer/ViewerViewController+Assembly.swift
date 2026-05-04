// ViewerViewController+Assembly.swift - Assembly result display for ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow
import os.log

private let assemblyDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAssembly")

extension ViewerViewController {
    /// Displays an assembly result viewport in place of the normal sequence viewer.
    public func displayAssemblyResult(_ result: AssemblyResult) {
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
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .assembly

        let controller = AssemblyResultViewController()
        addChild(controller)
        controller.onBlastVerification = { [weak self] request in
            guard let self else { return }
            guard let blastController = self.assemblyResultController else { return }
            blastController.showBlastLoading(phase: .submitting, requestId: nil)
            let blastCliCmd = OperationCenter.buildCLICommand(subcommand: "blast verify", args: [])
            let opID = OperationCenter.shared.start(
                title: "BLAST \(request.sourceLabel)",
                detail: "Preparing contig BLAST…",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

            let task = Task.detached {
                do {
                    let sequences = Self.blastSequences(from: request.sequences)
                    guard !sequences.isEmpty else {
                        throw BlastServiceError.noSequences
                    }

                    let verificationRequest = BlastVerificationRequest(
                        taxonName: request.sourceLabel,
                        taxId: request.taxId ?? 0,
                        sequences: sequences,
                        database: "core_nt",
                        entrezQuery: nil
                    )

                    let result = try await BlastService.shared.verify(
                        request: verificationRequest,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                                    let lower = message.lowercased()
                                    if lower.contains("waiting") {
                                        blastController.showBlastLoading(phase: .waiting, requestId: nil)
                                    } else if lower.contains("parsing") {
                                        blastController.showBlastLoading(phase: .parsing, requestId: nil)
                                    } else {
                                        blastController.showBlastLoading(phase: .submitting, requestId: nil)
                                    }
                                }
                            }
                        }
                    )

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "Results ready for \(request.readCount) contig\(request.readCount == 1 ? "" : "s")"
                            )
                            blastController.showBlastResults(result)
                        }
                    }
                } catch {
                    let errorText = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: errorText,
                                errorMessage: errorText
                            )
                            blastController.showBlastFailure(errorText)
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        }
        controller.onExtractSequenceRequested = { [weak self] fastaRecords, suggestedName in
            self?.presentFASTASequenceExtractionDialog(records: fastaRecords, suggestedName: suggestedName)
        }
        controller.onExportFASTARequested = { [weak self] fastaRecords, suggestedName in
            self?.exportFASTARecords(fastaRecords, suggestedName: suggestedName)
        }
        controller.onCreateBundleRequested = { [weak self] fastaRecords, suggestedName in
            self?.createReferenceBundle(from: fastaRecords, suggestedName: suggestedName)
        }
        controller.onRunOperationRequested = { [weak self] fastaRecords in
            let suggestedName: String
            if let firstHeader = fastaRecords.first?
                .split(whereSeparator: \.isNewline)
                .first?
                .dropFirst()
                .split(separator: " ")
                .first {
                suggestedName = String(firstHeader)
            } else {
                suggestedName = "selected-contigs"
            }
            self?.presentFASTAOperationDialog(records: fastaRecords, suggestedName: suggestedName)
        }

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let assemblyView = controller.view
        controller.configure(result: result)
        assemblyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(assemblyView)

        NSLayoutConstraint.activate([
            assemblyView.topAnchor.constraint(equalTo: view.topAnchor),
            assemblyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            assemblyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            assemblyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        assemblyResultController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        assemblyDisplayLogger.info(
            "displayAssemblyResult: Showing \(result.tool.displayName, privacy: .public) result"
        )
    }

    /// Removes the assembly result viewport and restores the normal viewer components.
    public func hideAssemblyView() {
        guard let controller = assemblyResultController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        assemblyResultController = nil

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }

    nonisolated static func blastSequences(from fastaRecords: [String]) -> [(id: String, sequence: String)] {
        fastaRecords.compactMap { fasta in
            let lines = fasta.split(whereSeparator: \.isNewline)
            guard let headerLine = lines.first, headerLine.hasPrefix(">") else {
                return nil
            }

            let identifier = headerLine.dropFirst().split(separator: " ").first.map(String.init) ?? "contig"
            let sequence = lines.dropFirst().joined()
            guard !sequence.isEmpty else { return nil }
            return (id: identifier, sequence: sequence)
        }
    }
}
