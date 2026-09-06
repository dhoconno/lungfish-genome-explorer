import Foundation
import LungfishCore
import LungfishKit
import LungfishIO
import LungfishWorkflow

struct CLIInvocation: Sendable, Equatable {
    let subcommand: String
    let arguments: [String]
}

struct FASTQCLIExecutionResult: Sendable, Equatable {
    let outputURLs: [URL]
}

typealias FASTQOperationProgressHandler = @Sendable (Double, String) -> Void

struct FASTQCLIProgressEvent: Sendable, Equatable {
    let progress: Double
    let message: String

    static func parse(_ line: String) throws -> FASTQCLIProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["event"] as? String == "progress",
              let message = payload["message"] as? String else {
            return nil
        }

        let progress: Double
        if let number = payload["progress"] as? NSNumber {
            progress = number.doubleValue
        } else if let value = payload["progress"] as? Double {
            progress = value
        } else {
            return nil
        }

        return FASTQCLIProgressEvent(
            progress: max(0, min(1, progress)),
            message: message
        )
    }
}

private final class FASTQCLIStderrCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedData = Data()
    private var pendingText = ""

    func append(_ data: Data) -> [FASTQCLIProgressEvent] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        capturedData.append(data)
        guard let text = String(data: data, encoding: .utf8) else {
            lock.unlock()
            return []
        }
        pendingText += text

        var events: [FASTQCLIProgressEvent] = []
        while let newlineIndex = pendingText.firstIndex(of: "\n") {
            let line = String(pendingText[..<newlineIndex])
            pendingText.removeSubrange(...newlineIndex)
            if let event = try? FASTQCLIProgressEvent.parse(line) {
                events.append(event)
            }
        }
        lock.unlock()
        return events
    }

    func finish() -> [FASTQCLIProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingText.isEmpty else { return [] }
        let line = pendingText
        pendingText.removeAll(keepingCapacity: true)
        if let event = try? FASTQCLIProgressEvent.parse(line) {
            return [event]
        }
        return []
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return capturedData
    }
}

struct FASTQOperationExecutionResult: Sendable, Equatable {
    let resolvedRequest: FASTQOperationLaunchRequest
    let executedInvocations: [CLIInvocation]
    let importedURLs: [URL]
    let groupedContainerURL: URL?
}

protocol FASTQOperationInputResolving: Sendable {
    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest
}

protocol FASTQOperationCommandRunning: Sendable {
    func run(
        invocation: CLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult
}

/// Reports a named phase of the post-execution import so the Operations
/// panel can show live progress instead of a stale "Launching lungfish-cli...".
/// `fraction` is the overall operation progress in `0...1`.
typealias FASTQOperationImportProgressHandler = @Sendable (Double, String) -> Void

protocol FASTQOperationDirectImporting: Sendable {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL,
        progress: FASTQOperationImportProgressHandler?
    ) async throws -> [URL]
}

extension FASTQOperationDirectImporting {
    /// Convenience overload for callers that do not report progress.
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL] {
        try await importOutputs(
            at: outputURLs,
            forResolvedRequest: request,
            originalRequest: originalRequest,
            outputDirectory: outputDirectory,
            progress: nil
        )
    }
}

protocol FASTQOperationSavontRollbackRemoving: Sendable {
    func removeItem(at url: URL) throws
}

struct FileManagerFASTQOperationSavontRollbackRemover: FASTQOperationSavontRollbackRemoving {
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

struct FASTQOperationRollbackRemovalFailure: Sendable, Equatable {
    let path: URL
    let message: String
}

struct FASTQOperationRollbackCleanupError: Error, LocalizedError {
    let originalError: any Error
    let retainedPaths: [URL]
    let removalFailures: [FASTQOperationRollbackRemovalFailure]

