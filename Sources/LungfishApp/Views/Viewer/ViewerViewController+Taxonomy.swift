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

/// Schedules a block on the main run loop using `CFRunLoopPerformBlock`.
///
/// This avoids cooperative executor scheduling stalls while preserving the
/// run-loop handoff pattern used by `ViewerViewController+Extraction.swift`.
private func scheduleTaxonomyOnMainRunLoop(_ block: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        block()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

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

        // Wire batch extraction callback for the taxa collections drawer.
        // When the user clicks "Extract" on a collection, run the batch pipeline
        // using the same Task.detached + OperationCenter pattern.
        controller.onBatchExtract = { [weak self] collection, classResult in
            guard let self else { return }
            let routeContext = OperationRouteContext(
                projectURL: ProjectTempDirectory.findProjectRoot(classResult.outputURL),
                windowStateScope: self.windowStateScope
            )
            ViewerViewController.beginTaxaCollectionExtractionOperation(
                collection: collection,
                routeContext: routeContext
            ) { opID in
                let tree = classResult.tree
                let outputDir = classResult.config.outputDirectory
                    .appendingPathComponent("extracted-\(collection.id)")

                let task = Task.detached {
                    do {
                        let pipeline = TaxonomyExtractionPipeline()
                        let outputURLs = try await pipeline.extractBatch(
                            collection: collection,
                            classificationResult: classResult,
                            tree: tree,
                            outputDirectory: outputDir,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        _ = OperationCenter.shared.update(
                                            id: opID,
                                            progress: fraction,
                                            detail: message
                                        )
                                    }
                                }
                            }
                        )

                        let capturedURLs = outputURLs
                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                let count = capturedURLs.count
                                _ = OperationCenter.shared.complete(
                                    id: opID,
                                    detail: "Extracted \(count) taxa from \(collection.name)",
                                    bundleURLs: capturedURLs
                                )

                                // Refresh sidebar to pick up new extracted files
                                if let sidebar = (self.parent as? MainSplitViewController)?.sidebarController {
                                    sidebar.requestReloadFromFilesystem()
                                }
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                _ = OperationCenter.shared.fail(
                                    id: opID,
                                    detail: errorDesc
                                )
                                showTaxonomyExtractionErrorAlert(errorDesc)
                            }
                        }
                    }
                }

                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            }
        }

        // Wire BLAST verification callback.
        // When user clicks "Run BLAST" in the config popover, submit to NCBI BLAST.
        // The inputs the classification recorded. The row's command names
        // each with one --source, and the run reads their files (D8).
        let capturedInputs = (try? KrakenResultReadSources.recordedInputs(of: result)) ?? []
        let capturedOutputURL = result.outputURL
        let capturedTree = result.tree
        let capturedResultDirectory = result.config.outputDirectory

        // Saved verifications live in the result folder and come back when
        // the result is reopened and the taxon is selected.
        controller.blastVerificationDirectoryResolver = { _ in capturedResultDirectory }

        controller.onBlastVerification = { [weak controller] node, readCount in
            ViewerViewController.beginKraken2BlastVerificationOperation(
                taxonName: node.name,
                classResult: result,
                sourceInputs: capturedInputs,
                taxId: node.taxId,
                readCount: readCount,
                resultDirectory: capturedResultDirectory
            ) { opID in
                let blastRunID = controller?.beginBlastVerification(for: node)
                let weakController = controller
                // The drawer's own Cancel button reads this to actually
                // cancel the run, rather than only logging.
                controller?.currentBlastOperationID = opID

                let taxId = node.taxId
                let taxonName = node.name
                let sourceInputs = capturedInputs
                let classificationOutput = capturedOutputURL
                let tree = capturedTree
                let resultDirectory = capturedResultDirectory
                let runClock = ProvenanceRunClock()


                let task = Task.detached {
                    do {
                        let blastService = BlastService.shared
                        let request = try await kraken2BlastVerificationRequest(
                            taxonName: taxonName,
                            taxId: taxId,
                            tree: tree,
                            classificationOutput: classificationOutput,
                            sourceInputs: sourceInputs,
                            readCount: readCount,
                            service: blastService
                        )

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.updateWithLog(
                                    id: opID,
                                    progress: 0.1,
                                    detail: "Submitting \(request.sequences.count) reads to NCBI BLAST\u{2026}"
                                ) else { return }
                                weakController?.showBlastLoading(phase: .submitting, requestId: nil, runID: blastRunID)
                            }
                        }

                        // Submit and wait for results
                        let blastResult = try await blastService.verify(
                            request: request,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        guard OperationCenter.shared.updateWithLog(
                                            id: opID,
                                            progress: fraction,
                                            detail: message
                                        ) else { return }
                                        let lower = message.lowercased()
                                        if lower.contains("waiting") {
                                            weakController?.showBlastLoading(phase: .waiting, requestId: nil, runID: blastRunID)
                                        } else if lower.contains("parsing") {
                                            weakController?.showBlastLoading(phase: .parsing, requestId: nil, runID: blastRunID)
                                        } else {
                                            weakController?.showBlastLoading(phase: .submitting, requestId: nil, runID: blastRunID)
                                        }
                                    }
                                }
                            }
                        )

                        saveBlastVerification(
                            blastResult,
                            request: request,
                            resultDirectory: resultDirectory,
                            classResult: result,
                            sourceInputs: sourceInputs,
                            readCount: readCount,
                            runClock: runClock
                        )

                        let capturedResult = blastResult
                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.complete(
                                    id: opID,
                                    detail: blastVerificationCompletionDetail(capturedResult)
                                ) else { return }
                                weakController?.showBlastResults(capturedResult, runID: blastRunID)
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.fail(
                                    id: opID,
                                    detail: errorDesc
                                ) else { return }
                                weakController?.showBlastFailure(message: errorDesc, runID: blastRunID)
                                showBlastVerificationErrorAlert(errorDesc)
                            }
                        }
                    }
                }

                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            }
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
    /// database. Does NOT wire extraction or BLAST callbacks because batch/DB mode uses
    /// the flat aggregated table, not the per-sample tree.
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

        // Wire BLAST verification for DB-backed batch display by resolving the
        // currently displayed sample's sidecar result from the batch manifest.
        // Single-sample DB-backed results have no batch manifest, so fall back
        // to loading `classification-result.json` directly from `resultURL`.
        controller.blastVerificationDirectoryResolver = { [weak controller] node in
            guard let controller else { return nil }
            return kraken2SampleResultDirectory(resultURL: resultURL, controller: controller, node: node)
        }

        controller.onBlastVerification = { [weak controller] node, readCount in
            guard let controller else { return }
            guard let sampleDirectory = kraken2SampleResultDirectory(resultURL: resultURL, controller: controller, node: node),
                  let sampleResult = try? ClassificationResult.load(from: sampleDirectory) else {
                taxonomyLogger.warning("BLAST: failed to resolve a Kraken2 classification sidecar for \(resultURL.path, privacy: .public)")
                return
            }
            let runClock = ProvenanceRunClock()
            let sourceInputs = (try? KrakenResultReadSources.recordedInputs(of: sampleResult)) ?? []

            ViewerViewController.beginKraken2BlastVerificationOperation(
                taxonName: node.name,
                classResult: sampleResult,
                sourceInputs: sourceInputs,
                taxId: node.taxId,
                readCount: readCount,
                resultDirectory: sampleDirectory
            ) { opID in
                let blastRunID = controller.beginBlastVerification(for: node)
                let weakController = controller
                // The drawer's own Cancel button reads this to actually
                // cancel the run, rather than only logging.
                controller.currentBlastOperationID = opID

                let taxId = node.taxId
                let taxonName = node.name
                let classificationOutput = sampleResult.outputURL
                let tree = sampleResult.tree

                let task = Task.detached {
                    do {
                        let blastService = BlastService.shared
                        let request = try await kraken2BlastVerificationRequest(
                            taxonName: taxonName,
                            taxId: taxId,
                            tree: tree,
                            classificationOutput: classificationOutput,
                            sourceInputs: sourceInputs,
                            readCount: readCount,
                            service: blastService
                        )

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.updateWithLog(
                                    id: opID,
                                    progress: 0.1,
                                    detail: "Submitting \(request.sequences.count) reads to NCBI BLAST\u{2026}"
                                ) else { return }
                                weakController.showBlastLoading(phase: .submitting, requestId: nil, runID: blastRunID)
                            }
                        }

                        let blastResult = try await blastService.verify(
                            request: request,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        guard OperationCenter.shared.updateWithLog(
                                            id: opID,
                                            progress: fraction,
                                            detail: message
                                        ) else { return }
                                        let lower = message.lowercased()
                                        if lower.contains("waiting") {
                                            weakController.showBlastLoading(phase: .waiting, requestId: nil, runID: blastRunID)
                                        } else if lower.contains("parsing") {
                                            weakController.showBlastLoading(phase: .parsing, requestId: nil, runID: blastRunID)
                                        } else {
                                            weakController.showBlastLoading(phase: .submitting, requestId: nil, runID: blastRunID)
                                        }
                                    }
                                }
                            }
                        )

                        saveBlastVerification(
                            blastResult,
                            request: request,
                            resultDirectory: sampleDirectory,
                            classResult: sampleResult,
                            sourceInputs: sourceInputs,
                            readCount: readCount,
                            runClock: runClock
                        )

                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.complete(
                                    id: opID,
                                    detail: blastVerificationCompletionDetail(blastResult)
                                ) else { return }
                                weakController.showBlastResults(blastResult, runID: blastRunID)
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        scheduleTaxonomyOnMainRunLoop {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.fail(id: opID, detail: errorDesc) else { return }
                                weakController.showBlastFailure(message: errorDesc, runID: blastRunID)
                                showBlastVerificationErrorAlert(errorDesc)
                            }
                        }
                    }
                }

                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            }
        }

        taxonomyViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        taxonomyLogger.info("displayTaxonomyFromDatabase: Showing DB-backed browser for '\(resultURL.lastPathComponent, privacy: .public)'")
    }

    /// Registers the batch-extraction row for a taxa collection and, only when
    /// it starts, calls `launch` with the operation ID. The run writes into
    /// the classification folder and locks no bundle.
    ///
    /// cli-parity-gap: taxa-collection-extraction. No `lungfish-cli` command
    /// extracts a whole collection. The closest is `lungfish-cli conda
    /// extract`, run once per taxon. The row records no command until a CLI
    /// command covers the batch.
    @discardableResult
    static func beginTaxaCollectionExtractionOperation(
        collection: TaxaCollection,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract \(collection.name)",
            detail: "Preparing batch extraction\u{2026}",
            operationType: .taxonomyExtraction,
            cliCommand: nil,
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
    /// when it starts, calls `launch` with the operation ID. The row records
    /// the `lungfish-cli blast verify` command for the same inputs, one
    /// `--source` for each of `sourceInputs`, including the `--result-dir`
    /// the app saves the verification into. It locks no bundle.
    @discardableResult
    static func beginKraken2BlastVerificationOperation(
        taxonName: String,
        classResult: ClassificationResult,
        sourceInputs: [URL],
        taxId: Int,
        readCount: Int,
        resultDirectory: URL,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "BLAST \(taxonName)",
            detail: "Preparing BLAST verification\u{2026}",
            operationType: .blastVerification,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: blastVerifyCLIArguments(
                    classResult: classResult,
                    sourceInputs: sourceInputs,
                    taxId: taxId,
                    readCount: readCount,
                    resultDirectory: resultDirectory
                )
            )
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

/// Presents an error alert for a failed taxonomy extraction.
///
/// Uses `beginSheetModal` per macOS 26 conventions (never `runModal()`).
/// Accesses the window via `NSApp` to avoid capturing `self`.
private func showTaxonomyExtractionErrorAlert(_ errorDescription: String) {
    MainActor.assumeIsolated {
        let alert = NSAlert()
        alert.messageText = "Taxonomy Extraction Failed"
        alert.informativeText = errorDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
    }
}

/// Arguments for the `lungfish-cli blast verify` command that reproduces an
/// in-app BLAST verification. The app always includes descendant taxa, and
/// it saves the verification under `<resultDirectory>/blast-verifications/`,
/// which `--result-dir` reproduces. Each input the classification recorded
/// is one `--source`, which the CLI resolves to the read files the app reads
/// (D8).
func blastVerifyCLIArguments(
    classResult: ClassificationResult,
    sourceInputs: [URL],
    taxId: Int,
    readCount: Int,
    resultDirectory: URL
) -> [String] {
    var args = [
        "--kreport", classResult.reportURL.path,
        "--kraken-output", classResult.outputURL.path,
    ]
    for input in sourceInputs {
        args += ["--source", input.path]
    }
    args += ["--taxid", "\(taxId)", "--include-children", "--reads", "\(readCount)"]
    args += ["--result-dir", resultDirectory.path]
    return args
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
/// database-backed display: the batch manifest's sample folder, or
/// `resultURL` itself for a single-sample result. Only checks that the
/// folder holds a classification sidecar, so it is cheap enough to call on
/// every selection.
@MainActor
func kraken2SampleResultDirectory(
    resultURL: URL,
    controller: TaxonomyViewController,
    node: TaxonNode
) -> URL? {
    func hasSidecar(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ClassificationResult.sidecarFilename).path
        )
    }
    if let manifest = MetagenomicsBatchResultStore.loadClassification(from: resultURL),
       let sampleId = controller.owningSampleId(for: node),
       let sampleRecord = manifest.samples.first(where: { $0.sampleId == sampleId }) {
        let directory = resultURL.appendingPathComponent(sampleRecord.resultDirectory)
        if hasSidecar(directory) { return directory }
    }
    return hasSidecar(resultURL) ? resultURL : nil
}

/// Saves a finished verification into `<resultDirectory>/blast-verifications/`
/// with a provenance sidecar. A failure is logged and never fails the run.
func saveBlastVerification(
    _ result: BlastVerificationResult,
    request: BlastVerificationRequest,
    resultDirectory: URL,
    classResult: ClassificationResult,
    sourceInputs: [URL],
    readCount: Int,
    runClock: ProvenanceRunClock
) {
    let argv = [CLICommandIdentity.executableName, "blast", "verify"]
        + blastVerifyCLIArguments(
            classResult: classResult,
            sourceInputs: sourceInputs,
            taxId: result.taxId,
            readCount: readCount,
            resultDirectory: resultDirectory
        )
    do {
        try BlastVerificationArchive.save(
            result,
            request: request,
            in: resultDirectory,
            sourceURLs: [classResult.reportURL],
            argv: argv,
            runClock: runClock
        )
    } catch {
        taxonomyLogger.warning("BLAST: could not save the verification to \(resultDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}

/// Presents an error alert for a failed BLAST verification request.
private func showBlastVerificationErrorAlert(_ errorDescription: String) {
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
