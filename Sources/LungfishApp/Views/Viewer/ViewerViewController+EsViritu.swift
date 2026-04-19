// ViewerViewController+EsViritu.swift - EsViritu result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds EsViritu viral detection result display to ViewerViewController,
// following the same child-VC pattern as displayTaxonomyResult / displayFASTACollection.

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
        hideAssemblyView()
        contentMode = .metagenomics

        let controller = EsVirituResultViewController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let esView = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for EsViritu.
        controller.onBlastVerification = { [weak controller] detection, readCount, accessions, bamURL, _ in
            guard let bamURL else {
                controller?.showBlastFailure("BAM file not available for BLAST verification.")
                return
            }

            let selectedReadCount = min(50, max(1, readCount))
            let taxonName = detection.name
            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: ["--virus", taxonName]
            )
            let opID = OperationCenter.shared.start(
                title: "BLAST \(taxonName)",
                detail: "Preparing BLAST verification…",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

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

                    let extractionConfig = BAMRegionExtractionConfig(
                        bamURL: bamURL,
                        regions: accessions,
                        fallbackToAll: false,
                        outputDirectory: tempDir,
                        outputBaseName: "blast_extract",
                        deduplicateReads: true
                    )

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.1,
                                detail: "Extracting reads for selected accessions…"
                            )
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

                    let request = BlastVerificationRequest(
                        taxonName: taxonName,
                        taxId: 0,
                        sequences: subsampled,
                        database: "core_nt",
                        entrezQuery: nil
                    )

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.2,
                                detail: "Submitting \(request.sequences.count) reads to NCBI BLAST…"
                            )
                            blastController?.showBlastLoading(phase: .submitting, requestId: nil)
                        }
                    }

                    let blastResult = try await blastService.verify(
                        request: request,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: fraction,
                                        detail: message
                                    )
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

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "\(blastResult.verifiedCount)/\(blastResult.readResults.count) verified"
                            )
                            blastController?.showBlastResults(blastResult)
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(id: opID, detail: errorDesc)
                            blastController?.showBlastFailure(errorDesc)
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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

    /// Removes the EsViritu result browser and restores normal viewer components.
    public func hideEsVirituView() {
        guard let controller = esVirituViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        esVirituViewController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
