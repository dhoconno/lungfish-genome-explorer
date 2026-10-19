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

    /// Displays the EsViritu viral detection browser backed by a SQLite database.
    ///
    /// Creates an ``EsVirituResultViewController``, adds it as a child filling the
    /// content area, and calls ``EsVirituResultViewController/configureFromDatabase(_:)``
    /// to populate it from the database. Follows the same pattern as
    /// ``displayTaxTriageFromDatabase(db:resultURL:)``.
    ///
    /// - Parameters:
    ///   - db: The opened ``EsVirituDatabase`` instance.
    ///   - resultURL: The batch result directory URL (used for logging).
    func displayEsVirituFromDatabase(db: EsVirituDatabase, resultURL: URL) {
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
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let esView = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for EsViritu.
        controller.onBlastVerification = { [weak self, weak controller] detection, readCount, accessions, bamURL, bamIndexURL in
            guard let bamURL else {
                controller?.showBlastFailure("BAM file not available for BLAST verification.")
                return
            }

            let selectedReadCount = min(50, max(1, readCount))
            if ClassifierBlastRouteSettings.currentRoute == .cli {
                self?.launchEsVirituBlastSubmit(
                    detection: detection, readCount: selectedReadCount, accessions: accessions, bamURL: bamURL,
                    bamIndexURL: bamIndexURL, resultURL: resultURL, controller: controller
                )
                return
            }

            // The in-process search, the route before Phase 2.12, kept behind `ClassifierBlastRoute` for one
            // release (C4, U-R1). Its row records no command. Phase 2.13 deletes it with the key.
            ViewerViewController.beginEsVirituBlastVerificationOperation(
                taxonName: detection.name
            ) { opID in
                let blastController = controller
                let task = Task.detached {
                    do {
                        let blastService = BlastService.shared
                        let readService = ReadExtractionService()

                        let contextURL = resultURL
                        let tempDir = try ProjectTempDirectory.create(
                            prefix: "esviritu-blast-",
                            in: ProjectTempDirectory.findProjectRoot(contextURL)
                        )
                        defer { try? FileManager.default.removeItem(at: tempDir) }

                        let extractionConfig = ViewerViewController.classifierBlastExtractionConfig(
                            bamURL: bamURL,
                            indexURL: bamIndexURL,
                            accessions: accessions,
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

                        let request = detection.blastVerificationRequest(sequences: subsampled)

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

        esView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(esView)

        NSLayoutConstraint.activate([
            esView.topAnchor.constraint(equalTo: view.topAnchor),
            esView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            esView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            esView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        esVirituViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

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
        extractReads: @escaping EsVirituBlastReads.Extractor = EsVirituBlastReads.extract
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
        Self.beginEsVirituBlastVerificationOperation(taxonName: detection.name) { opID in
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
                    let plan = try Self.esVirituBlastSubmitPlan(
                        detection: detection, reads: reads, readCount: readCount, accessions: accessions,
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

    /// The search of an EsViritu detection's reads on `blast submit` (2.12 lane 12.08). From `reads`, the
    /// reads of the selected accessions, it draws the subsample the in-process route drew, the mixed
    /// strategy with seed 0, and judges hits on the request `ViralDetection.blastVerificationRequest`
    /// builds, the detection's names with its genus as the relative. The record names the EsViritu result,
    /// the sample, the accessions as the contig and the count and seed of the subsample. The search's
    /// folder sits under the project's `blast-verifications/`, never in the EsViritu result.
    nonisolated static func esVirituBlastSubmitPlan(
        detection: ViralDetection,
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
            request: detection.blastVerificationRequest(sequences: subsampled),
            projectURL: projectURL, sourceResultURL: sourceResultURL, outputParentURL: projectURL,
            contig: accessions.isEmpty ? nil : accessions.joined(separator: ","), sample: detection.sampleId,
            subsampleCount: subsampled.count, subsampleSeed: seed, date: date
        )
    }

    /// Registers the BLAST verification row for an EsViritu detection and, only
    /// when it starts, calls `launch` with the operation ID. The run extracts
    /// reads from the sample's BAM and locks no bundle.
    ///
    /// `cliCommand` is the `lungfish-cli blast submit` command the run executes
    /// (``BlastSubmitPlan/cliCommand``), nil on the in-process route that
    /// ``ClassifierBlastRouteSettings`` keeps for one release.
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

    /// Removes the EsViritu result browser and restores normal viewer components.
    public func hideEsVirituView() {
        guard let controller = esVirituViewController else { return }
        controller.clearClassifierAlignmentEvidence()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        esVirituViewController = nil

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