    var errorDescription: String? {
        let retained = retainedPaths.map(\.path).joined(separator: ", ")
        let failures = removalFailures.map { "\($0.path.path): \($0.message)" }.joined(separator: "; ")
        return "Savont rollback cleanup failed after \(originalError.localizedDescription). "
            + "Retained paths: \(retained). Removal failures: \(failures)"
    }
}

protocol ReferenceBundleWrapping: Sendable {
    func importReferenceBundle(
        sourceURL: URL,
        outputDirectory: URL,
        preferredBundleName: String?
    ) async throws -> URL
}

protocol FASTQOutputIngesting: Sendable {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult
}

protocol FASTQOutputBundleWriting: Sendable {
    func importFASTQOutput(
        sourceURL: URL,
        bundleURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?,
        progress: FASTQOperationImportProgressHandler?
    ) async throws -> URL
}

extension FASTQOutputBundleWriting {
    /// Convenience overload for callers that do not report progress.
    func importFASTQOutput(
        sourceURL: URL,
        bundleURL: URL,
        originalRequest: FASTQOperationLaunchRequest,
        sourceInputURL: URL?
    ) async throws -> URL {
        try await importFASTQOutput(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            originalRequest: originalRequest,
            sourceInputURL: sourceInputURL,
            progress: nil
        )
    }
}

enum FASTQOperationExecutionError: Error, LocalizedError {
    case unsupportedAdapterTrim(String)
    case unsupportedPrimerRemoval(String)
    case unsupportedDemultiplex(String)
    case unsupportedOrient(String)
    case unsupportedAssembly(String)
    case invalidSavontOutputName(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAdapterTrim(let reason):
            return "FASTQ adapter trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedPrimerRemoval(let reason):
            return "FASTQ primer trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedDemultiplex(let reason):
            return "FASTQ demultiplex request is not supported by the CLI builder: \(reason)"
        case .unsupportedOrient(let reason):
            return "FASTQ orient request is not supported by the CLI builder: \(reason)"
        case .unsupportedAssembly(let reason):
            return "FASTQ assembly request is not supported by the CLI builder: \(reason)"
        case .invalidSavontOutputName(let reason):
            return "Savont output name is invalid: \(reason)"
        }
    }
}

struct FASTQOperationExecutionService {
    private let inputResolver: any FASTQOperationInputResolving
    private let commandRunner: any FASTQOperationCommandRunning
    private let directImporter: any FASTQOperationDirectImporting
    private let planner: FASTQOperationPlanner
    private let invocationBuilder: FASTQOperationCLIInvocationBuilder
    private let stagingCleanup: FASTQOperationStagingCleanup
    private let savontRollbackRemover: any FASTQOperationSavontRollbackRemoving

    init(
        inputResolver: any FASTQOperationInputResolving = FASTQSourceResolverAdapter(),
        commandRunner: any FASTQOperationCommandRunning = LungfishCLIProcessRunner(),
        directImporter: any FASTQOperationDirectImporting = IdentityFASTQOperationImporter(),
        planner: FASTQOperationPlanner = FASTQOperationPlanner(),
        invocationBuilder: FASTQOperationCLIInvocationBuilder = FASTQOperationCLIInvocationBuilder(),
        stagingCleanup: FASTQOperationStagingCleanup = FASTQOperationStagingCleanup(),
        savontRollbackRemover: any FASTQOperationSavontRollbackRemoving =
            FileManagerFASTQOperationSavontRollbackRemover()
    ) {
        self.inputResolver = inputResolver
        self.commandRunner = commandRunner
        self.directImporter = directImporter
        self.planner = planner
        self.invocationBuilder = invocationBuilder
        self.stagingCleanup = stagingCleanup
        self.savontRollbackRemover = savontRollbackRemover
    }

