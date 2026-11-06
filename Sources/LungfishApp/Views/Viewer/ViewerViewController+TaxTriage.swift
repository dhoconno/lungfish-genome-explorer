// ViewerViewController+TaxTriage.swift - TaxTriage result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds TaxTriage clinical triage result display to ViewerViewController,
// which shows the result through the viewer's surface host (TaxTriageSurface).

import AppKit
import LungfishCore
import LungfishIO
import LungfishTaxTriageUI
import LungfishWorkflow
import LungfishKit
import SwiftUI
import os.log

/// Logger for TaxTriage display operations.
private let taxTriageLogger = Logger(subsystem: "com.lungfish.app", category: "ViewerTaxTriage")


// MARK: - ViewerViewController TaxTriage Display Extension

extension ViewerViewController {

    /// The installed TaxTriage result viewer, read from the surface host.
    var taxTriageViewController: TaxTriageResultViewController? {
        (installedSurface as? TaxTriageSurface)?.controller
    }

    /// Shows the TaxTriage clinical triage browser backed by `db` through the surface host,
    /// in place of the normal sequence viewer, and returns once it is installed, or throws
    /// the reason it is not. The browser is configured from the database before the host
    /// adds it. `onWillDeactivate` runs whenever the host later removes this viewer,
    /// another TaxTriage result's show included.
    ///
    /// - Parameters:
    ///   - db: The opened TaxTriage SQLite database.
    ///   - resultURL: The batch result root directory (used for display context).
    func displayTaxTriageFromDatabase(
        db: TaxTriageDatabase,
        resultURL: URL,
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) throws {
        hideQuickLookPreview()
        hideFASTQDatasetView()
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

        let controller = TaxTriageResultViewController()
        controller.classifierAlignmentViewerFactory = { [weak self] in
            guard let split = self?.parent as? MainSplitViewController else {
                return UnavailableClassifierAlignmentViewer()
            }
            return split.makeClassifierAlignmentEvidenceViewport()
        }
        // Load the view and configure it before the host adds it to the view
        // hierarchy, which avoids a one-frame bounce.
        _ = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for TaxTriage.
        controller.resultActions.savedBlastSearchProject = { [weak self] in self?.blastSubmitProjectURL() }
        controller.onBlastVerification = { [weak self, weak controller] organism, readCount, accessions, bamURL, bamIndexURL in
            guard let bamURL else {
                controller?.showBlastFailure(ClassifierActionWords.alignmentFileMissing)
                return
            }

            let orgAccessions = accessions ?? []
            guard !orgAccessions.isEmpty else {
                controller?.showBlastFailure(ClassifierActionWords.noReferenceAccession)
                return
            }

            let selectedReadCount = min(50, max(1, readCount))
            self?.launchTaxTriageBlastSubmit(
                organism: organism, readCount: selectedReadCount, accessions: orgAccessions, bamURL: bamURL,
                bamIndexURL: bamIndexURL, resultURL: resultURL, controller: controller,
                taxonomyDirectory: { await Self.installedNCBITaxonomyDirectory() }
            )
        }
        // The request carries the row count and the rows left out from the selection its selectors came from.
        controller.resultActions.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        let surface = try showSurface(.analysis(.taxtriage), input: controller, as: TaxTriageSurface.self)
        surface.onWillDeactivate = onWillDeactivate
        // showSurface hides the genomics viewer. These two drawers are this kind's own lines.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        taxTriageLogger.info("displayTaxTriageFromDatabase: Showing DB-backed browser for '\(resultURL.lastPathComponent, privacy: .public)'")
    }

    /// The region extraction a classifier's BLAST Verify runs on the result's
    /// BAM. Region extraction refuses a BAM without an explicit index, so the
    /// index the result view resolved travels with the BAM.
    nonisolated static func classifierBlastExtractionConfig(
        bamURL: URL,
        indexURL: URL?,
        accessions: [String],
        outputDirectory: URL
    ) -> BAMRegionExtractionConfig {
        BAMRegionExtractionConfig(
            bamURL: bamURL,
            indexURL: indexURL,
            regions: accessions,
            fallbackToAll: false,
            outputDirectory: outputDirectory,
            outputBaseName: "blast_extract",
            deduplicateReads: true
        )
    }

