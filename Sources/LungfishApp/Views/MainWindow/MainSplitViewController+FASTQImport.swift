// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit
import os.log

extension MainSplitViewController {
    func shouldHandleSidebarFileDropNotification(from source: Any?) -> Bool {
        Self.shouldHandleSidebarFileDropNotification(
            from: source,
            owningSidebar: sidebarController,
            owningViewer: viewerController
        )
    }

    static func shouldHandleSidebarFileDropNotification(
        from source: Any?,
        owningSidebar: SidebarViewController,
        owningViewer: ViewerViewController?
    ) -> Bool {
        guard let source else { return true }
        if let sourceSidebar = source as? SidebarViewController {
            return sourceSidebar === owningSidebar
        }
        if let sourceViewer = source as? ViewerViewController {
            return sourceViewer === owningViewer
        }
        return true
    }

    func makeSidebarImportPlan(for droppedURLs: [URL]) -> SidebarImportPlan {
        SidebarImportPlanner.makePlan(
            for: droppedURLs,
            ontDirectoryDetector: { [weak self] url in
                self?.isONTDirectory(url) ?? false
            }
        )
    }

    /// Imports a single non-FASTQ file, handling duplicate resolution via sheet.
    func importNonFASTQFile(
        url: URL,
        projectURL: URL?,
        targetDir: URL,
        destinationItem: SidebarItem?,
        requestID: String?,
        displayAfterImport: Bool
    ) async {
        if ReferenceBundleImportService.isStandaloneReferenceSource(url) {
            guard let projectURL else {
                let errorMessage = "Open a project before importing standalone reference files."
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
                return
            }

            do {
                let refsDir = try ReferenceSequenceFolder.ensureFolder(in: projectURL)
                let cliCmd = OperationCenter.buildCLICommand(
                    subcommand: "import",
                    args: ["fasta", url.path, "--output-dir", refsDir.path]
                )
                let opID = OperationCenter.shared.start(
                    title: "Reference Import",
                    detail: "Importing \(url.lastPathComponent)...",
                    operationType: .bundleBuild,
                    cliCommand: cliCmd,
                    routeContext: operationRouteContext
                )

                let result = try await ReferenceBundleImportHelperLauncher.importAsReferenceBundleViaAppHelper(
                    sourceURL: url,
                    outputDirectory: refsDir
                ) { progress, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: progress,
                                detail: message
                            )
                        }
                    }
                }