    func execute(
        request: FASTQOperationLaunchRequest,
        workingDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler = { _, _ in }
    ) async throws -> FASTQOperationExecutionResult {
        try validatePreResolutionTopologyIfNeeded(for: request)

        let fileManager = FileManager.default
        var failureCleanupCandidates: [URL] = []
        var freshSavontRollbackCandidates: [URL] = []
        func trackFreshCleanupCandidate(_ url: URL) {
            let standardizedURL = url.standardizedFileURL
            if !fileManager.fileExists(atPath: standardizedURL.path) {
                failureCleanupCandidates.append(standardizedURL)
            }
        }

        let materializationDirectory = request.resolvesInputsBeforeCLI
            ? workingDirectory.appendingPathComponent(
                "materialized-inputs-\(UUID().uuidString)",
                isDirectory: true
            )
            : nil
        let outputDirectory = planner.executionOutputDirectory(for: request, workingDirectory: workingDirectory)

        do {
            if let materializationDirectory {
                trackFreshCleanupCandidate(materializationDirectory)
                try fileManager.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
            }

            if planner.cliCreatesFreshOutputDirectory(for: request) {
                trackFreshCleanupCandidate(outputDirectory)
                try fileManager.createDirectory(
                    at: outputDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } else {
                trackFreshCleanupCandidate(outputDirectory)
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            }

            let resolvedRequest: FASTQOperationLaunchRequest
            if let materializationDirectory {
                resolvedRequest = try await inputResolver.resolve(
                    request: request,
                    tempDirectory: materializationDirectory
                )
            } else {
                resolvedRequest = request
            }
            let executionPlans = planner.makeExecutionPlans(
                originalRequest: request,
                resolvedRequest: resolvedRequest,
                baseOutputDirectory: outputDirectory
            )
            if case .savont = resolvedRequest {
                freshSavontRollbackCandidates = executionPlans.flatMap { plan in
                    let output = plan.outputTarget.standardizedFileURL
                    return [output, ProvenanceRecorder.fileSidecarURL(for: output)]
                }.filter { !fileManager.fileExists(atPath: $0.path) }
            }

            var invocations: [CLIInvocation] = []
            var outputURLs: [URL] = []

            // The tool phase occupies the front half of the progress bar
            // (0...0.5); the import phase that follows takes 0.5...1.0.
            let totalPlans = executionPlans.count
            let operationPhaseLabel = request.operationDisplayTitle

            for (planIndex, executionPlan) in executionPlans.enumerated() {
                let cliCreatesFreshOutputDirectory = planner.cliCreatesFreshOutputDirectory(for: executionPlan)
                let executionDirectory = cliCreatesFreshOutputDirectory
                    ? executionPlan.outputTarget.deletingLastPathComponent()
                    : planner.executionDirectory(for: executionPlan)

                if cliCreatesFreshOutputDirectory {
                    trackFreshCleanupCandidate(executionPlan.outputTarget)
                } else {
                    trackFreshCleanupCandidate(executionDirectory)
                }
                try fileManager.createDirectory(at: executionDirectory, withIntermediateDirectories: true)

                let invocation = try invocationBuilder.buildInvocation(
                    for: executionPlan.resolvedRequest,
                    outputTargetPath: executionPlan.outputTarget.path
                )
                invocations.append(invocation)

                // Name the sample and its position in the batch so the
                // Operations panel shows which of N is running, instead of
                // holding a stale "Launching lungfish-cli..." for the whole run.
                let planSampleName = executionPlan.resolvedRequest.inputURLs.first
                    .map(FASTQOperationPlanner.sanitizedStem(for:))
                let toolPhaseFraction = 0.01
                    + (Double(planIndex) / Double(totalPlans)) * 0.49
                let toolPhaseMessage: String
                if totalPlans > 1, let planSampleName {
                    toolPhaseMessage = "\(operationPhaseLabel): sample \(planIndex + 1) of \(totalPlans) — \(planSampleName)"
                } else if let planSampleName {
                    toolPhaseMessage = "\(operationPhaseLabel): \(planSampleName)"
                } else {
                    toolPhaseMessage = "\(operationPhaseLabel): running\u{2026}"
                }
                progress(toolPhaseFraction, toolPhaseMessage)

                let result = try await commandRunner.run(
                    invocation: invocation,
                    outputDirectory: executionDirectory,
                    // Rescale the CLI's own 0...1 progress into this plan's
                    // slice of the tool phase so a multi-sample batch advances
                    // monotonically instead of restarting the bar per sample.
                    progress: { fraction, message in
                        let scaled = 0.01
                            + ((Double(planIndex) + max(0, min(1, fraction)))
                                / Double(totalPlans)) * 0.49
                        progress(scaled, message)
                    }
                )
                if case .savont = executionPlan.resolvedRequest {
                    // Savont publishes one FASTA at the exact path reserved by this plan. The
                    // generic CLI runner also discovers pre-existing FASTQ bundles in the shared
                    // Analyses directory; those are unrelated inputs or older results and must
                    // never be attributed to this clustering run.
                    outputURLs.append(contentsOf: planner.discoverOutputs(
                        for: executionPlan,
                        in: executionDirectory
                    ))
                } else if result.outputURLs.isEmpty {
                    outputURLs.append(contentsOf: planner.discoverOutputs(for: executionPlan, in: executionDirectory))
                } else {
                    outputURLs.append(contentsOf: result.outputURLs)
                }
            }

            if outputURLs.isEmpty, case .savont = resolvedRequest {
                // Do not replace a missing planned FASTA with unrelated bundles found beside it.
            } else if outputURLs.isEmpty {
                outputURLs = FASTQOperationPlanner.discoverFASTQBundles(in: outputDirectory)
            }

            switch planner.outputMode(for: resolvedRequest) {
            case .groupedResult:
                try planner.persistGroupedResultManifest(
                    originalRequest: request,
                    resolvedRequest: resolvedRequest,
                    outputURLs: outputURLs,
                    outputDirectory: outputDirectory
                )
                try planner.ensureGroupedResultProvenance(
                    originalRequest: request,
                    resolvedRequest: resolvedRequest,
                    invocations: invocations,
                    outputURLs: outputURLs,
                    outputDirectory: outputDirectory
                )
                stagingCleanup.cleanup(
                    directories: [materializationDirectory].compactMap { $0 },
                    preserving: [outputDirectory] + outputURLs
                )
                return FASTQOperationExecutionResult(
                    resolvedRequest: resolvedRequest,
                    executedInvocations: invocations,
                    importedURLs: [outputDirectory],
                    groupedContainerURL: outputDirectory
                )

            case .perInput, .fixedBatch:
                let importedURLs = try await directImporter.importOutputs(
                    at: outputURLs,
                    forResolvedRequest: resolvedRequest,
                    originalRequest: request,
                    outputDirectory: outputDirectory,
                    progress: { fraction, message in
                        progress(fraction, message)
                    }
                )
                stagingCleanup.cleanup(
                    directories: [materializationDirectory, outputDirectory].compactMap { $0 },
                    preserving: importedURLs
                )
                return FASTQOperationExecutionResult(
                    resolvedRequest: resolvedRequest,
                    executedInvocations: invocations,
                    importedURLs: importedURLs,
                    groupedContainerURL: nil
                )
            }
        } catch {
            let originalError = error
            var rollbackRemovalFailures: [FASTQOperationRollbackRemovalFailure] = []
            for candidate in freshSavontRollbackCandidates
                where fileManager.fileExists(atPath: candidate.path) {
                do {
                    try savontRollbackRemover.removeItem(at: candidate)
                } catch {
                    rollbackRemovalFailures.append(FASTQOperationRollbackRemovalFailure(
                        path: candidate,
                        message: error.localizedDescription
                    ))
                }
            }
            stagingCleanup.cleanupFailedRun(candidates: failureCleanupCandidates)
            let retainedPaths = freshSavontRollbackCandidates.filter {
                fileManager.fileExists(atPath: $0.path)
            }
            if !rollbackRemovalFailures.isEmpty || !retainedPaths.isEmpty {
                throw FASTQOperationRollbackCleanupError(
                    originalError: originalError,
                    retainedPaths: retainedPaths,
                    removalFailures: rollbackRemovalFailures
                )
            }
            throw originalError
        }
    }

    func buildInvocation(for request: FASTQOperationLaunchRequest) throws -> CLIInvocation {
        try invocationBuilder.buildInvocation(for: request)
    }

    private func validatePreResolutionTopologyIfNeeded(
        for request: FASTQOperationLaunchRequest
    ) throws {
        if case .savont(let savontRequest) = request,
           savontRequest.inputURLs.count == 1,
           let outputName = savontRequest.singleInputOutputName,
           FASTQSavontClusteringRequest.safeSingleInputOutputName(
                outputName,
                outputDirectoryURL: savontRequest.outputDirectoryURL
           ) == nil {
            throw FASTQOperationExecutionError.invalidSavontOutputName(
                "use a leaf file name without folders, traversal, or an absolute path."
            )
        }
        guard case .assemble(let assemblyRequest, _) = request else { return }

        if assemblyRequest.pairedEnd && assemblyRequest.inputURLs.count != 2 {
            throw FASTQOperationExecutionError.unsupportedAssembly(
                "Paired-end assembly requests must include exactly two sequence inputs."
            )
        }

        switch assemblyRequest.tool {
        case .flye:
            guard !assemblyRequest.pairedEnd, assemblyRequest.inputURLs.count == 1 else {
                throw FASTQOperationExecutionError.unsupportedAssembly(
                    "Flye expects a single ONT sequence input in v1."
                )
            }
        case .hifiasm:
            guard !assemblyRequest.pairedEnd, assemblyRequest.inputURLs.count == 1 else {
                throw FASTQOperationExecutionError.unsupportedAssembly(
                    "Hifiasm expects a single ONT or PacBio HiFi/CCS sequence input in v1."
                )
            }
        case .spades, .megahit, .skesa:
            break
        }
    }
}

private struct FASTQSourceResolverAdapter: FASTQOperationInputResolving {
    func resolve(
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL
    ) async throws -> FASTQOperationLaunchRequest {
        if request.requiresSingleResolvedFASTQPerInput {
            var resolvedURLs: [URL] = []
            resolvedURLs.reserveCapacity(request.inputURLs.count)
            for inputURL in request.inputURLs {
                resolvedURLs.append(
                    try await resolveSingleExecutionInput(
                        from: inputURL,
                        request: request,
                        tempDirectory: tempDirectory,
                        bridgeFASTAToFASTQ: request.requiresSyntheticFASTQBridge
                    )
                )
            }
            return request.replacingInputURLs(with: resolvedURLs)
        }

        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, tempDir, progress in
            try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDir,
                progress: progress
            )
        }

