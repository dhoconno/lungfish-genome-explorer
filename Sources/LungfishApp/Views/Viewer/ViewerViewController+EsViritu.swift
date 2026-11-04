// ViewerViewController+EsViritu.swift - EsViritu result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds EsViritu viral detection result display to ViewerViewController,
// following the same child-VC pattern as displayTaxonomyResult / displayFASTACollection.

import AppKit
import LungfishCore
import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
import SwiftUI
import os.log

/// Logger for EsViritu display operations.
private let esVirituLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerEsViritu")


// MARK: - ViewerViewController EsViritu Display Extension

extension ViewerViewController {

    /// The installed EsViritu result viewer, read from the surface host.
    var esVirituViewController: EsVirituResultViewController? {
        (installedSurface as? EsVirituSurface)?.controller
    }

    /// Shows the EsViritu viral detection browser backed by `db` through the surface host,
    /// in place of the normal sequence viewer, and returns once it is installed, or throws
    /// the reason it is not. The browser is configured from the database before the host
    /// adds it. `onWillDeactivate` runs whenever the host later removes this viewer,
    /// another EsViritu result's show included.
    ///
    /// - Parameters:
    ///   - db: The opened ``EsVirituDatabase`` instance.
    ///   - resultURL: The batch result directory URL.
    func displayEsVirituFromDatabase(
        db: EsVirituDatabase,
        resultURL: URL,
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

        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { [weak self] in
            guard let split = self?.parent as? MainSplitViewController else {
                return UnavailableClassifierAlignmentViewer()
            }
            return split.makeClassifierAlignmentEvidenceViewport()
        }
        // EsViritu aligns against the managed database's pangenome FASTA, which
        // lives outside the result directory. Only the App knows how to find it,
        // so the leaf receives it through this callback; without it the viewport
        // reports "reference: not provided" for every detection.
        let referenceResolver = EsVirituReferenceResolver()
        controller.onResolveReferenceCandidate = { sampleID, contig, length in
            let resolution = referenceResolver.resolve(
                resultURL: resultURL,
                sampleID: sampleID,
                contig: contig,
                length: length
            )
            if let reason = resolution.reason {
                esVirituLogger.info("EsViritu reference resolution: \(reason, privacy: .public)")
            }
            return resolution.candidate
        }
        // Load the view and configure it before the host adds it to the view
        // hierarchy, which avoids a one-frame bounce.
        _ = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for EsViritu.
        controller.resultActions.savedBlastSearchProject = { [weak self] in self?.blastSubmitProjectURL() }
        controller.onBlastVerification = { [weak self, weak controller] detection, readCount, accessions, bamURL, bamIndexURL in
            guard let bamURL else {
                controller?.showBlastFailure(ClassifierActionWords.alignmentFileMissing)
                return
            }

            let selectedReadCount = min(50, max(1, readCount))
            self?.launchEsVirituBlastSubmit(
                detection: detection, readCount: selectedReadCount, accessions: accessions, bamURL: bamURL,
                bamIndexURL: bamIndexURL, resultURL: resultURL, controller: controller
            )
        }
        // The shared actions hand the App one extraction request, which the App answers with its dialog.
        controller.resultActions.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        let surface = try showSurface(.analysis(.esviritu), input: controller, as: EsVirituSurface.self)
        surface.onWillDeactivate = onWillDeactivate
        // showSurface hides the genomics viewer. These two drawers are this kind's own lines.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        esVirituLogger.info("displayEsVirituFromDatabase: Showing DB-backed browser for '\(resultURL.lastPathComponent, privacy: .public)'")
    }

