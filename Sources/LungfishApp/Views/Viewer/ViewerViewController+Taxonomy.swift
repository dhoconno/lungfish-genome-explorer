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

/// Logger for taxonomy display operations.
private let taxonomyLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerTaxonomy")

// MARK: - ViewerViewController Taxonomy Display Extension

extension ViewerViewController {

    /// Displays the taxonomy classification browser in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook) and the
    /// normal viewer components, then adds `TaxonomyViewController` as a child
    /// view controller filling the content area.
    ///
    /// Follows the exact same child-VC pattern as ``displayFASTACollection(sequences:annotations:)``.
    /// Read extraction is driven by ``TaxonomyReadExtractionAction.shared.present(...)``,
    /// which the VC fires from its action bar or context menu.
    ///
    /// - Parameter result: The classification result to display.
    public func displayTaxonomyResult(_ result: ClassificationResult) {
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

        let controller = TaxonomyViewController()
        addChild(controller)

        // Hide annotation drawer so it doesn't overlap the taxonomy view.
        // Also hide the FASTQ metadata drawer if present.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let taxView = controller.view
        controller.configure(result: result)
        controller.applyProjectCopyRecord(ProjectItemCopyRecord.load(from: result.config.outputDirectory))
        taxView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taxView)

        NSLayoutConstraint.activate([
            taxView.topAnchor.constraint(equalTo: view.topAnchor),
            taxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            taxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            taxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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

        taxonomyViewController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        taxonomyLogger.info("displayTaxonomyResult: Showing browser with \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")
    }

    /// Displays the taxonomy classification browser backed by a pre-built SQLite database.
    ///
    /// Creates a ``TaxonomyViewController``, adds it as a child filling the content area,
    /// and calls ``TaxonomyViewController/configureFromDatabase(_:)`` to populate it from the
    /// database. It wires BLAST verification and the Collections drawer's Extract to the one
    /// sample the table shows, which the drawer resolves when the user presses Extract (row 69).
    ///
    /// - Parameters:
    ///   - db: The `Kraken2Database` to load rows from.
    ///   - resultURL: The batch result root directory (used for logging).
    func displayTaxonomyFromDatabase(db: Kraken2Database, resultURL: URL) {
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

        let controller = TaxonomyViewController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let taxView = controller.view
        controller.batchURL = resultURL
        controller.configureFromDatabase(db)
        controller.applyProjectCopyRecord(ProjectItemCopyRecord.load(from: resultURL))
        taxView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taxView)

        NSLayoutConstraint.activate([
            taxView.topAnchor.constraint(equalTo: view.topAnchor),
            taxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            taxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            taxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
                let words = "BLAST Matching Reads could not start because LGE could not find this sample's classification record. "
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
                let words = "BLAST Matching Reads could not start because LGE could not read this sample's classification record: "
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

        taxonomyViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

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

    /// Removes the taxonomy classification browser and restores normal viewer components.
    public func hideTaxonomyView() {
        guard let controller = taxonomyViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        taxonomyViewController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
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
    static func taxonomyExtractionAlertWords(for error: Error, sample: String) -> TaxonomyExtractionAlertWords {
        TaxonomyExtractionAlertWords(title: "Taxonomy Extraction Failed", text: error.localizedDescription, style: .warning)
    }
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

        return try await service.buildVerificationRequestFromReadIds(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sources: sources,
            readCount: readCount,
            targetTaxIds: targetTaxIds,
            classificationOutputURL: classificationOutput,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext
        )
    }
    // Slow path: linear scan (index will be built on next classification)
    taxonomyLogger.info("BLAST: no index available, using linear scan")
    return try await service.buildVerificationRequest(
        taxonName: taxonName,
        taxId: taxId,
        targetTaxIds: targetTaxIds,
        classificationOutputURL: classificationOutput,
        sources: sources,
        readCount: readCount,
        acceptedTaxonNames: acceptedTaxonNames,
        taxonomyContext: taxonomyContext
    )
}

/// Operations-panel summary for a finished BLAST verification.
///
/// Uses the same supporting/contradicting counts as the BLAST Results
/// drawer. The old "N/M reads verified" text counted alignment quality only,
/// so it could read "17/20" while the drawer said "0 supporting".
func blastVerificationCompletionDetail(_ result: BlastVerificationResult) -> String {
    let base = "\(result.supportingCount) supporting, \(result.contradictingCount) contradicting of \(result.totalReads) \(result.totalReads == 1 ? "read" : "reads")"
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

/// The result folder of the Kraken 2 sample `sampleId` in a database-backed display: the batch
/// manifest's sample folder, or `resultURL` itself for a single-sample result when
/// `fallsBackToResultFolder` holds. A caller that must act on one named sample passes false for a
/// batch of several, since the batch folder's own sidecar belongs to none of them. Only checks that
/// the folder holds a classification sidecar.
func kraken2SampleResultDirectory(
    resultURL: URL,
    sampleId: String?,
    fallsBackToResultFolder: Bool = true
) -> URL? {
    func hasSidecar(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ClassificationResult.sidecarFilename).path
        )
    }
    if let manifest = MetagenomicsBatchResultStore.loadClassification(from: resultURL),
       let sampleId,
       let sampleRecord = manifest.samples.first(where: { $0.sampleId == sampleId }) {
        let directory = resultURL.appendingPathComponent(sampleRecord.resultDirectory)
        if hasSidecar(directory) { return directory }
    }
    return fallsBackToResultFolder && hasSidecar(resultURL) ? resultURL : nil
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