    /// The TaxTriage organism's search on `blast submit` (2.12 lane 12.09, on the recipe of lane 12.08). With
    /// no project it shows the `No Project Open` refusal and begins no row. Otherwise the row begins at once
    /// with no command and the stage word `Extracting reads for selected accessions…`, so Cancel reaches it
    /// while the reads of `accessions` are extracted from the sample's BAM into the project's `.tmp`. Once
    /// they are read, the plan they make gives the command, which names the count the subsample drew. The row
    /// takes it through `setCommand` and the leaf starts at once. A Cancel during the extraction ends the row
    /// cancelled and starts no search, and an extraction that fails fails the row and the drawer. `drawer`,
    /// `runner` and `extractReads` are seams for tests. `taxonomyDirectory` finds the folder the verdicts are
    /// judged at species level with: the result view passes ``installedNCBITaxonomyDirectory()``, and the default
    /// of nil, which keeps a test off the installed taxonomy, judges by the organism's own tax ID. The result is the
    /// task that extracts and launches, nil when no row began.
    @discardableResult
    func launchTaxTriageBlastSubmit(
        organism: TaxTriageOrganism,
        readCount: Int,
        accessions: [String],
        bamURL: URL,
        bamIndexURL: URL?,
        resultURL: URL,
        controller: TaxTriageResultViewController?,
        drawer: BlastSubmitDrawer? = nil,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        extractReads: @escaping TaxTriageBlastReads.Extractor = TaxTriageBlastReads.extract,
        taxonomyDirectory: @escaping @Sendable () async -> URL? = { nil }
    ) -> Task<Void, Never>? {
        let window = view.window
        guard let projectURL = blastSubmitProjectURL() ?? ProjectTempDirectory.findProjectRoot(resultURL) else {
            Self.refuseBlastWithoutProject(window: window)
            return nil
        }
        let drawer = drawer ?? BlastSubmitDrawer.classifier { controller?.resultActions }
        var extraction: Task<Void, Never>?
        // 1. The row begins with no command. 2. The reads are extracted. 3. The row takes the plan's command.
        Self.beginTaxTriageBlastVerificationOperation(taxonName: organism.name) { opID in
            drawer.began?(opID)
            drawer.loading(.submitting)
            OperationCenter.shared.update(id: opID, progress: 0.1, detail: "Extracting reads for selected accessions…")
            let task = Task { @MainActor in
                do {
                    let reads = try await extractReads(bamURL, bamIndexURL, accessions, projectURL)
                    // A Cancel moves the row to cancelling at once but stops this task a moment later, so the
                    // row is asked as well as the task.
                    let stopIfCancelled = {
                        try Task.checkCancellation()
                        guard OperationCenter.shared.items.first(where: { $0.id == opID })?.state == .running else {
                            throw CancellationError()
                        }
                    }
                    try stopIfCancelled()
                    let directory = await taxonomyDirectory()
                    let plan = try await Self.blastSubmitPlanOffMainActor {
                        try Self.taxTriageBlastSubmitPlan(
                            organism: organism, reads: reads, readCount: readCount, accessions: accessions,
                            projectURL: projectURL, sourceResultURL: resultURL, taxonomyDirectory: directory
                        )
                    }.get()
                    try stopIfCancelled()
                    OperationCenter.shared.setCommand(id: opID, command: plan.cliCommand)
                    // No await sits between the checks above and the cancel callback this call replaces.
                    Self.launchBlastSubmit(plan, operationID: opID, runner: runner, drawer: drawer) {
                        blastVerificationCompletionDetail($0)
                    }
                } catch is CancellationError {
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                } catch {
                    let words = error.localizedDescription
                    guard OperationCenter.shared.fail(id: opID, detail: words, errorMessage: words) else { return }
                    drawer.failure(words)
                }
            }
            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            extraction = task
        }
        return extraction
    }

