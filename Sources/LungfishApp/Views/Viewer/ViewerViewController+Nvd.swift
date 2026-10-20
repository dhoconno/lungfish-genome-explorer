// ViewerViewController+Nvd.swift - NVD result display extension
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishNaoMgsUI
import LungfishNvdUI
import LungfishKit
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
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideAlignmentTreeBundleViews()
        contentMode = .metagenomics

        controller.classifierAlignmentViewerFactory = { [weak self] in
            guard let split = self?.parent as? MainSplitViewController else {
                return UnavailableClassifierAlignmentViewer()
            }
            return split.makeClassifierAlignmentEvidenceViewport()
        }

        addChild(controller)

        // Wire BLAST verification callback.
        // NVD submits a single contig sequence rather than multiple reads.
        controller.onBlastVerification = { [weak self, weak controller] hit, sequence in
            let contigName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
            // Use the classification name for concordance checking, not the contig name
            let classificationName = hit.adjustedTaxidName.isEmpty ? contigName : hit.adjustedTaxidName
            let taxIdInt = Int(hit.adjustedTaxid) ?? 0
            nvdDisplayLogger.info(
                "BLAST verification requested for \(contigName, privacy: .public) (\(classificationName, privacy: .public)), taxId=\(taxIdInt, privacy: .public)"
            )
            guard let plan = Self.blastSubmitPlan(window: self?.view.window, failure: { controller?.showBlastFailure($0) }, {
                try Self.nvdBlastSubmitPlan(
                    hit: hit, sequence: sequence, classificationName: classificationName,
                    projectURL: self?.blastSubmitProjectURL(), sourceResultURL: controller?.bundleURL
                )
            }) else { return }
            Self.beginNvdBlastVerificationOperation(
                contigName: contigName, classificationName: classificationName, taxId: taxIdInt, cliCommand: plan.cliCommand
            ) { opID in
                Self.launchBlastSubmit(plan, operationID: opID, drawer: BlastSubmitDrawer(
                    loading: { controller?.showBlastLoading(phase: $0, requestId: nil) },
                    results: { controller?.showBlastResults($0, recordURL: $1) },
                    failure: { controller?.showBlastFailure($0) }
                )) { "\($0.verifiedCount)/\($0.readResults.count) verified" }
            }
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
        controller.onExtractReadsRequested = { [weak controller] tool, resultPath, selectors, suggestedName in
            guard let controller else { return }
            controller.presentClassifierExtractionDialog(tool: tool, resultPath: resultPath, selectors: selectors, suggestedName: suggestedName)
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

    /// The NVD contig's search on `blast submit` (2.12 lane 12.08). It sends the one contig, trimmed, and
    /// judges hits on the request `NvdBlastHit.blastVerificationRequest` builds, the classification's name
    /// and its adjusted tax ID with that taxon's names. The record names the sample, the contig, the taxon
    /// and `sourceResultURL`, the NVD result, when the viewer has it. The search's folder sits under the
    /// project's `blast-verifications/`, never in the NVD result.
    nonisolated static func nvdBlastSubmitPlan(
        hit: NvdBlastHit,
        sequence: String,
        classificationName: String,
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let trimmed = sequence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BlastServiceError.noSequences }
        return try BlastSubmitPlan.make(
            request: hit.blastVerificationRequest(taxonName: classificationName, sequence: trimmed),
            projectURL: projectURL, sourceResultURL: sourceResultURL, outputParentURL: projectURL,
            contig: hit.qseqid, sample: hit.sampleId, date: date
        )
    }

    /// Registers the BLAST verification row for an NVD contig and, only when it
    /// starts, calls `launch` with the operation ID. The run submits the one
    /// contig sequence and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``). The row records it when it begins.
    @discardableResult
    static func beginNvdBlastVerificationOperation(
        contigName: String,
        classificationName: String,
        taxId: Int,
        cliCommand: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(contigName) \u{2014} \(classificationName)",
            detail: "Preparing BLAST verification\u{2026}",
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

    /// Hides the NVD result viewer if one is displayed and restores normal viewer components.
    public func hideNvdView() {
        for case let child as NvdResultViewController in children {
            child.clearClassifierAlignmentEvidence()
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
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
    }
}