        var resolvedURLs: [URL] = []
        for inputURL in request.inputURLs {
            if FASTQBundle.isBundleURL(inputURL) {
                let urls = try await resolver.resolve(
                    bundleURL: inputURL,
                    tempDirectory: tempDirectory,
                    progress: { _, _ in }
                )
                resolvedURLs.append(contentsOf: urls)
            } else if FASTQBundle.isBundleURL(inputURL.deletingLastPathComponent()) {
                let urls = try await resolver.resolve(
                    bundleURL: inputURL.deletingLastPathComponent(),
                    tempDirectory: tempDirectory,
                    progress: { _, _ in }
                )
                resolvedURLs.append(contentsOf: urls)
            } else {
                resolvedURLs.append(inputURL)
            }
        }

        if request.requiresSyntheticFASTQBridge {
            var bridgedURLs: [URL] = []
            bridgedURLs.reserveCapacity(resolvedURLs.count)
            for resolvedURL in resolvedURLs {
                bridgedURLs.append(
                    try await bridgeFASTAIfNeeded(
                        inputURL: resolvedURL,
                        tempDirectory: tempDirectory
                    )
                )
            }
            resolvedURLs = bridgedURLs
        }

        return request.replacingInputURLs(with: resolvedURLs)
    }

    private func resolveSingleExecutionInput(
        from inputURL: URL,
        request: FASTQOperationLaunchRequest,
        tempDirectory: URL,
        bridgeFASTAToFASTQ: Bool
    ) async throws -> URL {
        let standardizedInputURL = inputURL.standardizedFileURL
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInputURL) {
            if FASTQBundle.isDerivedBundle(bundleURL) {
                let materializedURL = try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                    fromBundle: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: nil
                )
                return try await bridgeFASTAIfNeeded(
                    inputURL: materializedURL,
                    tempDirectory: tempDirectory,
                    enabled: bridgeFASTAToFASTQ
                )
            }

            if let allFASTQURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL),
               allFASTQURLs.count > 1 {
                if request.allowsDirectMultiFileFASTQBundleInput {
                    return bundleURL
                }
                return try materializeConcatenatedFASTQ(
                    from: allFASTQURLs,
                    tempDirectory: tempDirectory
                )
            }

            if let primarySequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL) {
                return try await bridgeFASTAIfNeeded(
                    inputURL: primarySequenceURL,
                    tempDirectory: tempDirectory,
                    enabled: bridgeFASTAToFASTQ
                )
            }
        }

        if let primarySequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedInputURL) {
            return try await bridgeFASTAIfNeeded(
                inputURL: primarySequenceURL,
                tempDirectory: tempDirectory,
                enabled: bridgeFASTAToFASTQ
            )
        }

        return try await bridgeFASTAIfNeeded(
            inputURL: standardizedInputURL,
            tempDirectory: tempDirectory,
            enabled: bridgeFASTAToFASTQ
        )
    }

    private func materializeConcatenatedFASTQ(
        from inputURLs: [URL],
        tempDirectory: URL
    ) throws -> URL {
        guard let firstInputURL = inputURLs.first else {
            throw ExtractionError.noSourceFASTQ
        }

        let fileExtension: String
        if firstInputURL.pathExtension.lowercased() == "gz" {
            let baseExtension = firstInputURL.deletingPathExtension().pathExtension
            fileExtension = baseExtension.isEmpty ? "fastq.gz" : "\(baseExtension).gz"
        } else {
            fileExtension = firstInputURL.pathExtension.isEmpty ? "fastq" : firstInputURL.pathExtension
        }

        let outputURL = tempDirectory.appendingPathComponent(
            FASTQSourceResolver.tempFileName(extension: fileExtension)
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputURLs {
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            defer { try? inputHandle.close() }

            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }

        return outputURL
    }

    private func bridgeFASTAIfNeeded(
        inputURL: URL,
        tempDirectory: URL,
        enabled: Bool = true
    ) async throws -> URL {
        guard enabled, SequenceFormat.from(url: inputURL) == .fasta else {
            return inputURL
        }

        let outputURL = tempDirectory.appendingPathComponent(
            "synthetic-\(UUID().uuidString).fastq"
        )
        try await SyntheticFASTQBridge.convertFASTAToFASTQ(
            inputURL: inputURL,
            outputURL: outputURL
        )
        return outputURL
    }
}

