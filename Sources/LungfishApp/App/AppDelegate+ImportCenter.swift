// AppDelegate+ImportCenter.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
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
    // MARK: - Import Center URL-Accepting Methods

    /// Import a BAM file from a known URL (called from Import Center).
    ///
    /// Returns the started operation's id, or `nil` if the import was refused (no bundle
    /// open, or another operation already holds the bundle's write lock). A multi-file
    /// dispatch (`ImportCenterViewModel.dispatchFileImport`) awaits this id with
    /// `MainSplitViewController.pollUntilOperationTerminal(id:)` before starting the next
    /// file, so only the first of several BAMs no longer silently wins the lock race.
    @discardableResult
    func importBAMFromURL(_ url: URL) -> UUID? {
        guard let originController = activeMainWindowController(),
              let bundleURL = currentReferenceBundleURL(in: originController) else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing alignments.")
            return nil
        }
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "BAM import",
            presentingWindow: originController.window
        ) else { return nil }
        return performBAMImport(
            bamURL: url,
            bundleURL: bundleURL,
            routeContext: currentOperationRouteContext(for: originController)
        )
    }

    /// Import a VCF file from a known URL (called from Import Center). See
    /// `importBAMFromURL`'s doc comment.
    @discardableResult
    func importVCFFromURL(_ url: URL) -> UUID? {
        guard let originController = activeMainWindowController(),
              let originSplit = originController.mainSplitViewController else {
            showAlert(title: "No Project Open", message: "Please open a project before importing variants.")
            return nil
        }
        // `currentBundleURL` is nil for a `.browse`-mode reference bundle and for a
        // mapping result, which sent every such VCF to a new variant-only bundle at
        // the project root instead of attaching it to the displayed bundle.
        let bundleURL = currentReferenceBundleURL(in: originController)
        if let bundleURL {
            guard canWriteProjectOutputs(
                projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
                windowStateScope: originController.projectSession.windowStateScope,
                workflowName: "VCF import",
                presentingWindow: originController.window
            ) else { return nil }
            return performVCFImport(
                vcfURL: url,
                bundleURL: bundleURL,
                routeContext: currentOperationRouteContext(for: originController)
            )
        } else {
            originSplit.loadVCFFilesInBackground(urls: [url])
            return nil
        }
    }

    /// Import an ONT run directory from a known URL (called from Import Center).
    func importONTRunFromURL(_ url: URL) {
        guard let originController = activeMainWindowController(),
              let originSplit = originController.mainSplitViewController,
              let projectURL = originController.projectSession.projectURL
                ?? originSplit.sidebarController.currentProjectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open or create a project before importing an ONT run.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "ONT run import",
            presentingWindow: originController.window
        ) else { return }
        originSplit.importONTDirectoryInBackground(
            sourceURL: url,
            projectURL: projectURL
        )
    }

    /// Import a reference FASTA file from a known URL (called from Import Center).
    /// Import FASTQ files from known URLs (called from Import Center).
    ///
    /// Groups URLs into R1/R2 pairs and presents the FASTQ import config sheet
    /// via ``MainSplitViewController``.
    func importFASTQFromURLs(_ urls: [URL]) {
        guard let originController = activeMainWindowController(),
              let mainSplit = originController.mainSplitViewController else {
            showAlert(title: "No Project Open", message: "Please open a project before importing sequencing reads.")
            return
        }

        guard let projectURL = mainSplit.sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing sequencing reads.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "FASTQ import",
            presentingWindow: originController.window
        ) else { return }

        // Collect sequencing-read files, expanding directories. Existing `.lungfishfastq`
        // bundles are atomic imports; do not enumerate their preview/chunk payloads.
        var fastqURLs: [URL] = []
        var fastqBundleURLs: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if FASTQBundle.isBundleURL(url) {
                    fastqBundleURLs.append(url)
                    continue
                }
                // Scan directory for FASTQ files
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        if FASTQBundle.isBundleURL(fileURL) {
                            enumerator.skipDescendants()
                            fastqBundleURLs.append(fileURL)
                        } else if SequencingReadImportSource.isSupported(fileURL) {
                            fastqURLs.append(fileURL)
                        }
                    }
                }
            } else if SequencingReadImportSource.isSupported(url) {
                fastqURLs.append(url)
            }
        }

        guard !fastqURLs.isEmpty || !fastqBundleURLs.isEmpty else {
            showAlert(title: "No Read Files Found", message: "The selection does not contain FASTQ files or unmapped ONT BAM files.")
            return
        }

        for bundleURL in fastqBundleURLs {
            mainSplit.importFASTQBundleInBackground(sourceURL: bundleURL, projectDirectory: projectURL)
        }

        if !fastqURLs.isEmpty {
            let pairs = groupFASTQByPairs(fastqURLs)
            mainSplit.presentFASTQImportSheetFromImportCenter(pairs: pairs, projectDirectory: projectURL)
        }
    }

    /// Import paired FASTQ batches from a CSV sample sheet.
    func importFASTQSampleSheetFromURL(_ url: URL) {
        guard let originController = activeMainWindowController(),
              let mainSplit = originController.mainSplitViewController else {
            showAlert(title: "No Project Open", message: "Please open a project before importing sequencing reads.")
            return
        }

        guard let projectURL = mainSplit.sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing sequencing reads.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "FASTQ sample sheet import",
            presentingWindow: originController.window
        ) else { return }

        do {
            let sheet = try FASTQSampleSheet.parse(url: url)
            let pairs = sheet.entries.map { entry in
                FASTQFilePair(
                    r1: entry.r1,
                    r2: entry.r2,
                    sampleNameOverride: entry.sampleName,
                    metadata: entry.metadata,
                    sampleSheetURL: sheet.sourceURL
                )
            }
            mainSplit.presentFASTQImportSheetFromImportCenter(pairs: pairs, projectDirectory: projectURL)
        } catch {
            showAlert(title: "Invalid FASTQ Sample Sheet", message: error.localizedDescription)
        }
    }

    func importGeneiousExportFromURL(_ url: URL) {
        let routeContext = currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing a Geneious export.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Geneious import"
        ) else { return }

        let arguments = CLIApplicationExportImportRunner.buildGeneiousArguments(
            sourceURL: url,
            projectURL: projectURL
        )
        let runner = CLIApplicationExportImportRunner()
        Self.beginGeneiousImportOperation(
            sourceURL: url,
            arguments: arguments,
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        ) { opID in
            Task.detached { [weak self] in
                do {
                    let result = try await runner.run(arguments: arguments, operationID: opID)

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let detail = result.warningCount == 0
                                ? "Imported \(result.collectionURL.lastPathComponent)"
                                : "Imported \(result.collectionURL.lastPathComponent) with \(result.warningCount) warnings"
                            if result.warningCount == 0 {
                                guard OperationCenter.shared.complete(id: opID, detail: detail) else { return }
                            } else {
                                guard OperationCenter.shared.completeWithWarning(id: opID, detail: detail) else { return }
                            }
                            self?.refreshSidebarAndSelectImportedURL(
                                result.collectionURL,
                                in: self?.targetMainWindowController(routeContext: routeContext)
                            )
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                            self?.showAlert(title: "Geneious Import Failed", message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    func importApplicationExportFromURL(_ url: URL, kind: ApplicationExportKind) {
        let routeContext = currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing an application export.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "\(kind.displayName) import"
        ) else { return }

        let arguments = CLIApplicationExportImportRunner.buildApplicationExportArguments(
            sourceURL: url,
            projectURL: projectURL,
            kind: kind
        )
        let runner = CLIApplicationExportImportRunner()
        Self.beginApplicationExportImportOperation(
            kind: kind,
            sourceURL: url,
            arguments: arguments,
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        ) { opID in
            Task.detached { [weak self] in
                do {
                    let result = try await runner.run(arguments: arguments, operationID: opID)

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let detail = result.warningCount == 0
                                ? "Imported \(result.collectionURL.lastPathComponent)"
                                : "Imported \(result.collectionURL.lastPathComponent) with \(result.warningCount) warnings"
                            if result.warningCount == 0 {
                                guard OperationCenter.shared.complete(id: opID, detail: detail) else { return }
                            } else {
                                guard OperationCenter.shared.completeWithWarning(id: opID, detail: detail) else { return }
                            }
                            self?.refreshSidebarAndSelectImportedURL(
                                result.collectionURL,
                                in: self?.targetMainWindowController(routeContext: routeContext)
                            )
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                            self?.showAlert(title: "\(kind.displayName) Import Failed", message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    func importMultipleSequenceAlignmentFromURL(_ url: URL) {
        importNativeBundleFromURL(url, kind: .msa)
    }

    func importPhylogeneticTreeFromURL(_ url: URL) {
        importNativeBundleFromURL(url, kind: .tree)
    }

    private func importNativeBundleFromURL(_ url: URL, kind: CLINativeBundleImportRunner.BundleKind) {
        let routeContext = currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing \(kind.operationTitle.lowercased()).")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: kind.operationTitle
        ) else { return }

        let arguments = CLINativeBundleImportRunner.buildArguments(
            sourceURL: url,
            projectURL: projectURL,
            kind: kind
        )
        let runner = CLINativeBundleImportRunner()
        Self.beginNativeBundleImportOperation(
            kind: kind,
            sourceURL: url,
            arguments: arguments,
            routeContext: routeContext,
            onCancel: { runner.cancel() }
        ) { opID in
            Task.detached { [weak self] in
                do {
                    let result = try await runner.run(arguments: arguments, operationID: opID)

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let detail = result.warningCount == 0
                                ? "Imported \(result.bundleURL.lastPathComponent)"
                                : "Imported \(result.bundleURL.lastPathComponent) with \(result.warningCount) warnings"
                            if result.warningCount == 0 {
                                guard OperationCenter.shared.complete(
                                    id: opID,
                                    detail: detail,
                                    bundleURLs: [result.bundleURL]
                                ) else { return }
                            } else {
                                guard OperationCenter.shared.completeWithWarning(
                                    id: opID,
                                    detail: detail,
                                    bundleURLs: [result.bundleURL]
                                ) else { return }
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                            self?.showAlert(title: "\(kind.operationTitle) Failed", message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    @objc func importSampleMetadataToBundle(_ sender: Any?) {
        debugLog("importSampleMetadataToBundle: Menu action triggered")

        let controller = activeMainWindowController(sender: sender)
        guard let viewerController = controller?.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(
                title: "No Bundle Loaded",
                message: "Please open a reference or result bundle before importing sample metadata.",
                presentingWindow: controller?.window
            )
            return
        }

        let routeContext = currentOperationRouteContext(for: controller)
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: controller?.projectSession.windowStateScope,
            workflowName: "Sample metadata import",
            presentingWindow: controller?.window
        ) else { return }

        presentMetadataImportPanel(for: bundleURL, presentingWindow: controller?.window, routeContext: routeContext)
    }

    func importBundleSampleMetadataFromURL(_ url: URL) {
        let controller = activeMainWindowController()
        guard let viewerController = controller?.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(
                title: "No Bundle Loaded",
                message: "Please open a reference or result bundle before importing sample metadata.",
                presentingWindow: controller?.window
            )
            return
        }
        importBundleSampleMetadataFromURL(
            url,
            bundleURL: bundleURL,
            routeContext: currentOperationRouteContext(for: controller)
        )
    }

    func importBundleSampleMetadataFromURL(
        _ url: URL,
        bundleURL: URL,
        routeContext: OperationRouteContext? = nil
    ) {
        performSampleMetadataImport(metadataURL: url, bundleURL: bundleURL, routeContext: routeContext)
    }

    func presentMetadataImportPanel(
        for bundleURL: URL,
        presentingWindow: NSWindow?,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Sample metadata import",
            presentingWindow: presentingWindow ?? targetMainWindowController(routeContext: routeContext)?.window
        ) else { return }

        let panel = AppFilePanelFactory.sampleMetadataImportPanel()

        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let metadataURL = panel.url else {
                debugLog("presentMetadataImportPanel: User cancelled")
                return
            }
            self?.performSampleMetadataImport(
                metadataURL: metadataURL,
                bundleURL: bundleURL,
                routeContext: routeContext,
                presentingWindow: presentingWindow
            )
        }

        if let window = presentingWindow ?? targetMainWindowController(routeContext: routeContext)?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        }
    }

    private func performSampleMetadataImport(
        metadataURL: URL,
        bundleURL: URL,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        presentingWindow: NSWindow? = nil
    ) {
        debugLog("performSampleMetadataImport: Starting import of \(metadataURL.lastPathComponent) into \(bundleURL.lastPathComponent)")
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let targetController = targetMainWindowController(routeContext: routeContext)
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Sample metadata import",
            presentingWindow: presentingWindow ?? targetController?.window
        ) else { return }
        let format: MetadataFormat = metadataURL.pathExtension.lowercased() == "csv" ? .csv : .tsv

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let self else { return }
                if TwelveSAmpliconResultBundle.isBundleURL(bundleURL) {
                    let result = try Self.importResultBundleSampleMetadata(
                        metadataURL: metadataURL,
                        bundleURL: bundleURL
                    )
                    scheduleOnMainRunLoop { [weak self] in
                        guard let self else { return }
                        let targetController = self.targetMainWindowController(routeContext: routeContext)
                        if let viewerController = targetController?.mainSplitViewController?.viewerController,
                           viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                            targetController?.mainSplitViewController?.displayTwelveSAmpliconResultBundleFromSidebar(at: bundleURL)
                        }
                        self.showAlert(
                            title: "Metadata Imported",
                            message: "Imported \(result.store.columnNames.count.formatted()) metadata columns for \(result.store.matchedSampleIds.count.formatted()) sample(s).",
                            presentingWindow: targetController?.window ?? presentingWindow
                        )
                    }
                    return
                }

                let manifest = try BundleManifest.load(from: bundleURL)
                guard !manifest.variants.isEmpty else {
                    throw NSError(
                        domain: "Lungfish",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "This bundle has no variant tracks to apply metadata to."]
                    )
                }

                let targets = manifest.variants.compactMap { track -> VariantSampleMetadataImportTarget? in
                    guard let databasePath = track.databasePath else {
                        debugLog("performSampleMetadataImport: Skipping track '\(track.name)' (no databasePath)")
                        return nil
                    }
                    return VariantSampleMetadataImportTarget(
                        databaseURL: bundleURL.appendingPathComponent(databasePath),
                        trackName: track.name
                    )
                }
                let result = try VariantSampleMetadataImportService().importMetadata(
                    from: metadataURL,
                    format: format,
                    bundleURL: bundleURL,
                    targets: targets
                )
                let totalUpdated = result.totalUpdated
                let updatedTracks = result.updatedDatabaseCount

                scheduleOnMainRunLoop { [weak self] in
                    guard let self else { return }
                    debugLog("performSampleMetadataImport: Completed; tracks=\(updatedTracks), rows=\(totalUpdated)")
                    let targetController = self.targetMainWindowController(routeContext: routeContext)
                    if let viewerController = targetController?.mainSplitViewController?.viewerController,
                       viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                        do {
                            try viewerController.displayBundle(at: bundleURL)
                        } catch {
                            debugLog("performSampleMetadataImport: Bundle reload failed: \(error.localizedDescription)")
                        }
                    }
                    self.showAlert(
                        title: "Metadata Imported",
                        message: "Updated \(totalUpdated.formatted()) sample metadata row(s) across \(updatedTracks) variant track(s).",
                        presentingWindow: targetController?.window ?? presentingWindow
                    )
                }
            } catch {
                scheduleOnMainRunLoop { [weak self] in
                    debugLog("performSampleMetadataImport: Failed: \(error.localizedDescription)")
                    self?.showAlert(
                        title: "Metadata Import Failed",
                        message: error.localizedDescription,
                        presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window ?? presentingWindow
                    )
                }
            }
        }
    }

    nonisolated private static func importResultBundleSampleMetadata(
        metadataURL: URL,
        bundleURL: URL
    ) throws -> SampleMetadataBundleImportResult {
        let data = try Data(contentsOf: metadataURL)
        let knownSampleIds = try ResultBundleSampleMetadataResolver.knownSampleIDs(in: bundleURL)
        guard !knownSampleIds.isEmpty else {
            throw NSError(
                domain: "Lungfish",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No sample IDs were found in this result bundle."]
            )
        }

        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: knownSampleIds
        )
        guard let best = scanResult.bestColumn else {
            throw NSError(
                domain: "Lungfish",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No column in this file matched the bundle's sample IDs."]
            )
        }

        return try SampleMetadataBundleImportService().importMetadata(
            data: data,
            sourceURL: metadataURL,
            scanResult: scanResult,
            sampleColumnIndex: best.index,
            knownSampleIds: knownSampleIds,
            bundleURL: bundleURL
        )
    }

    /// Starts a VCF import as an `OperationCenter` operation and returns its id, or `nil`
    /// if it was refused. See `performBAMImport`'s doc comment.
    ///
    /// `replaceTrackID` names an existing variant track this import replaces;
    /// the caller has already confirmed that with the user (see
    /// `importVCFToBundle`). Without it, the import adds a new track under a
    /// unique id, so a second same-named VCF never overwrites the first one.
    @discardableResult
    internal func performVCFImport(
        vcfURL: URL, bundleURL: URL, routeContext explicitRouteContext: OperationRouteContext? = nil,
        replaceTrackID: String? = nil
    ) -> UUID? {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "VCF import",
            presentingWindow: targetMainWindowController(routeContext: routeContext)?.window
        ) else { return nil }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return nil
        }

        let selectedImportProfile = selectedVCFImportProfile()
        // The track id is decided against the manifest up front, exactly as
        // `lungfish-cli import vcf` does: a same-named VCF gets `calls-2`,
        // and a replacement must name a track that exists.
        let trackID: String
        do {
            let manifest = try BundleManifest.load(from: bundleURL)
            trackID = try VCFBundleVariantImport.resolveTrackID(
                forVCFURL: vcfURL, in: manifest, bundleURL: bundleURL, replacing: replaceTrackID)
        } catch {
            showAlert(title: "VCF Import Failed", message: error.localizedDescription,
                      presentingWindow: targetMainWindowController(routeContext: routeContext)?.window)
            return nil
        }
        // A replaced track whose import or materialization stopped is finished from
        // its own database with `--resume` or `--materialize`.
        let mode = VCFImportCLICommand.mode(forTrackID: trackID, replacing: replaceTrackID, in: bundleURL)
        let arguments = VCFImportCLICommand.arguments(
            vcfURL: vcfURL, bundleURL: bundleURL, importProfile: selectedImportProfile,
            replaceTrackID: replaceTrackID, mode: mode
        )
        let result = Self.beginVCFImportOperation(
            vcfURL: vcfURL,
            bundleURL: bundleURL,
            importProfile: selectedImportProfile,
            replaceTrackID: replaceTrackID,
            mode: mode,
            routeContext: routeContext,
            onCancel: {} // CLIBundleBuildRunner.launch wires the row's Cancel to the command once it starts
        ) { opID in
            // The import is `lungfish-cli import vcf`, and the row shows its events (Phase 2.12 lane 12.07, A64).
            Task { [weak self] in
                do {
                    let run = try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: opID)
                    guard OperationCenter.shared.complete(id: opID, detail: run.message ?? "Variants imported") else { return }

                    guard let originController = self?.targetMainWindowController(routeContext: routeContext),
                          let viewerController = originController.mainSplitViewController?.viewerController else {
                        debugLog("performVCFImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performVCFImport: Bundle reloaded (\(run.message ?? ""))")
                    } catch {
                        debugLog("performVCFImport: Bundle reload failed: \(error.localizedDescription)")
                        if let window = originController.window {
                            self?.showAlert(title: "Import Error", message: "VCF imported but bundle reload failed: \(error.localizedDescription)", presentingWindow: window)
                        }
                    }
                } catch is CancellationError {
                    // The runner acknowledged the cancel on the row.
                    debugLog("performVCFImport: Cancelled by user")
                } catch {
                    guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                    debugLog("performVCFImport: Failed: \(error.localizedDescription)")
                    if let window = self?.targetMainWindowController(routeContext: routeContext)?.window {
                        self?.showAlert(title: "VCF Import Failed", message: error.localizedDescription, presentingWindow: window)
                    }
                }
            }
        }
        return result.startedID
    }

    internal nonisolated static func vcfManifestReplacingTrack(
        _ track: VariantTrackInfo, in currentManifest: BundleManifest
    ) -> BundleManifest {
        currentManifest.replacingVariantTrack(track)
    }

    /// Final VCF publication boundary, isolated from helper execution so its
    /// database, receipt, and manifest failure behavior can be exercised directly.
    internal nonisolated static func publishVCFImportArtifacts(
        databasePublication: OperationImportStaging.SQLitePublication,
        bundleURL: URL,
        provenanceURL: URL,
        updatedManifest: BundleManifest,
        filePublication: ScientificFilePublicationTransaction? = nil,
        shouldCancel: () -> Bool = { false },
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil),
        writeProvenance: (ProvenanceWriter) throws -> Void
    ) throws {
        try VCFBundleVariantImport.publish(
            databasePublication: databasePublication,
            bundleURL: bundleURL,
            provenanceURL: provenanceURL,
            updatedManifest: updatedManifest,
            filePublication: filePublication,
            shouldCancel: shouldCancel,
            provenanceWriter: provenanceWriter,
            writeProvenance: writeProvenance
        )
    }

    private func selectedVCFImportProfile() -> VCFImportProfile {
        let raw = AppSettings.shared.vcfImportProfile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .auto }
        if let profile = VCFImportProfile(rawValue: raw) {
            return profile
        }
        switch raw.lowercased() {
        case "fast":
            return .fast
        case "lowmemory", "low-memory", "low_memory":
            return .lowMemory
        case "ultra-low-memory", "ultra_low_memory", "ultralow":
            return .ultraLowMemory
        default:
            return .auto
        }
    }

    nonisolated static func importProfileLabel(_ profile: VCFImportProfile) -> String {
        switch profile {
        case .auto:
            return "Auto"
        case .lowMemory:
            return "Low Memory"
        case .fast:
            return "Fast"
        case .ultraLowMemory:
            return "Ultra Low Memory"
        }
    }

    @objc func exportFASTA(_ sender: Any?) {
        exportSequences(defaultFormat: .fasta, controller: activeMainWindowController(sender: sender))
    }

    @objc func exportGenBank(_ sender: Any?) {
        exportSequences(defaultFormat: .genbank, controller: activeMainWindowController(sender: sender))
    }

    /// Unified sequence export supporting multi-selection, format choice, and compression.
    private func exportSequences(defaultFormat: SequenceExportFormat, controller: MainWindowController?) {
        guard let controller, let window = controller.window else { return }
        let routeContext = currentOperationRouteContext(for: controller)
        let selection = controller.mainSplitViewController?.sidebarController?.selectedItems() ?? []
        let scope = SidebarExportSelection(selection, format: .sequences)
        let document = controller.mainSplitViewController?.viewerController?.currentDocument
        guard selection.isEmpty ? document?.sequences.isEmpty == false : scope.hasExportableItems else {
            let detail = selection.isEmpty ? "Select files in the sidebar or open a document."
                : "The selected items cannot be exported as sequences: \(scope.skippedDescriptions.joined(separator: ", "))."
            showAnnotationExportMessage("No sequences to export", detail: detail, window: window)
            return
        }
        do {
            let request = try SequenceExportSourceResolver.capture(items: scope.exportable,
                session: controller.projectSession, currentDocument: document)
            let skippedMessage = scope.skipped.isEmpty ? nil
                : "\(scope.skipped.count) of \(selection.count) selected items cannot be exported as sequences and will be skipped: \(scope.skippedDescriptions.joined(separator: ", "))."
            Task { [weak self, weak window] in
                do {
                    let sources = try await request.resolve()
                    guard let self, let window, window.isVisible, !sources.isEmpty else { return }
                    if let skippedMessage {
                        let alert = NSAlert()
                        alert.messageText = "Some Selected Items Will Be Skipped"
                        alert.informativeText = skippedMessage
                        alert.addButton(withTitle: "Continue")
                        alert.addButton(withTitle: "Cancel")
                        alert.beginSheetModal(for: window) { [weak self, weak window] response in
                            guard response == .alertFirstButtonReturn, let window else { return }
                            self?.continueExportSequences(sources: sources, defaultFormat: defaultFormat, window: window, routeContext: routeContext)
                        }
                    } else {
                        self.continueExportSequences(sources: sources, defaultFormat: defaultFormat, window: window, routeContext: routeContext)
                    }
                } catch is CancellationError {
                    // A closed/switched source has no export destination to publish.
                } catch {
                    if let window { self?.showAnnotationExportMessage("Export unavailable", detail: error.localizedDescription, window: window) }
                }
            }
        } catch {
            showAnnotationExportMessage("Export unavailable", detail: error.localizedDescription, window: window)
        }
    }

    /// Continuation of `exportSequences(defaultFormat:)` after the
    /// skipped-items confirmation (if any) has been accepted.
    private func continueExportSequences(
        sources: [SequenceExportSourceResolver.Source],
        defaultFormat: SequenceExportFormat,
        window: NSWindow,
        routeContext: OperationRouteContext?
    ) {
        let selectedBundleURLs = sources.map { $0.metadata.url }
        if sources.count > 1, sources.allSatisfy({ $0.document == nil && $0.metadata.url.pathExtension.lowercased() == "lungfishref" }) {
            presentBatchSequenceExport(bundleURLs: selectedBundleURLs, defaultFormat: defaultFormat, window: window, routeContext: routeContext)
            return
        }
        let baseName = sources.count == 1
            ? (sources[0].document?.name ?? sources[0].metadata.url.deletingPathExtension().lastPathComponent)
            : "exported_sequences"

        let panel = AppFilePanelFactory.sequenceExportPanel()
        let panelController = SequenceExportPanelController(
            panel: panel,
            defaultFormat: defaultFormat,
            filenameBaseName: baseName
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputURL = panel.url else { return }
            guard let self else { return }

            self.startSequenceExport(
                sources: sources,
                outputURL: outputURL,
                format: panelController.selectedFormat,
                compression: panelController.selectedCompression,
                window: window,
                routeContext: routeContext
            )
        }
    }

    private func presentBatchSequenceExport(
        bundleURLs: [URL],
        defaultFormat: SequenceExportFormat,
        window: NSWindow,
        routeContext: OperationRouteContext?
    ) {
        let panel = AppFilePanelFactory.batchSequenceExportFolderPanel(itemCount: bundleURLs.count)
        let panelController = SequenceExportPanelController(
            panel: panel,
            defaultFormat: defaultFormat,
            filenameBaseName: nil
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputFolder = panel.url else { return }
            guard let self else { return }

            let format = panelController.selectedFormat
            let compression = panelController.selectedCompression

            let targets = Self.batchSequenceExportTargets(
                for: bundleURLs,
                outputFolder: outputFolder,
                format: format,
                compression: compression
            )
            Self.beginBatchSequenceExportOperation(
                bundleURLs: bundleURLs,
                outputFolder: outputFolder,
                format: format,
                compression: compression,
                routeContext: routeContext
            ) { opID in
                let task = Task.detached { [weak self] in
                    do {
                        var count = 0
                        for (index, bundleURL) in bundleURLs.enumerated() {
                            try Task.checkCancellation()
                            guard let outputURL = targets[bundleURL] else { continue }
                            await appPerformOnMainRunLoop {
                                let detail = "Exporting \(index + 1) of \(bundleURLs.count): \(bundleURL.deletingPathExtension().lastPathComponent)"
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: Double(index) / Double(max(bundleURLs.count, 1)),
                                    detail: detail
                                )
                                OperationCenter.shared.log(id: opID, level: .info, message: "\(detail) -> \(outputURL.lastPathComponent)")
                            }
                            count += try await self?.performSequenceExport(
                                inputs: [bundleURL],
                                outputURL: outputURL,
                                format: format,
                                compression: compression
                            ) ?? 0
                        }

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.complete(
                                    id: opID,
                                    detail: "Exported \(bundleURLs.count) file(s) with \(count) sequence(s)"
                                ) else { return }
                                let alert = NSAlert()
                                alert.messageText = "Export Complete"
                                alert.informativeText = "Exported \(bundleURLs.count) file(s) with \(count) sequence(s) to \(outputFolder.lastPathComponent)."
                                alert.alertStyle = .informational
                                alert.addButton(withTitle: "OK")
                                alert.addButton(withTitle: "Show in Finder")
                                alert.beginSheetModal(for: window) { response in
                                    if response == .alertSecondButtonReturn {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
                                    }
                                }
                            }
                        }
                    } catch {
                        debugLog("presentBatchSequenceExport: Failed - \(error)")
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard OperationCenter.shared.fail(
                                    id: opID,
                                    detail: error.localizedDescription,
                                    errorMessage: "Batch sequence export failed",
                                    errorDetail: error.localizedDescription
                                ) else { return }
                                let alert = NSAlert()
                                alert.messageText = "Export Failed"
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .critical
                                alert.addButton(withTitle: "OK")
                                alert.beginSheetModal(for: window)
                            }
                        }
                    }
                }
                OperationCenter.shared.setCancelCallback(for: opID) {
                    task.cancel()
                }
            }
        }
    }

    /// Reads sequences and annotations from a file or reference bundle for export.
    /// Loads only a reference bundle's annotations for export, without ever
    /// touching its genome.
    ///
    /// "Export annotations" used to call `loadSequencesForExport`
    /// and discard the sequences it returned. For a `.lungfishref`, that path
    /// decompressed the whole genome into a `String`, wrote it to a temp
    /// file, and parsed every sequence with `FASTAReader.readAll()` -- for a
    /// human or macaque reference (about 3 Gbp) that is roughly 9-12 GB of
    /// peak memory spent on data the GFF3 export never uses. This reads only
    /// the manifest and the annotation databases it points at.
    nonisolated func loadAnnotationsForExport(bundleURL: URL) throws -> [SequenceAnnotation] {
        let manifest = try BundleManifest.load(from: bundleURL)
        return try loadBundleAnnotations(bundleURL: bundleURL, manifest: manifest)
    }

    ///
    /// For reference bundles, reads the FASTA directly and loads annotations from the
    /// annotation database (BigBed tracks) via the bundle's data provider.
    /// For GenBank files, reads both sequences and annotations from the file.
    /// For FASTA files, reads sequences only.
    nonisolated func loadSequencesForExport(from url: URL) async throws -> ([LungfishCore.Sequence], [SequenceAnnotation]) {
        // Reference bundle: read FASTA path from manifest
        if url.pathExtension.lowercased() == "lungfishref" {
            let manifest = try BundleManifest.load(from: url)
            guard let genomePath = manifest.genome?.path else {
                throw NSError(domain: "com.lungfish.browser", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No genome sequence in bundle \(url.lastPathComponent)"])
            }
            let sourceURL = url.appendingPathComponent(genomePath)
            // `FASTAReader` already streams a `.gz` source line by
            // line via `GzipInputStream.forEachLine` (see `isCompressed` and
            // `forEachLineSync`), so there is no need to decompress the whole
            // genome into a `String` and write it to a temp file first. For a
            // human or macaque reference (about 3 Gbp), the old path held the
            // decompressed `Data`, the `String`, and the parsed `Sequence`s
            // simultaneously -- roughly 9-12 GB of peak memory just to hand
            // back sequences a caller may not even use (see
            // `loadAnnotationsForExport`, which never reaches this branch).
            let reader = try FASTAReader(url: sourceURL)
            let sequences = try await reader.readAll()
            let annotations = try loadBundleAnnotations(bundleURL: url, manifest: manifest)
            return (sequences, annotations)
        }

        // GenBank file: read sequences and annotations
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" { checkURL = checkURL.deletingPathExtension() }
        let ext = checkURL.pathExtension.lowercased()
        if ext == "gb" || ext == "gbk" || ext == "genbank" || ext == "gbff" {
            let reader = try GenBankReader(url: url)
            let records = try await reader.readAll()
            var sequences: [LungfishCore.Sequence] = []
            var annotations: [SequenceAnnotation] = []
            for record in records {
                sequences.append(record.sequence)
                annotations.append(contentsOf: record.annotations)
            }
            return (sequences, annotations)
        }

        // FASTA file
        let reader = try FASTAReader(url: url)
        let sequences = try await reader.readAll()
        return (sequences, [])
    }

    /// Returns current date in GenBank format (DD-MMM-YYYY)
    nonisolated static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }

    @objc func exportGFF3(_ sender: Any?) {
        guard let controller = activeMainWindowController(sender: sender), let window = controller.window else { return }
        let document = controller.mainSplitViewController?.viewerController?.currentDocument
        let sidebarSelection = controller.mainSplitViewController?.sidebarController?.selectedItems() ?? []
        if !sidebarSelection.isEmpty {
            let scope = SidebarExportSelection.annotations(sidebarSelection,
                loadedDocumentURL: document?.url, loadedDocumentID: document?.id,
                loadedNativeSequenceID: document?.projectSequenceID,
                hasLoadedAnnotations: document?.annotations.isEmpty == false)
            guard !scope.exportable.isEmpty else {
                showAnnotationExportMessage("No annotations to export", detail: "The selected items do not support annotation export: \(scope.skippedDescriptions.joined(separator: ", ")).", window: window)
                return
            }
            let sources = scope.exportable.compactMap { item -> AnnotationExportSourceChoice? in
                guard let url = item.url else { return nil }
                if let document, !document.annotations.isEmpty,
                   SidebarExportSelection.matchesLoadedDocument(item, url: document.url, id: document.id,
                       nativeSequenceID: document.projectSequenceID) {
                    return .init(source: .init(kind: .openDocument, urls: [document.url], name: document.name),
                        annotations: document.annotations)
                }
                return .init(source: .init(kind: .sidebarBundle, urls: [url], name: item.title), annotations: nil)
            }
            if sources.count > 1 || !scope.skipped.isEmpty {
                let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
                choice.addItems(withTitles: sources.map(\.displayTitle))
                for (item, source) in zip(choice.itemArray, sources) { item.toolTip = source.displayTitle }
                choice.setAccessibilityIdentifier("annotation-export-source-choice")
                let alert = NSAlert()
                alert.messageText = "Choose an annotation source"
                alert.informativeText = "Export one of \(scope.exportable.count) supported sources from \(sidebarSelection.count) selected items. Each export contains one source's annotations."
                if !scope.skipped.isEmpty {
                    alert.informativeText += "\nUnsupported selections: \(scope.skippedDescriptions.joined(separator: ", "))."
                }
                alert.accessoryView = choice
                alert.addButton(withTitle: "Choose Destination…")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self, weak window] response in
                    guard response == .alertFirstButtonReturn, let window,
                          sources.indices.contains(choice.indexOfSelectedItem) else { return }
                    self?.exportAnnotationSource(sources[choice.indexOfSelectedItem], window: window)
                }
            } else {
                exportAnnotationSource(sources[0], window: window)
            }
            return
        }
        guard let document, !document.annotations.isEmpty else {
            showAnnotationExportMessage("No annotations to export", detail: "Open a document with annotations or select a supported reference bundle.", window: window)
            return
        }
        beginGFF3Export(annotations: document.annotations,
            source: .init(kind: .openDocument, urls: [document.url], name: document.name),
            suggestedName: document.url.deletingPathExtension().lastPathComponent + ".gff3", window: window)
    }

    private func exportAnnotationSource(_ choice: AnnotationExportSourceChoice, window: NSWindow) {
        let source = choice.source
        guard let bundleURL = source.urls.first else { return }
        if let annotations = choice.annotations {
            beginGFF3Export(annotations: annotations, source: source,
                suggestedName: bundleURL.deletingPathExtension().lastPathComponent + ".gff3", window: window)
            return
        }
        Task { [weak self, weak window] in
            guard let self else { return }
            do {
                // This source is always a `.referenceBundle` (the
                // only sidebar kind whose `canExportAnnotations` is true), so
                // load its annotations directly rather than through
                // `loadSequencesForExport`, which would also decompress and
                // parse the whole genome only to discard it.
                let annotations = try self.loadAnnotationsForExport(bundleURL: bundleURL)
                guard let window, window.isVisible else { return }
                guard !annotations.isEmpty else {
                    self.showAnnotationExportMessage("No annotations to export", detail: "\(source.name) has no annotations.", window: window)
                    return
                }
                self.beginGFF3Export(annotations: annotations, source: source,
                    suggestedName: bundleURL.deletingPathExtension().lastPathComponent + ".gff3", window: window)
            } catch {
                guard let window else { return }
                self.showAnnotationExportMessage("Annotation export failed", detail: error.localizedDescription, window: window)
            }
        }
    }

    func canExportGFF3() -> Bool {
        let controller = activeMainWindowController()
        let selection = controller?.mainSplitViewController?.sidebarController?.selectedItems() ?? []
        let document = controller?.mainSplitViewController?.viewerController?.currentDocument
        if !selection.isEmpty {
            return SidebarExportSelection.annotations(selection, loadedDocumentURL: document?.url,
                loadedDocumentID: document?.id, loadedNativeSequenceID: document?.projectSequenceID,
                hasLoadedAnnotations: document?.annotations.isEmpty == false).hasExportableItems
        }
        return document?.annotations.isEmpty == false
    }

    private func showAnnotationExportMessage(_ title: String, detail: String, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func beginGFF3Export(annotations: [SequenceAnnotation], source: AnnotationExportService.Source, suggestedName: String, window: NSWindow) {
        let panel = AppFilePanelFactory.gff3ExportPanel(suggestedName: suggestedName)

        panel.message = "\(AnnotationExportSourceChoice(source: source, annotations: nil).displayTitle)\n\(annotations.count) annotations from one source."
        panel.beginSheetModal(for: window) { [weak self, weak window] response in
            guard response == .OK, let url = panel.url else { return }
            // `bundle export-gff3` writes the file and its record behind an Operations row (lane 12.39).
            self?.startAnnotationGFF3Export(annotations: annotations, source: source, outputURL: url) { [weak self, weak window] title, detail in
                debugLog("exportGFF3: \(title) - \(detail)")
                if let window { self?.showAnnotationExportMessage(title, detail: detail, window: window) }
            }
        }
    }

    @objc func exportImage(_ sender: Any?) {
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showExportError(message: "No viewer is currently available for export.")
            return
        }

        presentViewerGraphicsExportPanel(
            viewerController: viewerController,
            defaultFormat: .png,
            includeBitmapFormats: true
        )
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showExportError(message: "No viewer is currently available for export.")
            return
        }

        presentViewerGraphicsExportPanel(
            viewerController: viewerController,
            defaultFormat: .pdf,
            includeBitmapFormats: false
        )
    }

    private func presentViewerGraphicsExportPanel(
        viewerController: ViewerViewController,
        defaultFormat: ViewerGraphicFormat,
        includeBitmapFormats: Bool
    ) {
        guard let window = mainWindowController?.window else {
            showExportError(message: "Unable to determine active window for export.")
            return
        }

        let hasSelection = viewerController.viewerView.selectionRange?.isEmpty == false
        let formats: [ViewerGraphicFormat] = includeBitmapFormats ? [.png, .jpeg, .tiff, .pdf] : [.pdf]
        let scopes: [ViewerExportScope] = hasSelection ? [.tracks, .fullViewer, .selectedRegion] : [.tracks, .fullViewer]
        let panelController = ViewerGraphicsExportPanelController(
            formats: formats,
            scopes: scopes,
            initialFormat: defaultFormat
        )
        let panel = panelController.panel

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let rawURL = panel.url else { return }

            let scope = panelController.selectedScope
            let format = panelController.selectedFormat
            let scale = panelController.selectedBitmapScale
            let outputURL = panelController.normalizedOutputURL(from: rawURL)

            do {
                let data = try self.viewerExportData(
                    viewerController: viewerController,
                    scope: scope,
                    format: format,
                    bitmapScale: scale
                )
                try data.write(to: outputURL, options: .atomic)
                self.showExportSuccess(filename: outputURL.lastPathComponent, count: 1, itemType: "graphic")
            } catch {
                self.showExportError(message: "Failed to export viewer graphics: \(error.localizedDescription)")
            }
        }
    }

    private func viewerExportData(
        viewerController: ViewerViewController,
        scope: ViewerExportScope,
        format: ViewerGraphicFormat,
        bitmapScale: CGFloat
    ) throws -> Data {
        let (view, rect) = try viewerExportViewAndRect(viewerController: viewerController, scope: scope)
        if format.isVector {
            return view.dataWithPDF(inside: rect)
        }

        let pdfData = view.dataWithPDF(inside: rect)
        guard let image = NSImage(data: pdfData) else {
            throw NSError(domain: "LungfishExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render export image"])
        }

        let pixelsWide = max(1, Int((rect.width * bitmapScale).rounded(.up)))
        let pixelsHigh = max(1, Int((rect.height * bitmapScale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "LungfishExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate bitmap export buffer"])
        }

        rep.size = NSSize(width: rect.width, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "LungfishExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap graphics context"])
        }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1)

        let nsType: NSBitmapImageRep.FileType
        switch format {
        case .png: nsType = .png
        case .jpeg: nsType = .jpeg
        case .tiff: nsType = .tiff
        case .pdf: nsType = .png
        }
        guard let data = rep.representation(using: nsType, properties: [:]) else {
            throw NSError(domain: "LungfishExport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to encode bitmap export data"])
        }
        return data
    }

    func viewerExportViewAndRect(
        viewerController: ViewerViewController,
        scope: ViewerExportScope
    ) throws -> (NSView, NSRect) {
        switch scope {
        case .tracks:
            return (viewerController.viewerView, viewerController.viewerView.bounds)
        case .fullViewer:
            return (viewerController.view, viewerController.view.bounds)
        case .selectedRegion:
            guard let frame = viewerController.referenceFrame,
                  let range = viewerController.viewerView.selectionRange,
                  !range.isEmpty else {
                throw NSError(
                    domain: "LungfishExport",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No selected region is available for export."]
                )
            }

            let rawStartX = frame.screenPosition(for: Double(range.lowerBound))
            let rawEndX = frame.screenPosition(for: Double(range.upperBound))
            let minX = max(frame.leadingInset, min(rawStartX, rawEndX))
            let maxDataX = max(frame.leadingInset, viewerController.viewerView.bounds.width - frame.trailingInset)
            let maxX = min(maxDataX, max(rawStartX, rawEndX))
            let width = max(1, maxX - minX)
            let rect = NSRect(x: minX, y: 0, width: width, height: viewerController.viewerView.bounds.height)
            return (viewerController.viewerView, rect)
        }
    }

    /// Shows an error alert for export failures
    internal func showExportError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Shows a success alert after export
    private func showExportSuccess(filename: String, count: Int, itemType: String) {
        let alert = NSAlert()
        alert.messageText = "Export Successful"
        let plural = count == 1 ? itemType : "\(itemType)s"
        alert.informativeText = "Successfully exported \(count) \(plural) to \(filename)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }
}
