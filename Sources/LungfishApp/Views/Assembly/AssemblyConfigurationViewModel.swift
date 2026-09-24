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
import LungfishKit

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
    /// Routes the shared UI through ``AssemblyRunRequest`` while preserving the
    /// standalone execution backend boundary.
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
                _ = OperationCenter.shared.update(id: opID, progress: 0.01, detail: "Running \(request.tool.displayName)...")
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
                        _ = OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            await performAssemblyOperationCenterUpdate {
                _ = OperationCenter.shared.update(id: opID, progress: 0.92, detail: "Creating reference bundle...")
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
                        _ = OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            await performAssemblyOperationCenterUpdate {
                if result.outcome == .completedWithNoContigs {
                    _ = OperationCenter.shared.completeWithWarning(id: opID, detail: completionDetail(for: result), bundleURLs: [bundleURL])
                } else {
                    _ = OperationCenter.shared.complete(
                        id: opID,
                        detail: completionDetail(for: result),
                        bundleURLs: [bundleURL]
                    )
                }
            }

            guard await MainActor.run(body: { OperationCenter.shared.items.first { $0.id == opID }?.state == .completed }) else { return }
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
                _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                OperationCenter.shared.log(id: opID, level: .error, message: error.localizedDescription)
            }
            guard await MainActor.run(body: { OperationCenter.shared.items.first { $0.id == opID }?.state == .failed }) else { return }
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
        let materializationCommands = materializedPairs.map { originalURL, executionURL in
            CLISequenceInputMaterialization.materializationCommand(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let argv = materializationCommands.count == 1
            ? materializationCommands[0]
            : [
                "/bin/sh",
                "-lc",
                materializationCommands
                    .map { $0.map(shellEscape).joined(separator: " ") }
                    .joined(separator: " && "),
            ]

        return ProvenanceStep(
            toolName: CLISequenceInputMaterialization.materializationToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
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

    nonisolated static func completionDetail(for result: AssemblyResult) -> String {
        result.outcome == .completedWithNoContigs
            ? "Assembly completed, but no contigs were generated."
            : "Assembly complete"
    }

    nonisolated static func completionNotificationTitle(for result: AssemblyResult) -> String {
        result.outcome == .completedWithNoContigs
            ? "No Contigs Generated"
            : "Assembly Complete"
    }

    nonisolated static func completionNotificationBody(
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