    /// The EsViritu detection's search on `blast submit` (2.12 lane 12.08, review fix 4). With no project it
    /// shows the `No Project Open` refusal and begins no row. Otherwise the row begins at once with no
    /// command and the stage word `Extracting reads for selected accessions…`, so Cancel reaches it while
    /// the reads of `accessions` are extracted from the sample's BAM into the project's `.tmp`. Once they
    /// are read, the plan they make gives the command, which names the count the subsample drew. The row
    /// takes it through `setCommand` and the leaf starts at once. A Cancel during the extraction ends the
    /// row cancelled and starts no search, and an extraction that fails fails the row and the drawer.
    /// `drawer`, `runner` and `extractReads` are seams for tests. The result is the task that extracts
    /// and launches, nil when no row began.
    @discardableResult
    func launchEsVirituBlastSubmit(
        detection: ViralDetection,
        readCount: Int,
        accessions: [String],
        bamURL: URL,
        bamIndexURL: URL?,
        resultURL: URL,
        controller: EsVirituResultViewController?,
        drawer: BlastSubmitDrawer? = nil,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        extractReads: @escaping EsVirituBlastReads.Extractor = EsVirituBlastReads.extract,
        taxonomyContext: @escaping @Sendable (ViralDetection) async -> BlastTaxonomyContext
            = ViewerViewController.installedEsVirituBlastTaxonomyContext
    ) -> Task<Void, Never>? {
        let window = view.window
        guard let projectURL = blastSubmitProjectURL() ?? ProjectTempDirectory.findProjectRoot(resultURL) else {
            Self.refuseBlastWithoutProject(window: window)
            return nil
        }
        let drawer = drawer ?? BlastSubmitDrawer.classifier { controller?.resultActions }
        var extraction: Task<Void, Never>?
        // 1. The row begins with no command. 2. The reads are extracted. 3. The row takes the plan's command.
        Self.beginEsVirituBlastVerificationOperation(taxonName: detection.name) { opID in
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
                    let context = await taxonomyContext(detection)
                    try stopIfCancelled()
                    let plan = try Self.esVirituBlastSubmitPlan(
                        detection: detection, reads: reads, readCount: readCount, accessions: accessions,
                        projectURL: projectURL, sourceResultURL: resultURL, taxonomyContext: context
                    )
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

    /// The search of an EsViritu detection's reads on `blast submit` (2.12 lane 12.08). From `reads`, the
    /// reads of the selected accessions, it draws the subsample the in-process route drew, the mixed
    /// strategy with seed 0, and judges hits on the request `ViralDetection.blastVerificationRequest`
    /// builds under `taxonomyContext`, which ``installedEsVirituBlastTaxonomyContext(of:)`` reads, or with nil
    /// on the detection's names with its genus as the relative. The record names the EsViritu result,
    /// the sample, the accessions as the contig and the count and seed of the subsample. The search's
    /// folder sits under the project's `blast-verifications/`, never in the EsViritu result.
    nonisolated static func esVirituBlastSubmitPlan(
        detection: ViralDetection,
        reads: [(id: String, sequence: String)],
        readCount: Int,
        accessions: [String],
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        taxonomyContext: BlastTaxonomyContext? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        guard !reads.isEmpty else { throw BlastServiceError.noSequences }
        let longestCount = min(5, readCount / 4)
        let seed: UInt64 = 0
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: reads, strategy: .mixed(longest: longestCount, random: readCount - longestCount), seed: seed
        )
        return try BlastSubmitPlan.make(
            request: detection.blastVerificationRequest(sequences: subsampled, taxonomyContext: taxonomyContext),
            projectURL: projectURL, sourceResultURL: sourceResultURL, outputParentURL: projectURL,
            contig: BlastSavedSearchRow.lineageContig(of: accessions), sample: detection.sampleId,
            subsampleCount: subsampled.count, subsampleSeed: seed, date: date
        )
    }

    /// The taxonomy a detection's search is judged at on this Mac, from the installed EsViritu database and NCBI Taxonomy
    /// (BIO-BLAST-WALK Q2). It reads local files only, takes seconds and never downloads. With either one missing it is the
    /// names-only taxonomy. An imported result reads the same installed database, and its species must agree.
    @concurrent nonisolated static func installedEsVirituBlastTaxonomyContext(of detection: ViralDetection) async -> BlastTaxonomyContext {
        let databaseDirectory = await EsVirituDatabaseManager.shared.installedDatabaseInfo()?.path
        let taxonomyDirectory = await Self.installedNCBITaxonomyDirectory()
        return detection.blastTaxonomyContext(databaseDirectory: databaseDirectory, taxonomyDirectory: taxonomyDirectory)
    }

    /// Registers the BLAST verification row for an EsViritu detection and, only
    /// when it starts, calls `launch` with the operation ID. The run extracts
    /// reads from the sample's BAM and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``), nil on the row `launchEsVirituBlastSubmit`
    /// begins before the reads exist.
    @discardableResult
    static func beginEsVirituBlastVerificationOperation(
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

    /// Hides the EsViritu result viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    public func hideEsVirituView() {
        clearSurface(ifShowing: .analysis(.esviritu))
    }
}

/// The reads an EsViritu BLAST Verify sends, read off the main actor (2.12 lane 12.08).
enum EsVirituBlastReads {
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
        let tempDir = try ProjectTempDirectory.create(prefix: "esviritu-blast-", in: projectURL)
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
