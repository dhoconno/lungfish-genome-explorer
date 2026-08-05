import Foundation
import LungfishCore
import LungfishIO

public struct SavontProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let argv: [String]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let startedAt: Date
    public let completedAt: Date

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        argv: [String],
        runtimeIdentity: ProvenanceRuntimeIdentity,
        startedAt: Date,
        completedAt: Date
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.argv = argv
        self.runtimeIdentity = runtimeIdentity
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public protocol SavontProcessRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL) async throws -> SavontProcessResult
}

public struct ManagedSavontProcessRunner: SavontProcessRunning {
    public static let timeoutSeconds: TimeInterval = 7_200

    private let condaManager: CondaManager

    public init(condaManager: CondaManager = .shared) {
        self.condaManager = condaManager
    }

    public func run(arguments: [String], workingDirectory: URL) async throws -> SavontProcessResult {
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: "savont",
            arguments: arguments,
            environment: SavontClusteringRunRequest.condaEnvironment,
            workingDirectory: workingDirectory,
            timeout: Self.timeoutSeconds
        )
        let completedAt = Date()
        let rootPrefix = condaManager.rootPrefix
        let micromambaURL = rootPrefix.appendingPathComponent("bin/micromamba")
        let environmentURL = rootPrefix.appendingPathComponent(
            "envs/\(SavontClusteringRunRequest.condaEnvironment)",
            isDirectory: true
        )
        let argv = [
            micromambaURL.path,
            "run", "-n", SavontClusteringRunRequest.condaEnvironment,
            "savont",
        ] + arguments
        return SavontProcessResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            argv: argv,
            runtimeIdentity: ProvenanceRuntimeIdentity(
                executablePath: micromambaURL.path,
                condaEnvironment: SavontClusteringRunRequest.condaEnvironment,
                condaPrefix: environmentURL.path
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

public struct SavontClusteringResult: Sendable, Codable, Equatable {
    public let outputFASTAURL: URL
    public let provenanceURL: URL
    public let summary: SavontClusterSummary
    public let usedSingleThreadFallback: Bool
    public let usedSingleStrandFallback: Bool
    public let publicationCleanupPendingURLs: [URL]

    private enum CodingKeys: String, CodingKey {
        case outputFASTAURL
        case provenanceURL
        case summary
        case usedSingleThreadFallback
        case usedSingleStrandFallback
        case publicationCleanupPendingURLs
    }

    public init(
        outputFASTAURL: URL,
        provenanceURL: URL,
        summary: SavontClusterSummary,
        usedSingleThreadFallback: Bool,
        usedSingleStrandFallback: Bool,
        publicationCleanupPendingURLs: [URL] = []
    ) {
        self.outputFASTAURL = outputFASTAURL
        self.provenanceURL = provenanceURL
        self.summary = summary
        self.usedSingleThreadFallback = usedSingleThreadFallback
        self.usedSingleStrandFallback = usedSingleStrandFallback
        self.publicationCleanupPendingURLs = publicationCleanupPendingURLs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outputFASTAURL: try container.decode(URL.self, forKey: .outputFASTAURL),
            provenanceURL: try container.decode(URL.self, forKey: .provenanceURL),
            summary: try container.decode(SavontClusterSummary.self, forKey: .summary),
            usedSingleThreadFallback: try container.decode(Bool.self, forKey: .usedSingleThreadFallback),
            usedSingleStrandFallback: try container.decode(Bool.self, forKey: .usedSingleStrandFallback),
            publicationCleanupPendingURLs: try container.decodeIfPresent(
                [URL].self,
                forKey: .publicationCleanupPendingURLs
            ) ?? []
        )
    }
}

public enum SavontClusteringError: Error, LocalizedError, Sendable, Equatable {
    case invalidInputFASTQ(URL)
    case processFailed(status: Int32, stderr: String)
    case missingFinalASVs(URL)
    case emptyFinalASVs(URL)
    case outputDestinationIsDirectory(URL)
    case publicationRollbackFailed(originalError: String, rollbackErrors: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidInputFASTQ(let url):
            "Savont input is not a readable FASTQ file or .lungfishfastq bundle: \(url.path)"
        case .processFailed(let status, let stderr):
            "Savont failed with exit status \(status): \(stderr)"
        case .missingFinalASVs(let url):
            "Savont completed without producing final_asvs.fasta at \(url.path)."
        case .emptyFinalASVs(let url):
            "Savont completed with an empty final_asvs.fasta at \(url.path)."
        case .outputDestinationIsDirectory(let url):
            "Savont output destination is an existing directory: \(url.path)"
        case .publicationRollbackFailed(let originalError, let rollbackErrors):
            "Savont publication failed (\(originalError)) and rollback was incomplete: \(rollbackErrors.joined(separator: "; "))"
        }
    }
}

