// AssemblyConfigurationViewModel.swift - Assembly execution runner
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import os.log
import UserNotifications
import LungfishOperations
import LungfishWorkflow
import LungfishIO
import LungfishCore
import LungfishKit

/// Logger for assembly runner operations.
private let logger = Logger(subsystem: LogSubsystem.app, category: "AssemblyRunner")

/// Hands the shared input resolution the materializer closure the runner was
/// given: the derivative service's, or a test's.
private struct ClosureAssemblyInputMaterializer: CLISequenceInputMaterializing, Sendable {
    let body: AssemblyRunner.ManagedAssemblyMaterializer

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        try await body(bundleURL, tempDirectory, progress)
    }
}

/// The words of the alert a failed managed assembly shows, what happened and what to try next.
struct AssemblyFailureAlert: Equatable, Sendable {
    let title: String
    let message: String
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

    /// Checks that the run may write and has room, then starts it on `lungfish-cli assemble` (Phase
    /// 2.10 lane A46, decision C4). The in-process route and its key went in Phase 2.11 (K3).
    static func runValidated(
        request: AssemblyRunRequest,
        routeContext: OperationRouteContext? = nil
    ) {
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

        if runsInAppBundle {
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

        logger.info("Starting managed assembly: tool=\(request.tool.displayName, privacy: .public), project=\(projectName, privacy: .public)")

        startManagedAssembly(request: request, routeContext: routeContext)
    }

    // MARK: - The CLI route

    /// The argv the Reassemble key's CLI route runs, the command its row records
    /// (`cliCommandPreview`). `request` writes into `outputDirectory`, the pipeline's folder, and
    /// the command publishes the bundle and prints its events (Phase 2.10 lane A46, C4 and C5).
    nonisolated static func managedAssemblyCLIArguments(for request: AssemblyRunRequest, outputDirectory: URL) -> [String] {
        ["assemble"] + FASTQOperationCLIInvocationBuilder.assembleArguments(
            for: request,
            outputTargetPath: outputDirectory.path,
            referenceBundle: true
        )
    }

    /// The part of `runValidated` after its checks, which a test calls. Begins the row for the
    /// normalized `request` and runs it on `lungfish-cli assemble`. Returns the row's ID, or nil when
    /// it was refused.
    @discardableResult
    static func startManagedAssembly(
        request: AssemblyRunRequest,
        routeContext: OperationRouteContext?,
        runner: CLIReadsRunner = CLIReadsRunner(),
        presentFailureAlert: (@MainActor @Sendable (AssemblyFailureAlert) -> Void)? = nil
    ) -> UUID? {
        let executionRequest = Self.executionRequest(for: request)
        let began = beginAssemblyOperation(
            request: request,
            outputDirectory: executionRequest.outputDirectory,
            routeContext: routeContext
        ) { opID in
            let arguments = managedAssemblyCLIArguments(for: request, outputDirectory: executionRequest.outputDirectory)
            Task.detached {
                await runManagedAssemblyThroughCLI(
                    arguments: arguments,
                    executionRequest: executionRequest,
                    routeContext: routeContext,
                    operationID: opID,
                    runner: runner
                )
            }
            OperationCenter.shared.setCancelCallback(for: opID) { runner.cancel() }
        }
        return began.startedID
    }

    /// Runs `lungfish-cli assemble` for a Reassemble row on `CLIReadsRunner` and ends the row. The
    /// command writes the pipeline's folder, its record and the bundle, so the app only reads the
    /// result back. A run whose command exited 0 with its `complete` line keeps the folder and the
    /// bundle, and a cancel that came after that leaves the row cancelled and reloads the sidebar
    /// (fix 8). A run that threw removes nothing, since the command owns both and the bundle builder
    /// removes its own staging folder. The row opens the bundle the command named, never a path the
    /// app computes (UX), and a run with no contigs completes with a warning, as in process.
    static func runManagedAssemblyThroughCLI(
        arguments: [String],
        executionRequest: AssemblyRunRequest,
        routeContext: OperationRouteContext?,
        operationID opID: UUID,
        runner: CLIReadsRunner
    ) async {
        do {
            let completion = try await runner.runEvents(arguments: arguments, operationID: opID, startAsLog: true)
            let folder = executionRequest.outputDirectory
            let result = try await Task.detached { try AssemblyResult.load(from: folder) }.value
            let bundles = completion.outputs.filter { $0.hasSuffix(".lungfishref") }.map { URL(fileURLWithPath: $0) }
            let detail = completionDetail(for: result)
            let completed = result.outcome == .completedWithNoContigs
                ? OperationCenter.shared.completeWithWarning(id: opID, detail: detail, bundleURLs: bundles)
                : OperationCenter.shared.complete(id: opID, detail: detail, bundleURLs: bundles)
            guard completed else {
                AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                    .sidebarController.requestReloadFromFilesystem()
                return
            }
            postNotification(
                title: completionNotificationTitle(for: result),
                body: completionNotificationBody(
                    for: result,
                    toolDisplayName: executionRequest.tool.displayName,
                    projectName: executionRequest.projectName
                ),
                isSuccess: true
            )
        } catch is CancellationError {
            OperationCenter.shared.acknowledgeCancellation(id: opID)
        } catch {
            let failed = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
            OperationCenter.shared.log(id: opID, level: .error, message: error.localizedDescription)
            if failed {
                postNotification(title: "Assembly Failed", body: error.localizedDescription, isSuccess: false)
            }
        }
    }

    /// The request `runValidated` hands the managed pipeline: `request`
    /// writing into `<output>/<project name>` with its effective minimum
    /// contig length and every other field, `inputLayout` included, as the
    /// recorded command (`cliCommandPreview`) carries them (R3).
    nonisolated static func executionRequest(for request: AssemblyRunRequest) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: request.tool,
            readType: request.readType,
            inputURLs: request.inputURLs,
            projectName: request.projectName,
            outputDirectory: request.outputDirectory.appendingPathComponent(request.projectName, isDirectory: true),
            pairedEnd: request.pairedEnd,
            threads: request.threads,
            memoryGB: request.memoryGB,
            minContigLength: request.effectiveMinContigLength,
            selectedProfileID: request.selectedProfileID,
            extraArguments: request.extraArguments,
            profileSelectionBasis: request.profileSelectionBasis,
            inputLayout: request.inputLayout
        )
    }

    /// Registers the assembly row and, only when it starts, calls `launch` with the
    /// operation ID. The row locks no bundle.
    ///
    /// `request` is the normalized request and `outputDirectory` is the folder the
    /// managed pipeline writes to, `<output>/<project name>`. The row records the
    /// `lungfish-cli assemble` command that `cliCommandPreview` builds from them
    /// through `FASTQOperationCLIInvocationBuilder`, the same builder the FASTQ
    /// operations dialog uses. The builder cannot fail, so no row records a bare
    /// `assemble`.
    @discardableResult
    static func beginAssemblyOperation(
        request: AssemblyRunRequest,
        outputDirectory: URL,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "\(request.tool.displayName) Assembly: \(request.projectName)",
            detail: "Initializing...",
            operationType: .assembly,
            cliCommand: cliCommandPreview(request: request, outputDirectory: outputDirectory),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    nonisolated static func cliCommandPreview(config: SPAdesAssemblyConfig) -> String {
        cliCommandPreview(
            request: assemblyRunRequest(from: config),
            outputDirectory: config.outputDirectory
        )
    }

    /// The `lungfish-cli assemble` command a Reassemble row records, the dialog's argv with
    /// `--reference-bundle`, so the command publishes the bundle the route opens (Phase 2.10 lane
    /// A46). The builder's arm cannot fail, so no row records a bare `assemble`.
    nonisolated static func cliCommandPreview(
        request: AssemblyRunRequest,
        outputDirectory: URL? = nil
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "assemble",
            args: FASTQOperationCLIInvocationBuilder.assembleArguments(
                for: request,
                outputTargetPath: (outputDirectory ?? request.outputDirectory).path,
                referenceBundle: true
            )
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

    typealias ManagedAssemblyMaterializer = @Sendable (URL, URL, (@Sendable (String) -> Void)?) async throws -> URL

    struct ManagedAssemblyMaterializationResult {
        let request: AssemblyRunRequest
        /// The input each of `request.inputURLs` came from, one per execution file.
        let originalInputURLs: [URL]
        let materializationStartedAt: Date?
        let materializationEndedAt: Date?
        /// The sample's pairs and single reads when it holds both, with the
        /// splits that wrote their files (`AssemblyReadSetResolution`).
        var readSets: AssemblyResolvedInputs?
    }

    static func materializedManagedAssemblyRequest(
        from request: AssemblyRunRequest,
        tempDirectory: URL,
        materialize: @escaping ManagedAssemblyMaterializer
    ) async throws -> AssemblyRunRequest {
        try await materializedManagedAssemblyRequestResult(
            from: request,
            tempDirectory: tempDirectory,
            materialize: materialize
        ).request
    }

    /// The request the managed pipeline runs, its inputs resolved the way
    /// `lungfish-cli assemble` resolves them (R3,
    /// `AssemblyReadSetResolution.resolve`): every read a bundle holds, a
    /// virtual bundle materialized into `tempDirectory` by `materialize`, the
    /// unpaired files of one bundle joined there, and the R1 and R2 files of
    /// a mate pair kept apart and assembled as pairs. A sample that holds
    /// pairs and single reads is an R1 file, an R2 file and single-read
    /// files with their roles (decision 1 of 2026-10-03). The layout of a
    /// single file is resolved by the same rule as well
    /// (`AssemblyRunRequest.resolveInputLayout`): the request's own
    /// `inputLayout` (the recorded `--read-layout`) wins, otherwise the
    /// bundle metadata and then the records decide.
    static func materializedManagedAssemblyRequestResult(
        from request: AssemblyRunRequest,
        tempDirectory: URL,
        materialize: @escaping ManagedAssemblyMaterializer
    ) async throws -> ManagedAssemblyMaterializationResult {
        try validatePreMaterializationTopology(for: request)
        let readSets = try await AssemblyReadSetResolution.resolve(
            inputURLs: request.inputURLs,
            tool: request.tool,
            pairedEnd: request.pairedEnd,
            explicitLayout: request.inputLayout,
            materializationDirectory: tempDirectory,
            materializer: ClosureAssemblyInputMaterializer(body: materialize)
        )
        let resolved = readSets.inputs
        if request.inputLayout != nil, resolved.resolvedAsMatePair {
            throw ManagedAssemblyPipelineError.unsupportedInputTopology(
                "--read-layout describes one input file; \(request.inputURLs[0].lastPathComponent) holds R1 and R2 files."
            )
        }
        let executionRequest = readSets.request(
            tool: request.tool,
            readType: request.readType,
            projectName: request.projectName,
            outputDirectory: request.outputDirectory,
            pairedEnd: request.pairedEnd,
            explicitLayout: request.inputLayout,
            threads: request.threads,
            memoryGB: request.memoryGB,
            minContigLength: request.minContigLength,
            selectedProfileID: request.selectedProfileID,
            extraArguments: request.extraArguments,
            profileSelectionBasis: request.profileSelectionBasis
        ).request
        return ManagedAssemblyMaterializationResult(
            request: executionRequest,
            originalInputURLs: resolved.originalInputURLs,
            materializationStartedAt: resolved.materializationStartedAt,
            materializationEndedAt: resolved.materializationEndedAt,
            readSets: readSets
        )
    }

    static func validatePreMaterializationTopology(for request: AssemblyRunRequest) throws {
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

        guard runsInAppBundle else { return }
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.warning("Failed to post notification: \(error)") }
        }
    }

    /// Whether this process is an app, the only kind `UNUserNotificationCenter` serves. A test
    /// runner has a bundle identifier but no app bundle, and the center throws there
    /// (`bundleProxyForCurrentProcess is nil`).
    private static var runsInAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}
