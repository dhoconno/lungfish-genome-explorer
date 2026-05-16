// AssemblyConfigurationViewModel.swift - Assembly execution runner
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import os.log
import UserNotifications
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Logger for assembly runner operations.
private let logger = Logger(subsystem: LogSubsystem.app, category: "AssemblyRunner")

private func performAssemblyOperationCenterUpdate(_ block: @escaping @MainActor @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                block()
                continuation.resume()
            }
        }
    }
}

// MARK: - AssemblyRunner

/// Runs an assembly as a background operation tracked by ``OperationCenter``.
///
/// The runner registers the assembly with ``OperationCenter`` so that
/// progress is visible in the Operations Panel and the task survives
/// sheet dismissal. Completed bundles are delivered via
/// ``OperationCenter/onBundleReady``.
///
/// ## Usage
///
/// ```swift
/// AssemblyRunner.run(request: request)
/// ```
///
/// The method returns immediately. Assembly progress and completion are
/// reported through ``OperationCenter``.
@MainActor
public enum AssemblyRunner {

    /// Launches a managed assembly request in the background.
    ///
    /// Task 4 routes the shared UI through ``AssemblyRunRequest`` even while
    /// the standalone execution backend is being generalized.
    public static func run(request: AssemblyRunRequest, routeContext: OperationRouteContext? = nil) {
        Task {
            if let warning = await AssemblyRuntimePreflight.warningMessage(for: request) {
                AssemblyRuntimePreflight.presentWarning(
                    message: warning,
                    for: request.tool,
                    on: NSApp.keyWindow
                )
                return
            }
            runValidated(request: request, routeContext: routeContext)
        }
    }

