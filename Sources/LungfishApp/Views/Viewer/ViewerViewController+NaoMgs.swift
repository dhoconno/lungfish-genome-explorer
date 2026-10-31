// ViewerViewController+NaoMgs.swift - NAO-MGS result display extension
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishNaoMgsUI
import LungfishKit
import os.log

private let naoMgsDisplayLogger = Logger(subsystem: "com.lungfish", category: "NaoMgsDisplay")

// MARK: - ViewerViewController NAO-MGS Display Extension

extension ViewerViewController {

    /// Shows `controller` through the surface host in place of the normal sequence
    /// viewer and returns once it is installed, or throws the reason it is not. The
    /// caller fills the controller after the show. `onWillDeactivate` runs whenever
    /// the host later removes this viewer, another NAO-MGS result's show included.
    public func displayNaoMgsResult(
        _ controller: NaoMgsResultViewController,
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

        // Wire BLAST verification callback.
        controller.onBlastVerification = { [weak self, weak controller] summary, readCount, reads in
            let selectedReadCount = min(50, max(1, readCount))
            let taxonName = summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name
            naoMgsDisplayLogger.info(
                "BLAST verification requested for \(taxonName, privacy: .public), readCount=\(selectedReadCount, privacy: .public), availableReads=\(reads.count, privacy: .public)"
            )
            guard let plan = Self.blastSubmitPlan(window: self?.view.window, failure: { controller?.showBlastFailure($0) }, {
                try Self.naoMgsBlastSubmitPlan(
                    taxonName: taxonName, taxId: summary.taxId, readCount: selectedReadCount, reads: reads,
                    projectURL: self?.blastSubmitProjectURL(), sourceResultURL: controller?.bundleURL
                )
            }) else { return }
            Self.beginNaoMgsBlastVerificationOperation(
                taxonName: taxonName, taxId: summary.taxId, cliCommand: plan.cliCommand
            ) { opID in
                Self.launchBlastSubmit(plan, operationID: opID, drawer: BlastSubmitDrawer(
                    loading: { controller?.showBlastLoading(phase: $0, requestId: nil) },
                    results: { controller?.showBlastResults($0, recordURL: $1) },
                    failure: { controller?.showBlastFailure($0) }
                )) { "\($0.verifiedCount)/\($0.readResults.count) verified" }
            }
        }
        // The shared actions hand the App one extraction request, which the App answers with its dialog.
        controller.resultActions.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        let surface = try showSurface(.analysis(.naomgs), input: controller, as: NaoMgsSurface.self)
        surface.onWillDeactivate = onWillDeactivate
        // showSurface hides the genomics viewer. These two drawers are this kind's own lines.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
    }

    /// The NAO-MGS taxon's search on `blast submit` (2.11 A65 M2). It draws the
    /// subsample the in-process route drew, the mixed strategy with its seed
    /// of 0, and records the taxon, the count, the seed and the samples of the
    /// reads it drew. `sourceResultURL` is the folder of the NAO-MGS result the reads came from, which the
    /// record names as its lineage. The search's folder still sits under `projectURL`, never in that result.
    ///
    /// The search covers all of `core_nt` and sends no Entrez filter, as the EsViritu, TaxTriage, Kraken 2 and NVD
    /// routes do, so a read whose best match is another organism can count as contradicting the taxon (3.1
    /// BLAST-SCOPE). The verdicts are judged against the taxon's tax ID. A hit with another tax ID counts as inside
    /// the taxon only when its organism name holds the taxon's name as a whole phrase, so "Human rotavirus A"
    /// (10941) counts for "Rotavirus A" (28875), and a descendant or a parent named otherwise counts as outside
    /// (`BlastTaxonMatching.relation`). A `taxId` of 0 or less names no tax ID, and the older name rule judges.
    nonisolated static func naoMgsBlastSubmitPlan(
        taxonName: String,
        taxId: Int,
        readCount: Int,
        reads: [NaoMgsVirusHit],
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let allReads = reads.compactMap { hit -> (id: String, sequence: String)? in
            let sequence = hit.readSequence.trimmingCharacters(in: .whitespacesAndNewlines)
            return sequence.isEmpty ? nil : (id: hit.seqId, sequence: sequence)
        }
        guard !allReads.isEmpty else { throw BlastServiceError.noSequences }
        let longestCount = min(5, readCount / 4)
        let seed: UInt64 = 0
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: allReads, strategy: .mixed(longest: longestCount, random: readCount - longestCount), seed: seed
        )
        let sampleByRead = Dictionary(reads.map { ($0.seqId, $0.sample) }, uniquingKeysWith: { first, _ in first })
        let samples = Set(subsampled.compactMap { sampleByRead[$0.id] }).sorted()
        return try BlastSubmitPlan.make(
            sequences: subsampled, label: taxonName, projectURL: projectURL, sourceResultURL: sourceResultURL,
            outputParentURL: projectURL, taxId: taxId,
            sample: samples.isEmpty ? nil : samples.joined(separator: ","),
            subsampleCount: subsampled.count, subsampleSeed: seed,
            acceptedTaxIds: taxId > 0 ? [taxId] : [], acceptedNames: [taxonName], date: date
        )
    }

    /// Registers the BLAST verification row for a NAO-MGS taxon and, only when
    /// it starts, calls `launch` with the operation ID. The run submits reads
    /// the result already holds and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``).
    @discardableResult
    static func beginNaoMgsBlastVerificationOperation(
        taxonName: String,
        taxId: Int,
        cliCommand: String? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(taxonName)",
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

    /// Hides the NAO-MGS result viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    public func hideNaoMgsView() {
        clearSurface(ifShowing: .analysis(.naomgs))
    }
}
