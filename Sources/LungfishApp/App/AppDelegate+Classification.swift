// AppDelegate+Classification.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import SQLite3
import os
import LungfishKit

extension AppDelegate {
    // MARK: - Direct-Launch Classification Methods

    /// Launches Kraken2 classification directly (skipping the wizard chooser step).
    ///
    /// Called from the sidebar's "Run" button when the Classify Reads operation is selected.
    @objc func launchKraken2Classification(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .kraken2)
    }

    /// Launches EsViritu viral detection directly (skipping the wizard chooser step).
    @objc func launchEsVirituDetection(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .esViritu)
    }

    /// Launches TaxTriage comprehensive triage directly (skipping the wizard chooser step).
    @objc func launchTaxTriage(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .taxTriage)
    }

    /// Resolves `inputFiles` to the files a classifier reads, materializing a virtual FASTQ bundle into `tempDirectory`.
    /// `BundleResolutionCLIParityTests` compares its files with the command's. The in-process launches
    /// that called it at the start of a run went in Phase 2.9 (E14), and the Kraken2 resolver after them
    /// in Phase 2.10 (A32). The resolution itself is ``ResolvedSequenceInputs``, shared with the
    /// Map Reads window, with the derivative service's tool runner as the materializer.
    internal func resolveInputFiles(
        _ inputFiles: [URL],
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [URL] {
        try await ResolvedSequenceInputs.resolve(
            inputURLs: inputFiles,
            materializationDirectory: tempDirectory,
            materializer: FASTQCLIMaterializer(runner: FASTQDerivativeService.shared.runner),
            progress: progress
        ).executionInputURLs
    }

    /// Runs the TaxTriage Nextflow pipeline.
    ///
    /// Registers the operation with ``OperationCenter`` and displays the
    /// ``TaxTriageResultViewController`` when complete.
    internal func runTaxTriage(
        config: TaxTriageConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        // TaxTriage pipeline writes its own sample-subdirectory layout, so we just
        // create the batch-style parent directory and point outputDirectory at it.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL else {
            refuseClassifierLaunchWithoutProject(tool: FASTQOperationToolID.taxTriage.title, viewerController: viewerController, routeContext: routeContext)
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "TaxTriage"
        ) else { return }
        var createdTaxTriageDirectory: URL?
        if let batchDir = try? AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL, isBatch: true) {
            config.outputDirectory = batchDir
            createdTaxTriageDirectory = batchDir
        }

        Self.beginTaxTriageOperation(config: config, routeContext: routeContext) { opID in
            let config = config // The detached task cannot capture the mutable local.
            if let createdTaxTriageDirectory { OperationCenter.shared.trackAnalysisOutput(createdTaxTriageDirectory, for: opID) }

            let task = Task.detached { [weak self, makeRunner = TaxTriageLaunchSeam.makeRunner] in
                do {
                    // Materialize each sample's inputs into the result's inputs folder, which keeps them, because
                    // the records name them (O1).
                    let resolvedConfig = try await self?.resolvedTaxTriageConfig(
                        config,
                        tempDirectory: TaxTriageReadSetPlanner.materializationDirectory(in: config.outputDirectory),
                        progress: { message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    // The overlay shows a line only while the row runs (UX inventory T2).
                                    if OperationCenter.shared.update(id: opID, progress: 0, detail: message) { viewerController.showProgress(message) }
                                    OperationCenter.shared.log(id: opID, level: .info, message: message)
                                }
                            }
                        }
                    ) ?? config

                    let runner = makeRunner()
                    let result = try await runner.run(
                        config: resolvedConfig,
                        progress: { progress, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    Self.showTaxTriageProgress(progress, message, for: opID, on: viewerController)
                                }
                            }
                        }
                    )

                    try await Self.completeTaxTriageRun(
                        opID: opID,
                        result: result,
                        config: config,
                        routeContext: routeContext,
                        viewerController: viewerController
                    )
                } catch {
                    let errorDesc = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.hideProgress()
                            guard OperationCenter.shared.fail(id: opID, detail: errorDesc) else { return }

                            let alert = NSAlert()
                            alert.messageText = "TaxTriage Failed"
                            alert.informativeText = errorDesc
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = viewerController.view.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
            }

            OperationCenter.shared.setCancelCallback(for: opID) {
                Self.showTaxTriageCancelling(for: opID, on: viewerController)
                task.cancel()
            }
        }
    }

    /// Shows the database browser for the specified source.
    internal func showDatabaseBrowser(source: DatabaseSource, sender: Any? = nil) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)
        browserController.routeContext = currentOperationRouteContext(for: controller)

        // Dismiss the sheet immediately when a download is kicked off.
        // The download continues in background via DownloadCenter. Bundle
        // import is handled by DownloadCenter.onBundleReady (set in
        // applicationDidFinishLaunching), eliminating the fragile callback
        // chain through the sheet controller.
        browserController.onDownloadStarted = {
            debugLog("onDownloadStarted: Dismissing sheet immediately")
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }

        // Present as sheet
        let browserWindow = NSWindow(contentViewController: browserController)
        browserWindow.title = "Search Online Databases"

        window.beginSheet(browserWindow) { _ in
            debugLog("Sheet dismissed callback executing")
        }
    }

    /// Handles multiple downloaded files with better progress tracking.
    ///
    /// This method processes multiple downloaded files sequentially, showing overall progress
    /// in the activity indicator and refreshing the sidebar once at the end.
    ///
    /// - Parameter tempFileURLs: Array of URLs of downloaded files in the temp directory
    internal func handleMultipleDownloadsSync(_ tempFileURLs: [URL], routeContext: OperationRouteContext? = nil) {
        guard !tempFileURLs.isEmpty else { return }

        debugLog("handleMultipleDownloadsSync: Starting with \(tempFileURLs.count) files")

        // Get UI controllers
        // A context that names its window but not a project still belongs to
        // that window. Falling back to `workingDirectoryURL` instead sent
        // results into whichever project it last pointed at, including a
        // project whose window had been closed.
        let scopedController = mainWindowController(forWindowStateScopeID: routeContext?.windowStateScopeID)
        let targetController = targetMainWindowController(routeContext: routeContext) ?? scopedController
        let workingDirectoryURL = routeContext?.windowStateScopeID == nil ? self.workingDirectoryURL : nil
        let activityIndicator = targetController?.mainSplitViewController?.activityIndicator
        let viewerController = targetController?.mainSplitViewController?.viewerController
        let sidebarController = targetController?.mainSplitViewController?.sidebarController

        let routedProjectURL = routeContext?.projectURL ?? targetController?.projectSession.projectURL
        guard canWriteProjectOutputs(
            projectURL: routedProjectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Downloaded imports",
            presentingWindow: targetController?.window
        ) else {
            return
        }

        let totalCount = tempFileURLs.count
        activityIndicator?.show(message: "Importing \(totalCount) file\(totalCount == 1 ? "" : "s")...", style: .indeterminate)

        // Determine destination directory
        let destinationDirectory: URL
        if let projectURL = routedProjectURL {
            destinationDirectory = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            destinationDirectory = workingURL.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Created only before the first file is written into it. Results that
        // already live in the project (mapping, assembly and every other
        // in-project analysis) are kept in place, and creating the folder up
        // front left an empty Downloads folder in the project after each run.
        var destinationDirectoryReady = false
        func ensureDestinationDirectory() -> Bool {
            if destinationDirectoryReady { return true }
            do {
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                destinationDirectoryReady = true
                return true
            } catch {
                debugLog("handleMultipleDownloadsSync: Failed to create directory - \(error)")
                return false
            }
        }

        var copiedURLs: [URL] = []
        var packagedFASTQPayloads: [String: URL] = [:]

        // Copy all files first
        for (index, tempURL) in tempFileURLs.enumerated() {
            // Keep bundles in place only when they already live in a visible
            // project folder. Project-local staging under `.tmp/` must still be
            // copied into Downloads so the sidebar can surface it.
            let alreadyInProject = DownloadImportRouting.shouldPreserveInPlace(
                downloadedURL: tempURL,
                projectURL: routedProjectURL,
                workingDirectoryURL: workingDirectoryURL
            )

            if alreadyInProject {
                debugLog("handleMultipleDownloadsSync: \(tempURL.lastPathComponent) already in project, skipping copy")
                copiedURLs.append(tempURL)
                continue
            }

            let originalFilename = tempURL.lastPathComponent

            // Build the full compound extension (e.g. "fastq.gz") and true base name
            var strippedURL = tempURL
            var extensionParts: [String] = []
            while !strippedURL.pathExtension.isEmpty {
                extensionParts.insert(strippedURL.pathExtension, at: 0)
                strippedURL = strippedURL.deletingPathExtension()
            }
            let fileExtension = extensionParts.joined(separator: ".")
            var baseName = strippedURL.lastPathComponent

            // Strip the UID suffix from batch downloads (format: "accession_uid.ext" -> "accession.ext")
            // UIDs are numeric, so we look for _digits at the end of the basename.
            // Skip for .lungfishref bundles — their filenames are already clean accessions
            // and accession numbers like NC_045512 contain underscore+digits that would be
            // incorrectly stripped.
            if !extensionParts.contains("lungfishref"),
               !extensionParts.contains(FASTQBundle.directoryExtension),
               !FASTQBundle.isFASTQFileURL(tempURL),
               let underscoreRange = baseName.range(of: "_", options: .backwards) {
                let potentialUID = String(baseName[underscoreRange.upperBound...])
                // Check if everything after the underscore is digits (a UID)
                if !potentialUID.isEmpty && potentialUID.allSatisfy({ $0.isNumber }) {
                    baseName = String(baseName[..<underscoreRange.lowerBound])
                    debugLog("handleMultipleDownloadsSync: Stripped UID from filename, using base: \(baseName)")
                }
            }

            let cleanFilename = "\(baseName).\(fileExtension)"
            activityIndicator?.updateMessage("Copying \(cleanFilename) (\(index + 1)/\(totalCount))...")

            guard ensureDestinationDirectory() else { continue }

            // FASTQ imports are stored as package bundles so the FASTQ payload,
            // index, and metadata always travel together.
            if FASTQBundle.isFASTQFileURL(tempURL) {
                var bundleURL = destinationDirectory.appendingPathComponent(
                    "\(baseName).\(FASTQBundle.directoryExtension)",
                    isDirectory: true
                )
                var bundleCounter = 1
                while FileManager.default.fileExists(atPath: bundleURL.path) {
                    bundleURL = destinationDirectory.appendingPathComponent(
                        "\(baseName)_\(bundleCounter).\(FASTQBundle.directoryExtension)",
                        isDirectory: true
                    )
                    bundleCounter += 1
                }

                do {
                    try FileManager.default.createDirectory(
                        at: bundleURL,
                        withIntermediateDirectories: true
                    )

                    let bundledFASTQURL = bundleURL.appendingPathComponent(cleanFilename)
                    try FileManager.default.copyItem(at: tempURL, to: bundledFASTQURL)
                    debugLog("handleMultipleDownloadsSync: Packaged \(originalFilename) into \(bundleURL.path)")
                    rehydrateCopiedProvenance(from: tempURL, to: bundledFASTQURL)

                    let sourceSidecar = FASTQMetadataStore.metadataURL(for: tempURL)
                    if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                        let destSidecar = FASTQMetadataStore.metadataURL(for: bundledFASTQURL)
                        try? FileManager.default.copyItem(at: sourceSidecar, to: destSidecar)
                        try? FileManager.default.removeItem(at: sourceSidecar)
                    }

                    let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                    if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                        let destFASTQIndex = bundledFASTQURL.appendingPathExtension("fai")
                        try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                        try? FileManager.default.removeItem(at: sourceFASTQIndex)
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                    copiedURLs.append(bundleURL)
                    packagedFASTQPayloads[DownloadImportRouting.canonicalPath(for: bundleURL)] = bundledFASTQURL
                } catch {
                    debugLog("handleMultipleDownloadsSync: Failed to package FASTQ \(originalFilename) - \(error)")
                }
                continue
            }

            // Generate unique filename if needed
            var destinationURL = destinationDirectory.appendingPathComponent(cleanFilename)
            var counter = 1

            while FileManager.default.fileExists(atPath: destinationURL.path) {
                let newFilename = "\(baseName)_\(counter).\(fileExtension)"
                destinationURL = destinationDirectory.appendingPathComponent(newFilename)
                counter += 1
            }

            // Copy file
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                debugLog("handleMultipleDownloadsSync: Copied \(originalFilename) to \(destinationURL.path)")
                rehydrateCopiedProvenance(from: tempURL, to: destinationURL)

                // Copy metadata sidecar if it exists (e.g. SRA/ENA download metadata)
                let sidecarURL = FASTQMetadataStore.metadataURL(for: tempURL)
                if FileManager.default.fileExists(atPath: sidecarURL.path) {
                    let destSidecar = FASTQMetadataStore.metadataURL(for: destinationURL)
                    try? FileManager.default.copyItem(at: sidecarURL, to: destSidecar)
                    try? FileManager.default.removeItem(at: sidecarURL)
                }

                // Copy FASTQ index sidecar when present (e.g. pre-import fqidx output).
                let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                    let destFASTQIndex = destinationURL.appendingPathExtension("fai")
                    try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                    try? FileManager.default.removeItem(at: sourceFASTQIndex)
                }

                try? FileManager.default.removeItem(at: tempURL)
                copiedURLs.append(destinationURL)
            } catch {
                debugLog("handleMultipleDownloadsSync: Failed to copy \(originalFilename) - \(error)")
            }
        }

        // Trigger FASTQ ingestion only for raw FASTQ files this method packaged into
        // new bundles. Existing `.lungfishfastq` bundles are atomic imports; resolving
        // their "primary" FASTQ can point at a representative chunk and mutate/copy
        // only part of an ONT multi-file bundle.
        for url in copiedURLs {
            if let fastqURL = DownloadImportRouting.postCopyFASTQIngestionTarget(
                importedURL: url,
                packagedFASTQPayloads: packagedFASTQPayloads
            ) {
                let existingMeta = FASTQMetadataStore.load(for: fastqURL)
                FASTQIngestionService.ingestIfNeeded(
                    url: fastqURL,
                    existingMetadata: existingMeta,
                    routeContext: routeContext
                )
            }
        }

        // Now load the first file to display (load others in background)
        if let firstURL = copiedURLs.first {
            if firstURL.pathExtension.lowercased() == "lungfishref" ||
                FASTQBundle.resolvePrimaryFASTQURL(for: firstURL) != nil {
                activityIndicator?.hide()
                refreshSidebarAndSelectImportedURL(firstURL, in: targetController)
                debugLog("handleMultipleDownloadsSync: Imported \(copiedURLs.count) bundled item(s)")
                return
            }

            activityIndicator?.updateMessage("Loading \(firstURL.lastPathComponent)...")
            let importedFileCount = copiedURLs.count

            loadFileInBackground(at: firstURL) { result in
                scheduleOnMainRunLoop { [weak activityIndicator, weak viewerController, weak sidebarController] in
                    if result.error == nil {
                        // Create and display the first document
                        let document = LoadedDocument(url: result.url, type: result.type)
                        document.sequences = result.sequences
                        document.annotations = result.annotations
                        DocumentManager.shared.registerDocument(document)
                        viewerController?.displayDocument(document)
                        debugLog("handleMultipleDownloadsSync: Displayed first document '\(document.name)'")
                    }

                    activityIndicator?.hide()

                    // Refresh sidebar to show all new files. The recursive project
                    // scan runs off the main actor; only the cheap apply and the
                    // follow-up selection happen back on it once it returns.
                    // Plain `Task`: `scheduleOnMainRunLoop`'s block is already
                    // @MainActor, so the task inherits that isolation.
                    Task { [weak self, weak sidebarController] in
                        await sidebarController?.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: true)?.value
                        guard let self else { return }

                        // Select the first downloaded file in the sidebar to highlight what's being viewed
                        if result.error == nil {
                            sidebarController?.selectItem(forURL: result.url)
                            self.requestInspectorDocumentModeAfterDownload(in: targetController)
                        }

                        debugLog("handleMultipleDownloadsSync: Completed importing \(importedFileCount) files")
                    }
                }
            }
        } else {
            activityIndicator?.hide()
            sidebarController?.requestReloadFromFilesystem()
        }
    }

    internal func rehydrateCopiedProvenance(from sourceURL: URL, to destinationURL: URL) {
        if GUIImportedProvenanceRehydrator.finalBundleRoot(containing: destinationURL) != nil {
            do {
                try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: sourceURL, to: destinationURL)
            } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
                    debugLog("rehydrateCopiedProvenance: \(message)")
                }
            } catch ProvenanceRehydrationError.missingSourceProvenance {
                debugLog("rehydrateCopiedProvenance: no source provenance for \(sourceURL.path)")
            } catch {
                debugLog("rehydrateCopiedProvenance: failed schema-aware rehydration for \(sourceURL.path): \(error)")
            }
            return
        }

        ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
            debugLog("rehydrateCopiedProvenance: \(message)")
        }
    }
}
