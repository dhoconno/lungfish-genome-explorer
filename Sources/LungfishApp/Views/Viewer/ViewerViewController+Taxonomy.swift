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
            let batchExtractCliCmd = "# Taxonomy Read Extraction workflow for collection '\(collection.name)' (batch pipeline; see output provenance for replay details)"
            let opID = OperationCenter.shared.start(
                title: "Extract \(collection.name)",
                detail: "Preparing batch extraction\u{2026}",
                operationType: .taxonomyExtraction,
                cliCommand: batchExtractCliCmd,
                routeContext: routeContext
            )

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

        // Wire BLAST verification callback.
        // When user clicks "Run BLAST" in the config popover, submit to NCBI BLAST.
        let capturedSource = try? ClassifierReadResolver.resolveKraken2PrimarySource(classResult: result)
        let capturedOutputURL = result.outputURL
        let capturedTree = result.tree
        let capturedResultDirectory = result.config.outputDirectory

        // Saved verifications live in the result folder and come back when
        // the result is reopened and the taxon is selected.
        controller.blastVerificationDirectoryResolver = { _ in capturedResultDirectory }

        controller.onBlastVerification = { [weak controller] node, readCount in
            let blastRunID = controller?.beginBlastVerification(for: node)
            let weakController = controller
            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: blastVerifyCLIArguments(
                    classResult: result,
                    sourceURL: capturedSource,
                    taxId: node.taxId,
                    readCount: readCount
                )
            )
            let opID = OperationCenter.shared.start(
                title: "BLAST \(node.name)",
                detail: "Preparing BLAST verification\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )
            // WFL-12: the drawer's own Cancel button reads this to actually
            // cancel the run, rather than only logging.
            controller?.currentBlastOperationID = opID

            let taxId = node.taxId
            let taxonName = node.name
            let resolvedSource = capturedSource
            let classificationOutput = capturedOutputURL
            let tree = capturedTree
            let resultDirectory = capturedResultDirectory
            let startedAt = Date()


            let task = Task.detached {
                do {
                    // Guard: source FASTQ must exist for BLAST read extraction
                    guard let sourceURL = resolvedSource else {
                        taxonomyLogger.error("BLAST: could not resolve a source FASTQ for this classification")
                        throw BlastServiceError.noSequences
                    }
                    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                        taxonomyLogger.error("BLAST: source FASTQ not found at \(sourceURL.path, privacy: .public)")
                        throw BlastServiceError.noSequences
                    }

                    // Build read ID set for this taxon using the indexed
                    // sidecar when available (O(k) vs O(n) linear scan).
                    // Clade (sampling targets and supporting hits) plus the
                    // genus relatives the tree knows about.
                    let taxonomyContext = tree.blastTaxonomyContext(for: taxId)
                    let targetTaxIds = taxonomyContext.cladeTaxIds
                    let acceptedTaxonNames = taxonomyContext.cladeNames

                    let blastService = BlastService.shared
                    let request: BlastVerificationRequest

                    let indexURL = KrakenIndexDatabase.indexURL(for: classificationOutput)
                    if let db = try? KrakenIndexDatabase(url: indexURL),
                       db.canResolve(taxIds: targetTaxIds) {
                        // Fast path: use indexed lookup
                        let matchingReadIds = try db.readIds(forTaxIds: targetTaxIds)
                        db.close()
                        taxonomyLogger.info("BLAST: indexed lookup found \(matchingReadIds.count, privacy: .public) reads for \(targetTaxIds.count, privacy: .public) taxIds")

                        request = try await blastService.buildVerificationRequestFromReadIds(
                            taxonName: taxonName,
                            taxId: taxId,
                            matchingReadIds: matchingReadIds,
                            sourceURL: sourceURL,
                            readCount: readCount,
                            targetTaxIds: targetTaxIds,
                            classificationOutputURL: classificationOutput,
                            acceptedTaxonNames: acceptedTaxonNames,
                            taxonomyContext: taxonomyContext
                        )
                    } else {
                        // Slow path: linear scan (index will be built on next classification)
                        taxonomyLogger.info("BLAST: no index available, using linear scan")
                        request = try await blastService.buildVerificationRequest(
                            taxonName: taxonName,
                            taxId: taxId,
                            targetTaxIds: targetTaxIds,
                            classificationOutputURL: classificationOutput,
                            sourceURL: sourceURL,
                            readCount: readCount,
                            acceptedTaxonNames: acceptedTaxonNames,
                            taxonomyContext: taxonomyContext
                        )
                    }

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
                        sourceURL: sourceURL,
                        readCount: readCount,
                        startedAt: startedAt
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
            let blastRunID = controller.beginBlastVerification(for: node)
            guard let sampleDirectory = kraken2SampleResultDirectory(resultURL: resultURL, controller: controller, node: node),
                  let sampleResult = try? ClassificationResult.load(from: sampleDirectory) else {
                taxonomyLogger.warning("BLAST: failed to resolve a Kraken2 classification sidecar for \(resultURL.path, privacy: .public)")
                return
            }
            let startedAt = Date()

            let weakController = controller
            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: blastVerifyCLIArguments(
                    classResult: sampleResult,
                    sourceURL: try? ClassifierReadResolver.resolveKraken2PrimarySource(classResult: sampleResult),
                    taxId: node.taxId,
                    readCount: readCount
                )
            )
            let opID = OperationCenter.shared.start(
                title: "BLAST \(node.name)",
                detail: "Preparing BLAST verification\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )
            // WFL-12: the drawer's own Cancel button reads this to actually
            // cancel the run, rather than only logging.
            controller.currentBlastOperationID = opID

            let taxId = node.taxId
            let taxonName = node.name
            let resolvedSource = try? ClassifierReadResolver.resolveKraken2PrimarySource(
                classResult: sampleResult
            )
            let classificationOutput = sampleResult.outputURL
            let tree = sampleResult.tree

            let task = Task.detached {
                do {
                    guard let sourceURL = resolvedSource else {
                        taxonomyLogger.error("BLAST: could not resolve a source FASTQ for the selected sample")
                        throw BlastServiceError.noSequences
                    }
                    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                        taxonomyLogger.error("BLAST: source FASTQ not found at \(sourceURL.path, privacy: .public)")
                        throw BlastServiceError.noSequences
                    }

                    // Clade (sampling targets and supporting hits) plus the
                    // genus relatives the tree knows about.
                    let taxonomyContext = tree.blastTaxonomyContext(for: taxId)
                    let targetTaxIds = taxonomyContext.cladeTaxIds
                    let acceptedTaxonNames = taxonomyContext.cladeNames

                    let blastService = BlastService.shared
                    let request: BlastVerificationRequest

                    let indexURL = KrakenIndexDatabase.indexURL(for: classificationOutput)
                    if let db = try? KrakenIndexDatabase(url: indexURL),
                       db.canResolve(taxIds: targetTaxIds) {
                        let matchingReadIds = try db.readIds(forTaxIds: targetTaxIds)
                        db.close()
                        request = try await blastService.buildVerificationRequestFromReadIds(
                            taxonName: taxonName,
                            taxId: taxId,
                            matchingReadIds: matchingReadIds,
                            sourceURL: sourceURL,
                            readCount: readCount,
                            targetTaxIds: targetTaxIds,
                            classificationOutputURL: classificationOutput,
                            acceptedTaxonNames: acceptedTaxonNames,
                            taxonomyContext: taxonomyContext
                        )
                    } else {
                        request = try await blastService.buildVerificationRequest(
                            taxonName: taxonName,
                            taxId: taxId,
                            targetTaxIds: targetTaxIds,
                            classificationOutputURL: classificationOutput,
                            sourceURL: sourceURL,
                            readCount: readCount,
                            acceptedTaxonNames: acceptedTaxonNames,
                            taxonomyContext: taxonomyContext
                        )
                    }

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
                        sourceURL: sourceURL,
                        readCount: readCount,
                        startedAt: startedAt
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

        taxonomyViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        taxonomyLogger.info("displayTaxonomyFromDatabase: Showing DB-backed browser for '\(resultURL.lastPathComponent, privacy: .public)'")
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

/// Presents an error alert for a failed BLAST verification request.
/// Arguments for the `lungfish-cli blast verify` command that reproduces an
/// in-app BLAST verification. The app always includes descendant taxa.
func blastVerifyCLIArguments(
    classResult: ClassificationResult,
    sourceURL: URL?,
    taxId: Int,
    readCount: Int
) -> [String] {
    var args = [
        "--kreport", classResult.reportURL.path,
        "--kraken-output", classResult.outputURL.path,
    ]
    if let sourceURL {
        args += ["--source", sourceURL.path]
    }
    args += ["--taxid", "\(taxId)", "--include-children", "--reads", "\(readCount)"]
    return args
}

/// Operations-panel summary for a finished BLAST verification.
///
/// Uses the same supporting/contradicting counts as the BLAST Results
/// drawer. The old "N/M reads verified" text counted alignment quality only,
/// so it could read "17/20" while the drawer said "0 supporting".
func blastVerificationCompletionDetail(_ result: BlastVerificationResult) -> String {
    let base = "\(result.supportingCount) supporting, \(result.contradictingCount) contradicting of \(result.totalReads) reads"
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
    sourceURL: URL,
    readCount: Int,
    startedAt: Date
) {
    let argv = [CLICommandIdentity.executableName, "blast", "verify"]
        + blastVerifyCLIArguments(
            classResult: classResult,
            sourceURL: sourceURL,
            taxId: result.taxId,
            readCount: readCount
        )
        + ["--result-dir", resultDirectory.path]
    do {
        try BlastVerificationArchive.save(
            result,
            request: request,
            in: resultDirectory,
            sourceURLs: [classResult.reportURL],
            argv: argv,
            startedAt: startedAt
        )
    } catch {
        taxonomyLogger.warning("BLAST: could not save the verification to \(resultDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}

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