public struct SavontClusteringPipeline: Sendable {
    private let processRunner: any SavontProcessRunning
    private let scratchRootURL: URL
    private let publicationFailureInjector: (@Sendable () throws -> Void)?
    private let publicationBackupCleanupInjector: (@Sendable (URL) throws -> Void)?

    public init(
        processRunner: any SavontProcessRunning = ManagedSavontProcessRunner(),
        scratchRootURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.processRunner = processRunner
        self.scratchRootURL = scratchRootURL.standardizedFileURL
        publicationFailureInjector = nil
        publicationBackupCleanupInjector = nil
    }

    init(
        processRunner: any SavontProcessRunning,
        scratchRootURL: URL,
        publicationFailureInjector: @escaping @Sendable () throws -> Void,
        publicationBackupCleanupInjector: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.processRunner = processRunner
        self.scratchRootURL = scratchRootURL.standardizedFileURL
        self.publicationFailureInjector = publicationFailureInjector
        self.publicationBackupCleanupInjector = publicationBackupCleanupInjector
    }

    public func run(_ request: SavontClusteringRunRequest) async throws -> SavontClusteringResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let originalInputURL = request.inputFASTQURL.standardizedFileURL
        guard fileManager.fileExists(atPath: originalInputURL.path),
              FASTQBundle.resolvePrimaryFASTQURL(for: originalInputURL) != nil else {
            throw SavontClusteringError.invalidInputFASTQ(originalInputURL)
        }

