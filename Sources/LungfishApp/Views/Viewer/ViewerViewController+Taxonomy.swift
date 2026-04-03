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

/// Logger for taxonomy display operations.
private let taxonomyLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerTaxonomy")

/// Schedules a block on the main run loop using `CFRunLoopPerformBlock`.
///
/// This avoids the cooperative executor scheduling issues described in MEMORY.md
/// and matches the pattern in `ViewerViewController+Extraction.swift`.
private func scheduleTaxonomyOnMainRunLoop(_ block: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        block()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// Writes a small JSON file inside the bundle recording extraction provenance.
///
/// This is separate from the ``PersistedFASTQMetadata`` sidecar because it
/// captures taxonomy-specific information (tax IDs, source classification
/// output, include-children flag) that doesn't fit the generic metadata model.
private func writeTaxonomyExtractionProvenance(
    config: TaxonomyExtractionConfig,
    bundleURL: URL
) {
    let provenance: [String: Any] = [
        "extractionType": "taxonomy",
        "taxIds": config.taxIds.sorted(),
        "includeChildren": config.includeChildren,
        "sourceFile": config.sourceFile.lastPathComponent,
        "classificationOutput": config.classificationOutput.lastPathComponent,
        "extractedAt": ISO8601DateFormatter().string(from: Date()),
    ]

    let provenanceURL = bundleURL.appendingPathComponent("extraction-provenance.json")
    if let data = try? JSONSerialization.data(
        withJSONObject: provenance,
        options: [.prettyPrinted, .sortedKeys]
    ) {
        try? data.write(to: provenanceURL, options: .atomic)
    }
}

// MARK: - ViewerViewController Taxonomy Display Extension

extension ViewerViewController {

    /// Displays the taxonomy classification browser in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook) and the
    /// normal viewer components, then adds `TaxonomyViewController` as a child
    /// view controller filling the content area.
    ///
    /// Wires the ``TaxonomyViewController/onExtractConfirmed`` callback so that
    /// clicking "Extract Sequences" in the extraction sheet runs the
    /// ``TaxonomyExtractionPipeline``, creates a `.lungfishfastq` bundle from the
    /// extracted reads, and refreshes the sidebar.
    ///
    /// Follows the exact same child-VC pattern as ``displayFASTACollection(sequences:annotations:)``.
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
        contentMode = .metagenomics

        let controller = TaxonomyViewController()
        addChild(controller)

        // Hide annotation drawer so it doesn't overlap the taxonomy view.
        // Also hide the FASTQ metadata drawer if present.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let taxView = controller.view
        taxView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taxView)

        NSLayoutConstraint.activate([
            taxView.topAnchor.constraint(equalTo: view.topAnchor),
            taxView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            taxView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            taxView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result)

        // Wire the extraction confirmed callback so "Extract Sequences" actually works.
        //
        // Uses Task.detached because TaxonomyExtractionPipeline is an actor with
        // potentially long-running buffered I/O. Progress and completion hop back
        // to the main thread via scheduleTaxonomyOnMainRunLoop + MainActor.assumeIsolated
        // per project conventions (cooperative executor is unreliable from detached tasks).
        //
        // The detached task does NOT capture `self` at all. All main-thread work
        // uses free functions and NSApp.delegate, matching the pattern in
        // ViewerViewController+Extraction.swift.
        controller.onExtractConfirmed = { config in
            let taxonLabel: String
            if config.taxIds.count == 1 {
                taxonLabel = "taxId \(config.taxIds.first!)"
            } else {
                taxonLabel = "\(config.taxIds.count) taxa"
            }

            // Register the operation in OperationCenter for the operations panel.
            let extractCliCmd: String = {
                var args = ["extract"]
                args += ["--kraken-output", config.classificationOutput.path]
                for taxId in config.taxIds.sorted() {
                    args += ["--taxid", "\(taxId)"]
                }
                if config.includeChildren {
                    args += ["--include-children"]
                }
                if !config.keepReadPairs {
                    args += ["--no-read-pairs"]
                }
                for source in config.sourceFiles {
                    args += ["--source", source.path]
                }
                for output in config.outputFiles {
                    args += ["--output", output.path]
                }
                return OperationCenter.buildCLICommand(subcommand: "conda", args: args)
            }()
            let opID = OperationCenter.shared.start(
                title: "Extract \(taxonLabel)",
                detail: "Preparing\u{2026}",
                operationType: .taxonomyExtraction,
                cliCommand: extractCliCmd
            )

            // Capture the tree from the result for descendant lookup inside the
            // detached task. ClassificationResult.tree is Sendable.
            let tree = result.tree

            let task = Task.detached {
                do {
                    let pipeline = TaxonomyExtractionPipeline()
                    let outputURLs = try await pipeline.extract(
                        config: config,
                        tree: tree,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: fraction,
                                        detail: message
                                    )
                                }
                            }
                        }
                    )

                    // Create a bundle from the extracted reads using ReadExtractionService.
                    let service = ReadExtractionService()
                    let extractionResult = ExtractionResult(
                        fastqURLs: outputURLs,
                        readCount: 0, // actual count tracked by service
                        pairedEnd: config.isPairedEnd
                    )
                    let metadata = ExtractionMetadata(
                        sourceDescription: config.sourceFile.deletingPathExtension().lastPathComponent,
                        toolName: "Kraken2",
                        parameters: [
                            "taxIds": config.taxIds.sorted().map(String.init).joined(separator: ","),
                            "includeChildren": "\(config.includeChildren)",
                        ]
                    )
                    let parentDir = outputURLs[0].deletingLastPathComponent()
                    let bundleURL = try await service.createBundle(
                        from: extractionResult,
                        metadata: metadata,
                        in: parentDir
                    )

                    nonisolated(unsafe) let capturedBundleURL = bundleURL
                    nonisolated(unsafe) let capturedConfig = config
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            writeTaxonomyExtractionProvenance(config: capturedConfig, bundleURL: capturedBundleURL)
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "Extracted to \(capturedBundleURL.lastPathComponent)",
                                bundleURLs: [capturedBundleURL]
                            )
                            if let appDelegate = NSApp.delegate as? AppDelegate {
                                if let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                                    sidebar.reloadFromFilesystem()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        MainActor.assumeIsolated {
                                            _ = sidebar.selectItem(forURL: capturedBundleURL)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: errorDesc
                            )
                            showTaxonomyExtractionErrorAlert(errorDesc)
                        }
                    }
                }
            }

            // Wire cancellation so the operations panel can cancel this task.
            OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
        }


        // Wire batch extraction callback for the taxa collections drawer.
        // When the user clicks "Extract" on a collection, run the batch pipeline
        // using the same Task.detached + OperationCenter pattern.
        controller.onBatchExtract = { collection, classResult in
            let batchExtractCliCmd = "# Batch extraction for collection '\(collection.name)' \u{2014} run individual 'lungfish conda extract' commands per taxon"
            let opID = OperationCenter.shared.start(
                title: "Extract \(collection.name)",
                detail: "Preparing batch extraction\u{2026}",
                operationType: .taxonomyExtraction,
                cliCommand: batchExtractCliCmd
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
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: fraction,
                                        detail: message
                                    )
                                }
                            }
                        }
                    )

                    nonisolated(unsafe) let capturedURLs = outputURLs
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            let count = capturedURLs.count
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "Extracted \(count) taxa from \(collection.name)",
                                bundleURLs: capturedURLs
                            )

                            // Refresh sidebar to pick up new extracted files
                            if let appDelegate = NSApp.delegate as? AppDelegate {
                                if let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                                    sidebar.reloadFromFilesystem()
                                }
                            }
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
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
        let capturedInputFiles = result.config.inputFiles
        let capturedOutputURL = result.outputURL
        let capturedTree = result.tree

        controller.onBlastVerification = { [weak controller] node, readCount in
            nonisolated(unsafe) let weakController = controller
            let blastCliCmd = OperationCenter.buildCLICommand(subcommand: "blast verify", args: [
                "--kreport", capturedOutputURL.path,
                "--taxid", "\(node.taxId)",
            ])
            let opID = OperationCenter.shared.start(
                title: "BLAST \(node.name)",
                detail: "Preparing BLAST verification\u{2026}",
                operationType: .blastVerification,
                cliCommand: blastCliCmd
            )

            let taxId = node.taxId
            let taxonName = node.name
            nonisolated(unsafe) let inputFiles = capturedInputFiles
            nonisolated(unsafe) let classificationOutput = capturedOutputURL
            nonisolated(unsafe) let tree = capturedTree

            let task = Task.detached {
                do {
                    // Guard: source FASTQ must exist for BLAST read extraction
                    guard let sourceURL = inputFiles.first else {
                        throw BlastServiceError.noSequences
                    }
                    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                        taxonomyLogger.error("BLAST: source FASTQ not found at \(sourceURL.path, privacy: .public)")
                        throw BlastServiceError.noSequences
                    }

                    // Build read ID set for this taxon using the indexed
                    // sidecar when available (O(k) vs O(n) linear scan).
                    let pipeline = TaxonomyExtractionPipeline()
                    let targetTaxIds = await pipeline.collectDescendantTaxIds(Set([taxId]), tree: tree)

                    let blastService = BlastService.shared
                    let request: BlastVerificationRequest

                    let indexURL = KrakenIndexDatabase.indexURL(for: classificationOutput)
                    if KrakenIndexDatabase.isValid(at: indexURL, for: classificationOutput) {
                        // Fast path: use indexed lookup
                        let db = try KrakenIndexDatabase(url: indexURL)
                        let matchingReadIds = try db.readIds(forTaxIds: targetTaxIds)
                        db.close()
                        taxonomyLogger.info("BLAST: indexed lookup found \(matchingReadIds.count, privacy: .public) reads for \(targetTaxIds.count, privacy: .public) taxIds")

                        request = try await blastService.buildVerificationRequestFromReadIds(
                            taxonName: taxonName,
                            taxId: taxId,
                            matchingReadIds: matchingReadIds,
                            sourceURL: sourceURL,
                            readCount: readCount
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
                            readCount: readCount
                        )
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: 0.1,
                                detail: "Submitting \(request.sequences.count) reads to NCBI BLAST\u{2026}"
                            )
                            weakController?.showBlastLoading(phase: .submitting, requestId: nil)
                        }
                    }

                    // Submit and wait for results
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
                                        weakController?.showBlastLoading(phase: .waiting, requestId: nil)
                                    } else if lower.contains("parsing") {
                                        weakController?.showBlastLoading(phase: .parsing, requestId: nil)
                                    } else {
                                        weakController?.showBlastLoading(phase: .submitting, requestId: nil)
                                    }
                                }
                            }
                        }
                    )

                    nonisolated(unsafe) let capturedResult = blastResult
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "\(capturedResult.verifiedCount)/\(capturedResult.readResults.count) reads verified"
                            )
                            weakController?.showBlastResults(capturedResult)
                        }
                    }
                } catch {
                    let errorDesc = error.localizedDescription
                    scheduleTaxonomyOnMainRunLoop {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: errorDesc
                            )
                            weakController?.showBlastFailure(message: errorDesc)
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
        annotationDrawerView?.isHidden = false
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
