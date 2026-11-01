// ViewerViewController+Nvd.swift - NVD result display extension
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
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

    /// Shows `controller` through the surface host in place of the normal sequence
    /// viewer and returns once it is installed, or throws the reason it is not. The
    /// caller fills the controller after the show. `onWillDeactivate` runs whenever
    /// the host later removes this viewer, another NVD result's show included.
    public func displayNvdResult(
        _ controller: NvdResultViewController,
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) throws {
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
            let window = self?.view.window
            let projectURL = self?.blastSubmitProjectURL()
            let sourceResultURL = controller?.bundleURL
            // The taxonomy's files are read before the row begins, so the drawer says so meanwhile. With no project the
            // plan refuses, and the refusal shows no drawer.
            if projectURL != nil { controller?.showBlastLoading(phase: .submitting, requestId: nil) }
            Task { @MainActor in
                let taxonomyDirectory = await Self.installedNCBITaxonomyDirectory()
                let planned = await Self.blastSubmitPlanOffMainActor {
                    try Self.nvdBlastSubmitPlan(
                        hit: hit, sequence: sequence, classificationName: classificationName,
                        projectURL: projectURL, sourceResultURL: sourceResultURL, taxonomyDirectory: taxonomyDirectory
                    )
                }
                guard let plan = Self.blastSubmitPlan(
                    window: window, failure: { controller?.showBlastFailure($0) }, { try planned.get() }
                ) else { return }
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
        // The shared actions hand the App one extraction request, which the App answers with its dialog.
        controller.resultActions.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        let surface = try showSurface(.analysis(.nvd), input: controller, as: NvdSurface.self)
        surface.onWillDeactivate = onWillDeactivate
        // showSurface hides the genomics viewer. These two drawers are this kind's own lines.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
    }

    /// The NVD contig's search on `blast submit` (2.12 lane 12.08). It sends the one contig, trimmed, and
    /// judges hits on the request `NvdBlastHit.blastVerificationRequest` builds, the classification's name
    /// and its adjusted tax ID with that taxon's names, judged at species level with `taxonomyDirectory`, the
    /// installed NCBI Taxonomy (BLAST-CLADE-BY-LINEAGE). The record names the sample, the contig, the taxon
    /// and `sourceResultURL`, the NVD result, when the viewer has it. The search's folder sits under the
    /// project's `blast-verifications/`, never in the NVD result.
    nonisolated static func nvdBlastSubmitPlan(
        hit: NvdBlastHit,
        sequence: String,
        classificationName: String,
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        taxonomyDirectory: URL? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let trimmed = sequence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BlastServiceError.noSequences }
        guard projectURL != nil else { throw BlastSubmitPlanError.noProject }
        return try BlastSubmitPlan.make(
            request: hit.blastVerificationRequest(taxonName: classificationName, sequence: trimmed, taxonomyDirectory: taxonomyDirectory),
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

    /// Hides the NVD result viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    public func hideNvdView() {
        clearSurface(ifShowing: .analysis(.nvd))
    }
}