    /// The search of a TaxTriage organism's reads on `blast submit` (2.12 lane 12.09). From `reads`, the
    /// reads of the selected accessions, it draws the subsample the in-process route drew, the mixed
    /// strategy with seed 0, and judges hits on the request `TaxTriageOrganism.blastVerificationRequest`
    /// builds, the organism's own tax ID and name with no relatives, judged at species level with
    /// `taxonomyDirectory`, the installed NCBI Taxonomy (BLAST-CLADE-BY-LINEAGE). The record names the TaxTriage
    /// result, the organism's tax ID, the accessions as the contig, the organism's sample when it names one and the
    /// count and seed of the subsample. The result view names the sample whose BAM the reads came from (lane
    /// 12.09b), and a nil sample records none. The search's folder sits under the project's
    /// `blast-verifications/`, never in the TaxTriage result.
    nonisolated static func taxTriageBlastSubmitPlan(
        organism: TaxTriageOrganism,
        reads: [(id: String, sequence: String)],
        readCount: Int,
        accessions: [String],
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        taxonomyDirectory: URL? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        guard !reads.isEmpty else { throw BlastServiceError.noSequences }
        guard projectURL != nil else { throw BlastSubmitPlanError.noProject }
        let longestCount = min(5, readCount / 4)
        let seed: UInt64 = 0
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: reads, strategy: .mixed(longest: longestCount, random: readCount - longestCount), seed: seed
        )
        return try BlastSubmitPlan.make(
            request: organism.blastVerificationRequest(sequences: subsampled, taxonomyDirectory: taxonomyDirectory),
            projectURL: projectURL, sourceResultURL: sourceResultURL, outputParentURL: projectURL,
            contig: BlastSavedSearchRow.lineageContig(of: accessions), sample: organism.sample,
            subsampleCount: subsampled.count, subsampleSeed: seed, date: date
        )
    }

    /// Registers the BLAST verification row for a TaxTriage organism and, only
    /// when it starts, calls `launch` with the operation ID. The run extracts
    /// reads from the sample's BAM and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``), nil on the row
    /// ``launchTaxTriageBlastSubmit(organism:readCount:accessions:bamURL:bamIndexURL:resultURL:controller:drawer:runner:extractReads:)``
    /// begins before the reads exist.
    @discardableResult
    static func beginTaxTriageBlastVerificationOperation(
        taxonName: String,
        cliCommand: String? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(taxonName)",
            detail: "Preparing BLAST verification…",
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

    /// Hides the TaxTriage result viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    public func hideTaxTriageView() {
        clearSurface(ifShowing: .analysis(.taxtriage))
    }
}

/// The reads a TaxTriage BLAST Verify sends, read off the main actor (2.12 lane 12.09, the shape of
/// `EsVirituBlastReads`).
enum TaxTriageBlastReads {
    /// The extraction a BLAST Verify runs, ``extract`` or a test's stand-in.
    typealias Extractor = @Sendable (
        _ bamURL: URL, _ indexURL: URL?, _ accessions: [String], _ projectURL: URL
    ) async throws -> [(id: String, sequence: String)]

    /// The reads of `accessions` in the sample's BAM, at most 5,000, as the in-process route reads them. The
    /// extraction runs through `classifierBlastExtractionConfig`, which carries the BAM's index (PF12,
    /// `d4bed54e0`), into a folder under the project's `.tmp` that is removed once the reads are read.
    @concurrent static func extract(
        bamURL: URL,
        indexURL: URL?,
        accessions: [String],
        projectURL: URL
    ) async throws -> [(id: String, sequence: String)] {
        let tempDir = try ProjectTempDirectory.create(prefix: "taxtriage-blast-", in: projectURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let config = ViewerViewController.classifierBlastExtractionConfig(
            bamURL: bamURL, indexURL: indexURL, accessions: accessions, outputDirectory: tempDir
        )
        let extraction = try await ReadExtractionService().extractByBAMRegion(config: config)
        guard let fastq = extraction.fastqURLs.first else { throw BlastServiceError.noSequences }
        var reads: [(id: String, sequence: String)] = []
        reads.reserveCapacity(min(5_000, extraction.readCount))
        for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
            let sequence = record.sequence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sequence.isEmpty else { continue }
            reads.append((id: record.identifier, sequence: sequence))
            if reads.count >= 5_000 { break }
        }
        guard !reads.isEmpty else { throw BlastServiceError.noSequences }
        return reads
    }
}
