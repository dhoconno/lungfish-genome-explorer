// ViewerViewController+Taxonomy.swift - Taxonomy view display for ViewerViewController
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds taxonomy classification result display to ViewerViewController,
// following the same child-VC pattern as displayFASTACollection / displayFASTQDataset.

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit
import LungfishTaxonomyUI

/// Logger for taxonomy display operations.
private let taxonomyLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerTaxonomy")

// MARK: - ViewerViewController Taxonomy Display Extension

extension ViewerViewController {

    /// The installed Kraken2 taxonomy browser, read from the surface host.
    var taxonomyViewController: TaxonomyViewController? {
        (installedSurface as? Kraken2Surface)?.controller
    }

    /// Shows the taxonomy classification browser for `result` through the surface host, in
    /// place of the normal sequence viewer. The browser is configured before the host adds it.
    /// When the show does not install, the viewer says so in words that say what to try, since
    /// the route that calls this (the CLI route's completion) has no catch of its own.
    /// Read extraction is driven by ``TaxonomyReadExtractionAction.shared.present(...)``,
    /// which the VC fires from its action bar or context menu.
    ///
    /// - Parameters:
    ///   - result: The classification result to display.
    ///   - onWillDeactivate: Runs whenever the host later removes this viewer.
    public func displayTaxonomyResult(_ result: ClassificationResult, onWillDeactivate: (@MainActor () -> Void)? = nil) {
        clearSurfaceForNewContent()
        contentMode = .metagenomics

        let controller = TaxonomyViewController()
        // The Extract Reads dialog is an App sheet, so the view hands its request up and the App presents it.
        controller.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        // Load the view and configure it before the host adds it to the view
        // hierarchy, which avoids a one-frame bounce.
        _ = controller.view
        controller.configure(result: result)
        controller.applyProjectCopyRecord(ProjectItemCopyRecord.load(from: result.config.outputDirectory))

        // Wire batch extraction callback for the taxa collections drawer. Both display
        // routes share one wiring, so both run the same command (row 69).
        wireTaxaCollectionExtraction(on: controller)

        // Wire BLAST verification callback.
        // When user clicks "Run BLAST" in the config popover, submit to NCBI BLAST.
        // The inputs the classification recorded. The search reads their
        // files (D8).
        // A result whose reads the open project lacks refuses before any row, in the words that name them (WF-3).
        let capturedInputs = Result { try KrakenResultReadSources.recordedInputs(of: result, refusalAction: .blast) }
        let capturedResultDirectory = result.config.outputDirectory

        // Saved verifications live in the result folder and come back when
        // the result is reopened and the taxon is selected.
        controller.blastVerificationDirectoryResolver = { _ in capturedResultDirectory }

        controller.onBlastVerification = { [weak self, weak controller] node, readCount in
            if case .failure(let error) = capturedInputs, let refusal = error as? ClassifierExtractionError,
               case .sourceNotInProject = refusal {
                controller?.showBlastFailure(message: refusal.localizedDescription, runID: controller?.currentBlastRunID)
                showBlastVerificationErrorAlert(refusal.localizedDescription)
                return
            }
            self?.beginKraken2BlastSubmit(
                controller: controller, node: node, readCount: readCount, classResult: result,
                sourceInputs: (try? capturedInputs.get()) ?? [], resultDirectory: capturedResultDirectory
            )
        }

        do {
            try showKraken2Browser(controller, onWillDeactivate: onWillDeactivate)
        } catch {
            taxonomyLogger.error("displayTaxonomyResult: Kraken2 not shown - \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: Self.kraken2NotShownWords)
            return
        }

        taxonomyLogger.info("displayTaxonomyResult: Showing browser with \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")
    }

    /// The words a person reads when a Kraken2 result does not open, with no kind id and no
    /// internal error text. The sidebar route's catch shows the same sentence.
    static let kraken2NotShownWords = "Unable to open the Kraken2 result. Select it again."

    /// Hands the configured browser to the surface host, which installs it in place of the
    /// genomics viewer, then hides the two drawers that are this kind's own lines.
    private func showKraken2Browser(_ controller: TaxonomyViewController, onWillDeactivate: (@MainActor () -> Void)?) throws {
        let surface = try showSurface(.analysis(.kraken2), input: controller, as: Kraken2Surface.self)
        surface.onWillDeactivate = onWillDeactivate
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
    }

    /// Shows the taxonomy classification browser backed by a pre-built SQLite database through
    /// the surface host, and returns once it is installed, or throws the reason it is not.
    ///
    /// Creates a ``TaxonomyViewController`` and calls
    /// ``TaxonomyViewController/configureFromDatabase(_:)`` to populate it from the database
    /// before the host adds it. It wires BLAST verification and the Collections drawer's Extract
    /// to the one sample the table shows, which the drawer resolves when the user presses Extract
    /// (row 69). `onWillDeactivate` runs whenever the host later removes this viewer, another
    /// Kraken2 result's show included.
    ///
    /// - Parameters:
    ///   - db: The `Kraken2Database` to load rows from.
    ///   - resultURL: The batch result root directory (used for logging).
    func displayTaxonomyFromDatabase(
        db: Kraken2Database,
        resultURL: URL,
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) throws {
        clearSurfaceForNewContent()
        contentMode = .metagenomics

        let controller = TaxonomyViewController()
        // The Extract Reads dialog is an App sheet, so the view hands its request up and the App presents it.
        controller.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }

        // Load the view and configure it before the host adds it to the view
        // hierarchy, which avoids a one-frame bounce.
        _ = controller.view
        controller.batchURL = resultURL
        controller.configureFromDatabase(db)
        controller.applyProjectCopyRecord(ProjectItemCopyRecord.load(from: resultURL))

        // Wire the Collections drawer's Extract the way the single-result route does (row 69).
        wireTaxaCollectionExtraction(on: controller)

        // Wire BLAST verification for DB-backed batch display by resolving the
        // currently displayed sample's sidecar result from the batch manifest.
        // Single-sample DB-backed results have no batch manifest, so fall back
        // to loading `classification-result.json` directly from `resultURL`.
        controller.blastVerificationDirectoryResolver = { [weak controller] node in
            guard let controller else { return nil }
            return kraken2SampleResultDirectory(resultURL: resultURL, controller: controller, node: node)
        }

        controller.onBlastVerification = { [weak self, weak controller] node, readCount in
            guard let controller else { return }
            // Run marked the search begun, so a start that fails ends it as every other BLAST failure does, in words
            // that say which record is the problem (ARCH Backlog B12).
            guard let sampleDirectory = kraken2SampleResultDirectory(resultURL: resultURL, controller: controller, node: node) else {
                taxonomyLogger.warning("BLAST: failed to resolve a Kraken2 classification sidecar for \(resultURL.path, privacy: .public)")
                let words = "Verify with BLAST could not start because LGE could not find this sample's classification record. "
                    + "Run the classification again to rebuild it."
                controller.showBlastFailure(message: words, runID: controller.currentBlastRunID)
                showBlastVerificationErrorAlert(words)
                return
            }
            let sampleResult: ClassificationResult
            do {
                sampleResult = try ClassificationResult.load(from: sampleDirectory)
            } catch {
                taxonomyLogger.warning("BLAST: failed to resolve a Kraken2 classification sidecar for \(resultURL.path, privacy: .public)")
                var reason = error.localizedDescription
                if reason.hasSuffix(".") { reason.removeLast() }
                let words = "Verify with BLAST could not start because LGE could not read this sample's classification record: "
                    + "\(reason). Run the classification again to rebuild it."
                controller.showBlastFailure(message: words, runID: controller.currentBlastRunID)
                showBlastVerificationErrorAlert(words)
                return
            }
            let recorded = Result { try KrakenResultReadSources.recordedInputs(of: sampleResult, refusalAction: .blast) }
            if case .failure(let error) = recorded, let refusal = error as? ClassifierExtractionError,
               case .sourceNotInProject = refusal {
                controller.showBlastFailure(message: refusal.localizedDescription, runID: controller.currentBlastRunID)
                showBlastVerificationErrorAlert(refusal.localizedDescription)
                return
            }
            let sourceInputs = (try? recorded.get()) ?? []
            self?.beginKraken2BlastSubmit(
                controller: controller, node: node, readCount: readCount, classResult: sampleResult,
                sourceInputs: sourceInputs, resultDirectory: sampleDirectory, sample: controller.owningSampleId(for: node)
            )
        }

        try showKraken2Browser(controller, onWillDeactivate: onWillDeactivate)

        taxonomyLogger.info("displayTaxonomyFromDatabase: Showing DB-backed browser for '\(resultURL.lastPathComponent, privacy: .public)'")
    }

