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
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .genomics

        let controller = AssemblyResultViewController()
        addChild(controller)
        controller.onBlastVerification = { request in
            let blastCliCmd = OperationCenter.buildCLICommand(subcommand: "blast verify", args: [])
            let opID = OperationCenter.shared.start(
                title: "BLAST \(request.sourceLabel)",
                detail: "Preparing BLAST verification…",
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
                                OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                            }
                        }
                    )

                    DispatchQueue.main.async {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(result.verifiedCount)/\(result.readResults.count) verified"
                        )
                    }
                } catch {
                    let errorText = error.localizedDescription
                    DispatchQueue.main.async {
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: errorText,
                            errorMessage: errorText
                        )
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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

    private nonisolated static func blastSequences(from fastaRecords: [String]) -> [(id: String, sequence: String)] {
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