                OperationCenter.shared.complete(
                    id: opID,
                    detail: "Imported \(result.bundleURL.lastPathComponent)"
                )
                sidebarController.reloadFromFilesystem()
                if displayAfterImport {
                    loadGenomicsFileInBackground(url: result.bundleURL)
                }
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: true,
                    error: nil
                )
            } catch {
                let errorMessage = error.localizedDescription
                mainSplitLogger.error(
                    "handleSidebarFileDropped: Reference helper import failed for \(url.lastPathComponent, privacy: .public): \(errorMessage, privacy: .public)"
                )
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
            }
            return
        }

        if ReferenceBundleImportService.classify(url) == .annotationTrack {
            guard let projectURL else {
                let errorMessage = "Open a project before importing annotation tracks."
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: errorMessage)
                return
            }

            let preferredBundleURL = destinationItem?.type == .referenceBundle ? destinationItem?.url : nil
            guard let importConfiguration = await ReferenceBundleAnnotationImportConfigurationPresenter.choose(
                projectURL: projectURL,
                preferredBundleURL: preferredBundleURL,
                sourceURL: url,
                presentingWindow: view.window
            ) else {
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: "Annotation import cancelled.")
                return
            }
            let bundleURL = importConfiguration.bundleURL

            let opID = OperationCenter.shared.start(
                title: "Annotation Import",
                detail: "Importing \(url.lastPathComponent)...",
                operationType: .bundleBuild,
                cliCommand: nil,
                routeContext: operationRouteContext
            )

            do {
                let result = try await ReferenceBundleAnnotationImportService()
                    .attachAnnotationTrack(
                        sourceURL: url,
                        bundleURL: bundleURL,
                        trackID: importConfiguration.trackID,
                        trackName: importConfiguration.trackName
                    )
                OperationCenter.shared.complete(
                    id: opID,
                    detail: "Imported \(result.featureCount) annotations"
                )
                sidebarController.reloadFromFilesystem()
                if viewerController?.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                    try? viewerController?.displayBundle(at: bundleURL)
                }
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: true, error: nil)
            } catch {
                OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: error.localizedDescription)
            }
            return
        }

        if MHCAmpliconReferenceBundle.isBundleURL(url) {
            guard let projectURL else {
                let errorMessage = "Open a project before importing reference allele databases."
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
                return
            }

            do {
                let installedURL = try HaplotypeDefinitionCommandService(projectRoot: projectURL)
                    .installMHCReferenceBundle(
                        from: url,
                        argv: ["lungfish-cli", "haplotypes", "bundle-install", url.path]
                    )
                mainSplitLogger.info(
                    "handleSidebarFileDropped: Installed reference allele database at \(installedURL.path, privacy: .public)"
                )
                sidebarController.reloadFromFilesystem()
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: true,
                    error: nil
                )
            } catch {
                let errorMessage = error.localizedDescription
                mainSplitLogger.error(
                    "handleSidebarFileDropped: Reference allele database install failed for \(url.lastPathComponent, privacy: .public): \(errorMessage, privacy: .public)"
                )
                postSidebarFileDropCompleted(
                    requestID: requestID,
                    sourceURL: url,
                    success: false,
                    error: errorMessage
                )
            }
            return
        }

        var urlToLoad = url
        var importSucceeded = true
        var importError: String?
        if projectURL != nil {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: targetDir.path) {
                try? fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }

            let destinationURL = targetDir.appendingPathComponent(url.lastPathComponent)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    urlToLoad = try copyProjectItemForImport(from: url, to: destinationURL)
                    mainSplitLogger.info("handleSidebarFileDropped: Copied file to project at \(destinationURL.path, privacy: .public)")
                    sidebarController.reloadFromFilesystem()
                } catch {
                    mainSplitLogger.error("handleSidebarFileDropped: Failed to copy file: \(error.localizedDescription, privacy: .public)")
                    importSucceeded = false
                    importError = error.localizedDescription
                }
            } else {
                let resolution = await showDuplicateFileDialog(filename: url.lastPathComponent)
                switch resolution {
                case .replace:
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        urlToLoad = try copyProjectItemForImport(from: url, to: destinationURL)
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        mainSplitLogger.error("handleSidebarFileDropped: Failed to replace file: \(error.localizedDescription, privacy: .public)")
                        importSucceeded = false
                        importError = error.localizedDescription
                    }
                case .keepBoth:
                    let uniqueURL = generateUniqueFilename(for: url, in: targetDir)
                    do {
                        urlToLoad = try copyProjectItemForImport(from: url, to: uniqueURL)
                        sidebarController.reloadFromFilesystem()
                    } catch {
                        mainSplitLogger.error("handleSidebarFileDropped: Failed to copy with unique name: \(error.localizedDescription, privacy: .public)")
                        importSucceeded = false
                        importError = error.localizedDescription
                    }
                case .skip:
                    urlToLoad = destinationURL
                }
            }
        }

        // Imported project files should route through the same sidebar display path
        // as manual selection so generic files use QuickLook and genomics files use
        // the appropriate native handler.
        if displayAfterImport {
            displayImportedProjectFile(at: urlToLoad)
        }
        postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: importSucceeded, error: importError)
    }

    func importFASTQBundleInBackground(sourceURL: URL, projectDirectory: URL, requestID: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.importNonFASTQFile(
                url: sourceURL,
                projectURL: projectDirectory,
                targetDir: projectDirectory,
                destinationItem: nil,
                requestID: requestID,
                displayAfterImport: true
            )
        }
    }

    func copyProjectItemForImport(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        if FASTQBundle.isBundleURL(sourceURL) {
            let argv = ["lungfish", "fastq", "import-ont", sourceURL.path, "--output", destinationURL.path]
            let result = try FASTQBundleCopyImportWorkflow().importBundle(
                sourceBundleURL: sourceURL,
                outputURL: destinationURL,
                context: FASTQBundleCopyImportWorkflow.CommandContext(
                    workflowName: "lungfish fastq import-ont",
                    workflowVersion: WorkflowRun.currentAppVersion,
                    toolName: "lungfish fastq import-ont",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    durableReplayArgv: argv,
                    explicitOptions: [
                        "input": .file(sourceURL),
                        "output": .file(destinationURL)
                    ],
                    defaultOptions: [
                        "sourceKind": .string("raw-ont-directory"),
                        "copyMode": .string("none")
                    ],
                    resolvedOptions: [
                        "input": .file(sourceURL),
                        "output": .file(destinationURL),
                        "destinationBundle": .file(destinationURL),
                        "sourceKind": .string("existing-fastq-bundle"),
                        "copyMode": .string("atomic-bundle-copy"),
                        "caller": .string("app")
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity()
                )
            )
            return result.bundleURL
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    // MARK: - FASTQ Import Sheet

    /// Presents the FASTQ import configuration sheet for the given file pairs.
    func presentFASTQImportSheet(pairs: [FASTQFilePair], projectDirectory: URL, requestID: String?) {
        guard canWriteProjectOutputs(workflowName: "FASTQ import") else { return }
        guard let window = view.window else {
            // Fallback: import first pair with defaults if no window for sheet
            for pair in pairs {
                importFASTQFileInBackground(sourceURL: pair.r1, projectDirectory: projectDirectory, requestID: requestID)
            }
            return
        }

        // Auto-detect platform from the first R1 file
        let detectedPlatform = LungfishIO.SequencingPlatform.detect(fromFASTQ: pairs[0].r1) ?? .unknown

        FASTQImportConfigSheet.present(
            on: window,
            pairs: pairs,
            detectedPlatform: detectedPlatform,
            onImport: { [weak self] config in
                self?.importFASTQBatchWithConfig(
                    pairs: pairs,
                    config: config,
                    projectDirectory: projectDirectory,
                    requestID: requestID
                )
            },
            onCancel: { [weak self] in
                for pair in pairs {
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: "Cancelled by user")
                }
            }
        )
    }

    /// Entry point for Import Center FASTQ import (no sidebar request ID).
    func presentFASTQImportSheetFromImportCenter(pairs: [FASTQFilePair], projectDirectory: URL) {
        presentFASTQImportSheet(pairs: pairs, projectDirectory: projectDirectory, requestID: nil)
    }

    /// Imports multiple FASTQ file pairs using the same user-configured settings.
    func importFASTQBatchWithConfig(
        pairs: [FASTQFilePair],
        config: FASTQImportConfiguration,
        projectDirectory: URL,
        requestID: String?
    ) {
        guard let viewerController = self.viewerController else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, pair) in pairs.enumerated() {
                await self.importFASTQPair(
                    pair: pair, index: index, totalPairs: pairs.count,
                    config: config, projectDirectory: projectDirectory,
                    viewerController: viewerController, requestID: requestID
                )
            }
        }
    }

    /// Imports a single FASTQ pair, resolving duplicates via sheet if needed.
    func importFASTQPair(
        pair: FASTQFilePair, index: Int, totalPairs: Int,
        config: FASTQImportConfiguration, projectDirectory: URL,
        viewerController: ViewerViewController, requestID: String?
    ) async {
        let baseName = pair.sampleName
        var effectiveBundleName = baseName

        let bundleExt = FASTQBundle.directoryExtension
        var bundleURL = projectDirectory.appendingPathComponent("\(effectiveBundleName).\(bundleExt)")

        // Check for existing bundle
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let resolution = await showDuplicateFileDialog(filename: "\(effectiveBundleName).\(bundleExt)")
            switch resolution {
            case .replace:
                do {
                    try FileManager.default.removeItem(at: bundleURL)
                } catch {
                    mainSplitLogger.error("importFASTQBatch: Failed to remove existing bundle: \(error)")
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: error.localizedDescription)
                    return
                }
            case .keepBoth:
                var counter = 2
                var uniqueName = "\(baseName) \(counter)"
                while FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("\(uniqueName).\(bundleExt)").path) {
                    counter += 1
                    uniqueName = "\(baseName) \(counter)"
                }
                effectiveBundleName = uniqueName
                bundleURL = projectDirectory.appendingPathComponent("\(effectiveBundleName).\(bundleExt)")
            case .skip:
                displayGenomicsFile(url: bundleURL)
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                return
            }
        }

        let progressMessage = totalPairs > 1
            ? "Importing \(index + 1) of \(totalPairs): \(pair.r1.lastPathComponent)\u{2026}"
            : "Importing \(pair.r1.lastPathComponent)\u{2026}"
        viewerController.showProgress(progressMessage)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            FASTQIngestionService.ingestAndBundle(
                pair: pair,
                projectDirectory: projectDirectory,
                bundleName: effectiveBundleName,
                importConfig: config,
                routeContext: operationRouteContext
            ) { [weak self, weak viewerController] result in
                defer { continuation.resume() }
                switch result {
                case .success(let bundleURL):
                    viewerController?.hideProgress()
                    self?.sidebarController.reloadFromFilesystem()
                    self?.displayGenomicsFile(url: bundleURL)
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                case .failure(let error):
                    viewerController?.hideProgress()
                    mainSplitLogger.error("importFASTQBatch: \(error)")
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: error.localizedDescription)
                    let alert = NSAlert()
                    alert.messageText = "Failed to Import FASTQ"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.applyLungfishBranding()
                    if let window = self?.view.window ?? NSApp.keyWindow {
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    // MARK: - Duplicate File Handling

    /// Shows a dialog asking the user how to handle a duplicate file
    /// Shows a dialog asking the user how to handle a duplicate file
    func showDuplicateFileDialog(filename: String) async -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file named \"\(filename)\" already exists in this location. What would you like to do?"
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Replace")    // First button = index 1000
        alert.addButton(withTitle: "Keep Both")  // Second button = index 1001
        alert.addButton(withTitle: "Skip")       // Third button = index 1002

        alert.applyLungfishBranding()

        guard let window = self.view.window ?? NSApp.keyWindow else { return .skip }
        let response = await alert.beginSheetModal(for: window)

        switch response {
        case .alertFirstButtonReturn:  // Replace
            return .replace
        case .alertSecondButtonReturn: // Keep Both
            return .keepBoth
        default:                       // Skip or Cancel
            return .skip
        }
    }

    /// Generates a unique filename by appending a number suffix
    func generateUniqueFilename(for sourceURL: URL, in targetDir: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var counter = 2
        var newURL = targetDir.appendingPathComponent("\(baseName) \(counter).\(ext)")

        while FileManager.default.fileExists(atPath: newURL.path) {
            counter += 1
            newURL = targetDir.appendingPathComponent("\(baseName) \(counter).\(ext)")
        }

        return newURL
    }

    // MARK: - FASTQ Import Pipeline

    /// Imports a FASTQ file: ingests in temp dir, then creates a `.lungfishfastq`
    /// bundle in the project with the processed file inside.
    ///
    /// Flow: source FASTQ → copy to temp → clumpify + compress → create bundle
    /// in project → move processed file into bundle → display.
    func importFASTQFileInBackground(sourceURL: URL, projectDirectory: URL, requestID: String?) {
        guard canWriteProjectOutputs(workflowName: "FASTQ import") else {
            postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: "Project is open read only.")
            return
        }
        guard let viewerController = self.viewerController else {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: sourceURL,
                success: false,
                error: "Viewer unavailable while importing FASTQ."
            )
            return
        }

        let baseName = FASTQBundle.deriveBaseName(from: sourceURL)
        let bundleExt = FASTQBundle.directoryExtension
        let bundleURL = projectDirectory.appendingPathComponent("\(baseName).\(bundleExt)")

        // Check for existing bundle
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolution = await self.showDuplicateFileDialog(filename: "\(baseName).\(bundleExt)")
                self.completeFASTQImport(
                    resolution: resolution, baseName: baseName, bundleExt: bundleExt,
                    bundleURL: bundleURL, sourceURL: sourceURL,
                    projectDirectory: projectDirectory, viewerController: viewerController,
                    requestID: requestID
                )
            }
        } else {
            performFASTQIngest(
                effectiveBundleName: baseName, sourceURL: sourceURL,
                projectDirectory: projectDirectory, viewerController: viewerController,
                requestID: requestID
            )
        }
    }

    /// Handles the duplicate resolution result and proceeds with FASTQ import.
    func completeFASTQImport(
        resolution: DuplicateResolution, baseName: String, bundleExt: String,
        bundleURL: URL, sourceURL: URL,
        projectDirectory: URL, viewerController: ViewerViewController,
        requestID: String?
    ) {
        var effectiveBundleName = baseName
        switch resolution {
        case .replace:
            do {
                try FileManager.default.removeItem(at: bundleURL)
            } catch {
                mainSplitLogger.error("importFASTQFileInBackground: Failed to remove existing bundle: \(error)")
                self.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Failed to Replace Bundle"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
                return
            }
        case .keepBoth:
            var counter = 2
            var uniqueName = "\(baseName) \(counter)"
            while FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("\(uniqueName).\(bundleExt)").path) {
                counter += 1
                uniqueName = "\(baseName) \(counter)"
            }
            effectiveBundleName = uniqueName
        case .skip:
            displayGenomicsFile(url: bundleURL)
            postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)
            return
        }
        performFASTQIngest(
            effectiveBundleName: effectiveBundleName, sourceURL: sourceURL,
            projectDirectory: projectDirectory, viewerController: viewerController,
            requestID: requestID
        )
    }

    /// Performs the actual FASTQ ingestion after duplicate resolution.
    func performFASTQIngest(
        effectiveBundleName: String, sourceURL: URL,
        projectDirectory: URL, viewerController: ViewerViewController,
        requestID: String?
    ) {
        viewerController.showProgress("Importing \(sourceURL.lastPathComponent)\u{2026}")

        FASTQIngestionService.ingestAndBundle(
            sourceURL: sourceURL,
            projectDirectory: projectDirectory,
            bundleName: effectiveBundleName,
            routeContext: operationRouteContext
        ) { [weak self, weak viewerController] result in
            viewerController?.hideProgress()
            switch result {
            case .success(let bundleURL):
                self?.sidebarController.reloadFromFilesystem()
                self?.displayGenomicsFile(url: bundleURL)
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)
            case .failure(let error):
                mainSplitLogger.error("importFASTQFileInBackground: \(error)")
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Failed to Import FASTQ"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                if let window = self?.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Returns `true` when the URL looks like an ONT instrument output directory
    /// (contains `barcode*` subdirectories with `.fastq.gz` chunks).
    func isONTDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard !FASTQBundle.isBundleURL(url) else {
            return false
        }
        // Quick probe — try detecting layout without throwing
        let importer = ONTDirectoryImporter()
        return (try? importer.detectLayout(at: url)) != nil
    }

    /// Imports an ONT output directory into per-barcode `.lungfishfastq` bundles
    /// via the ONTDirectoryImporter, running in the background.
    func importONTDirectoryInBackground(sourceURL: URL, projectURL: URL, requestID: String? = nil) {
        guard canWriteProjectOutputs(workflowName: "ONT import") else {
            postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: "Project is open read only.")
            return
        }
        guard let viewerController = self.viewerController else {
            postSidebarFileDropCompleted(
                requestID: requestID,
                sourceURL: sourceURL,
                success: false,
                error: "Viewer unavailable while importing ONT directory."
            )
            return
        }

        // Ask for ONT-specific import options before creating scientific data.
        let importer = ONTDirectoryImporter()
        let layout = try? importer.detectLayout(at: sourceURL)
        let hasUnclassified = layout?.hasUnclassified ?? false

        if let window = self.view.window ?? NSApp.keyWindow {
            let alert = NSAlert()
            alert.messageText = "ONT Directory Import"
            if let layout {
                alert.informativeText = "Found \(layout.barcodeDirectories.count) barcode directories."
            } else {
                alert.informativeText = "Choose how this ONT directory should be stored in the project."
            }
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10

            let storageRow = NSStackView()
            storageRow.orientation = .horizontal
            storageRow.alignment = .centerY
            storageRow.spacing = 8
            let storageLabel = NSTextField(labelWithString: "Storage")
            storageLabel.alignment = .right
            storageLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let storagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            storagePopup.addItems(withTitles: [
                "Keep chunks",
                "Flatten to single FASTQ",
            ])
            storagePopup.selectItem(at: 0)
            storagePopup.toolTip = "Keep chunked ONT files for atomic bundle copies, or flatten each barcode into one FASTQ payload."
            storagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            storageRow.addArrangedSubview(storageLabel)
            storageRow.addArrangedSubview(storagePopup)
            stack.addArrangedSubview(storageRow)

            let optimizeStorageButton = NSButton(
                checkboxWithTitle: "Optimize flattened FASTQ with clumpify",
                target: nil,
                action: nil
            )
            optimizeStorageButton.state = .off
            optimizeStorageButton.toolTip = "Runs clumpify after flattened import. This can reduce storage size, but requires the managed BBTools environment."
            stack.addArrangedSubview(optimizeStorageButton)
            let accessoryController = ONTImportOptionsAccessoryController(
                storagePopup: storagePopup,
                optimizeStorageButton: optimizeStorageButton
            )

            let includeUnclassifiedButton: NSButton?
            if hasUnclassified {
                let checkbox = NSButton(checkboxWithTitle: "Include unclassified reads", target: nil, action: nil)
                checkbox.state = .off
                stack.addArrangedSubview(checkbox)
                includeUnclassifiedButton = checkbox
            } else {
                includeUnclassifiedButton = nil
            }

            stack.frame = NSRect(x: 0, y: 0, width: 360, height: hasUnclassified ? 104 : 72)
            alert.accessoryView = stack
            alert.applyLungfishBranding()
            alert.beginSheetModal(for: window) { [weak self] response in
                _ = accessoryController
                guard response == .alertFirstButtonReturn else {
                    self?.postSidebarFileDropCompleted(
                        requestID: requestID,
                        sourceURL: sourceURL,
                        success: true,
                        error: nil
                    )
                    return
                }
                let includeUnclassified = includeUnclassifiedButton?.state == .on
                let storageMode: ONTImportStorageMode = storagePopup.indexOfSelectedItem == 1 ? .flattened : .chunked
                let optimizeStorage = storageMode == .flattened && optimizeStorageButton.state == .on
                MainActor.assumeIsolated {
                    self?.performONTImport(
                        sourceURL: sourceURL, projectURL: projectURL,
                        includeUnclassified: includeUnclassified,
                        storageMode: storageMode,
                        optimizeStorage: optimizeStorage,
                        viewerController: viewerController, requestID: requestID
                    )
                }
            }
        } else {
            performONTImport(
                sourceURL: sourceURL, projectURL: projectURL,
                includeUnclassified: false,
                storageMode: .chunked,
                optimizeStorage: false,
                viewerController: viewerController, requestID: requestID
            )
        }
    }

    /// Performs the actual ONT directory import after the user has chosen whether to include unclassified reads.
    func performONTImport(
        sourceURL: URL, projectURL: URL,
        includeUnclassified: Bool,
        storageMode: ONTImportStorageMode,
        optimizeStorage: Bool,
        viewerController: ViewerViewController, requestID: String?
    ) {
        viewerController.showProgress("Importing ONT directory\u{2026}")
        let coordinator = ONTImportOperationCoordinator(operationCenter: .shared)
        let routeContext = operationRouteContext

        Task(priority: .userInitiated) { [weak self, weak viewerController] in
            do {
                let workflowResult = try await coordinator.importDirectory(
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    includeUnclassified: includeUnclassified,
                    storageMode: storageMode,
                    optimizeStorage: optimizeStorage,
                    qualityBinning: .none,
                    routeContext: routeContext
                )
                let result = workflowResult.importResult

                let detail = "\(result.bundleURLs.count) barcode bundles, \(result.totalReadCount) reads"
                mainSplitLogger.info("importONTDirectoryInBackground: \(detail)")

                viewerController?.hideProgress()
                self?.sidebarController.reloadFromFilesystem()
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: true, error: nil)

                // Display the first bundle
                if let firstBundle = result.bundleURLs.first {
                    self?.displayGenomicsFile(url: firstBundle)
                }
            } catch {
                mainSplitLogger.error("importONTDirectoryInBackground: \(error)")
                viewerController?.hideProgress()
                self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: sourceURL, success: false, error: error.localizedDescription)

                let alert = NSAlert()
                alert.messageText = "ONT Import Failed"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                if let window = self?.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    func postSidebarFileDropCompleted(requestID: String?, sourceURL: URL, success: Bool, error: String?) {
        var userInfo: [String: Any] = [
            "url": sourceURL,
            "success": success
        ]
        if let requestID {
            userInfo["requestID"] = requestID
        }
        if let error {
            userInfo["error"] = error
        }
        NotificationCenter.default.post(
            name: .sidebarFileDropCompleted,
            object: self,
            userInfo: userInfo
        )
    }

}
