import Foundation
import LungfishIO
import LungfishWorkflow

struct CLIInvocation: Sendable, Equatable {
    let subcommand: String
    let arguments: [String]
}

struct FASTQCLIExecutionResult: Sendable, Equatable {
    let outputURLs: [URL]
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
    func run(invocation: CLIInvocation, outputDirectory: URL) async throws -> FASTQCLIExecutionResult
}

protocol FASTQOperationDirectImporting: Sendable {
    func importOutputs(
        at outputURLs: [URL],
        forResolvedRequest request: FASTQOperationLaunchRequest,
        originalRequest: FASTQOperationLaunchRequest,
        outputDirectory: URL
    ) async throws -> [URL]
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
        sourceInputURL: URL?
    ) async throws -> URL
}

enum FASTQOperationExecutionError: Error, LocalizedError {
    case unsupportedAdapterTrim(String)
    case unsupportedPrimerRemoval(String)
    case unsupportedDemultiplex(String)
    case unsupportedOrient(String)
    case unsupportedAssembly(String)

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

    init(
        inputResolver: any FASTQOperationInputResolving = FASTQSourceResolverAdapter(),
        commandRunner: any FASTQOperationCommandRunning = LungfishCLIProcessRunner(),
        directImporter: any FASTQOperationDirectImporting = IdentityFASTQOperationImporter(),
        planner: FASTQOperationPlanner = FASTQOperationPlanner(),
        invocationBuilder: FASTQOperationCLIInvocationBuilder = FASTQOperationCLIInvocationBuilder(),
        stagingCleanup: FASTQOperationStagingCleanup = FASTQOperationStagingCleanup()
    ) {
        self.inputResolver = inputResolver
        self.commandRunner = commandRunner
        self.directImporter = directImporter
        self.planner = planner
        self.invocationBuilder = invocationBuilder
        self.stagingCleanup = stagingCleanup
    }

    func execute(
        request: FASTQOperationLaunchRequest,
        workingDirectory: URL
    ) async throws -> FASTQOperationExecutionResult {
        try validatePreResolutionTopologyIfNeeded(for: request)

        let materializationDirectory = request.resolvesInputsBeforeCLI
            ? workingDirectory.appendingPathComponent(
                "materialized-inputs-\(UUID().uuidString)",
                isDirectory: true
            )
            : nil
        let outputDirectory = planner.executionOutputDirectory(for: request, workingDirectory: workingDirectory)
        if let materializationDirectory {
            try FileManager.default.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

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

        var invocations: [CLIInvocation] = []
        var outputURLs: [URL] = []

        for executionPlan in executionPlans {
            let executionDirectory = planner.executionDirectory(for: executionPlan)
            try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
            let invocation = try invocationBuilder.buildInvocation(
                for: executionPlan.resolvedRequest,
                outputTargetPath: executionPlan.outputTarget.path
            )
            invocations.append(invocation)
            let result = try await commandRunner.run(
                invocation: invocation,
                outputDirectory: executionDirectory
            )
            if result.outputURLs.isEmpty {
                outputURLs.append(contentsOf: planner.discoverOutputs(for: executionPlan, in: executionDirectory))
            } else {
                outputURLs.append(contentsOf: result.outputURLs)
            }
        }

        if outputURLs.isEmpty {
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
                outputDirectory: outputDirectory
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
    }

    func buildInvocation(for request: FASTQOperationLaunchRequest) throws -> CLIInvocation {
        try invocationBuilder.buildInvocation(for: request)
    }

    private func validatePreResolutionTopologyIfNeeded(
        for request: FASTQOperationLaunchRequest
    ) throws {
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

private struct LungfishCLIProcessRunner: FASTQOperationCommandRunning {
    func run(invocation: CLIInvocation, outputDirectory: URL) async throws -> FASTQCLIExecutionResult {
        guard let cliURL = LungfishCLIRunner.findCLI() else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }

        let process = Process()
        process.executableURL = cliURL
        process.currentDirectoryURL = outputDirectory
        process.arguments = [invocation.subcommand] + invocation.arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutTask = Task.detached(priority: .userInitiated) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let terminationStatus: Int32
        do {
            terminationStatus = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: LungfishCLIRunner.RunError.launchFailed(error.localizedDescription)
                    )
                }
            }
        } catch {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }

        let stderrData = await stderrTask.value
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
