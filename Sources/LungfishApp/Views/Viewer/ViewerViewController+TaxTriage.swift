// ViewerViewController+TaxTriage.swift - TaxTriage result display for ViewerViewController
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds TaxTriage clinical triage result display to ViewerViewController,
// following the same child-VC pattern as displayEsVirituResult / displayTaxonomyResult.

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
        contentMode = .metagenomics

        let controller = TaxTriageResultViewController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        // Force loadView() so all subviews exist, then configure BEFORE adding
        // to the view hierarchy to avoid a one-frame bounce.
        let ttView = controller.view
        controller.configureFromDatabase(db, resultURL: resultURL)

        // Wire BLAST verification callback for TaxTriage.
        controller.onBlastVerification = { [weak controller] organism, readCount, accessions, bamURL, _ in
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
            let taxonName = organism.name
            let blastCliCmd = OperationCenter.buildCLICommand(
                subcommand: "blast verify",
                args: ["--organism", taxonName]
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

                    let tempDir = try ProjectTempDirectory.create(
                        prefix: "taxtriage-blast-",
                        in: ProjectTempDirectory.findProjectRoot(resultURL)
                    )
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    let extractionConfig = BAMRegionExtractionConfig(
                        bamURL: bamURL,
                        regions: orgAccessions,
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
                        taxId: organism.taxId ?? 0,
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

    /// Removes the TaxTriage result browser and restores normal viewer components.
    public func hideTaxTriageView() {
        guard let controller = taxTriageViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        taxTriageViewController = nil

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
