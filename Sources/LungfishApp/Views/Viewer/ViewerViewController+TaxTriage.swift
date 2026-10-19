// ViewerViewController+TaxTriage.swift - TaxTriage result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds TaxTriage clinical triage result display to ViewerViewController,
// following the same child-VC pattern as displayEsVirituResult / displayTaxonomyResult.

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

    /// Displays the TaxTriage clinical triage browser backed by a pre-built SQLite database.
    ///
    /// Creates a ``TaxTriageResultViewController``, adds it as a child filling the content area,
    /// and calls ``TaxTriageResultViewController/configureFromDatabase(_:)`` to load rows
    /// directly from the database rather than parsing per-sample files.
    ///
    /// - Parameters:
    ///   - db: The opened TaxTriage SQLite database.
    ///   - resultURL: The batch result root directory (used for display context).
    func displayTaxTriageFromDatabase(db: TaxTriageDatabase, resultURL: URL) {
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

        let controller = TaxTriageResultViewController()
        controller.classifierAlignmentViewerFactory = { [weak self] in
            guard let split = self?.parent as? MainSplitViewController else {
                return UnavailableClassifierAlignmentViewer()
            }
            return split.makeClassifierAlignmentEvidenceViewport()
        }
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let ttView = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for TaxTriage.
        controller.onBlastVerification = { [weak self, weak controller] organism, readCount, accessions, bamURL, bamIndexURL in
            guard let bamURL else {
                controller?.showBlastFailure("BAM file not available for BLAST verification.")
                return
            }

            let orgAccessions = accessions ?? []
            guard !orgAccessions.isEmpty else {
                controller?.showBlastFailure("No reference accessions available for BLAST verification.")
                return
            }

            let selectedReadCount = min(50, max(1, readCount))
            if ClassifierBlastRouteSettings.currentRoute == .cli {
                self?.launchTaxTriageBlastSubmit(
                    organism: organism, readCount: selectedReadCount, accessions: orgAccessions, bamURL: bamURL,
                    bamIndexURL: bamIndexURL, resultURL: resultURL, controller: controller
                )
                return
            }

            // The in-process search, the route before Phase 2.12, kept behind `ClassifierBlastRoute` for one
            // release (C4, U-R1). Its row records no command. Phase 2.13 deletes it with the key.
            ViewerViewController.beginTaxTriageBlastVerificationOperation(
                taxonName: organism.name
            ) { opID in
                let blastController = controller
                let task = Task.detached {
                    do {
                        let blastService = BlastService.shared
                        let readService = ReadExtractionService()

                        let tempDir = try ProjectTempDirectory.create(
                            prefix: "taxtriage-blast-",
                            in: ProjectTempDirectory.findProjectRoot(resultURL)
                        )
                        defer { try? FileManager.default.removeItem(at: tempDir) }

                        let extractionConfig = ViewerViewController.classifierBlastExtractionConfig(
                            bamURL: bamURL,
                            indexURL: bamIndexURL,
                            accessions: orgAccessions,
                            outputDirectory: tempDir
                        )

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.update(
                                    id: opID,
                                    progress: 0.1,
                                    detail: "Extracting reads for selected accessions…"
                                ) else { return }
                                blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                            }
                        }

                        let extractionResult = try await readService.extractByBAMRegion(config: extractionConfig)
                        guard let extractedFASTQ = extractionResult.fastqURLs.first else {
                            throw BlastServiceError.noSequences
                        }

                        let reader = FASTQReader(validateSequence: false)
                        var allReads: [(id: String, sequence: String)] = []
                        allReads.reserveCapacity(min(5_000, extractionResult.readCount))
                        for try await record in reader.records(from: extractedFASTQ) {
                            let seq = record.sequence.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !seq.isEmpty else { continue }
                            allReads.append((id: record.identifier, sequence: seq))
                            if allReads.count >= 5_000 { break }
                        }

                        guard !allReads.isEmpty else {
                            throw BlastServiceError.noSequences
                        }

                        let longestCount = min(5, selectedReadCount / 4)
                        let strategy = SubsampleStrategy.mixed(
                            longest: longestCount,
                            random: selectedReadCount - longestCount
                        )
                        let subsampled = blastService.subsampleReads(from: allReads, strategy: strategy)
                        guard !subsampled.isEmpty else {
                            throw BlastServiceError.noSequences
                        }

                        let request = organism.blastVerificationRequest(sequences: subsampled)

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.update(
                                    id: opID,
                                    progress: 0.2,
                                    detail: "Submitting \(request.sequences.count) reads to NCBI BLAST…"
                                ) else { return }
                                blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                            }
                        }

                        let blastResult = try await blastService.verify(
                            request: request,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        guard OperationCenter.shared.update(
                                            id: opID,
                                            progress: fraction,
                                            detail: message
                                        ) else { return }
                                        let lower = message.lowercased()
                                        if lower.contains("waiting") {
                                            blastController?.showBlastLoading(phase: .waiting, requestId: nil)
                                        } else if lower.contains("parsing") {
                                            blastController?.showBlastLoading(phase: .parsing, requestId: nil)
                                        } else {
                                            blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                                        }
                                    }
                                }
                            }
                        )

                        try FileManager.default.removeItem(at: tempDir)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.complete(
                                    id: opID,
                                    detail: "\(blastResult.verifiedCount)/\(blastResult.readResults.count) verified"
                                ) else { return }
                                blastController?.showBlastResults(blastResult, recordURL: nil) // The in-process route saves no file (ARCH T5), and 13.03 deletes it.
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.fail(id: opID, detail: errorDesc) else { return }
                                blastController?.showBlastFailure(errorDesc)
                            }
                        }
                    }
                }

                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            }
        }
        controller.onExtractReadsRequested = { [weak controller] tool, resultPath, selectors, suggestedName in
            guard let controller else { return }
            controller.presentClassifierExtractionDialog(tool: tool, resultPath: resultPath, selectors: selectors, suggestedName: suggestedName)
        }
        ttView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ttView)

        NSLayoutConstraint.activate([
            ttView.topAnchor.constraint(equalTo: view.topAnchor),
            ttView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ttView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ttView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        taxTriageViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

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
    /// `runner` and `extractReads` are seams for tests. The result is the task that extracts and launches,
    /// nil when no row began.
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
        extractReads: @escaping TaxTriageBlastReads.Extractor = TaxTriageBlastReads.extract
    ) -> Task<Void, Never>? {
        let window = view.window
        guard let projectURL = blastSubmitProjectURL() ?? ProjectTempDirectory.findProjectRoot(resultURL) else {
            Self.refuseBlastWithoutProject(window: window)
            return nil
        }
        let drawer = drawer ?? BlastSubmitDrawer(
            loading: { controller?.showBlastLoading(phase: $0, requestId: nil) },
            results: { controller?.showBlastResults($0, recordURL: $1) },
            failure: { controller?.showBlastFailure($0) }
        )
        var extraction: Task<Void, Never>?
        // 1. The row begins with no command. 2. The reads are extracted. 3. The row takes the plan's command.
        Self.beginTaxTriageBlastVerificationOperation(taxonName: organism.name) { opID in
            drawer.loading(.submitting)
            OperationCenter.shared.update(id: opID, progress: 0.1, detail: "Extracting reads for selected accessions…")
            let task = Task { @MainActor in
                do {
                    let reads = try await extractReads(bamURL, bamIndexURL, accessions, projectURL)
                    // A Cancel moves the row to cancelling at once but stops this task a moment later, so the
                    // row is asked as well as the task.
                    try Task.checkCancellation()
                    guard OperationCenter.shared.items.first(where: { $0.id == opID })?.state == .running else {
                        throw CancellationError()
                    }
                    let plan = try Self.taxTriageBlastSubmitPlan(
                        organism: organism, reads: reads, readCount: readCount, accessions: accessions,
                        projectURL: projectURL, sourceResultURL: resultURL
                    )
                    OperationCenter.shared.setCommand(id: opID, command: plan.cliCommand)
                    // No await sits between the checks above and the cancel callback this call replaces.
                    Self.launchBlastSubmit(plan, operationID: opID, runner: runner, drawer: drawer) {
                        "\($0.verifiedCount)/\($0.readResults.count) verified"
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
    /// builds, the organism's own tax ID and name with no relatives. The record names the TaxTriage result,
    /// the organism's tax ID, the accessions as the contig, the organism's sample when it names one and the
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
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        guard !reads.isEmpty else { throw BlastServiceError.noSequences }
        let longestCount = min(5, readCount / 4)
        let seed: UInt64 = 0
        let subsampled = BlastService(environment: [:]).subsampleReads(
            from: reads, strategy: .mixed(longest: longestCount, random: readCount - longestCount), seed: seed
        )
        return try BlastSubmitPlan.make(
            request: organism.blastVerificationRequest(sequences: subsampled),
            projectURL: projectURL, sourceResultURL: sourceResultURL, outputParentURL: projectURL,
            contig: accessions.isEmpty ? nil : accessions.joined(separator: ","), sample: organism.sample,
            subsampleCount: subsampled.count, subsampleSeed: seed, date: date
        )
    }

    /// Registers the BLAST verification row for a TaxTriage organism and, only
    /// when it starts, calls `launch` with the operation ID. The run extracts
    /// reads from the sample's BAM and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``), nil on the in-process route that
    /// ``ClassifierBlastRouteSettings`` keeps for one release and on the row
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

    /// Removes the TaxTriage result browser and restores normal viewer components.
    public func hideTaxTriageView() {
        guard let controller = taxTriageViewController else { return }
        controller.clearClassifierAlignmentEvidence()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        taxTriageViewController = nil

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