        let outputURL = request.outputFASTAURL.standardizedFileURL
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)
        if Self.isDirectory(outputURL, fileManager: fileManager) {
            throw SavontClusteringError.outputDestinationIsDirectory(outputURL)
        }

        let token = UUID().uuidString
        let stagedOutputURL = outputDirectoryURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(token).savont-publish.tmp"
        )
        let stagedSidecarURL = outputDirectoryURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(token).savont-provenance.tmp"
        )
        let runScratchURL = scratchRootURL.appendingPathComponent(
            ".savont-run-\(token)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: runScratchURL, withIntermediateDirectories: false)
        defer {
            Self.removeIfPresent(stagedOutputURL, fileManager: fileManager)
            Self.removeIfPresent(stagedSidecarURL, fileManager: fileManager)
            Self.removeIfPresent(runScratchURL, fileManager: fileManager)
        }

        let workflowStartedAt = Date()
        let isBundleInput = FASTQBundle.isBundleURL(originalInputURL)
        let originalBundleDescriptor = isBundleInput
            ? ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
                    url: originalInputURL,
                    format: .unknown,
                    role: .input
                ),
                sourceProvenancePath: ProvenanceRecorder.findProvenanceEnvelope(
                    for: originalInputURL
                )?.sidecarURL.path
            )
            : nil
        let materialization = try FullLengthONTMHCFASTQMaterializer.materializePlainFASTQ(
            inputURL: originalInputURL,
            outputURL: runScratchURL.appendingPathComponent("input.fastq"),
            internalCommandName: "materialize-savont-clustering-fastq"
        )
        let materializedInputURL = materialization.outputURL
        guard let materializedOutputDescriptor = materialization.step.outputs.first else {
            throw SavontClusteringError.invalidInputFASTQ(originalInputURL)
        }
        let materializedInputDescriptor = ProvenanceFileDescriptor(
            path: materializedOutputDescriptor.path,
            checksumSHA256: materializedOutputDescriptor.checksumSHA256,
            fileSize: materializedOutputDescriptor.fileSize,
            format: .fastq,
            role: .input,
            originPath: originalInputURL.path
        )
        let consumedPlainInputDescriptor = materialization.step.inputs.first {
            $0.path == originalInputURL.path && $0.format == .fastq
        }

        var attemptedThreads = request.threads
        var attemptedSingleStrand = request.singleStrand
        var usedSingleThreadFallback = false
        var usedSingleStrandFallback = false
        var usedEmptyClusterFallback = false
        var attemptSteps: [ProvenanceStep] = []
        var finalRuntimeIdentity: ProvenanceRuntimeIdentity?
        var summary: SavontClusterSummary?

        attemptLoop: while true {
            try Task.checkCancellation()
            let scratchURL = scratchRootURL.appendingPathComponent(
                ".savont-attempt-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: scratchURL, withIntermediateDirectories: false)
            do {
                defer { Self.removeIfPresent(scratchURL, fileManager: fileManager) }
                let executionRequest = try SavontClusteringRunRequest(
                    inputFASTQURL: materializedInputURL,
                    outputFASTAURL: outputURL,
                    threads: request.threads,
                    qualityValueCutoff: request.qualityValueCutoff,
                    minimumClusterSize: request.minimumClusterSize,
                    minimumReadLength: request.minimumReadLength,
                    maximumReadLength: request.maximumReadLength,
                    singleStrand: request.singleStrand
                )
                let arguments = try executionRequest.arguments(
                    outputDirectory: scratchURL,
                    threads: attemptedThreads,
                    singleStrand: attemptedSingleStrand
                )
                let processResult = try await processRunner.run(
                    arguments: arguments,
                    workingDirectory: scratchURL
                )
                try Task.checkCancellation()
                finalRuntimeIdentity = processResult.runtimeIdentity

                let rawOutputURL = scratchURL.appendingPathComponent("final_asvs.fasta")
                let rawOutputDescriptor: ProvenanceFileDescriptor?
                if fileManager.fileExists(atPath: rawOutputURL.path), !Self.isDirectory(rawOutputURL, fileManager: fileManager) {
                    rawOutputDescriptor = try ProvenanceFileDescriptor.file(
                        url: rawOutputURL,
                        format: .fasta,
                        role: .output
                    )
                } else {
                    rawOutputDescriptor = nil
                }
                let exactArgv = processResult.argv.isEmpty ? ["savont"] + arguments : processResult.argv
                attemptSteps.append(ProvenanceStep(
                    toolName: "savont",
                    toolVersion: SavontClusteringRunRequest.toolVersion,
                    argv: exactArgv,
                    durableReplayArgv: nil,
                    resolvedOptions: attemptResolvedOptions(
                        request: request,
                        resolvedInputURL: materializedInputURL,
                        outputDirectory: scratchURL,
                        threads: attemptedThreads,
                        singleStrand: attemptedSingleStrand
                    ),
                    runtimeIdentity: processResult.runtimeIdentity,
                    inputs: [materializedInputDescriptor],
                    outputs: rawOutputDescriptor.map { [$0] } ?? [],
                    exitStatus: Int(processResult.exitCode),
                    wallTimeSeconds: max(0, processResult.completedAt.timeIntervalSince(processResult.startedAt)),
                    stderr: processResult.stderr.isEmpty ? nil : processResult.stderr,
                    startedAt: processResult.startedAt,
                    completedAt: processResult.completedAt
                ))

                if processResult.exitCode == 0 {
                    guard rawOutputDescriptor != nil else {
                        throw SavontClusteringError.missingFinalASVs(rawOutputURL)
                    }
                    let successfulSummary = try SavontClusterFASTA.normalize(
                        sourceURL: rawOutputURL,
                        destinationURL: stagedOutputURL
                    )
                    guard successfulSummary.clusterCount > 0 else {
                        throw SavontClusteringError.emptyFinalASVs(rawOutputURL)
                    }
                    summary = successfulSummary
                    break attemptLoop
                }

                switch SavontRetryPolicy.decision(
                    exitCode: processResult.exitCode,
                    attemptedThreads: attemptedThreads,
                    attemptedSingleStrand: attemptedSingleStrand,
                    stderr: processResult.stderr
                ) {
                case .singleThread:
                    attemptedThreads = 1
                    usedSingleThreadFallback = true
                    continue attemptLoop
                case .singleStrand:
                    attemptedSingleStrand = true
                    usedSingleStrandFallback = true
                    continue attemptLoop
                case .emptyClusters:
                    try Data().write(to: rawOutputURL, options: .atomic)
                    summary = try SavontClusterFASTA.normalize(
                        sourceURL: rawOutputURL,
                        destinationURL: stagedOutputURL
                    )
                    usedEmptyClusterFallback = true
                    break attemptLoop
                case .none:
                    throw SavontClusteringError.processFailed(
                        status: processResult.exitCode,
                        stderr: processResult.stderr
                    )
                }
            }
        }

        try Task.checkCancellation()
        let finalSummary = try requireSummary(summary)
        let runtimeIdentity = finalRuntimeIdentity ?? ProvenanceRuntimeIdentity(
            condaEnvironment: SavontClusteringRunRequest.condaEnvironment
        )
        let stagedDescriptor = try ProvenanceFileDescriptor.file(
            url: stagedOutputURL,
            format: .fasta,
            role: .output
        )
        let finalDescriptor = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: stagedDescriptor.checksumSHA256,
            fileSize: stagedDescriptor.fileSize,
            format: .fasta,
            role: .output,
            originPath: stagedOutputURL.path
        )
        let topLevelArgv = replayArgv(for: request)
        let workflowCompletedAt = Date()
        let finalSidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let publicationBackupCleanupCandidateCount = [outputURL, finalSidecarURL].reduce(into: 0) {
            if fileManager.fileExists(atPath: $1.path) {
                $0 += 1
            }
        }
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish fastq savont-cluster",
            workflowVersion: SavontClusteringRunRequest.workflowVersion,
            toolName: "savont",
            toolVersion: SavontClusteringRunRequest.toolVersion
        )
        builder = builder.argv(topLevelArgv)
        builder = builder.durableReplayArgv(topLevelArgv)
        builder = builder.reproducibleCommand(topLevelArgv.map(shellEscape).joined(separator: " "))
        builder = builder.options(
            explicit: explicitOptions(request: request, resolvedInputURL: materializedInputURL),
            defaults: defaultOptions(),
            resolved: resolvedOptions(
                request: request,
                resolvedInputURL: materializedInputURL,
                summary: finalSummary,
                usedSingleThreadFallback: usedSingleThreadFallback,
                usedSingleStrandFallback: usedSingleStrandFallback,
                usedEmptyClusterFallback: usedEmptyClusterFallback,
                publicationBackupCleanupCandidateCount: publicationBackupCleanupCandidateCount
            )
        )
        if let originalBundleDescriptor {
            builder = try builder.input(originalBundleDescriptor)
        } else {
            guard let consumedPlainInputDescriptor else {
                throw SavontClusteringError.invalidInputFASTQ(originalInputURL)
            }
            builder = try builder.consumedInputSnapshot(consumedPlainInputDescriptor)
        }
        builder = builder.runtime(runtimeIdentity)
        builder = try builder.relocatedOutput(finalDescriptor)
        builder = builder.step(materialization.step)
        for step in attemptSteps {
            builder = builder.step(step)
        }
        let combinedStderr = attemptSteps.compactMap(\.stderr).joined(separator: "\n")
        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: combinedStderr.isEmpty ? nil : combinedStderr,
            startedAt: workflowStartedAt,
            endedAt: workflowCompletedAt
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: stagedSidecarURL)
        try Task.checkCancellation()
        let publicationCleanupPendingURLs = try publishPair(
            stagedOutputURL: stagedOutputURL,
            stagedSidecarURL: stagedSidecarURL,
            outputURL: outputURL
        )

        return SavontClusteringResult(
            outputFASTAURL: outputURL,
            provenanceURL: ProvenanceRecorder.fileSidecarURL(for: outputURL),
            summary: finalSummary,
            usedSingleThreadFallback: usedSingleThreadFallback,
            usedSingleStrandFallback: usedSingleStrandFallback,
            publicationCleanupPendingURLs: publicationCleanupPendingURLs
        )
    }

    private func publishPair(
        stagedOutputURL: URL,
        stagedSidecarURL: URL,
        outputURL: URL
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let finalSidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let parentURL = outputURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let backupOutputURL = parentURL.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(token).savont-publish.backup"
        )
        let backupSidecarURL = parentURL.appendingPathComponent(
            ".\(finalSidecarURL.lastPathComponent).\(token).savont-publish.backup"
        )
        var outputBackedUp = false
        var sidecarBackedUp = false
        var outputInstalled = false

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.moveItem(at: outputURL, to: backupOutputURL)
                outputBackedUp = true
            }
            if fileManager.fileExists(atPath: finalSidecarURL.path) {
                try fileManager.moveItem(at: finalSidecarURL, to: backupSidecarURL)
                sidecarBackedUp = true
            }
            try fileManager.moveItem(at: stagedOutputURL, to: outputURL)
            outputInstalled = true
            try publicationFailureInjector?()
            try fileManager.moveItem(at: stagedSidecarURL, to: finalSidecarURL)
        } catch {
            var rollbackErrors: [String] = []
            if outputInstalled {
                do { try fileManager.removeItem(at: outputURL) }
                catch { rollbackErrors.append("remove new output: \(error.localizedDescription)") }
            }
            if outputBackedUp {
                do { try fileManager.moveItem(at: backupOutputURL, to: outputURL) }
                catch { rollbackErrors.append("restore prior output: \(error.localizedDescription)") }
            }
            if sidecarBackedUp {
                do { try fileManager.moveItem(at: backupSidecarURL, to: finalSidecarURL) }
                catch { rollbackErrors.append("restore prior sidecar: \(error.localizedDescription)") }
            }
            guard rollbackErrors.isEmpty else {
                throw SavontClusteringError.publicationRollbackFailed(
                    originalError: error.localizedDescription,
                    rollbackErrors: rollbackErrors
                )
            }
            throw error
        }

        var cleanupPendingURLs: [URL] = []
        for (wasBackedUp, backupURL) in [
            (outputBackedUp, backupOutputURL),
            (sidecarBackedUp, backupSidecarURL),
        ] where wasBackedUp && fileManager.fileExists(atPath: backupURL.path) {
            do {
                try publicationBackupCleanupInjector?(backupURL)
                try fileManager.removeItem(at: backupURL)
            } catch {
                cleanupPendingURLs.append(backupURL)
            }
        }
        return cleanupPendingURLs
    }

    private func replayArgv(for request: SavontClusteringRunRequest) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "fastq", "savont-cluster",
            request.inputFASTQURL.path,
            "--output", request.outputFASTAURL.path,
            "--threads", String(request.threads),
            "--quality-value-cutoff", String(request.qualityValueCutoff),
            "--min-cluster-size", String(request.minimumClusterSize),
        ]
        if let minimumReadLength = request.minimumReadLength {
            argv.append(contentsOf: ["--min-read-length", String(minimumReadLength)])
        }
        if let maximumReadLength = request.maximumReadLength {
            argv.append(contentsOf: ["--max-read-length", String(maximumReadLength)])
        }
        if request.singleStrand {
            argv.append("--single-strand")
        }
        return argv
    }

    private func explicitOptions(
        request: SavontClusteringRunRequest,
        resolvedInputURL: URL
    ) -> [String: ParameterValue] {
        [
            "inputFASTQ": .file(request.inputFASTQURL),
            "resolvedInputFASTQ": .file(resolvedInputURL),
            "outputFASTA": .file(request.outputFASTAURL),
            "threads": .integer(request.threads),
            "qualityValueCutoff": .integer(request.qualityValueCutoff),
            "minimumClusterSize": .integer(request.minimumClusterSize),
            "minimumReadLength": request.minimumReadLength.map(ParameterValue.integer) ?? .null,
            "maximumReadLength": request.maximumReadLength.map(ParameterValue.integer) ?? .null,
            "singleStrand": .boolean(request.singleStrand),
        ]
    }

    private func defaultOptions() -> [String: ParameterValue] {
        [
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "qualityValueCutoff": .integer(90),
            "minimumClusterSize": .integer(3),
            "minimumReadLength": .null,
            "maximumReadLength": .null,
            "singleStrand": .boolean(false),
            "condaEnvironment": .string(SavontClusteringRunRequest.condaEnvironment),
            "timeoutSeconds": .integer(Int(ManagedSavontProcessRunner.timeoutSeconds)),
        ]
    }

    private func resolvedOptions(
        request: SavontClusteringRunRequest,
        resolvedInputURL: URL,
        summary: SavontClusterSummary,
        usedSingleThreadFallback: Bool,
        usedSingleStrandFallback: Bool,
        usedEmptyClusterFallback: Bool,
        publicationBackupCleanupCandidateCount: Int
    ) -> [String: ParameterValue] {
        [
            "inputFASTQ": .file(request.inputFASTQURL),
            "resolvedInputFASTQ": .file(resolvedInputURL),
            "outputFASTA": .file(request.outputFASTAURL),
            "threads": .integer(request.threads),
            "qualityValueCutoff": .integer(request.qualityValueCutoff),
            "minimumClusterSize": .integer(request.minimumClusterSize),
            "minimumReadLength": request.minimumReadLength.map(ParameterValue.integer) ?? .null,
            "maximumReadLength": request.maximumReadLength.map(ParameterValue.integer) ?? .null,
            "singleStrand": .boolean(request.singleStrand),
            "usedSingleThreadFallback": .boolean(usedSingleThreadFallback),
            "usedSingleStrandFallback": .boolean(usedSingleStrandFallback),
            "emptyClusterFallback": .boolean(usedEmptyClusterFallback),
            "clusterCount": .integer(summary.clusterCount),
            "totalSupportingReads": .integer(summary.totalSupportingReads),
            "condaEnvironment": .string(SavontClusteringRunRequest.condaEnvironment),
            "timeoutSeconds": .integer(Int(ManagedSavontProcessRunner.timeoutSeconds)),
            "publicationBackupCleanupRequired": .boolean(publicationBackupCleanupCandidateCount > 0),
            "publicationBackupCleanupCandidateCount": .integer(publicationBackupCleanupCandidateCount),
            "publicationBackupCleanupStatus": .string("evaluated-after-commit"),
        ]
    }

    private func attemptResolvedOptions(
        request: SavontClusteringRunRequest,
        resolvedInputURL: URL,
        outputDirectory: URL,
        threads: Int,
        singleStrand: Bool
    ) -> [String: ParameterValue] {
        [
            "inputFASTQ": .file(resolvedInputURL),
            "outputDirectory": .file(outputDirectory),
            "threads": .integer(threads),
            "qualityValueCutoff": .integer(request.qualityValueCutoff),
            "minimumClusterSize": .integer(request.minimumClusterSize),
            "minimumReadLength": request.minimumReadLength.map(ParameterValue.integer) ?? .null,
            "maximumReadLength": request.maximumReadLength.map(ParameterValue.integer) ?? .null,
            "singleStrand": .boolean(singleStrand),
            "condaEnvironment": .string(SavontClusteringRunRequest.condaEnvironment),
            "timeoutSeconds": .integer(Int(ManagedSavontProcessRunner.timeoutSeconds)),
        ]
    }

    private func requireSummary(_ summary: SavontClusterSummary?) throws -> SavontClusterSummary {
        guard let summary else {
            throw SavontClusteringError.processFailed(status: 1, stderr: "Savont produced no clustering summary.")
        }
        return summary
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func removeIfPresent(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // Best-effort cleanup must not replace the workflow or publication result.
        }
    }

}
