// ViewerViewController+Assembly.swift - Assembly result display for ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit
import LungfishAssemblyUI

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
        hideCzIdView()
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
            guard let plan = Self.blastSubmitPlan(window: self.view.window, failure: { blastController.showBlastFailure($0) }, {
                try Self.assemblyBlastSubmitPlan(
                    sourceLabel: request.sourceLabel, taxId: request.taxId, fastaRecords: request.sequences,
                    resultURL: result.outputDirectory
                )
            }) else { return }
            Self.beginAssemblyContigBlastVerificationOperation(
                sourceLabel: request.sourceLabel, cliCommand: plan.cliCommand
            ) { opID in
                Self.launchBlastSubmit(plan, operationID: opID, drawer: BlastSubmitDrawer(
                    loading: { blastController.showBlastLoading(phase: $0, requestId: nil) },
                    results: { blastController.showBlastResults($0, recordURL: $1) },
                    failure: { blastController.showBlastFailure($0) }
                )) { [count = request.readCount] _ in "Results ready for \(count) contig\(count == 1 ? "" : "s")" }
            }
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
            assemblyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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

    /// The contig search of an assembly result on `blast submit` (2.11 A65
    /// M2). The result folder is the assembly's, and the record names the
    /// contigs and the taxon when the selection has one.
    nonisolated static func assemblyBlastSubmitPlan(
        sourceLabel: String,
        taxId: Int?,
        fastaRecords: [String],
        resultURL: URL,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let sequences = blastSequences(from: fastaRecords)
        return try BlastSubmitPlan.make(
            sequences: sequences, label: sourceLabel, projectURL: ProjectTempDirectory.findProjectRoot(resultURL),
            sourceResultURL: resultURL, taxId: taxId, contig: sequences.map(\.id).joined(separator: ","), date: date
        )
    }

    /// Registers the contig BLAST row for an assembly result and, only when it
    /// starts, calls `launch` with the operation ID. The run locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``).
    @discardableResult
    static func beginAssemblyContigBlastVerificationOperation(
        sourceLabel: String,
        cliCommand: String? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(sourceLabel)",
            detail: "Preparing contig BLAST…",
            operationType: .blastVerification,
            cliCommand: cliCommand
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
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
        revealAnnotationDrawerUnlessNativeBundleInstalled()
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