    static func runValidated(request: AssemblyRunRequest, routeContext: OperationRouteContext? = nil) {
        let request = request.normalizedForExecution()
        let projectName = request.projectName
        guard AppDelegate.shared?.canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "\(request.tool.displayName) assembly",
            presentingWindow: AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?.window
        ) ?? true else {
            return
        }

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { logger.warning("Notification authorization error: \(error)") }
            }
        }

        let baseOutputDirectory = request.outputDirectory
        let diskCheck = checkDiskSpace(
            inputFiles: request.inputURLs,
            outputDirectory: baseOutputDirectory
        )
        if !diskCheck.sufficient {
            let requiredStr = ByteCountFormatter.string(fromByteCount: diskCheck.requiredBytes, countStyle: .file)
            let availableStr = ByteCountFormatter.string(fromByteCount: diskCheck.availableBytes, countStyle: .file)
            showDiskSpaceAlert(required: requiredStr, available: availableStr)
            return
        }

        let executionRequest = AssemblyRunRequest(
            tool: request.tool,
            readType: request.readType,
            inputURLs: request.inputURLs,
            projectName: request.projectName,
            outputDirectory: baseOutputDirectory.appendingPathComponent(projectName, isDirectory: true),
            pairedEnd: request.pairedEnd,
            threads: request.threads,
            memoryGB: request.memoryGB,
            minContigLength: request.effectiveMinContigLength,
            selectedProfileID: request.selectedProfileID,
            extraArguments: request.extraArguments
        )

        logger.info("Starting managed assembly: tool=\(request.tool.displayName, privacy: .public), project=\(projectName, privacy: .public)")

        let opID = OperationCenter.shared.start(
            title: "\(request.tool.displayName) Assembly: \(projectName)",
            detail: "Initializing...",
            operationType: .assembly,
            cliCommand: cliCommandPreview(
                request: request,
                outputDirectory: executionRequest.outputDirectory
            ),
            routeContext: routeContext
        )

        let task = Task.detached {
            await runManagedAssemblyOperation(
                request: executionRequest,
                baseOutputDirectory: baseOutputDirectory,
                projectName: projectName,
                operationID: opID
            )
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Launches a SPAdes assembly in the background.
    ///
    /// Registers the operation with ``OperationCenter``, then runs the
    /// pipeline in a detached task so the calling sheet can safely dismiss.
    ///
    /// - Parameter config: The fully configured ``SPAdesAssemblyConfig``.
    public static func run(config: SPAdesAssemblyConfig, routeContext: OperationRouteContext? = nil) {
        let projectName = config.projectName

        // Request notification permission (idempotent).
        // Guard against crash when running without a bundle identifier (CLI / swift build).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { logger.warning("Notification authorization error: \(error)") }
            }
        }

        // Check disk space
        let diskCheck = checkDiskSpace(inputFiles: config.allInputFiles, outputDirectory: config.outputDirectory)
        if !diskCheck.sufficient {
            let requiredStr = ByteCountFormatter.string(fromByteCount: diskCheck.requiredBytes, countStyle: .file)
            let availableStr = ByteCountFormatter.string(fromByteCount: diskCheck.availableBytes, countStyle: .file)
            showDiskSpaceAlert(required: requiredStr, available: availableStr)
            return
        }

        logger.info("Starting SPAdes assembly: mode=\(config.mode.displayName, privacy: .public), project=\(projectName, privacy: .public)")

        let cliCmd = cliCommandPreview(config: config)

        let opID = OperationCenter.shared.start(
            title: "SPAdes Assembly: \(projectName)",
            detail: "Initializing...",
            operationType: .assembly,
            cliCommand: cliCmd,
            routeContext: routeContext
        )

        let task = Task.detached {
            await runAssemblyOperation(config: config, projectName: projectName, operationID: opID)
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    private static func spadesConfig(from request: AssemblyRunRequest) -> SPAdesAssemblyConfig? {
        guard request.tool == .spades else { return nil }

        let pairedReads: ([URL], [URL], [URL])
        if request.pairedEnd, request.inputURLs.count == 2 {
            pairedReads = ([request.inputURLs[0]], [request.inputURLs[1]], [])
        } else {
            pairedReads = ([], [], request.inputURLs)
        }

        return SPAdesAssemblyConfig(
            mode: SPAdesMode(rawValue: request.selectedProfileID ?? "isolate") ?? .isolate,
            forwardReads: pairedReads.0,
            reverseReads: pairedReads.1,
            unpairedReads: pairedReads.2,
            memoryGB: request.memoryGB ?? 8,
            threads: request.threads,
            minContigLength: request.effectiveMinContigLength ?? 500,
            skipErrorCorrection: request.extraArguments.contains("--only-assembler"),
            careful: request.extraArguments.contains("--careful"),
            customArgs: request.extraArguments.filter { $0 != "--only-assembler" && $0 != "--careful" },
            outputDirectory: request.outputDirectory,
            projectName: request.projectName
        )
    }

    nonisolated static func cliCommandPreview(config: SPAdesAssemblyConfig) -> String {
        cliCommandPreview(
            request: assemblyRunRequest(from: config),
            outputDirectory: config.outputDirectory
        )
    }

    nonisolated static func cliCommandPreview(
        request: AssemblyRunRequest,
        outputDirectory: URL? = nil
    ) -> String {
        guard let invocation = try? FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: .assemble(request: request, outputMode: .groupedResult),
            outputTargetPath: (outputDirectory ?? request.outputDirectory).path
        ) else {
            return OperationCenter.buildCLICommand(subcommand: "assemble", args: [])
        }

        return OperationCenter.buildCLICommand(
            subcommand: invocation.subcommand,
            args: invocation.arguments
        )
    }

    nonisolated private static func assemblyRunRequest(from config: SPAdesAssemblyConfig) -> AssemblyRunRequest {
        var extraArguments: [String] = []
        if config.skipErrorCorrection {
            extraArguments.append("--only-assembler")
        }
        if config.careful {
            extraArguments.append("--careful")
        }
        if let kmerSizes = config.kmerSizes, !kmerSizes.isEmpty {
            extraArguments += ["-k", kmerSizes.map(String.init).joined(separator: ",")]
        }
        if let covCutoff = config.covCutoff, !covCutoff.isEmpty {
            extraArguments += ["--cov-cutoff", covCutoff]
        }
        if let phredOffset = config.phredOffset {
            extraArguments += ["--phred-offset", "\(phredOffset)"]
        }
        extraArguments += config.customArgs

        return AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: config.forwardReads + config.reverseReads + config.unpairedReads,
            projectName: config.projectName,
            outputDirectory: config.outputDirectory,
            pairedEnd: !config.forwardReads.isEmpty || !config.reverseReads.isEmpty,
            threads: config.threads,
            memoryGB: config.memoryGB,
            minContigLength: config.minContigLength,
            selectedProfileID: config.mode.rawValue,
            extraArguments: extraArguments
        )
    }

    // MARK: - Pipeline Execution

    typealias ManagedAssemblyMaterializer = (URL, URL, (@Sendable (String) -> Void)?) async throws -> URL

    struct ManagedAssemblyMaterializationResult {
        let request: AssemblyRunRequest
        let materializationStartedAt: Date?
        let materializationEndedAt: Date?
    }

    static func materializedManagedAssemblyRequest(
        from request: AssemblyRunRequest,
        tempDirectory: URL,
        materialize: ManagedAssemblyMaterializer
    ) async throws -> AssemblyRunRequest {
        try await materializedManagedAssemblyRequestResult(
            from: request,
            tempDirectory: tempDirectory,
            materialize: materialize
        ).request
    }

    static func materializedManagedAssemblyRequestResult(
        from request: AssemblyRunRequest,
        tempDirectory: URL,
        materialize: ManagedAssemblyMaterializer
    ) async throws -> ManagedAssemblyMaterializationResult {
        try validatePreMaterializationTopology(for: request)

        var resolvedInputURLs: [URL] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?
        for inputURL in request.inputURLs {
            if let bundleURL = AssemblyInputMaterialization.bundleRequiringMaterialization(for: inputURL) {
                if materializationStartedAt == nil {
                    materializationStartedAt = Date()
                }
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                let materializedURL = try await materialize(bundleURL, tempDirectory, nil)
                materializationEndedAt = Date()
                resolvedInputURLs.append(materializedURL.standardizedFileURL)
                continue
            }

            let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) ?? inputURL
            resolvedInputURLs.append(resolvedURL.standardizedFileURL)
        }

        let executionRequest = AssemblyRunRequest(
            tool: request.tool,
            readType: request.readType,
            inputURLs: resolvedInputURLs,
            projectName: request.projectName,
            outputDirectory: request.outputDirectory,
            pairedEnd: request.pairedEnd,
            threads: request.threads,
            memoryGB: request.memoryGB,
            minContigLength: request.minContigLength,
            selectedProfileID: request.selectedProfileID,
            extraArguments: request.extraArguments
        )
        return ManagedAssemblyMaterializationResult(
            request: executionRequest,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
    }

    static func validatePreMaterializationTopology(for request: AssemblyRunRequest) throws {
        guard AssemblyCompatibility.isSupported(tool: request.tool, for: request.readType) else {
            throw ManagedAssemblyPipelineError.incompatibleSelection(
                "\(request.tool.displayName) is not available for \(request.readType.displayName) in v1."
            )
        }

        for inputURL in request.inputURLs {
            if let unsupportedMessage = AssemblyInputMaterialization.unsupportedAssemblyInputMessage(for: inputURL) {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(unsupportedMessage)
            }
        }

        if request.pairedEnd && request.inputURLs.count != 2 {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "Paired-end assembly requests must include exactly two sequence inputs."
            )
        }

        switch request.tool {
        case .flye:
            guard !request.pairedEnd, request.inputURLs.count == 1 else {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                    "Flye expects a single ONT sequence input in v1."
                )
            }
        case .hifiasm:
            guard !request.pairedEnd, request.inputURLs.count == 1 else {
                throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                    "Hifiasm expects a single ONT or PacBio HiFi/CCS sequence input in v1."
                )
            }
        case .spades, .megahit, .skesa:
            break
        }
    }

    static func managedAssemblyInputRecords(
        originalRequest: AssemblyRunRequest,
        executionRequest: AssemblyRunRequest
    ) -> [InputFileRecord] {
        AssemblyInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: originalRequest.inputURLs,
            executionInputURLs: executionRequest.inputURLs
        )
    }

    private static func runManagedAssemblyOperation(
        request: AssemblyRunRequest,
        baseOutputDirectory: URL,
        projectName: String,
        operationID opID: UUID
    ) async {
        do {
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Running \(request.tool.displayName)...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Launching managed assembly pipeline")
            }

            let materializationDirectory = request.outputDirectory
                .appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true)
            try validatePreMaterializationTopology(for: request)
            let materializationResult = try await materializedManagedAssemblyRequestResult(
                from: request,
                tempDirectory: materializationDirectory,
                materialize: { bundleURL, tempDirectory, progress in
                    try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                        fromBundle: bundleURL,
                        tempDirectory: tempDirectory,
                        progress: progress
                    )
                }
            )
            let executionRequest = materializationResult.request

            let pipeline = ManagedAssemblyPipeline()
            let result = try await pipeline.run(request: executionRequest) { fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let scaledProgress = 0.05 + fraction * 0.85
                        OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.92, detail: "Creating reference bundle...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Creating reference bundle")
            }

            let materializationStep = try managedAssemblyMaterializationStep(
                originalRequest: request,
                executionRequest: executionRequest,
                startedAt: materializationResult.materializationStartedAt,
                endedAt: materializationResult.materializationEndedAt
            )
            let provenance = ProvenanceBuilder.build(
                request: executionRequest,
                result: result,
                inputRecords: managedAssemblyInputRecords(
                    originalRequest: request,
                    executionRequest: executionRequest
                ),
                steps: materializationStep.map { [$0] } ?? []
            )

            let bundleBuilder = AssemblyBundleBuilder()
            let bundleURL = try await bundleBuilder.build(
                result: result,
                request: executionRequest,
                provenance: provenance,
                outputDirectory: baseOutputDirectory,
                bundleName: projectName
            ) { fraction, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let scaledProgress = 0.92 + fraction * 0.08
                        OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            await performAssemblyOperationCenterUpdate {
                if result.outcome == .completedWithNoContigs {
                    OperationCenter.shared.completeWithWarning(id: opID, detail: completionDetail(for: result), bundleURLs: [bundleURL])
                } else {
                    OperationCenter.shared.complete(
                        id: opID,
                        detail: completionDetail(for: result),
                        bundleURLs: [bundleURL]
                    )
                }
            }

            postNotification(
                title: completionNotificationTitle(for: result),
                body: completionNotificationBody(
                    for: result,
                    toolDisplayName: request.tool.displayName,
                    projectName: projectName
                ),
                isSuccess: true
            )
        } catch {
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                OperationCenter.shared.log(id: opID, level: .error, message: error.localizedDescription)
            }
            postNotification(
                title: "Assembly Failed",
                body: error.localizedDescription,
                isSuccess: false
            )
        }
    }

    static func managedAssemblyMaterializationStep(
        originalRequest: AssemblyRunRequest,
        executionRequest: AssemblyRunRequest,
        startedAt: Date?,
        endedAt: Date?
    ) throws -> ProvenanceStep? {
        let inputPairs = zipOriginalAndExecutionInputs(
            originalInputURLs: originalRequest.inputURLs,
            executionInputURLs: executionRequest.inputURLs
        )
        let materializedPairs = inputPairs.filter { originalURL, executionURL in
            AssemblyInputMaterialization.requiresMaterialization(originalURL)
                && originalURL.standardizedFileURL != executionURL.standardizedFileURL
        }
        guard !materializedPairs.isEmpty else { return nil }
        guard let startedAt else { return nil }

        let completedAt = endedAt ?? startedAt
        let inputs = try materializedPairs.flatMap { originalURL, _ in
            try AssemblyInputMaterialization.originalInputDescriptors(for: originalURL)
        }
        let outputs = try materializedPairs.map { originalURL, executionURL in
            try AssemblyInputMaterialization.executionInputDescriptor(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let argv = ["lungfish-app", "assemble", "materialize-inputs"]
            + originalRequest.inputURLs.map(\.path)

        return ProvenanceStep(
            toolName: "lungfish.assemble.input-materialization",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private static func zipOriginalAndExecutionInputs(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [(originalURL: URL, executionURL: URL)] {
        executionInputURLs.enumerated().map { index, executionURL in
            let originalURL = originalInputURLs.indices.contains(index) ? originalInputURLs[index] : executionURL
            return (originalURL, executionURL)
        }
    }

    /// Runs the assembly pipeline and reports progress to ``OperationCenter``.
    ///
    /// This is a static method that captures no mutable external state so
    /// the calling sheet can safely dismiss while the assembly continues.
    private static func runAssemblyOperation(
        config: SPAdesAssemblyConfig,
        projectName: String,
        operationID opID: UUID
    ) async {
        do {
            // Materialize virtual FASTQ bundles (subset/trim/demux produce only preview.fastq)
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Resolving input files...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Checking for virtual FASTQ materialization")
            }

            var mutableConfig = config
            let tempDir = try ProjectTempDirectory.createFromContext(
                prefix: "assembly-", contextURL: config.forwardReads.first ?? config.outputDirectory)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let allInputs = config.forwardReads + config.reverseReads + config.unpairedReads
            var resolvedForward: [URL] = []
            var resolvedReverse: [URL] = []
            var resolvedUnpaired: [URL] = []

            for fileURL in allInputs {
                let bundleURL: URL?
                if FASTQBundle.isBundleURL(fileURL) {
                    bundleURL = fileURL
                } else if FASTQBundle.isBundleURL(fileURL.deletingLastPathComponent()) {
                    bundleURL = fileURL.deletingLastPathComponent()
                } else {
                    bundleURL = nil
                }

                var resolvedURL = fileURL
                if let bundle = bundleURL,
                   let manifest = FASTQBundle.loadDerivedManifest(in: bundle) {
                    switch manifest.payload {
                    case .subset, .trim, .demuxedVirtual:
                        let materializedURL = try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                            fromBundle: bundle,
                            tempDirectory: tempDir,
                            progress: { msg in
                                DispatchQueue.main.async { MainActor.assumeIsolated {
                                    OperationCenter.shared.log(id: opID, level: .info, message: msg)
                                }}
                            }
                        )
                        resolvedURL = materializedURL
                    default:
                        if let primaryURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundle) {
                            resolvedURL = primaryURL
                        }
                    }
                }

                // Maintain the forward/reverse/unpaired split
                if config.forwardReads.contains(fileURL) {
                    resolvedForward.append(resolvedURL)
                } else if config.reverseReads.contains(fileURL) {
                    resolvedReverse.append(resolvedURL)
                } else {
                    resolvedUnpaired.append(resolvedURL)
                }
            }

            mutableConfig = SPAdesAssemblyConfig(
                mode: config.mode,
                forwardReads: resolvedForward,
                reverseReads: resolvedReverse,
                unpairedReads: resolvedUnpaired,
                kmerSizes: config.kmerSizes,
                memoryGB: config.memoryGB,
                threads: config.threads,
                minContigLength: config.minContigLength,
                skipErrorCorrection: config.skipErrorCorrection,
                careful: config.careful,
                covCutoff: config.covCutoff,
                phredOffset: config.phredOffset,
                customArgs: config.customArgs,
                outputDirectory: config.outputDirectory,
                projectName: config.projectName
            )

            let runtime = try await AppleContainerRuntime()

            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.05, detail: "Container runtime initialized")
                OperationCenter.shared.log(id: opID, level: .info, message: "Container runtime initialized")
            }

            let pipeline = SPAdesAssemblyPipeline()
            let result = try await pipeline.run(
                config: mutableConfig,
                runtime: runtime
            ) { fraction, message in
                let scaledProgress = 0.02 + fraction * 0.93
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            let stats = result.statistics
            logger.info("Assembly stats: contigs=\(stats.contigCount), N50=\(stats.n50), total=\(stats.totalLengthBP)bp")

            // Save config for potential reassembly
            let spadesOutputDir = config.outputDirectory.appendingPathComponent(projectName)
            try? SPAdesAssemblyPipeline.saveConfig(config, to: spadesOutputDir)

            // Clean intermediate files
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.94, detail: "Cleaning intermediate files...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Cleaning intermediate files")
            }
            let freed = try? SPAdesAssemblyPipeline.cleanIntermediates(in: spadesOutputDir)
            if let freed {
                let freedStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                logger.info("Freed \(freedStr) of intermediate files")
            }

            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Creating reference bundle...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Creating reference bundle")
            }

            let inputRecords = config.allInputFiles.map { url in
                ProvenanceBuilder.inputRecord(for: url)
            }
            let provenance = ProvenanceBuilder.build(
                config: config,
                result: result,
                inputRecords: inputRecords
            )

            let bundleBuilder = AssemblyBundleBuilder()
            let bundleURL = try await bundleBuilder.build(
                result: result,
                config: config,
                provenance: provenance,
                outputDirectory: config.outputDirectory,
                bundleName: projectName
            ) { fraction, message in
                let overallFraction = 0.95 + fraction * 0.05
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: overallFraction, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }
            let normalizedResult = AssemblyResult.fromLegacy(result)

            await performAssemblyOperationCenterUpdate {
                if normalizedResult.outcome == .completedWithNoContigs {
                    OperationCenter.shared.completeWithWarning(id: opID, detail: completionDetail(for: normalizedResult), bundleURLs: [bundleURL])
                } else {
                    OperationCenter.shared.complete(
                        id: opID,
                        detail: completionDetail(for: normalizedResult),
                        bundleURLs: [bundleURL]
                    )
                }
            }

            postNotification(
                title: completionNotificationTitle(for: normalizedResult),
                body: completionNotificationBody(
                    for: normalizedResult,
                    toolDisplayName: "SPAdes",
                    projectName: projectName
                ),
                isSuccess: true
            )

        } catch is CancellationError {
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
            }
        } catch {
            let errorMessage = "\(error)"
            logger.error("Assembly failed: \(error)")
            await performAssemblyOperationCenterUpdate {
                OperationCenter.shared.fail(id: opID, detail: errorMessage)
            }

            postNotification(
                title: "Assembly Failed",
                body: "Project \"\(projectName)\" failed: \(errorMessage)",
                isSuccess: false
            )
        }
    }

    // MARK: - Disk Space Check

    /// Checks whether the output directory has sufficient disk space for assembly.
    ///
    /// SPAdes typically needs at least 2x input file size plus 1 GB overhead.
    private static func checkDiskSpace(
        inputFiles: [URL],
        outputDirectory: URL
    ) -> (sufficient: Bool, requiredBytes: Int64, availableBytes: Int64) {
        let totalInputBytes: Int64 = inputFiles.reduce(0) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let requiredBytes: Int64 = totalInputBytes * 2 + 1_073_741_824

        do {
            let resourceValues = try outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let availableBytes = Int64(resourceValues.volumeAvailableCapacityForImportantUsage ?? 0)
            return (availableBytes >= requiredBytes, requiredBytes, availableBytes)
        } catch {
            logger.warning("Failed to check disk space: \(error)")
            return (true, requiredBytes, 0)
        }
    }

    // MARK: - Alerts

    /// Presents a disk space warning as a sheet modal.
    private static func showDiskSpaceAlert(required: String, available: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insufficient Disk Space"
        alert.informativeText = """
            The output directory does not have enough free space for this assembly.

            Required: \(required)
            Available: \(available)

            SPAdes needs at least 2x the total input file size plus 1 GB of overhead. \
            Please free up disk space or choose a different output directory.
            """
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
        logger.warning("Assembly blocked: insufficient disk space (required=\(required), available=\(available))")
    }

    // MARK: - Notifications

    private static func completionDetail(for result: AssemblyResult) -> String {
        result.outcome == .completedWithNoContigs
            ? "Assembly completed, but no contigs were generated."
            : "Assembly complete"
    }

    private static func completionNotificationTitle(for result: AssemblyResult) -> String {
        result.outcome == .completedWithNoContigs
            ? "No Contigs Generated"
            : "Assembly Complete"
    }

    private static func completionNotificationBody(
        for result: AssemblyResult,
        toolDisplayName: String,
        projectName: String
    ) -> String {
        if result.outcome == .completedWithNoContigs {
            return "\(toolDisplayName) finished for \(projectName), but no contigs were generated."
        }
        return "\(toolDisplayName) finished for \(projectName)."
    }

    /// Posts a macOS notification for assembly completion or failure.
    private static func postNotification(title: String, body: String, isSuccess: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isSuccess ? .default : UNNotificationSound.defaultCritical

        let request = UNNotificationRequest(
            identifier: "assembly-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        // Guard against crash when running without a bundle identifier (CLI / swift build)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.warning("Failed to post notification: \(error)") }
        }
    }
}
