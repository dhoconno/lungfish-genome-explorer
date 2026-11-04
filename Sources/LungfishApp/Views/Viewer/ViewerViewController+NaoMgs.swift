// ViewerViewController+NaoMgs.swift - NAO-MGS result display extension
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishNaoMgsUI
import LungfishKit
import LungfishWorkflow
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
        controller.resultActions.savedBlastSearchProject = { [weak self] in self?.blastSubmitProjectURL() }
        controller.onBlastVerification = { [weak self, weak controller] summary, readCount, reads in
            let selectedReadCount = min(50, max(1, readCount))
            let taxonName = summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name
            naoMgsDisplayLogger.info(
                "BLAST verification requested for \(taxonName, privacy: .public), readCount=\(selectedReadCount, privacy: .public), availableReads=\(reads.count, privacy: .public)"
            )
            let window = self?.view.window
            let projectURL = self?.blastSubmitProjectURL()
            let sourceResultURL = controller?.bundleURL
            let taxId = summary.taxId
            // The taxonomy's files are read before the row begins, so the drawer says so meanwhile. With no project the
            // plan refuses, and the refusal shows no drawer.
            if projectURL != nil { controller?.showBlastLoading(phase: .submitting, requestId: nil) }
            Task { @MainActor in
                let taxonomyDirectory = await Self.installedNCBITaxonomyDirectory()
                let planned = await Self.blastSubmitPlanOffMainActor {
                    try Self.naoMgsBlastSubmitPlan(
                        taxonName: taxonName, taxId: taxId, readCount: selectedReadCount, reads: reads,
                        projectURL: projectURL, sourceResultURL: sourceResultURL, taxonomyDirectory: taxonomyDirectory
                    )
                }
                guard let plan = Self.blastSubmitPlan(
                    window: window, failure: { controller?.showBlastFailure($0) }, { try planned.get() }
                ) else { return }
                Self.beginNaoMgsBlastVerificationOperation(
                    taxonName: taxonName, taxId: taxId, cliCommand: plan.cliCommand
                ) { opID in
                    Self.launchBlastSubmit(
                        plan, operationID: opID, drawer: .classifier { controller?.resultActions }
                    ) { blastVerificationCompletionDetail($0) }
                }
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
    /// BLAST-SCOPE). With the NCBI Taxonomy installed, the verdicts are judged at species level: the accepted tax IDs
    /// are the taxon's nearest species-rank ancestor (the taxon itself at or above species), the path up to it, and
    /// every descendant of it up to 5,000 (BLAST-CLADE-BY-LINEAGE). Without it, or for a `taxId` of 0 or less, the
    /// taxon's own tax ID and name judge, and a descendant or parent named otherwise counts as outside.
    ///
    /// `taxonomyDirectory` is ``installedNCBITaxonomyDirectory()``. Reading it walks whole files, so a caller on the
    /// main actor builds this plan through ``blastSubmitPlanOffMainActor(_:)``.
    nonisolated static func naoMgsBlastSubmitPlan(
        taxonName: String,
        taxId: Int,
        readCount: Int,
        reads: [NaoMgsVirusHit],
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        taxonomyDirectory: URL? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let allReads = reads.compactMap { hit -> (id: String, sequence: String)? in
            let sequence = hit.readSequence.trimmingCharacters(in: .whitespacesAndNewlines)
            return sequence.isEmpty ? nil : (id: hit.seqId, sequence: sequence)
        }
        guard !allReads.isEmpty else { throw BlastServiceError.noSequences }
        guard projectURL != nil else { throw BlastSubmitPlanError.noProject }
        let context = NCBITaxonomyLineage.blastTaxonomyContext(of: taxId, names: [taxonName], taxonomyDirectory: taxonomyDirectory)
        let acceptedTaxIds = context.map { $0.cladeTaxIds.sorted() } ?? (taxId > 0 ? [taxId] : [])
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
            sample: BlastSavedSearchRow.lineageSample(of: samples),
            subsampleCount: subsampled.count, subsampleSeed: seed,
            acceptedTaxIds: acceptedTaxIds, acceptedNames: context?.cladeNames ?? [taxonName], date: date
        )
    }

    /// The folder of the installed NCBI Taxonomy, or nil when it is not installed, as the NAO-MGS, TaxTriage and NVD
    /// searches take it. It only looks, and never downloads (BIO-BLAST-CLADE Q2).
    nonisolated static func installedNCBITaxonomyDirectory() async -> URL? {
        let installed = try? await MetagenomicsDatabaseRegistry.shared.installedDatabase(tool: .ncbiTaxonomy)
        return installed?.path
    }

    /// Runs `makePlan` off the main actor and hands back its plan or its error, for a plan that reads the taxonomy.
    @concurrent nonisolated static func blastSubmitPlanOffMainActor(
        _ makePlan: @Sendable () throws -> BlastSubmitPlan
    ) async -> Result<BlastSubmitPlan, any Error> {
        Result { try makePlan() }
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