    /// Wires the Collections drawer's Extract of `controller` to ``extractTaxaCollection(_:from:)``.
    /// Both display routes call it (row 69). The drawer hands over the result it extracts from, which
    /// is the result displayed alone or the one sample a database-backed table shows.
    func wireTaxaCollectionExtraction(on controller: TaxonomyViewController) {
        controller.onBatchExtract = { [weak self] collection, classResult in
            self?.extractTaxaCollection(collection, from: classResult)
        }
    }

    /// Runs `lungfish-cli extract taxa-collection` over `classResult` and ends the row with the taxa
    /// count. The command writes one file per taxon into `extracted-<collection id>` inside the
    /// result's own folder, which makes a batch sample's folder hold that sample's reads alone.
    func extractTaxaCollection(_ collection: TaxaCollection, from classResult: ClassificationResult) {
        let routeContext = OperationRouteContext(
            projectURL: ProjectTempDirectory.findProjectRoot(classResult.outputURL),
            windowStateScope: windowStateScope
        )
        // The folder the result was loaded from, where its files are, which `ClassificationResult.load(from:)`
        // also names in `config.outputDirectory`. The row's project and both folders of the command come from
        // it, so a result renamed, moved or copied after its run never extracts from or into the folder its
        // run stored (OBS-W4).
        let resultFolder = classResult.outputURL.deletingLastPathComponent()
        let arguments = ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection,
            resultDirectory: resultFolder,
            outputDirectory: resultFolder.appendingPathComponent("extracted-\(collection.id)")
        )
        // The sample the alert names when the collection finds no reads, as the table names it.
        let sample = Kraken2TaxonomyTableExport.sidecarSampleId(config: classResult.config)
        ViewerViewController.beginTaxaCollectionExtractionOperation(
            collection: collection,
            arguments: arguments,
            routeContext: routeContext
        ) { opID in
            Task { @MainActor in
                do {
                    let run = try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: opID)
                    let outputURLs = run.outputs.map { URL(fileURLWithPath: $0) }
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: run.message ?? "Extracted \(outputURLs.count) taxa from \(collection.name)",
                        bundleURLs: outputURLs
                    )

                    // Refresh sidebar to pick up new extracted files
                    if let sidebar = (self.parent as? MainSplitViewController)?.sidebarController {
                        sidebar.requestReloadFromFilesystem()
                    }
                } catch is CancellationError {
                    // The runner acknowledged the cancel on the row, and the command stopped.
                } catch {
                    let words = Self.taxonomyExtractionAlertWords(for: error, sample: sample)
                    _ = OperationCenter.shared.fail(id: opID, detail: words.text)
                    showTaxonomyExtractionAlert(words)
                }
            }
        }
    }

    /// Registers the batch-extraction row for a taxa collection and, only when
    /// it starts, calls `launch` with the operation ID. The run writes into
    /// the classification folder and locks no bundle. The row records the
    /// `lungfish-cli extract taxa-collection` command that `launch` runs, built
    /// from `arguments` (``taxaCollectionExtractionArguments(collection:resultDirectory:outputDirectory:)``),
    /// so Copy CLI Command replays the extraction (Phase 2.11 lane A66).
    @discardableResult
    static func beginTaxaCollectionExtractionOperation(
        collection: TaxaCollection,
        arguments: [String],
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract \(collection.name)",
            detail: "Preparing batch extraction\u{2026}",
            operationType: .taxonomyExtraction,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "extract taxa-collection",
                args: Array(arguments.dropFirst(2))
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the BLAST verification row for a Kraken2 taxon and, only
    /// when it starts, calls `launch` with the operation ID. It locks no
    /// bundle. `cliCommand` is what the row records when it begins. The row
    /// on `blast submit` begins with none and takes `plan.cliCommand` once
    /// the read lookup has planned the search (`launchKraken2BlastSubmit`).
    @discardableResult
    static func beginKraken2BlastVerificationOperation(
        taxonName: String,
        cliCommand: String?,
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
}

// MARK: - Bundle Creation
// Bundle creation now handled by ReadExtractionService.createBundle() called inline
// in the extraction Task.detached block above.

/// The words of the alert a taxa collection extraction ends in when its command fails.
struct TaxonomyExtractionAlertWords: Equatable {
    let title: String
    let text: String
    let style: NSAlert.Style
}

extension ViewerViewController {
    /// The alert for `error`, which ended `lungfish-cli extract taxa-collection` on the result of `sample`.
    ///
    /// The command writes a file for each ticked taxon that has reads in the sample and skips the others. When it
    /// skips them all it has no output to record, and its record refuses the run with the provenance builder's
    /// sentence "completed successfully without recording at least one scientific output", which says nothing a
    /// person can act on. That one ending becomes an informational alert that says no ticked taxon has reads
    /// (OBS-W5). Every other failure keeps its warning alert and its words.
    static func taxonomyExtractionAlertWords(for error: Error, sample: String) -> TaxonomyExtractionAlertWords {
        if let failure = error as? CLISubprocessTransport.RunError,
           case .failedEvent(let message, _) = failure,
           message == ProvenanceBuilderError.missingOutput(taxaCollectionWorkflowName).errorDescription {
            return TaxonomyExtractionAlertWords(
                title: "No reads to extract",
                text: "None of the ticked taxa has reads in \(sample), so there was nothing to extract. "
                    + "Tick a taxon that has reads in this sample, then choose Extract.",
                style: .informational
            )
        }
        return TaxonomyExtractionAlertWords(title: "Taxonomy Extraction Failed", text: error.localizedDescription, style: .warning)
    }

    /// The name `lungfish-cli extract taxa-collection` gives its run in the record, which its failure messages quote.
    private static let taxaCollectionWorkflowName = "lungfish extract taxa-collection"
}

/// Presents the alert a failed taxonomy extraction ends in.
///
/// Uses `beginSheetModal` per macOS 26 conventions (never `runModal()`).
/// Accesses the window via `NSApp` to avoid capturing `self`.
private func showTaxonomyExtractionAlert(_ words: TaxonomyExtractionAlertWords) {
    MainActor.assumeIsolated {
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.text
        alert.alertStyle = words.style
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
    }
}

/// The BLAST verification request for a Kraken2 taxon, which both BLAST
/// rows of the viewer submit. It finds the taxon's fragments through the
/// result's read index when the index can resolve the clade, and by a scan
/// of the per-read output otherwise.
///
/// It reads every read file of `sourceInputs`, each pair's R1 and R2, then
/// the single reads, so a fragment whose evidence is on mate 2 is sent from
/// the R2 file and a merged fragment is found (D8). `lungfish-cli blast
/// verify` with one `--source` per input builds the same request.
func kraken2BlastVerificationRequest(
    taxonName: String,
    taxId: Int,
    tree: TaxonTree,
    classificationOutput: URL,
    sourceInputs: [URL],
    readCount: Int,
    service: BlastService = .shared
) async throws -> BlastVerificationRequest {
    // A trimmed or oriented subset is materialized for this request only.
    let scratch = try ProjectTempDirectory.createFromContext(prefix: "blast-sources-", contextURL: classificationOutput)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sources: [BlastReadSource]
    do {
        sources = try await KrakenResultReadSources.resolve(
            inputs: sourceInputs,
            classificationOutput: classificationOutput,
            materializationDirectory: scratch
        ).blastReadSources
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as ClassifierExtractionError {
        // The reads are missing, so the BLAST alert shows the words Extract shows, which say where they should be
        // and what to try, and not "No sequences provided" (W4-COPY-SOURCE).
        taxonomyLogger.error("BLAST: could not resolve the source reads of this classification: \(error.localizedDescription, privacy: .public)")
        throw error
    } catch {
        taxonomyLogger.error("BLAST: could not resolve the source reads of this classification: \(error.localizedDescription, privacy: .public)")
        throw BlastServiceError.noSequences
    }

    // A drawn read that is missing or has another length than kraken2 recorded means the files at the result's place
    // hold other reads under the same names, so the alert names the place and nothing is sent (BIO-READ-IDENTITY 4.1).
    func refusingChangedReads(_ build: () async throws -> BlastVerificationRequest) async throws -> BlastVerificationRequest {
        do {
            return try await build()
        } catch let changed as KrakenReadsChanged {
            throw ClassifierExtractionError.readsChanged(
                place: KrakenResultReadSources.place(of: sourceInputs), check: changed.check, forBLAST: true
            )
        }
    }

    // Build read ID set for this taxon using the indexed
    // sidecar when available (O(k) vs O(n) linear scan).
    // Clade (sampling targets and supporting hits) plus the
    // genus relatives the tree knows about.
    let taxonomyContext = tree.blastTaxonomyContext(for: taxId)
    let targetTaxIds = taxonomyContext.cladeTaxIds
    let acceptedTaxonNames = taxonomyContext.cladeNames

    let indexURL = KrakenIndexDatabase.indexURL(for: classificationOutput)
    if let db = try? KrakenIndexDatabase(url: indexURL),
       db.canResolve(taxIds: targetTaxIds) {
        // Fast path: use indexed lookup
        let matchingReadIds = try db.readIds(forTaxIds: targetTaxIds)
        db.close()
        taxonomyLogger.info("BLAST: indexed lookup found \(matchingReadIds.count, privacy: .public) reads for \(targetTaxIds.count, privacy: .public) taxIds")

        return try await refusingChangedReads { try await service.buildVerificationRequestFromReadIds(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sources: sources,
            readCount: readCount,
            targetTaxIds: targetTaxIds,
            classificationOutputURL: classificationOutput,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext
        ) }
    }
    // Slow path: linear scan (index will be built on next classification)
    taxonomyLogger.info("BLAST: no index available, using linear scan")
    return try await refusingChangedReads { try await service.buildVerificationRequest(
        taxonName: taxonName,
        taxId: taxId,
        targetTaxIds: targetTaxIds,
        classificationOutputURL: classificationOutput,
        sources: sources,
        readCount: readCount,
        acceptedTaxonNames: acceptedTaxonNames,
        taxonomyContext: taxonomyContext
    ) }
}

/// Operations-panel summary for a finished BLAST verification.
///
/// Uses the same supporting/contradicting counts as the BLAST Results
/// drawer. The old "N/M reads verified" text counted alignment quality only,
/// so it could read "17/20" while the drawer said "0 supporting".
func blastVerificationCompletionDetail(_ result: BlastVerificationResult) -> String {
    let base = "\(result.supportingCount) supporting, \(result.contradictingCount) contradicting of \(BlastResultsDrawerTab.countedRowWords(of: result))"
    return result.errorCount > 0 ? "\(base), \(result.errorCount) with no BLAST result" : base
}

/// The result folder of the Kraken 2 sample that owns `node` in a
/// database-backed display, found the way
/// ``kraken2SampleResultDirectory(resultURL:sampleId:fallsBackToResultFolder:)`` finds a sample's.
/// Only checks that the folder holds a classification sidecar, so it is cheap enough to call on
/// every selection.
@MainActor
func kraken2SampleResultDirectory(
    resultURL: URL,
    controller: TaxonomyViewController,
    node: TaxonNode
) -> URL? {
    kraken2SampleResultDirectory(resultURL: resultURL, sampleId: controller.owningSampleId(for: node))
}

/// Presents an error alert for a failed BLAST verification request.
func showBlastVerificationErrorAlert(_ errorDescription: String) {
    MainActor.assumeIsolated {
        let alert = NSAlert()
        alert.messageText = "BLAST Verification Failed"
        alert.informativeText = errorDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
    }
}
