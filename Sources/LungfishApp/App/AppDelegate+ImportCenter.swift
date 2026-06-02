// AppDelegate+ImportCenter.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3
import os
import LungfishKit

extension AppDelegate {
    // MARK: - Import Center URL-Accepting Methods

    /// Import a BAM file from a known URL (called from Import Center).
    func importBAMFromURL(_ url: URL) {
        guard let originController = activeMainWindowController(),
              let viewerController = originController.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing alignments.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "BAM import",
            presentingWindow: originController.window
        ) else { return }
        performBAMImport(
            bamURL: url,
            bundleURL: bundleURL,
            routeContext: currentOperationRouteContext(for: originController)
        )
    }

    /// Import a VCF file from a known URL (called from Import Center).
    func importVCFFromURL(_ url: URL) {
        guard let originController = activeMainWindowController(),
              let originSplit = originController.mainSplitViewController else {
            showAlert(title: "No Project Open", message: "Please open a project before importing variants.")
            return
        }
        let viewerController = originSplit.viewerController
        let bundleURL = viewerController?.currentBundleURL
        if let bundleURL {
            guard canWriteProjectOutputs(
                projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
                windowStateScope: originController.projectSession.windowStateScope,
                workflowName: "VCF import",
                presentingWindow: originController.window
            ) else { return }
            performVCFImport(
                vcfURL: url,
                bundleURL: bundleURL,
                routeContext: currentOperationRouteContext(for: originController)
            )
        } else {
            originSplit.loadVCFFilesInBackground(urls: [url])
        }
    }

    /// Import a GTF/GFF/GFF3/BED annotation track from a known URL (called from Import Center).
    func importAnnotationTrackFromURL(_ url: URL) {
        importAnnotationTracksFromURLs([url])
    }

    /// Import GTF/GFF/GFF3/BED annotation tracks from known URLs (called from Import Center).
    func importAnnotationTracksFromURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let unsupported = urls.filter { ReferenceBundleImportService.classify($0) != .annotationTrack }
        guard unsupported.isEmpty else {
            showAlert(title: "Unsupported Annotation Import", message: "Select a GTF, GFF, GFF3, or BED file.")
            return
        }

        guard let originController = activeMainWindowController(),
              let originSplit = originController.mainSplitViewController,
              let projectURL = originSplit.sidebarController.currentProjectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing annotation tracks.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "Annotation import",
            presentingWindow: originController.window
        ) else { return }

        let preferredBundleURL = originSplit.viewerController.currentBundleURL
        ReferenceBundleAnnotationImportConfigurationPresenter.present(
            projectURL: projectURL,
            preferredBundleURL: preferredBundleURL,
            sourceURL: urls[0],
            presentingWindow: originController.window
        ) { [weak self] configuration in
            guard let self, let configuration else { return }
            if urls.count == 1 {
                Task { [weak self] in
                    await self?.performSingleAnnotationTrackImport(
                        annotationURL: urls[0],
                        configuration: configuration
                    )
                }
            } else {
                self.performAnnotationTrackImports(
                    annotationURLs: urls,
                    bundleURL: configuration.bundleURL
                )
            }
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

        // Collect FASTQ files, expanding directories. Existing `.lungfishfastq`
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
                        } else if FASTQBundle.isFASTQFileURL(fileURL) {
                            fastqURLs.append(fileURL)
                        }
                    }
                }
            } else if FASTQBundle.isFASTQFileURL(url) {
                fastqURLs.append(url)
            }
        }

        guard !fastqURLs.isEmpty || !fastqBundleURLs.isEmpty else {
            showAlert(title: "No FASTQ Files Found", message: "The selected files or folders do not contain any FASTQ files.")
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

    func importFASTAFromURL(_ url: URL, routeContext: OperationRouteContext? = nil) {
        guard let controller = targetMainWindowController(routeContext: routeContext) ?? activeMainWindowController(),
              let sidebarController = controller.mainSplitViewController?.sidebarController,
              let projectURL = routeContext?.projectURL ?? sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing reference sequences.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            workflowName: "Reference import",
            presentingWindow: controller.window
        ) else { return }

        guard ReferenceBundleImportService.isStandaloneReferenceSource(url) else {
            let classification = ReferenceBundleImportService.classify(url)
            let message: String
            switch classification {
            case .annotationTrack:
                message = "Annotation files should be imported into an existing reference bundle."
            case .variantTrack:
                message = "VCF/BCF files should be imported with the variant import workflow."
            case .alignmentTrack:
                message = "Alignment files should be imported into an existing reference bundle."
            case .unsupported:
                message = "This file type is not supported for standalone reference import."
            case .standaloneReferenceSequence:
                message = "Unexpected reference import classification."
            }
            showAlert(title: "Unsupported Reference Import", message: message)
            return
        }

        let refsDir: URL
        do {
            refsDir = try ReferenceSequenceFolder.ensureFolder(in: projectURL)
        } catch {
            showAlert(title: "Import Failed", message: "Could not prepare Reference Sequences folder: \(error.localizedDescription)")
            return
        }

        let routeContext = routeContext ?? currentOperationRouteContext(for: controller)
        let cliCmd = OperationCenter.buildCLICommand(
            subcommand: "import",
            args: ["fasta", url.path, "--output-dir", refsDir.path]
        )

        let opID = OperationCenter.shared.start(
            title: "Reference Import",
            detail: "Importing \(url.lastPathComponent)...",
            operationType: .bundleBuild,
            cliCommand: cliCmd,
            routeContext: routeContext
        )

        Task.detached { [weak self] in
            do {
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

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "Imported \(result.bundleURL.lastPathComponent)",
                            bundleURLs: [result.bundleURL]
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        self?.showAlert(
                            title: "Reference Import Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
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
        let opID = OperationCenter.shared.start(
            title: "Geneious Import",
            detail: "Importing \(url.lastPathComponent)...",
            operationType: .applicationExportImport,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: {
                Task { await runner.cancel() }
            }
        )

        Task.detached { [weak self] in
            do {
                let result = try await runner.run(arguments: arguments, operationID: opID)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = result.warningCount == 0
                            ? "Imported \(result.collectionURL.lastPathComponent)"
                            : "Imported \(result.collectionURL.lastPathComponent) with \(result.warningCount) warnings"
                        if result.warningCount == 0 {
                            OperationCenter.shared.complete(id: opID, detail: detail)
                        } else {
                            OperationCenter.shared.completeWithWarning(id: opID, detail: detail)
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
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        self?.showAlert(title: "Geneious Import Failed", message: error.localizedDescription)
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
        let opID = OperationCenter.shared.start(
            title: "\(kind.displayName) Import",
            detail: "Importing \(url.lastPathComponent)...",
            operationType: .applicationExportImport,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: {
                Task { await runner.cancel() }
            }
        )

        Task.detached { [weak self] in
            do {
                let result = try await runner.run(arguments: arguments, operationID: opID)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = result.warningCount == 0
                            ? "Imported \(result.collectionURL.lastPathComponent)"
                            : "Imported \(result.collectionURL.lastPathComponent) with \(result.warningCount) warnings"
                        if result.warningCount == 0 {
                            OperationCenter.shared.complete(id: opID, detail: detail)
                        } else {
                            OperationCenter.shared.completeWithWarning(id: opID, detail: detail)
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
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        self?.showAlert(title: "\(kind.displayName) Import Failed", message: error.localizedDescription)
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
        let operationType: OperationType = kind == .msa
            ? .multipleSequenceAlignmentImport
            : .phylogeneticTreeImport
        let opID = OperationCenter.shared.start(
            title: kind.operationTitle,
            detail: "Importing \(url.lastPathComponent)...",
            operationType: operationType,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "import",
                args: Array(arguments.dropFirst())
            ),
            routeContext: routeContext,
            onCancel: {
                Task { await runner.cancel() }
            }
        )

        Task.detached { [weak self] in
            do {
                let result = try await runner.run(arguments: arguments, operationID: opID)

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = result.warningCount == 0
                            ? "Imported \(result.bundleURL.lastPathComponent)"
                            : "Imported \(result.bundleURL.lastPathComponent) with \(result.warningCount) warnings"
                        if result.warningCount == 0 {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: detail,
                                bundleURLs: [result.bundleURL]
                            )
                        } else {
                            OperationCenter.shared.completeWithWarning(
                                id: opID,
                                detail: detail,
                                bundleURLs: [result.bundleURL]
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        self?.showAlert(title: "\(kind.operationTitle) Failed", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func performAnnotationTrackImports(annotationURLs: [URL], bundleURL: URL) {
        guard !annotationURLs.isEmpty else { return }

        Task { [weak self] in
            for annotationURL in annotationURLs {
                await self?.performSingleAnnotationTrackImport(annotationURL: annotationURL, bundleURL: bundleURL)
            }
        }
    }

    private func performSingleAnnotationTrackImport(
        annotationURL: URL,
        configuration: ReferenceBundleAnnotationImportConfiguration
    ) async {
        await performSingleAnnotationTrackImport(
            annotationURL: annotationURL,
            bundleURL: configuration.bundleURL,
            trackID: configuration.trackID,
            trackName: configuration.trackName
        )
    }

    private func performSingleAnnotationTrackImport(annotationURL: URL, bundleURL: URL) async {
        await performSingleAnnotationTrackImport(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            trackID: nil,
            trackName: nil
        )
    }

    private func performSingleAnnotationTrackImport(
        annotationURL: URL,
        bundleURL: URL,
        trackID: String?,
        trackName: String?
    ) async {
        let routeContext = currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Annotation import"
        ) else { return }
        let opID = OperationCenter.shared.start(
            title: "Annotation Import",
            detail: "Importing \(annotationURL.lastPathComponent)...",
            operationType: .bundleBuild,
            cliCommand: nil,
            routeContext: routeContext
        )

        do {
            let result = try await ReferenceBundleAnnotationImportService()
                .attachAnnotationTrack(
                    sourceURL: annotationURL,
                    bundleURL: bundleURL,
                    trackID: trackID,
                    trackName: trackName
                )
            OperationCenter.shared.complete(
                id: opID,
                detail: "Imported \(result.featureCount) annotations"
            )
            let targetController = targetMainWindowController(routeContext: routeContext)
            refreshSidebarAndSelectImportedURL(bundleURL, in: targetController)
            if let viewerController = targetController?.mainSplitViewController?.viewerController,
               viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try viewerController.displayBundle(at: bundleURL)
            }
        } catch {
            OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
            showAlert(title: "Annotation Import Failed", message: error.localizedDescription)
        }
    }

    /// Import a Kraken2 result file (.kreport) from a known URL (called from Import Center).
    func importKraken2ResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .kraken2,
            operationTitle: "Kraken2 Import",
            missingProjectMessage: "Please open a project before importing classification results."
        )
    }

    /// Import an EsViritu result from a known URL (called from Import Center).
    func importEsVirituResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .esviritu,
            operationTitle: "EsViritu Import",
            missingProjectMessage: "Please open a project before importing EsViritu results."
        )
    }

    /// Import a TaxTriage result from a known URL (called from Import Center).
    func importTaxTriageResultFromURL(_ url: URL) {
        importClassifierResultFromURL(
            url,
            kind: .taxtriage,
            operationTitle: "TaxTriage Import",
            missingProjectMessage: "Please open a project before importing TaxTriage results."
        )
    }

    internal func importNaoMgsResultFromURL(_ url: URL, routeContext: OperationRouteContext? = nil) {
        importClassifierResultFromURL(
            url,
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            missingProjectMessage: "Please open a project before importing NAO-MGS results.",
            routeContext: routeContext,
            naoMgsOptions: .init(fetchReferences: true)
        )
    }

    private func importClassifierResultFromURL(
        _ url: URL,
        kind: MetagenomicsImportKind,
        operationTitle: String,
        missingProjectMessage: String,
        preferredName: String? = nil,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        naoMgsOptions: MetagenomicsImportHelperClient.NaoMgsOptions? = nil
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let targetController = targetMainWindowController(routeContext: routeContext)
        guard let sidebarController = targetController?.mainSplitViewController?.sidebarController,
              let projectURL = sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: missingProjectMessage, presentingWindow: targetController?.window)
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: operationTitle,
            presentingWindow: targetController?.window
        ) else { return }

        // NAO-MGS results go to Analyses/ (they are analysis results, not raw imports)
        let outputDir: URL
        if kind == .naomgs {
            do {
                outputDir = try AnalysesFolder.url(for: projectURL)
            } catch {
                showAlert(title: "Import Failed", message: "Could not prepare Analyses folder: \(error.localizedDescription)", presentingWindow: targetController?.window)
                return
            }
        } else {
            outputDir = projectURL.appendingPathComponent("Imports", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            } catch {
                showAlert(title: "Import Failed", message: "Could not prepare Imports folder: \(error.localizedDescription)", presentingWindow: targetController?.window)
                return
            }
        }

        let importSubcommand = (kind == .naomgs) ? "nao-mgs" : kind.rawValue
        var cliArgs = [importSubcommand, url.path, "--output-dir", outputDir.path]
        if let preferredName,
           !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cliArgs.append(contentsOf: ["--name", preferredName])
        }
        if kind == .naomgs {
            let options = naoMgsOptions ?? .init()
            cliArgs.append(contentsOf: ["--fetch-references", options.fetchReferences ? "true" : "false"])
        }

        let cliCmd = OperationCenter.buildCLICommand(
            subcommand: "import",
            args: cliArgs
        )
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Importing \(url.lastPathComponent)...",
            cliCommand: cliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                let result = try await MetagenomicsImportHelperClient.importViaCLI(
                    kind: kind,
                    inputURL: url,
                    outputDirectory: outputDir,
                    preferredName: preferredName,
                    naoMgsOptions: naoMgsOptions
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

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: result.detail,
                            bundleURLs: [result.resultDirectory]
                        )
                        OperationCenter.shared.log(
                            id: opID,
                            level: .info,
                            message: "Imported result at \(result.resultDirectory.lastPathComponent)"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let detail = error.localizedDescription
                        OperationCenter.shared.fail(id: opID, detail: detail)

                        // Cleanup partial result directory left by failed import
                        if let partialDir = (error as? MetagenomicsImportHelperClientError)?
                            .partialResultDirectory {
                            try? FileManager.default.removeItem(at: partialDir)
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "Cleaned up partial import directory"
                            )
                        }

                        self?.showAlert(
                            title: "\(operationTitle) Failed",
                            message: detail,
                            presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                        )
                    }
                }
            }
        }

        // Wire cancellation so the Operations Panel cancel button stops downloads.
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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

                var totalUpdated = 0
                var updatedTracks = 0

                for track in manifest.variants {
                    guard let databasePath = track.databasePath else {
                        debugLog("performSampleMetadataImport: Skipping track '\(track.name)' (no databasePath)")
                        continue
                    }
                    let dbURL = bundleURL.appendingPathComponent(databasePath)
                    let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                    let updated = try rwDB.importSampleMetadata(from: metadataURL, format: format)
                    totalUpdated += updated
                    updatedTracks += 1
                    debugLog("performSampleMetadataImport: Track '\(track.name)' updated \(updated) rows")
                }

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
                        message: "Updated \(totalUpdated.formatted()) sample metadata values across \(updatedTracks) variant track(s).",
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

    internal func performVCFImport(vcfURL: URL, bundleURL: URL, routeContext explicitRouteContext: OperationRouteContext? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "VCF import",
            presentingWindow: targetMainWindowController(routeContext: routeContext)?.window
        ) else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return
        }

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let selectedImportProfile = selectedVCFImportProfile()
        let profileLabel = Self.importProfileLabel(selectedImportProfile)
        var helperBaseURL = vcfURL
        if helperBaseURL.pathExtension.lowercased() == "gz" {
            helperBaseURL = helperBaseURL.deletingPathExtension()
        }
        if helperBaseURL.pathExtension.lowercased() == "vcf" {
            helperBaseURL = helperBaseURL.deletingPathExtension()
        }
        let helperTrackID = helperBaseURL.lastPathComponent
        let helperDBPath = bundleURL
            .appendingPathComponent("variants")
            .appendingPathComponent("\(helperTrackID).db")
            .path
        let cliCmd = OperationCenter.buildCLICommand(
            subcommand: "--vcf-import-helper",
            args: [
                "--vcf-path", vcfURL.path,
                "--output-db-path", helperDBPath,
                "--source-file", vcfURL.lastPathComponent,
                "--import-profile", selectedImportProfile.rawValue,
            ]
        )
        let opID = OperationCenter.shared.start(
            title: "Importing \(vcfURL.lastPathComponent)",
            detail: "Importing VCF variants (\(profileLabel))...",
            operationType: .vcfImport,
            targetBundleURL: bundleURL,
            cliCommand: cliCmd,
            routeContext: routeContext,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )
        let importStartedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            // All file I/O on background thread — no UI references captured
            let result: Result<(variantCount: Int, trackInfo: VariantTrackInfo), Error>
            let isCancelled: @Sendable () -> Bool = { cancelFlag.withLock { $0 } }

            // Compute dbURL before `do` so it's available for cleanup on cancellation
            var baseURL = vcfURL
            if baseURL.pathExtension.lowercased() == "gz" {
                baseURL = baseURL.deletingPathExtension()
            }
            if baseURL.pathExtension.lowercased() == "vcf" {
                baseURL = baseURL.deletingPathExtension()
            }
            let trackId = baseURL.lastPathComponent
            let dbFilename = "\(trackId).db"
            let variantsDir = bundleURL.appendingPathComponent("variants")
            let dbURL = variantsDir.appendingPathComponent(dbFilename)

            do {
                // Create variants directory if needed
                try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)

                let variantCount: Int

                // Check if there's a resumable incomplete import from a previous crash.
                let detectedImportState = VariantDatabase.importState(at: dbURL)
                let dbExists = FileManager.default.fileExists(atPath: dbURL.path)
                debugLog("performVCFImport: dbExists=\(dbExists), importState=\(detectedImportState ?? "nil"), path=\(dbURL.lastPathComponent)")

                func runFreshImport(startedAt: Date) throws -> Int {
                    if FileManager.default.fileExists(atPath: dbURL.path) {
                        try FileManager.default.removeItem(at: dbURL)
                    }

                    debugLog("performVCFImport: Creating variant database at \(dbURL.lastPathComponent) via helper")

                    do {
                        var importedCount = try Self.runVCFImportViaHelper(
                            vcfURL: vcfURL,
                            outputDBURL: dbURL,
                            sourceFile: vcfURL.lastPathComponent,
                            importProfile: selectedImportProfile,
                            shouldCancel: isCancelled,
                            progressHandler: { progress, message in
                                let clampedProgress = max(0.0, min(1.0, progress))
                                let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: startedAt)
                                let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                scheduleOnMainRunLoop {
                                    OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                }
                            }
                        )

                        // Staged ultra-low-memory imports intentionally return after insert
                        // phase with import_state=indexing so indexing runs in a fresh process.
                        if VariantDatabase.importState(at: dbURL) == "indexing" {
                            debugLog("performVCFImport: Insert phase complete, launching phase-2 index build helper")
                            let resumeStartedAt = Date()
                            importedCount = try Self.runVCFResumeViaHelper(
                                outputDBURL: dbURL,
                                shouldCancel: isCancelled,
                                progressHandler: { progress, message in
                                    let clampedProgress = max(0.0, min(1.0, progress))
                                    let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: resumeStartedAt)
                                    let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                    scheduleOnMainRunLoop {
                                        OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                    }
                                }
                            )
                            debugLog("performVCFImport: Phase-2 index build complete with \(importedCount) variants")
                        }

                        return importedCount
                    } catch {
                        // If helper failed during indexing, inserts are complete and only
                        // index creation needs recovery in a fresh process.
                        if let importState = VariantDatabase.importState(at: dbURL),
                           importState == "indexing" {
                            debugLog("performVCFImport: Helper failed during indexing, auto-resuming index creation...")
                            let resumeStartedAt = Date()
                            let resumedCount = try Self.runVCFResumeViaHelper(
                                outputDBURL: dbURL,
                                shouldCancel: isCancelled,
                                progressHandler: { progress, message in
                                    let clampedProgress = max(0.0, min(1.0, progress))
                                    let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: resumeStartedAt)
                                    let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                    scheduleOnMainRunLoop {
                                        OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                    }
                                }
                            )
                            debugLog("performVCFImport: Auto-resume complete with \(resumedCount) variants")
                            return resumedCount
                        }
                        throw error
                    }
                }

                if detectedImportState == "indexing" {
                    debugLog("performVCFImport: Found interrupted indexing phase, resuming via helper")
                    variantCount = try Self.runVCFResumeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            let clampedProgress = max(0.0, min(1.0, progress))
                            let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: importStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                } else if detectedImportState == "inserting" {
                    // Partial row ingest cannot be resumed safely without replaying the VCF.
                    debugLog("performVCFImport: Found interrupted inserting phase, restarting full import from source VCF")
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                } else if VariantDatabase.metadataValue(at: dbURL, key: "materialize_state") == "materializing" {
                    // Import is complete but materialization was interrupted — resume it.
                    debugLog("performVCFImport: Found incomplete materialization, resuming via helper")
                    let importedDB = try VariantDatabase(url: dbURL)
                    variantCount = importedDB.totalCount()

                    let materializeStartedAt = Date()
                    try Self.runVCFMaterializeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            let clampedProgress = max(0.0, min(1.0, progress))
                            let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: materializeStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                    debugLog("performVCFImport: Materialization resume complete")
                } else if dbExists, detectedImportState == nil,
                          VariantDatabase.hasVariantsTable(at: dbURL) {
                    // DB file exists with a variants table but import_state is unreadable
                    // (likely corrupted metadata from a crash). We cannot prove inserts
                    // completed, so rebuild from source VCF.
                    debugLog("performVCFImport: DB has variants table but missing import_state, restarting full import from source VCF")
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                } else {
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                }

                debugLog("performVCFImport: Created database with \(variantCount) variants")
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
                }

                // Normalize chromosome names to match the bundle.
                // Only performs name-based mapping (aliases, chr prefix, version suffix).
                // Length-based matching is deferred to the runtime alias map which uses
                // contig lengths stored in the database — this avoids slow UPDATE statements
                // on very large databases.
                let currentManifestForChrom = try BundleManifest.load(from: bundleURL)
                let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                let vcfChroms = rwDB.allChromosomes()
                let chromMapping = mapVCFChromosomes(vcfChroms, toBundleChromosomes: currentManifestForChrom.genome?.chromosomes ?? [])
                if !chromMapping.isEmpty {
                    try rwDB.renameChromosomes(chromMapping)
                    debugLog("performVCFImport: Remapped chromosomes: \(chromMapping)")
                }
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
                }

                // Materialize variant_info EAV table if it was skipped during
                // ultraLowMemory import.  This runs as a separate helper process
                // with a fresh address space so it cannot OOM the GUI.
                if rwDB.variantInfoSkipped {
                    debugLog("performVCFImport: Variant info was skipped — launching materialization helper")
                    let materializeStartedAt = Date()
                    try Self.runVCFMaterializeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            // Map materialization progress to the tail end of the operation
                            let displayProgress = 0.95 + progress * 0.05
                            let clampedProgress = max(0.0, min(1.0, displayProgress))
                            let etaText = Self.estimatedRemainingText(progress: progress, startedAt: materializeStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                    debugLog("performVCFImport: Materialization complete")
                }

                // Create VariantTrackInfo
                let trackInfo = VariantTrackInfo(
                    id: trackId,
                    name: vcfURL.deletingPathExtension().lastPathComponent,
                    description: "Imported from \(vcfURL.lastPathComponent)",
                    path: "variants/\(trackId).bcf",
                    indexPath: "variants/\(trackId).bcf.csi",
                    databasePath: "variants/\(dbFilename)",
                    variantType: .mixed,
                    variantCount: variantCount,
                    source: "VCF Import"
                )

                // Load current manifest, add track, save
                let currentManifest = try BundleManifest.load(from: bundleURL)

                // Check for duplicate track ID — remove old entry if re-importing
                let filteredVariants = currentManifest.variants.filter { $0.id != trackId }
                let baseManifest: BundleManifest
                if filteredVariants.count != currentManifest.variants.count {
                    baseManifest = BundleManifest(
                        formatVersion: currentManifest.formatVersion,
                        name: currentManifest.name,
                        identifier: currentManifest.identifier,
                        description: currentManifest.description,
                        createdDate: currentManifest.createdDate,
                        modifiedDate: Date(),
                        source: currentManifest.source,
                        genome: currentManifest.genome,
                        annotations: currentManifest.annotations,
                        variants: filteredVariants,
                        tracks: currentManifest.tracks,
                        metadata: currentManifest.metadata
                    )
                } else {
                    baseManifest = currentManifest
                }

                let updatedManifest = baseManifest.addingVariantTrack(trackInfo)
                try updatedManifest.save(to: bundleURL)

                result = .success((variantCount, trackInfo))
            } catch {
                result = .failure(error)
            }

            debugLog("performVCFImport: Background work done, scheduling main thread callback")

            scheduleOnMainRunLoop { [weak self] in
                debugLog("performVCFImport: Main thread callback executing")

                switch result {
                case .success(let (variantCount, _)):
                    OperationCenter.shared.complete(id: opID, detail: "\(variantCount) variants imported")

                    guard let viewerController = self?.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?.viewerController else {
                        debugLog("performVCFImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performVCFImport: Bundle reloaded with \(variantCount) variants")
                    } catch {
                        debugLog("performVCFImport: Bundle reload failed: \(error.localizedDescription)")
                        self?.showAlert(title: "Import Error", message: "VCF imported but bundle reload failed: \(error.localizedDescription)")
                    }

                case .failure(let error):
                    if let dbErr = error as? VariantDatabaseError, case .cancelled = dbErr {
                        try? FileManager.default.removeItem(at: dbURL)
                        debugLog("performVCFImport: Cancelled by user")
                        // cancel() already called fail() via onCancel callback
                    } else {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        debugLog("performVCFImport: Failed: \(error.localizedDescription)")
                        self?.showAlert(title: "VCF Import Failed", message: error.localizedDescription)
                    }
                }
            }
        }
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

    private nonisolated static func importProfileLabel(_ profile: VCFImportProfile) -> String {
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

    private nonisolated static func signalName(forTerminationStatus status: Int32) -> String? {
        switch status {
        case 9:
            return "SIGKILL"
        case 15:
            return "SIGTERM"
        case 6:
            return "SIGABRT"
        case 11:
            return "SIGSEGV"
        case 10:
            return "SIGBUS"
        case 5:
            return "SIGTRAP"
        case 2:
            return "SIGINT"
        default:
            return nil
        }
    }

    private nonisolated static func runVCFImportViaHelper(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper import")
        }

        let vcfImportTempDir = try ProjectTempDirectory.createFromContext(
            prefix: "vcf-import-", contextURL: outputDBURL)
        defer { try? FileManager.default.removeItem(at: vcfImportTempDir) }
        let debugLogURL = vcfImportTempDir.appendingPathComponent("debug.log")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-import-helper",
            "--vcf-path", vcfURL.path,
            "--output-db-path", outputDBURL.path,
            "--source-file", sourceFile,
            "--import-profile", importProfile.rawValue,
            "--debug-log-path", debugLogURL.path,
        ]
        debugLog(
            "runVCFImportViaHelper: launch helper=\(executablePath) vcf=\(vcfURL.lastPathComponent) db=\(outputDBURL.lastPathComponent) profile=\(importProfile.rawValue) debugLog=\(debugLogURL.path)"
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())
        let stderrState = OSAllocatedUnfairLock(initialState: Data())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    debugLog("runVCFImportViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                    parseState.withLock { state in
                        if state.helperError == nil {
                            state.helperError = text
                        }
                    }
                }
                return
            }

            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Importing VCF..."
                    debugLog("runVCFImportViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Importing VCF...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFImportViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF helper import failed"
                debugLog("runVCFImportViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFImportViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFImportViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrState.withLock { $0.append(data) }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                debugLog("runVCFImportViaHelper: stderr '\(String(text.prefix(300)))'")
            }
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFImportViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFImportViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let signalSuffix: String
            if process.terminationReason == .uncaughtSignal {
                let signalName = signalName(forTerminationStatus: process.terminationStatus)
                signalSuffix = " (signal \(process.terminationStatus)\(signalName.map { " \($0)" } ?? ""))"
            } else {
                signalSuffix = ""
            }
            let defaultMessage = "VCF helper exited with status \(process.terminationStatus)\(signalSuffix)"
            let baseMessage = helperError ?? (stderrMessage.isEmpty ? defaultMessage : stderrMessage)
            debugLog("runVCFImportViaHelper: failure '\(String(baseMessage.prefix(320)))'")
            let message = "\(baseMessage)\nDebug log: \(debugLogURL.path)"
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount = parseState.withLock({ $0.variantCount }) {
            return variantCount
        }

        let importedDB = try VariantDatabase(url: outputDBURL)
        return importedDB.totalCount()
    }

    /// Launch the helper process in `--vcf-resume-helper` mode to finish an
    /// interrupted import (creates missing indexes on an existing database).
    private nonisolated static func runVCFResumeViaHelper(
        outputDBURL: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper resume")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-resume-helper",
            "--output-db-path", outputDBURL.path,
        ]
        debugLog("runVCFResumeViaHelper: launch helper=\(executablePath) db=\(outputDBURL.lastPathComponent)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    debugLog("runVCFResumeViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                }
                return
            }
            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Resuming..."
                    debugLog("runVCFResumeViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Resuming...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFResumeViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF resume helper failed"
                debugLog("runVCFResumeViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFResumeViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFResumeViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFResumeViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFResumeViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let message = helperError ?? "VCF resume helper exited with status \(process.terminationStatus)"
            debugLog("runVCFResumeViaHelper: failure '\(String(message.prefix(320)))'")
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount = parseState.withLock({ $0.variantCount }) {
            return variantCount
        }

        let resumedDB = try VariantDatabase(url: outputDBURL)
        return resumedDB.totalCount()
    }

    /// Launch the helper process in `--vcf-materialize-helper` mode to populate
    /// the variant_info EAV table from raw INFO strings stored during
    /// ultraLowMemory import.
    @discardableResult
    private nonisolated static func runVCFMaterializeViaHelper(
        outputDBURL: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper materialize")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-materialize-helper",
            "--output-db-path", outputDBURL.path,
        ]
        debugLog("runVCFMaterializeViaHelper: launch helper=\(executablePath) db=\(outputDBURL.lastPathComponent)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    debugLog("runVCFMaterializeViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                }
                return
            }
            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Materializing..."
                    debugLog("runVCFMaterializeViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Materializing...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFMaterializeViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF materialize helper failed"
                debugLog("runVCFMaterializeViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFMaterializeViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFMaterializeViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFMaterializeViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFMaterializeViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let message = helperError ?? "VCF materialize helper exited with status \(process.terminationStatus)"
            debugLog("runVCFMaterializeViaHelper: failure '\(String(message.prefix(320)))'")
            throw VariantDatabaseError.createFailed(message)
        }

        return parseState.withLock { $0.variantCount } ?? 0
    }

    private nonisolated static func estimatedRemainingText(progress: Double, startedAt: Date) -> String {
        guard progress > 0.01, progress < 1.0 else { return "" }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return "" }
        let totalEstimate = elapsed / progress
        let remaining = max(0, totalEstimate - elapsed)
        guard remaining.isFinite else { return "" }

        let rounded = Int(remaining.rounded())
        if rounded < 60 {
            return "ETA ~\(rounded)s"
        }
        let mins = rounded / 60
        let secs = rounded % 60
        return secs == 0 ? "ETA ~\(mins)m" : "ETA ~\(mins)m \(secs)s"
    }

    // MARK: - BAM/CRAM Import

    internal func performBAMImport(bamURL: URL, bundleURL: URL, routeContext explicitRouteContext: OperationRouteContext? = nil) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "BAM import",
            presentingWindow: targetMainWindowController(routeContext: routeContext)?.window
        ) else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return
        }

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let cliCmd = OperationCenter.buildCLICommand(
            subcommand: "--bam-import-helper",
            args: [
                "--bam-path", bamURL.path,
                "--bundle-path", bundleURL.path,
                "--name", bamURL.lastPathComponent,
            ]
        )
        let opID = OperationCenter.shared.start(
            title: "Importing \(bamURL.lastPathComponent)",
            detail: "Importing alignments...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            cliCommand: cliCmd,
            routeContext: routeContext,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )
        let importStartedAt = Date()

        Task.detached {
            let result: Result<BAMImportHelperClient.Result, Error>
            do {
                let importResult = try await BAMImportHelperClient.importViaCLI(
                    bamURL: bamURL,
                    bundleURL: bundleURL,
                    name: bamURL.lastPathComponent,
                    shouldCancel: { cancelFlag.withLock { $0 } },
                    progressHandler: { progress, message in
                        let clampedProgress = max(0.0, min(1.0, progress))
                        let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: importStartedAt)
                        let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                        scheduleOnMainRunLoop {
                            OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                        }
                    }
                )
                result = .success(importResult)
            } catch {
                result = .failure(error)
            }

            scheduleOnMainRunLoop { [weak self] in
                switch result {
                case .success(let importResult):
                    let readCount = importResult.mappedReads + importResult.unmappedReads
                    OperationCenter.shared.complete(id: opID, detail: "\(readCount) reads imported")

                    guard let viewerController = self?.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?.viewerController else {
                        debugLog("performBAMImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performBAMImport: Bundle reloaded with alignment track (\(readCount) reads)")
                    } catch {
                        debugLog("performBAMImport: Bundle reload failed: \(error)")
                        self?.showAlert(title: "Import Error", message: "Alignments imported but bundle reload failed: \(error.localizedDescription)")
                    }

                case .failure(let error):
                    if cancelFlag.withLock({ $0 }) || error is CancellationError {
                        debugLog("performBAMImport: Cancelled by user")
                        // cancel() already called fail() via onCancel callback
                    } else {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        debugLog("performBAMImport: Failed: \(error)")
                        self?.showAlert(title: "BAM Import Failed", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc func exportFASTA(_ sender: Any?) {
        exportSequences(defaultFormat: .fasta)
    }

    @objc func exportGenBank(_ sender: Any?) {
        exportSequences(defaultFormat: .genbank)
    }

    /// Unified sequence export supporting multi-selection, format choice, and compression.
    private func exportSequences(defaultFormat: SequenceExportFormat) {
        // Try sidebar multi-selection first
        let sidebarItems = mainWindowController?.mainSplitViewController?.sidebarController?.selectedItems()
            .filter { $0.type == .referenceBundle || $0.type == .sequence } ?? []

        // Fall back to current document
        let documents: [SequenceExportDocumentSnapshot]
        if !sidebarItems.isEmpty {
            // Will load from sidebar items
            documents = []
        } else if let doc = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument,
                  !doc.sequences.isEmpty {
            documents = [SequenceExportDocumentSnapshot(
                name: doc.name,
                url: doc.url,
                sequences: doc.sequences,
                annotations: doc.annotations
            )]
        } else {
            showExportError(message: "No sequences to export. Select files in the sidebar or open a document.")
            return
        }

        guard let window = mainWindowController?.window else { return }

        let selectedBundleURLs = sidebarItems.compactMap(\.url)
        if sidebarItems.count > 1,
           sidebarItems.allSatisfy({ $0.type == .referenceBundle }),
           selectedBundleURLs.count == sidebarItems.count {
            presentBatchSequenceExport(
                bundleURLs: selectedBundleURLs,
                defaultFormat: defaultFormat,
                window: window
            )
            return
        }

        let baseName: String
        if sidebarItems.count == 1 {
            baseName = sidebarItems[0].title
        } else if sidebarItems.count > 1 {
            baseName = "exported_sequences"
        } else {
            baseName = documents[0].name.replacingOccurrences(of: ".\(documents[0].url.pathExtension)", with: "")
        }

        let panel = AppFilePanelFactory.sequenceExportPanel()
        let panelController = SequenceExportPanelController(
            panel: panel,
            defaultFormat: defaultFormat,
            filenameBaseName: baseName
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputURL = panel.url else { return }
            guard let self else { return }

            let format = panelController.selectedFormat
            let compression = panelController.selectedCompression

            let itemURLs = sidebarItems.compactMap(\.url)
            let exportTitle = "Exporting \(outputURL.lastPathComponent)"
            let opID = OperationCenter.shared.start(
                title: exportTitle,
                detail: "Preparing sequence export...",
                operationType: .export,
                cliCommand: Self.sequenceExportCLICommand(
                    inputURL: itemURLs.count == 1 ? itemURLs[0] : nil,
                    outputURL: outputURL,
                    format: format,
                    compression: compression
                ),
                routeContext: currentOperationRouteContext()
            )

            let task = Task.detached { [weak self] in
                do {
                    await appPerformOnMainRunLoop {
                        OperationCenter.shared.log(id: opID, level: .info, message: "Writing \(format.displayName) export to \(outputURL.path)")
                    }
                    let count = try await self?.performSequenceExport(
                        sidebarURLs: itemURLs,
                        documents: documents,
                        outputURL: outputURL,
                        format: format,
                        compression: compression
                    ) ?? 0

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "Exported \(count) sequence(s) to \(outputURL.lastPathComponent)"
                            )
                            let alert = NSAlert()
                            alert.messageText = "Export Complete"
                            alert.informativeText = "Exported \(count) sequence(s) to \(outputURL.lastPathComponent)."
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "OK")
                            alert.addButton(withTitle: "Show in Finder")
                            alert.beginSheetModal(for: window) { response in
                                if response == .alertSecondButtonReturn {
                                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                }
                            }
                        }
                    }
                } catch {
                    debugLog("exportSequences: Failed - \(error)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: error.localizedDescription,
                                errorMessage: "Sequence export failed",
                                errorDetail: error.localizedDescription
                            )
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

    private func presentBatchSequenceExport(
        bundleURLs: [URL],
        defaultFormat: SequenceExportFormat,
        window: NSWindow
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
            let cliCommands = Self.batchSequenceExportCLICommands(
                for: bundleURLs,
                outputFolder: outputFolder,
                format: format,
                compression: compression
            )
            let opID = OperationCenter.shared.start(
                title: "Exporting \(bundleURLs.count) sequence files",
                detail: "Preparing batch export...",
                operationType: .export,
                cliCommand: cliCommands.first.map { firstCommand in
                    guard cliCommands.count > 1 else { return firstCommand }
                    return "\(firstCommand)\n# ... \(cliCommands.count - 1) more export command(s)"
                },
                routeContext: currentOperationRouteContext()
            )

            let task = Task.detached { [weak self] in
                do {
                    var count = 0
                    for (index, bundleURL) in bundleURLs.enumerated() {
                        try Task.checkCancellation()
                        guard let outputURL = targets[bundleURL] else { continue }
                        await appPerformOnMainRunLoop {
                            let detail = "Exporting \(index + 1) of \(bundleURLs.count): \(bundleURL.deletingPathExtension().lastPathComponent)"
                            OperationCenter.shared.update(
                                id: opID,
                                progress: Double(index) / Double(max(bundleURLs.count, 1)),
                                detail: detail
                            )
                            OperationCenter.shared.log(id: opID, level: .info, message: "\(detail) -> \(outputURL.lastPathComponent)")
                        }
                        count += try await self?.performSequenceExport(
                            sidebarURLs: [bundleURL],
                            documents: [],
                            outputURL: outputURL,
                            format: format,
                            compression: compression
                        ) ?? 0
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: opID,
                                detail: "Exported \(bundleURLs.count) file(s) with \(count) sequence(s)"
                            )
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
                            OperationCenter.shared.fail(
                                id: opID,
                                detail: error.localizedDescription,
                                errorMessage: "Batch sequence export failed",
                                errorDetail: error.localizedDescription
                            )
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

    /// Loads sequences from sidebar URLs or documents, writes to output file, and optionally compresses.
    nonisolated private func performSequenceExport(
        sidebarURLs: [URL],
        documents: [SequenceExportDocumentSnapshot],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        if sidebarURLs.count == 1,
           let bundleURL = sidebarURLs.first,
           bundleURL.pathExtension.lowercased() == "lungfishref" {
            return try await performReferenceBundleSequenceExport(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: format,
                compression: compression
            )
        }

        // Collect all sequences and annotations
        var allSequences: [LungfishCore.Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []

        if !sidebarURLs.isEmpty {
            for url in sidebarURLs {
                try Task.checkCancellation()
                let (seqs, annots) = try await loadSequencesForExport(from: url)
                allSequences.append(contentsOf: seqs)
                allAnnotations.append(contentsOf: annots)
            }
        } else {
            for doc in documents {
                try Task.checkCancellation()
                allSequences.append(contentsOf: doc.sequences)
                allAnnotations.append(contentsOf: doc.annotations)
            }
        }

        guard !allSequences.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No sequences found in selected files."])
        }

        // Determine write target (temp file if compressing, final file if not)
        let writeURL: URL
        if compression != .none {
            let exportTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "export-", contextURL: outputURL)
            writeURL = exportTempDir.appendingPathComponent("export.\(format == .genbank ? "gb" : "fa")")
        } else {
            writeURL = outputURL
        }

        // Write the file
        switch format {
        case .fasta:
            let writer = FASTAWriter(url: writeURL)
            try writer.write(allSequences)

        case .genbank:
            var records: [GenBankRecord] = []
            for sequence in allSequences {
                let seqAnnotations = allAnnotations.filter {
                    $0.chromosome == nil || $0.chromosome == sequence.name
                }
                let moleculeType: MoleculeType
                switch sequence.alphabet {
                case .dna: moleculeType = .dna
                case .rna: moleculeType = .rna
                case .protein: moleculeType = .protein
                }
                let locus = LocusInfo(
                    name: sequence.name,
                    length: sequence.length,
                    moleculeType: moleculeType,
                    topology: .linear,
                    division: nil,
                    date: Self.currentDateString()
                )
                records.append(GenBankRecord(
                    sequence: sequence,
                    annotations: seqAnnotations,
                    locus: locus,
                    definition: sequence.description,
                    accession: nil,
                    version: nil
                ))
            }
            let writer = GenBankWriter(url: writeURL)
            try writer.write(records)
        }

        // Apply compression if needed
        if compression != .none {
            defer { try? FileManager.default.removeItem(at: writeURL.deletingLastPathComponent()) }
            switch compression {
            case .gzip:
                try compressExportFile(writeURL, to: outputURL, compression: .gzip)
            case .zstd:
                try compressExportFile(writeURL, to: outputURL, compression: .zstd)
            case .none:
                break
            }
        }

        return allSequences.count
    }

    nonisolated static func batchSequenceExportTargets(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [URL: URL] {
        var usedNames = Set<String>()
        var targets: [URL: URL] = [:]

        for bundleURL in bundleURLs {
            let rawBase = bundleURL.deletingPathExtension().lastPathComponent
            let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "reference" : rawBase
            var filename = "\(base).\(format.fileExtension)"
            if let compressionExtension = compression.fileExtension {
                filename += ".\(compressionExtension)"
            }

            if usedNames.contains(filename) {
                var counter = 2
                repeat {
                    filename = "\(base)-\(counter).\(format.fileExtension)"
                    if let compressionExtension = compression.fileExtension {
                        filename += ".\(compressionExtension)"
                    }
                    counter += 1
                } while usedNames.contains(filename)
            }

            usedNames.insert(filename)
            targets[bundleURL] = outputFolder.appendingPathComponent(filename)
        }

        return targets
    }

    nonisolated static func batchSequenceExportCLICommands(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [String] {
        let targets = batchSequenceExportTargets(
            for: bundleURLs,
            outputFolder: outputFolder,
            format: format,
            compression: compression
        )
        return bundleURLs.compactMap { bundleURL in
            guard let outputURL = targets[bundleURL] else { return nil }
            return sequenceExportCLICommand(
                inputURL: bundleURL,
                outputURL: outputURL,
                format: format,
                compression: compression
            )
        }
    }

    nonisolated static func sequenceExportCLICommand(
        inputURL: URL?,
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> String? {
        guard let inputURL else { return nil }
        guard compression == .none else { return nil }
        if inputURL.pathExtension.lowercased() == "lungfishref" {
            let args = Array(referenceBundleSequenceExportCLIArguments(
                bundleURL: inputURL,
                outputURL: outputURL,
                format: format
            ).dropFirst())
            return OperationCenter.buildCLICommand(subcommand: "convert", args: args)
        }
        let args = [
            inputURL.path,
            "--to", outputURL.path,
            "--to-format", format.cliFormat,
            "--force"
        ]
        return OperationCenter.buildCLICommand(subcommand: "convert", args: args)
    }

    nonisolated static func referenceBundleSequenceExportCLIArguments(
        bundleURL: URL,
        outputURL: URL,
        format: SequenceExportFormat
    ) -> [String] {
        [
            "convert",
            bundleURL.path,
            "--to", outputURL.path,
            "--to-format", format.cliFormat,
            "--include-annotations",
            "--force",
            "--quiet",
        ]
    }

    nonisolated private func performReferenceBundleSequenceExport(
        bundleURL: URL,
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        let manifest = try BundleManifest.load(from: bundleURL)
        try Task.checkCancellation()
        guard let genome = manifest.genome, !genome.chromosomes.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No genome sequence in bundle \(bundleURL.lastPathComponent)"])
        }

        if compression == .none {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cliOutput = try LungfishCLIRunner.run(arguments: Self.referenceBundleSequenceExportCLIArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: format
            ))
            if !cliOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                debugLog("performReferenceBundleSequenceExport: CLI stderr: \(cliOutput.stderr)")
            }
            return genome.chromosomes.count
        }

        let writeURL: URL
        if compression != .none {
            let exportTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "export-", contextURL: outputURL)
            writeURL = exportTempDir.appendingPathComponent("export.\(format.fileExtension)")
        } else {
            writeURL = outputURL
        }

        try? FileManager.default.removeItem(at: writeURL)

        let bundle = try await ReferenceBundle(url: bundleURL)
        let annotations = try loadBundleAnnotations(bundleURL: bundleURL, manifest: manifest)

        switch format {
        case .fasta:
            let writer = FASTAWriter(url: writeURL)
            for chromosome in genome.chromosomes {
                try Task.checkCancellation()
                let sequence = try await sequenceForWholeChromosome(chromosome, in: bundle)
                try writer.append(sequence)
            }
        case .genbank:
            let writer = GenBankWriter(url: writeURL)
            for chromosome in genome.chromosomes {
                try Task.checkCancellation()
                let sequence = try await sequenceForWholeChromosome(chromosome, in: bundle)
                let seqAnnotations = annotations.filter {
                    $0.chromosome == nil || $0.chromosome == sequence.name
                }
                let locus = LocusInfo(
                    name: sequence.name,
                    length: sequence.length,
                    moleculeType: .dna,
                    topology: .linear,
                    division: nil,
                    date: Self.currentDateString()
                )
                let record = GenBankRecord(
                    sequence: sequence,
                    annotations: seqAnnotations,
                    locus: locus,
                    definition: sequence.description,
                    accession: nil,
                    version: nil
                )
                try writer.append(record)
            }
        }

        if compression != .none {
            defer { try? FileManager.default.removeItem(at: writeURL.deletingLastPathComponent()) }
            try compressExportFile(writeURL, to: outputURL, compression: compression)
        }

        return genome.chromosomes.count
    }

    nonisolated private func sequenceForWholeChromosome(_ chromosome: ChromosomeInfo, in bundle: ReferenceBundle) async throws -> LungfishCore.Sequence {
        let region = GenomicRegion(chromosome: chromosome.name, start: 0, end: Int(chromosome.length))
        let bases = try await bundle.fetchSequence(region: region)
        return try LungfishCore.Sequence(
            name: chromosome.name,
            description: chromosome.fastaDescription,
            alphabet: .dna,
            bases: bases
        )
    }

    nonisolated private func loadBundleAnnotations(bundleURL: URL, manifest: BundleManifest) throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        for track in manifest.annotations {
            guard let dbPath = track.databasePath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            let db = try AnnotationDatabase(url: dbURL)
            let records = db.query(limit: Int.max)
            annotations.append(contentsOf: records.map { $0.toAnnotation() })
        }
        return annotations
    }

    nonisolated private func compressExportFile(
        _ writeURL: URL,
        to outputURL: URL,
        compression: SequenceExportCompression
    ) throws {
        let process = Process()
        switch compression {
        case .gzip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        case .zstd:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zstd")
        case .none:
            return
        }
        process.arguments = ["-c", writeURL.path]
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "com.lungfish.browser", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Compression failed for \(outputURL.lastPathComponent)."])
        }
    }

    /// Reads sequences and annotations from a file or reference bundle for export.
    ///
    /// For reference bundles, reads the FASTA directly and loads annotations from the
    /// annotation database (BigBed tracks) via the bundle's data provider.
    /// For GenBank files, reads both sequences and annotations from the file.
    /// For FASTA files, reads sequences only.
    nonisolated private func loadSequencesForExport(from url: URL) async throws -> ([LungfishCore.Sequence], [SequenceAnnotation]) {
        // Reference bundle: read FASTA path from manifest
        if url.pathExtension.lowercased() == "lungfishref" {
            let manifest = try BundleManifest.load(from: url)
            guard let genomePath = manifest.genome?.path else {
                throw NSError(domain: "com.lungfish.browser", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No genome sequence in bundle \(url.lastPathComponent)"])
            }
            let sourceURL = url.appendingPathComponent(genomePath)
            // Decompress to temp file if needed (FASTAReader doesn't handle gzip internally)
            let readURL: URL
            var tempDecompressed: URL?
            if sourceURL.pathExtension.lowercased() == "gz" {
                let decompTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "export-decomp-", contextURL: url)
                let tmpURL = decompTempDir.appendingPathComponent("decompressed.fa")
                let gzStream = try GzipInputStream(url: sourceURL)
                let content = try await gzStream.readAll()
                try content.write(to: tmpURL, atomically: true, encoding: .utf8)
                readURL = tmpURL
                tempDecompressed = tmpURL
            } else {
                readURL = sourceURL
            }
            defer { if let tmp = tempDecompressed { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) } }

            let reader = try FASTAReader(url: readURL)
            let sequences = try await reader.readAll()

            // Load annotations from annotation tracks in the bundle
            var annotations: [SequenceAnnotation] = []
            for track in manifest.annotations {
                // Prefer SQLite database (has rich metadata) over BigBed
                if let dbPath = track.databasePath {
                    let dbURL = url.appendingPathComponent(dbPath)
                    if FileManager.default.fileExists(atPath: dbURL.path) {
                        let db = try AnnotationDatabase(url: dbURL)
                        let records = db.query(limit: Int.max)
                        annotations.append(contentsOf: records.map { $0.toAnnotation() })
                        continue
                    }
                }
            }
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
    nonisolated private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }

    @objc func exportGFF3(_ sender: Any?) {
        // Get current document
        guard let document = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument else {
            showExportError(message: "No document is currently open.")
            return
        }

        // Check if there are annotations to export
        guard !document.annotations.isEmpty else {
            showExportError(message: "The current document has no annotations to export.")
            return
        }

        let suggestedName = document.name.replacingOccurrences(of: ".\(document.url.pathExtension)", with: "") + ".gff3"
        let panel = AppFilePanelFactory.gff3ExportPanel(suggestedName: suggestedName)

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            Task {
                do {
                    try await GFF3Writer.write(document.annotations, to: url, source: "Lungfish")

                    await MainActor.run {
                        debugLog("exportGFF3: Successfully exported \(document.annotations.count) annotations to \(url.path)")
                        self?.showExportSuccess(filename: url.lastPathComponent, count: document.annotations.count, itemType: "annotation")
                    }
                } catch {
                    await MainActor.run {
                        debugLog("exportGFF3: Export failed - \(error.localizedDescription)")
                        self?.showExportError(message: "Failed to export GFF3: \(error.localizedDescription)")
                    }
                }
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

    private func viewerExportViewAndRect(
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
