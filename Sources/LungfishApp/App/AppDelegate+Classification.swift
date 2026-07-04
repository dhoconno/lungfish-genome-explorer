// AppDelegate+Classification.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
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

    /// Runs the classification pipeline, dispatching based on the config's goal.
    ///
    /// Registers the operation with ``OperationCenter`` so it appears in the
    /// Operations Panel with live progress updates.
    ///
    /// - `.classify`: Runs Kraken2 only, displays taxonomy browser.
    /// - `.profile`: Runs Kraken2 + Bracken, displays taxonomy browser with abundances.
    /// - `.extract`: Runs Kraken2, displays taxonomy browser, then auto-presents
    ///   the extraction sheet so the user can select taxa to extract.
    internal func runClassification(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        guard let first = configs.first else { return }
        if configs.count == 1 {
            runClassification(config: first, viewerController: viewerController, routeContext: routeContext)
            return
        }
        runClassificationBatch(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    /// Resolves input FASTQ files using ``FASTQSourceResolver``, materializing
    /// virtual datasets as needed.
    ///
    /// Delegates to the centralized resolver from `LungfishWorkflow`, injecting
    /// `FASTQDerivativeService` as the materializer for derived bundles.
    /// Finds the `.lungfishfastq` bundle URL from a list of input file URLs.
    ///
    /// Handles two cases:
    /// 1. The URL itself is a bundle (e.g., `SRR123.lungfishfastq`)
    /// 2. The URL is a file inside a bundle (e.g., `SRR123.lungfishfastq/reads.fastq.gz`)
    static func findSourceBundle(for inputFiles: [URL]) -> URL? {
        for url in inputFiles {
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: url) {
                return bundleURL
            }
            if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: url) {
                return referenceBundleURL
            }
        }
        return nil
    }

    nonisolated internal static func durableSequenceInputsForProvenance(_ inputFiles: [URL]) -> [URL] {
        inputFiles.flatMap { inputURL -> [URL] in
            let standardizedInput = inputURL.standardizedFileURL
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInput) {
                if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                    let payloadURLs = durableMaterializedPayloadURLs(manifest.payload, in: bundleURL)
                    return payloadURLs.isEmpty ? [bundleURL] : payloadURLs
                }
                if let physicalFASTQs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL),
                   !physicalFASTQs.isEmpty {
                    return physicalFASTQs
                }
                return [bundleURL]
            }
            if let resolvedSequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedInput) {
                return [resolvedSequenceURL]
            }
            return [standardizedInput]
        }
    }

    nonisolated private static func durableDerivedPayloadURLs(
        _ payload: FASTQDerivativePayload,
        in bundleURL: URL
    ) -> [URL] {
        let candidates: [URL]
        switch payload {
        case .subset(let readIDListFilename):
            candidates = [bundleURL.appendingPathComponent(readIDListFilename)]
        case .trim(let trimPositionFilename):
            candidates = [bundleURL.appendingPathComponent(trimPositionFilename)]
        case .full(let fastqFilename):
            candidates = [bundleURL.appendingPathComponent(fastqFilename)]
        case .fullFASTA(let fastaFilename):
            candidates = [bundleURL.appendingPathComponent(fastaFilename)]
        case .fullPaired(let r1Filename, let r2Filename):
            candidates = [
                bundleURL.appendingPathComponent(r1Filename),
                bundleURL.appendingPathComponent(r2Filename),
            ]
        case .fullMixed(let classification):
            candidates = classification.files.map { bundleURL.appendingPathComponent($0.filename) }
        case .demuxedVirtual(_, let readIDListFilename, let previewFilename, let trimPositionsFilename, let orientMapFilename):
            candidates = [
                bundleURL.appendingPathComponent(readIDListFilename),
                bundleURL.appendingPathComponent(previewFilename),
                trimPositionsFilename.map { bundleURL.appendingPathComponent($0) },
                orientMapFilename.map { bundleURL.appendingPathComponent($0) },
            ].compactMap { $0 }
        case .orientMap(let orientMapFilename, let previewFilename):
            candidates = [
                bundleURL.appendingPathComponent(orientMapFilename),
                bundleURL.appendingPathComponent(previewFilename),
            ]
        case .demuxGroup:
            candidates = []
        }
        return candidates
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated private static func durableMaterializedPayloadURLs(
        _ payload: FASTQDerivativePayload,
        in bundleURL: URL
    ) -> [URL] {
        switch payload {
        case .full, .fullFASTA, .fullPaired, .fullMixed:
            return durableDerivedPayloadURLs(payload, in: bundleURL)
        case .subset, .trim, .demuxedVirtual, .demuxGroup, .orientMap:
            return []
        }
    }

    nonisolated internal static func durableSequenceInputRecordsForProvenance(_ inputFiles: [URL]) -> [FileRecord] {
        inputFiles.flatMap { inputURL -> [FileRecord] in
            let standardizedInput = inputURL.standardizedFileURL
            guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInput),
                  let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
                return durableSequenceInputsForProvenance([standardizedInput]).map {
                    ProvenanceRecorder.fileRecord(url: $0, role: .input)
                }
            }

            var durableURLs = [FASTQBundle.derivedManifestURL(in: bundleURL)]
            durableURLs += durableDerivedPayloadURLs(manifest.payload, in: bundleURL)

            let rootBundleURL = FASTQBundle.resolveBundle(
                relativePath: manifest.rootBundleRelativePath,
                from: bundleURL
            )
            let rootSequenceURL = rootBundleURL
                .appendingPathComponent(manifest.rootFASTQFilename)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: rootSequenceURL.path) {
                durableURLs.append(rootSequenceURL)
            }

            var seen = Set<String>()
            return durableURLs.compactMap { url in
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return nil }
                return ProvenanceRecorder.fileRecord(url: url, role: .input)
            }
        }
    }

    ///
    /// Called at the start of `runClassification` / `runEsViritu` / `runTaxTriage`
    /// so that dialogs appear instantly and materialization happens as the first
    /// pipeline step after the user clicks Run.
    internal func resolveInputFiles(
        _ inputFiles: [URL],
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [URL] {
        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, tempDir, progressCallback in
            try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDir,
                progress: { msg in progressCallback(msg) }
            )
        }

        var resolved: [URL] = []
        for inputURL in inputFiles {
            try Task.checkCancellation()

            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) {
                let urls = try await resolver.resolve(
                    bundleURL: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: { _, msg in progress?(msg) }
                )
                resolved.append(contentsOf: urls)
                continue
            }

            if let resolvedSequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) {
                resolved.append(resolvedSequenceURL)
                continue
            }

            resolved.append(inputURL)
        }
        return resolved
    }

    internal func runClassification(
        config: ClassificationConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Classification"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL) {
                config.outputDirectory = analysisDir
            }
        }

        let pipeline = ClassificationPipeline()

        // Build a descriptive title from the first input file and the goal.
        let inputName = config.inputFiles.first?.lastPathComponent ?? "reads"
        let goalLabel: String
        switch config.goal {
        case .classify: goalLabel = "Classifying"
        case .profile:  goalLabel = "Profiling"
        case .extract:  goalLabel = "Classifying (extract)"
        }
        let operationTitle = "\(goalLabel) \(inputName)"

        // Register the operation with OperationCenter so it appears in the Operations Panel.
        let cliCmd = OperationCenter.buildCLICommand(subcommand: "classify", args: {
            var args = ["--db", config.databasePath.path]
            args += config.inputFiles.map(\.path)
            return args
        }())
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Starting Kraken2 with \(config.databaseName)...",
            operationType: .classification,
            cliCommand: cliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs as the first pipeline step.
                // This creates temp files that are cleaned up after classification.
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "classify-", contextURL: config.inputFiles.first ?? config.databasePath)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    config.inputFiles,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                ) ?? config.inputFiles

                // Build a config with resolved (materialized) input files
                var resolvedConfig = config
                // Preserve the original bundle display name before materialization
                // replaces inputFiles, so the taxonomy viewer shows the real sample
                // name instead of "materialized".
                if resolvedConfig.sampleDisplayName == nil {
                    let bundleName = config.inputFiles.first?
                        .deletingPathExtension().lastPathComponent
                    resolvedConfig.sampleDisplayName = bundleName
                }
                // Preserve original input files before materialization replaces them,
                // so extraction can locate a valid source FASTQ after the materialized
                // temp file is deleted.
                if resolvedConfig.originalInputFiles == nil {
                    resolvedConfig.originalInputFiles = config.inputFiles
                }
                resolvedConfig.inputFiles = resolvedFiles

                let progressCallback: @Sendable (Double, String) -> Void = { progress, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.showProgress(message)
                            OperationCenter.shared.update(
                                id: opID,
                                progress: max(0, min(1, progress)),
                                detail: message
                            )
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                        }
                    }
                }

                let result: ClassificationResult
                switch resolvedConfig.goal {
                case .classify, .extract:
                    result = try await pipeline.classify(config: resolvedConfig, progress: progressCallback)
                case .profile:
                    result = try await pipeline.profile(config: resolvedConfig, progress: progressCallback)
                }

                // Persist the classification result sidecar so the sidebar can
                // rediscover this result when the project is reopened.
                do {
                    try result.save(to: config.outputDirectory)
                } catch {
                    // Non-fatal: the result is still displayed, just not persisted.
                    appDelegateLogger.warning("runClassification: Failed to save result sidecar - \(error.localizedDescription, privacy: .public)")
                }

                let capturedConfig = config
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()

                        let readCount = result.tree.totalReads
                        let classifiedCount = result.tree.classifiedReads
                        let summaryDetail = "\(classifiedCount) of \(readCount) reads classified"
                        OperationCenter.shared.complete(id: opID, detail: summaryDetail)

                        viewerController.displayTaxonomyResult(result)

                        // For the extract goal, auto-present the unified
                        // extraction dialog after showing the taxonomy browser
                        // so the user can pick taxa. Phase 5 routes through
                        // TaxonomyReadExtractionAction.shared.present(...).
                        if capturedConfig.goal == .extract,
                           viewerController.taxonomyViewController != nil,
                           let topSpecies = result.tree.dominantSpecies,
                           let window = viewerController.view.window {
	                            let ctx = TaxonomyReadExtractionAction.Context(
	                                tool: .kraken2,
	                                resultPath: capturedConfig.outputDirectory,
	                                selections: [ClassifierRowSelector(
	                                    sampleId: nil,
	                                    accessions: [],
	                                    taxIds: [topSpecies.taxId]
	                                )],
	                                suggestedName: "kraken2_\(topSpecies.name.replacingOccurrences(of: " ", with: "_"))",
	                                routeContext: routeContext
	                            )
                            TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: window)
                        }

                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifest
                        if let bundleURL = Self.findSourceBundle(for: capturedConfig.originalInputFiles ?? capturedConfig.inputFiles) {
                            let entry = AnalysisManifestEntry(
                                tool: "kraken2",
                                analysisDirectoryName: capturedConfig.outputDirectory.lastPathComponent,
                                displayName: "Kraken2 Classification",
                                parameters: capturedConfig.summaryParameters(),
                                summary: "\(readCount) reads, \(classifiedCount) classified",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)

                        let alert = NSAlert()
                        alert.messageText = "Classification Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }

        // Wire cancellation so the Operations Panel cancel button works
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }


    /// Runs the EsViritu viral detection pipeline.
    ///
    /// Registers the operation with ``OperationCenter`` and displays the
    /// ``EsVirituResultViewController`` when complete.
    internal func runEsViritu(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        guard let first = configs.first else { return }
        if configs.count == 1 {
            runEsViritu(config: first, viewerController: viewerController, routeContext: routeContext)
            return
        }
        runEsVirituBatch(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    internal func runEsViritu(
        config: EsVirituConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        // Single-sample runs also use batch-style layout (sample in a subdirectory)
        // so there's only one display path for EsViritu results.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "EsViritu detection"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
                tool: "esviritu", in: projectURL, isBatch: true
            ) {
                let sampleSubdir = batchDir.appendingPathComponent(config.sampleName, isDirectory: true)
                try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                config.outputDirectory = sampleSubdir
            }
        }

        let esCliArgs: [String] = {
            var args = ["--input"] + config.inputFiles.map(\.path)
            args += ["--sample", config.sampleName]
            return args
        }()
        let esCliCmd = OperationCenter.buildCLICommand(subcommand: "esviritu detect", args: esCliArgs)
        let esCliArgv = ["lungfish", "esviritu", "detect"] + esCliArgs
        let opID = OperationCenter.shared.start(
            title: "EsViritu \(config.sampleName)",
            detail: "Starting EsViritu viral detection\u{2026}",
            operationType: .classification,
            cliCommand: esCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs before running EsViritu
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "esviritu-", contextURL: config.inputFiles.first ?? config.outputDirectory)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    config.inputFiles,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                ) ?? config.inputFiles

                var resolvedConfig = config
                resolvedConfig.inputFiles = resolvedFiles

                let pipeline = EsVirituPipeline()
                let result = try await pipeline.detect(
                    config: resolvedConfig,
                    progress: { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                OperationCenter.shared.update(
                                    id: opID,
                                    progress: max(0, min(1, progress)),
                                    detail: message
                                )
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )

                // Parse EsViritu output files into the LungfishIO display model.
                let detections = (try? EsVirituDetectionParser.parse(url: result.detectionURL)) ?? []
                let assemblies = EsVirituDetectionParser.groupByAssembly(detections)
                let taxProfile: [ViralTaxProfile]
                if let tpURL = result.taxProfileURL {
                    taxProfile = (try? EsVirituTaxProfileParser.parse(url: tpURL)) ?? []
                } else {
                    taxProfile = []
                }
                let coverageWindows: [ViralCoverageWindow]
                if let cvURL = result.coverageURL {
                    coverageWindows = (try? EsVirituCoverageParser.parse(url: cvURL)) ?? []
                } else {
                    coverageWindows = []
                }

                let ioResult = LungfishIO.EsVirituResult(
                    sampleId: config.sampleName,
                    detections: detections,
                    assemblies: assemblies,
                    taxProfile: taxProfile,
                    coverageWindows: coverageWindows,
                    totalFilteredReads: detections.first?.filteredReadsInSample ?? 0,
                    detectedFamilyCount: Set(detections.compactMap(\.family)).count,
                    detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
                    runtime: result.runtime,
                    toolVersion: result.toolVersion
                )

                // Build the SQLite database at the parent batch directory so
                // the single-sample result opens directly into the DB-backed view.
                // config.outputDirectory is the per-sample subdir; its parent is
                // the batch root the sidebar shows.
                let esvBatchRoot = config.outputDirectory.deletingLastPathComponent()
                var dbBuildErrorDescription: String?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building EsViritu database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building esviritu.sqlite from single-sample result")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "esviritu", resultURL: esvBatchRoot, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runEsViritu: Failed to build esviritu.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }

                let summaryURL = esvBatchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
                let sampleID = MetagenomicsSampleGrouper.sanitizeSampleId(config.sampleName)
                let summaryLines = [
                    "sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror",
                    [
                        appTSVField(sampleID),
                        "ok",
                        String(result.virusCount),
                        String(ioResult.detectedFamilyCount),
                        String(ioResult.detectedSpeciesCount),
                        "",
                    ].joined(separator: "\t"),
                ]
                do {
                    try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
                } catch {
                    appDelegateLogger.warning("runEsViritu: Failed to write summary TSV - \(error.localizedDescription, privacy: .public)")
                }

                let manifest = EsVirituBatchResultManifest(
                    header: MetagenomicsBatchManifestHeader(
                        schemaVersion: 1,
                        createdAt: Date(),
                        sampleCount: 1
                    ),
                    summaryTSV: summaryURL.lastPathComponent,
                    samples: [
                        MetagenomicsBatchSampleRecord(
                            sampleId: sampleID,
                            resultDirectory: appRelativePath(from: esvBatchRoot, to: config.outputDirectory),
                            inputFiles: config.inputFiles.map(\.path),
                            isPairedEnd: config.isPairedEnd
                        )
                    ]
                )

                do {
                    try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: esvBatchRoot)
                } catch {
                    appDelegateLogger.warning("runEsViritu: Failed to save batch manifest - \(error.localizedDescription, privacy: .public)")
                }

                do {
                    try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
                        batchRoot: esvBatchRoot,
                        manifest: manifest,
                        summaryURL: summaryURL,
                        sqliteURL: esvBatchRoot.appendingPathComponent("esviritu.sqlite"),
                        command: esCliArgv
                    )
                } catch {
                    appDelegateLogger.warning("runEsViritu: Failed to write root provenance - \(error.localizedDescription, privacy: .public)")
                }

                let capturedResult = ioResult
                let capturedConfig = config
                let capturedDBBuildError = dbBuildErrorDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        if let dbError = capturedDBBuildError {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                            )
                        }
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(capturedResult.detections.count) viruses detected in \(capturedResult.detectedFamilyCount) families"
                        )
                        // Reload sidebar so the new result bundle appears.
                        // User clicks the new result to view it (batch-only display path).
                        self?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifest
                        if let bundleURL = Self.findSourceBundle(for: capturedConfig.inputFiles) {
                            let entry = AnalysisManifestEntry(
                                tool: "esviritu",
                                analysisDirectoryName: capturedConfig.outputDirectory.lastPathComponent,
                                displayName: "EsViritu Detection",
                                parameters: capturedConfig.summaryParameters(),
                                summary: "\(capturedResult.detections.count) viruses detected in \(capturedResult.detectedFamilyCount) families",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        OperationCenter.shared.fail(id: opID, detail: errorDesc)

                        let alert = NSAlert()
                        alert.messageText = "EsViritu Failed"
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

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Runs Kraken2/Bracken profiling in batch mode (one run per sample).
    private func runClassificationBatch(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        guard !configs.isEmpty else { return }

        // Redirect output to project-level Analyses/ folder when a project is open.
        var configs = configs
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let projectURL = routeContext?.projectURL
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Classification batch"
        ) else { return }
        if let projectURL, let batchDir = try? AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, isBatch: true) {
            for i in configs.indices {
                let sampleSubdir = batchDir.appendingPathComponent(configs[i].outputDirectory.lastPathComponent, isDirectory: true)
                try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                configs[i].outputDirectory = sampleSubdir
            }
        }

        let sampleCount = configs.count
        let firstConfig = configs[0]
        let batchRoot = firstConfig.outputDirectory.deletingLastPathComponent()

        let sampleIDs: [String] = configs.enumerated().map { index, config in
            let outputName = config.outputDirectory.lastPathComponent
            if !outputName.isEmpty {
                return MetagenomicsSampleGrouper.sanitizeSampleId(outputName)
            }
            if let firstInput = config.inputFiles.first {
                return MetagenomicsSampleGrouper.sanitizeSampleId(
                    firstInput.deletingPathExtension().lastPathComponent
                )
            }
            return "sample_\(index + 1)"
        }

        let batchCliCmd: String = {
            guard let first = configs.first else { return "lungfish classify --batch" }
            var args = ["--db", first.databasePath.path]
            for c in configs {
                args += c.inputFiles.map(\.path)
            }
            return OperationCenter.buildCLICommand(subcommand: "classify", args: args)
        }()
        let opID = OperationCenter.shared.start(
            title: "Classification Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting Kraken2/Bracken batch\u{2026}",
            operationType: .classification,
            cliCommand: batchCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }

            let batchMaterializeTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "classify-batch-mat-", contextURL: firstConfig.inputFiles.first ?? firstConfig.databasePath)
            defer { try? FileManager.default.removeItem(at: batchMaterializeTempDir) }

            let pipeline = ClassificationPipeline()
            var successfulResults: [(sampleId: String, config: ClassificationConfig, result: ClassificationResult)] = []
            var failedResults: [(sampleId: String, error: String)] = []

            for (index, config) in configs.enumerated() {
                if Task.isCancelled {
                    break
                }

                let sampleID = sampleIDs[index]
                let samplePrefix = "Sample \(index + 1)/\(sampleCount) (\(sampleID))"

                let progressCallback: @Sendable (Double, String) -> Void = { sampleProgress, message in
                    let bounded = max(0, min(1, sampleProgress))
                    let overall = (Double(index) + bounded) / Double(sampleCount)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.showProgress("\(samplePrefix): \(message)")
                            OperationCenter.shared.update(
                                id: opID,
                                progress: overall,
                                detail: "\(samplePrefix): \(message)"
                            )
                        }
                    }
                }

                do {
                    let resolvedFiles = try await self.resolveInputFiles(
                        config.inputFiles,
                        tempDirectory: batchMaterializeTempDir,
                        progress: { message in
                            let prefixed = "\(samplePrefix): \(message)"
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(prefixed)
                                    OperationCenter.shared.update(id: opID, progress: Double(index) / Double(sampleCount), detail: prefixed)
                                    OperationCenter.shared.log(id: opID, level: .info, message: prefixed)
                                }
                            }
                        }
                    )

                    var resolvedConfig = config
                    if resolvedConfig.sampleDisplayName == nil {
                        let bundleName = config.inputFiles.first?
                            .deletingPathExtension().lastPathComponent
                        resolvedConfig.sampleDisplayName = bundleName
                    }
                    if resolvedConfig.originalInputFiles == nil {
                        resolvedConfig.originalInputFiles = config.inputFiles
                    }
                    resolvedConfig.inputFiles = resolvedFiles

                    let result: ClassificationResult
                    switch resolvedConfig.goal {
                    case .classify, .extract:
                        result = try await pipeline.classify(config: resolvedConfig, progress: progressCallback)
                    case .profile:
                        result = try await pipeline.profile(config: resolvedConfig, progress: progressCallback)
                    }

                    do {
                        try result.save(to: config.outputDirectory)
                    } catch {
                        appDelegateLogger.warning("runClassificationBatch: Failed to save sidecar for \(sampleID, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                    }

                    successfulResults.append((sampleID, config, result))
                } catch {
                    failedResults.append((sampleID, error.localizedDescription))
                    appDelegateLogger.warning("runClassificationBatch: Sample \(sampleID, privacy: .public) failed - \(error.localizedDescription, privacy: .public)")
                }
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)

            let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
            var summaryLines: [String] = []
            summaryLines.append("sample_id\tstatus\ttotal_reads\tclassified_reads\tclassified_pct\tspecies_count\tdominant_species\terror")

            for entry in successfulResults {
                let tree = entry.result.tree
                let dominant = tree.dominantSpecies?.name ?? ""
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "ok",
                    String(tree.totalReads),
                    String(tree.classifiedReads),
                    String(format: "%.2f", tree.classifiedFraction * 100),
                    String(tree.speciesCount),
                    appTSVField(dominant),
                    "",
                ].joined(separator: "\t"))
            }

            for entry in failedResults {
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "failed",
                    "",
                    "",
                    "",
                    "",
                    "",
                    appTSVField(entry.error),
                ].joined(separator: "\t"))
            }

            do {
                try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
            } catch {
                appDelegateLogger.warning("runClassificationBatch: Failed to write summary TSV - \(error.localizedDescription, privacy: .public)")
            }

            let sampleRecords = successfulResults.map { item in
                MetagenomicsBatchSampleRecord(
                    sampleId: item.sampleId,
                    resultDirectory: appRelativePath(from: batchRoot, to: item.config.outputDirectory),
                    inputFiles: item.config.inputFiles.map(\.path),
                    isPairedEnd: item.config.isPairedEnd
                )
            }

            let manifest = ClassificationBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 1,
                    createdAt: Date(),
                    sampleCount: sampleCount
                ),
                goal: firstConfig.goal.rawValue,
                databaseName: firstConfig.databaseName,
                databaseVersion: firstConfig.databaseVersion,
                summaryTSV: summaryURL.lastPathComponent,
                samples: sampleRecords
            )

            do {
                try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)
            } catch {
                appDelegateLogger.warning("runClassificationBatch: Failed to save batch manifest - \(error.localizedDescription, privacy: .public)")
            }

            // Build the SQLite database from the per-sample kreports before the
            // operation completes, so the batch can be opened immediately.
            // Skipped when every sample failed (no data to aggregate).
            var dbBuildErrorDescription: String?
            let successfulCountForDB = successfulResults.count
            if successfulCountForDB > 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building Kraken2 database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building kraken2.sqlite from \(successfulCountForDB) sample(s)")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "kraken2", resultURL: batchRoot, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runClassificationBatch: Failed to build kraken2.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let capturedDBBuildError = dbBuildErrorDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    viewerController.hideProgress()

                    if Task.isCancelled {
                        OperationCenter.shared.fail(id: opID, detail: "Batch cancelled")
                        return
                    }

                    let successCount = successfulResults.count
                    let failureCount = failedResults.count

                    if successCount == 0 {
                        let detail = failedResults.first?.error ?? "All samples failed"
                        OperationCenter.shared.fail(id: opID, detail: detail)

                        let alert = NSAlert()
                        alert.messageText = "Classification Batch Failed"
                        alert.informativeText = detail
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                        return
                    }

                    if let dbError = capturedDBBuildError {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .warning,
                            message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                        )
                    }

                    if failureCount == 0 {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) of \(sampleCount) samples completed"
                        )
                    } else {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) completed, \(failureCount) failed"
                        )
                    }

                    if let firstResult = successfulResults.first?.result {
                        viewerController.displayTaxonomyResult(firstResult)
                    }

                    self.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?
                        .sidebarController.requestReloadFromFilesystem()

                    // Record analysis in source bundle manifests
                    for entry in successfulResults {
                        let bundleURL = Self.findSourceBundle(for: entry.config.originalInputFiles ?? entry.config.inputFiles)
                        if let bundleURL {
                            let tree = entry.result.tree
                            let manifestEntry = AnalysisManifestEntry(
                                tool: "kraken2",
                                analysisDirectoryName: batchRoot.lastPathComponent,
                                displayName: "Kraken2 Batch",
                                parameters: entry.config.summaryParameters(),
                                summary: "\(tree.totalReads) reads, \(tree.classifiedReads) classified",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(manifestEntry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Runs EsViritu detection in batch mode (one run per sample).
    private func runEsVirituBatch(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        guard !configs.isEmpty else { return }

        // Redirect output to project-level Analyses/ folder when a project is open.
        var configs = configs
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let projectURL = routeContext?.projectURL
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "EsViritu batch"
        ) else { return }
        if let projectURL, let batchDir = try? AnalysesFolder.createAnalysisDirectory(tool: "esviritu", in: projectURL, isBatch: true) {
            for i in configs.indices {
                let sampleSubdir = batchDir.appendingPathComponent(configs[i].outputDirectory.lastPathComponent, isDirectory: true)
                try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                configs[i].outputDirectory = sampleSubdir
            }
        }

        let sampleCount = configs.count
        let firstConfig = configs[0]
        let batchRoot = firstConfig.outputDirectory.deletingLastPathComponent()

        let esBatchCliArgs: [String] = {
            var args = ["--input"]
            for c in configs {
                args += c.inputFiles.map(\.path)
            }
            args += ["--sample", configs.first?.sampleName ?? "batch"]
            return args
        }()
        let esBatchCliCmd = OperationCenter.buildCLICommand(subcommand: "esviritu detect", args: esBatchCliArgs)
        let esBatchCliArgv = ["lungfish", "esviritu", "detect"] + esBatchCliArgs
        let opID = OperationCenter.shared.start(
            title: "EsViritu Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting EsViritu batch\u{2026}",
            operationType: .classification,
            cliCommand: esBatchCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }

            let batchMaterializeTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "esviritu-batch-mat-", contextURL: firstConfig.inputFiles.first ?? firstConfig.outputDirectory)
            defer { try? FileManager.default.removeItem(at: batchMaterializeTempDir) }

            let pipeline = EsVirituPipeline()
            var successfulResults: [(sampleId: String, config: EsVirituConfig, pipelineResult: LungfishWorkflow.EsVirituResult, ioResult: LungfishIO.EsVirituResult)] = []
            var failedResults: [(sampleId: String, error: String)] = []

            for (index, config) in configs.enumerated() {
                if Task.isCancelled {
                    break
                }

                let sampleID = MetagenomicsSampleGrouper.sanitizeSampleId(config.sampleName)
                let samplePrefix = "Sample \(index + 1)/\(sampleCount) (\(sampleID))"

                do {
                    let resolvedFiles = try await self.resolveInputFiles(
                        config.inputFiles,
                        tempDirectory: batchMaterializeTempDir,
                        progress: { message in
                            let prefixed = "\(samplePrefix): \(message)"
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(prefixed)
                                    OperationCenter.shared.update(id: opID, progress: Double(index) / Double(sampleCount), detail: prefixed)
                                    OperationCenter.shared.log(id: opID, level: .info, message: prefixed)
                                }
                            }
                        }
                    )

                    var resolvedConfig = config
                    resolvedConfig.inputFiles = resolvedFiles

                    let pipelineResult = try await pipeline.detect(
                        config: resolvedConfig,
                        progress: { progress, message in
                            let bounded = max(0, min(1, progress))
                            let overall = (Double(index) + bounded) / Double(sampleCount)
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress("\(samplePrefix): \(message)")
                                    OperationCenter.shared.update(
                                        id: opID,
                                        progress: overall,
                                        detail: "\(samplePrefix): \(message)"
                                    )
                                }
                            }
                        }
                    )

                    let detections = (try? EsVirituDetectionParser.parse(url: pipelineResult.detectionURL)) ?? []
                    let assemblies = EsVirituDetectionParser.groupByAssembly(detections)
                    let taxProfile: [ViralTaxProfile]
                    if let tpURL = pipelineResult.taxProfileURL {
                        taxProfile = (try? EsVirituTaxProfileParser.parse(url: tpURL)) ?? []
                    } else {
                        taxProfile = []
                    }
                    let coverageWindows: [ViralCoverageWindow]
                    if let cvURL = pipelineResult.coverageURL {
                        coverageWindows = (try? EsVirituCoverageParser.parse(url: cvURL)) ?? []
                    } else {
                        coverageWindows = []
                    }

                    let ioResult = LungfishIO.EsVirituResult(
                        sampleId: config.sampleName,
                        detections: detections,
                        assemblies: assemblies,
                        taxProfile: taxProfile,
                        coverageWindows: coverageWindows,
                        totalFilteredReads: detections.first?.filteredReadsInSample ?? 0,
                        detectedFamilyCount: Set(detections.compactMap(\.family)).count,
                        detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
                        runtime: pipelineResult.runtime,
                        toolVersion: pipelineResult.toolVersion
                    )

                    successfulResults.append((sampleID, config, pipelineResult, ioResult))
                } catch {
                    failedResults.append((sampleID, error.localizedDescription))
                    appDelegateLogger.warning("runEsVirituBatch: Sample \(sampleID, privacy: .public) failed - \(error.localizedDescription, privacy: .public)")
                }
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)

            let summaryURL = batchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
            var summaryLines: [String] = []
            summaryLines.append("sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror")

            for entry in successfulResults {
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "ok",
                    String(entry.pipelineResult.virusCount),
                    String(entry.ioResult.detectedFamilyCount),
                    String(entry.ioResult.detectedSpeciesCount),
                    "",
                ].joined(separator: "\t"))
            }

            for entry in failedResults {
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "failed",
                    "",
                    "",
                    "",
                    appTSVField(entry.error),
                ].joined(separator: "\t"))
            }

            do {
                try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
            } catch {
                appDelegateLogger.warning("runEsVirituBatch: Failed to write summary TSV - \(error.localizedDescription, privacy: .public)")
            }

            let sampleRecords = successfulResults.map { item in
                MetagenomicsBatchSampleRecord(
                    sampleId: item.sampleId,
                    resultDirectory: appRelativePath(from: batchRoot, to: item.config.outputDirectory),
                    inputFiles: item.config.inputFiles.map(\.path),
                    isPairedEnd: item.config.isPairedEnd
                )
            }

            let manifest = EsVirituBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 1,
                    createdAt: Date(),
                    sampleCount: sampleCount
                ),
                summaryTSV: summaryURL.lastPathComponent,
                samples: sampleRecords
            )

            do {
                try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: batchRoot)
            } catch {
                appDelegateLogger.warning("runEsVirituBatch: Failed to save batch manifest - \(error.localizedDescription, privacy: .public)")
            }

            // Build the SQLite database from the per-sample outputs before the
            // operation completes, so the batch can be opened immediately.
            // Skipped when every sample failed (no data to aggregate).
            var dbBuildErrorDescription: String?
            let successfulCountForDB = successfulResults.count
            if successfulCountForDB > 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building EsViritu database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building esviritu.sqlite from \(successfulCountForDB) sample(s)")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "esviritu", resultURL: batchRoot, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runEsVirituBatch: Failed to build esviritu.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            if !successfulResults.isEmpty {
                do {
                    try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
                        batchRoot: batchRoot,
                        manifest: manifest,
                        summaryURL: summaryURL,
                        sqliteURL: batchRoot.appendingPathComponent("esviritu.sqlite"),
                        command: esBatchCliArgv
                    )
                } catch {
                    appDelegateLogger.warning("runEsVirituBatch: Failed to write root provenance - \(error.localizedDescription, privacy: .public)")
                }
            }

            let capturedDBBuildError = dbBuildErrorDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    viewerController.hideProgress()

                    if Task.isCancelled {
                        OperationCenter.shared.fail(id: opID, detail: "Batch cancelled")
                        return
                    }

                    let successCount = successfulResults.count
                    let failureCount = failedResults.count

                    if successCount == 0 {
                        let detail = failedResults.first?.error ?? "All samples failed"
                        OperationCenter.shared.fail(id: opID, detail: detail)

                        let alert = NSAlert()
                        alert.messageText = "EsViritu Batch Failed"
                        alert.informativeText = detail
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                        return
                    }

                    if let dbError = capturedDBBuildError {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .warning,
                            message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                        )
                    }

                    if failureCount == 0 {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) of \(sampleCount) samples completed"
                        )
                    } else {
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) completed, \(failureCount) failed"
                        )
                    }

                    // Reload sidebar so the new batch result appears.
                    // User clicks the new result to view it (batch-only display path).
                    self.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?
                        .sidebarController.requestReloadFromFilesystem()

                    // Record analysis in source bundle manifests
                    for entry in successfulResults {
                        let bundleURL = Self.findSourceBundle(for: entry.config.inputFiles)
                        if let bundleURL {
                            let manifestEntry = AnalysisManifestEntry(
                                tool: "esviritu",
                                analysisDirectoryName: batchRoot.lastPathComponent,
                                displayName: "EsViritu Batch",
                                parameters: entry.config.summaryParameters(),
                                summary: "\(entry.ioResult.detections.count) viruses in \(entry.ioResult.detectedFamilyCount) families",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(manifestEntry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
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
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "TaxTriage"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
                tool: "taxtriage", in: projectURL, isBatch: true
            ) {
                config.outputDirectory = batchDir
            }
        }

        let sampleCount = config.samples.count
        let ttCliCmd: String = {
            var args = ["--input"]
            for sample in config.samples {
                args.append(sample.fastq1.path); if let f2 = sample.fastq2 { args.append(f2.path) }
            }
            return OperationCenter.buildCLICommand(subcommand: "taxtriage", args: args)
        }()
        let opID = OperationCenter.shared.start(
            title: "TaxTriage (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting TaxTriage pipeline\u{2026}",
            operationType: .classification,
            cliCommand: ttCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs for each sample before running TaxTriage
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "taxtriage-", contextURL: config.samples.first?.fastq1 ?? config.outputDirectory)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                var resolvedConfig = config
                for (i, sample) in resolvedConfig.samples.enumerated() {
                    let allFiles = [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])
                    let resolved = try await self?.resolveInputFiles(
                        allFiles,
                        tempDirectory: materializeTempDir,
                        progress: { message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(message)
                                    OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                    OperationCenter.shared.log(id: opID, level: .info, message: message)
                                }
                            }
                        }
                    ) ?? allFiles
                    resolvedConfig.samples[i].fastq1 = resolved[0]
                    if resolved.count > 1 {
                        resolvedConfig.samples[i].fastq2 = resolved[1]
                    }
                }

                let runner = TaxTriageSerialBatchRunner()
                let result = try await runner.run(
                    config: resolvedConfig,
                    progress: { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                OperationCenter.shared.update(
                                    id: opID,
                                    progress: max(0, min(1, progress)),
                                    detail: message
                                )
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )

                // Build the SQLite database from the Nextflow outputs before the
                // operation completes, so the batch can be opened immediately.
                var dbBuildErrorDescription: String?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building TaxTriage database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building taxtriage.sqlite from TaxTriage outputs")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "taxtriage", resultURL: result.outputDirectory, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runTaxTriage: Failed to build taxtriage.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }

                _ = MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(
                    resultDirectory: result.outputDirectory
                )

                let capturedResult = result
                let capturedConfig = config
                let capturedDBBuildError = dbBuildErrorDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        if let dbError = capturedDBBuildError {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                            )
                        }
                        if capturedResult.hasIgnoredFailures {
                            let sampleIDs = Array(Set(capturedResult.ignoredFailures.compactMap(\.sampleID))).sorted()
                            let sampleSummary: String
                            if sampleIDs.isEmpty {
                                sampleSummary = "\(capturedResult.ignoredFailures.count) ignored task failures"
                            } else {
                                let preview = sampleIDs.prefix(5).joined(separator: ", ")
                                let suffix = sampleIDs.count > 5 ? ", +\(sampleIDs.count - 5) more" : ""
                                sampleSummary = "\(capturedResult.ignoredFailures.count) ignored sample failures across \(sampleIDs.count) samples (\(preview)\(suffix))"
                            }
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: sampleSummary
                            )
                        }
                        if capturedResult.hasSampleFailures {
                            let preview = capturedResult.sampleFailures
                                .prefix(5)
                                .map { failure in
                                    "\(failure.sampleID): \(failure.errorDescription)"
                                }
                                .joined(separator: "; ")
                            let suffix = capturedResult.sampleFailures.count > 5
                                ? "; +\(capturedResult.sampleFailures.count - 5) more"
                                : ""
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "\(capturedResult.sampleFailures.count) TaxTriage samples failed (\(preview)\(suffix))"
                            )
                        }
                        let completionDetail: String
                        var warningSummaries: [String] = []
                        if capturedResult.hasIgnoredFailures {
                            warningSummaries.append("\(capturedResult.ignoredFailures.count) ignored task failures")
                        }
                        if capturedResult.hasSampleFailures {
                            warningSummaries.append("\(capturedResult.sampleFailures.count) failed samples")
                        }
                        if !warningSummaries.isEmpty {
                            completionDetail = "\(capturedResult.reportFiles.count) reports, \(warningSummaries.joined(separator: ", "))"
                        } else {
                            completionDetail = capturedResult.summary
                        }
                        OperationCenter.shared.complete(
                            id: opID,
                            detail: completionDetail
                        )
                        // Write cross-reference sidecars into each source bundle so
                        // the sidebar discovers TaxTriage results under all contributors.
                        Self.writeTaxTriageCrossRefSidecars(result: capturedResult, config: capturedConfig)

                        // Record in batch run history log
                        BatchRunHistory.recordRun(result: capturedResult, config: capturedConfig)

                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifests
                        for sample in capturedConfig.samples {
                            if let bundleURL = Self.findSourceBundle(for: [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])) {
                                let entry = AnalysisManifestEntry(
                                    tool: "taxtriage",
                                    analysisDirectoryName: capturedConfig.outputDirectory.lastPathComponent,
                                    displayName: "TaxTriage Classification",
                                    parameters: capturedConfig.summaryParameters(),
                                    summary: capturedResult.summary,
                                    status: .completed
                                )
                                do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                            }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        OperationCenter.shared.fail(id: opID, detail: errorDesc)

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

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Writes TaxTriage cross-reference sidecars into each source bundle directory.
    ///
    /// After a multi-sample TaxTriage batch run, each contributing source bundle
    /// gets a `taxtriage-ref-{runId}.json` so the sidebar can discover the result
    /// under every bundle, not just the one containing the output directory.
    private static func writeTaxTriageCrossRefSidecars(result: TaxTriageResult, config: TaxTriageConfig) {
        guard let sourceBundleURLs = result.sourceBundleURLs, sourceBundleURLs.count > 1 else { return }

        let runId = result.outputDirectory.lastPathComponent
        let now = Date()

        for (index, bundleURL) in sourceBundleURLs.enumerated() {
            // Determine which sample(s) came from this bundle
            let sampleId: String
            if index < config.samples.count {
                sampleId = config.samples[index].sampleId
            } else {
                sampleId = "sample-\(index)"
            }

            let ref = TaxTriageCrossRef(
                resultDirectory: result.outputDirectory.path,
                runId: runId,
                sampleId: sampleId,
                createdAt: now,
                batchSampleCount: config.samples.count
            )

            do {
                try MetagenomicsBatchResultStore.saveTaxTriageRef(ref, to: bundleURL)
                debugLog("Wrote TaxTriage cross-ref sidecar to \(bundleURL.lastPathComponent) for sample \(sampleId)")
            } catch {
                debugLog("Failed to write TaxTriage cross-ref to \(bundleURL.lastPathComponent): \(error)")
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
        let targetController = targetMainWindowController(routeContext: routeContext)
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

        // Create destination directory
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("handleMultipleDownloadsSync: Failed to create directory - \(error)")
            activityIndicator?.hide()
            return
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

                    // Refresh sidebar to show all new files
                    sidebarController?.reloadFromFilesystem()

                    // Select the first downloaded file in the sidebar to highlight what's being viewed
                    if result.error == nil {
                        sidebarController?.selectItem(forURL: result.url)
                        self.requestInspectorDocumentModeAfterDownload(in: targetController)
                    }

                    debugLog("handleMultipleDownloadsSync: Completed importing \(importedFileCount) files")
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