struct LungfishCLIProcessRunner: FASTQOperationCommandRunning {
    private let cliURLProvider: @Sendable () -> URL?

    init(cliURLProvider: @escaping @Sendable () -> URL? = { LungfishCLIRunner.findCLI() }) {
        self.cliURLProvider = cliURLProvider
    }

    func run(
        invocation: CLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        guard let cliURL = cliURLProvider() else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }

        let process = Process()
        process.environment = ManagedStorageConfigStore().subprocessEnvironment()
        process.executableURL = cliURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = [invocation.subcommand] + invocation.arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let cancellationHandle = NativeProcessCancellationHandle()
        let stdoutTask = Task.detached(priority: .userInitiated) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrCapture = FASTQCLIStderrCapture()
        let stderrTask = Task.detached(priority: .userInitiated) {
            let handle = stderr.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let events = stderrCapture.append(chunk)
                for event in events {
                    progress(event.progress, event.message)
                }
            }
            for event in stderrCapture.finish() {
                progress(event.progress, event.message)
            }
        }

        let terminationStatus: Int32
        do {
            terminationStatus = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { terminatedProcess in
                        continuation.resume(returning: terminatedProcess.terminationStatus)
                    }

                    do {
                        try process.run()
                        cancellationHandle.store(process)
                        cancellationHandle.terminateIfRequested(gracePeriod: 0)
                    } catch {
                        stdout.fileHandleForWriting.closeFile()
                        stderr.fileHandleForWriting.closeFile()
                        if cancellationHandle.isTerminationRequested || Task.isCancelled {
                            continuation.resume(throwing: LungfishCLIRunner.RunError.cancelled)
                        } else {
                            continuation.resume(
                                throwing: LungfishCLIRunner.RunError.launchFailed(error.localizedDescription)
                            )
                        }
                    }
                }
            } onCancel: {
                cancellationHandle.terminateProcessTree(gracePeriod: 0)
            }
        } catch is CancellationError {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw LungfishCLIRunner.RunError.cancelled
        } catch {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }

        let wasCancelled = cancellationHandle.isTerminationRequested || Task.isCancelled
        cancellationHandle.clear(process)
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        if wasCancelled {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw LungfishCLIRunner.RunError.cancelled
        }

        await stderrTask.value
        let stderrData = stderrCapture.data
        let stdoutData = await stdoutTask.value
        _ = stdoutData

        if terminationStatus != 0 {
            let stderrText = String(
                data: stderrData,
                encoding: .utf8
            ) ?? ""
            throw LungfishCLIRunner.RunError.nonZeroExit(
                status: terminationStatus,
                stderr: stderrText
            )
        }

        return FASTQCLIExecutionResult(
            outputURLs: FASTQOperationPlanner.discoverFASTQBundles(in: outputDirectory)
        )
    }
}
