import Foundation
import LungfishCore
import LungfishIO

public struct PBAANextflowRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let rawOutputDirectory: URL
    public let argv: [String]

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        rawOutputDirectory: URL,
        argv: [String] = []
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.rawOutputDirectory = rawOutputDirectory
        self.argv = argv
    }
}

public struct PBAAClusteringResult: Sendable, Equatable {
    public let referenceBundleURL: URL
    public let rawOutputDirectory: URL
    public let passedConsensusFASTAURL: URL

    public init(referenceBundleURL: URL, rawOutputDirectory: URL, passedConsensusFASTAURL: URL) {
        self.referenceBundleURL = referenceBundleURL
        self.rawOutputDirectory = rawOutputDirectory
        self.passedConsensusFASTAURL = passedConsensusFASTAURL
    }
}

public enum PBAAClusteringError: Error, LocalizedError, Equatable {
    case nextflowUnavailable
    case nextflowFailed(status: Int32, stderr: String)
    case missingPassedConsensusFASTA(URL)
    case emptyPassedConsensusFASTA(URL)

    public var errorDescription: String? {
        switch self {
        case .nextflowUnavailable:
            return "Nextflow is not available. Install or provision Nextflow before running pbAA clustering."
        case .nextflowFailed(let status, let stderr):
            return "pbAA Nextflow workflow failed with exit status \(status): \(stderr)"
        case .missingPassedConsensusFASTA(let url):
            return "pbAA did not produce the passed cluster FASTA: \(url.lastPathComponent)"
        case .emptyPassedConsensusFASTA(let url):
            return "pbAA produced an empty passed cluster FASTA: \(url.lastPathComponent)"
        }
    }
}

public protocol PBAANextflowRunning: Sendable {
    func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult
}

public struct PBAAClusteringPipeline: Sendable {
    private let workflowWriter: PBAANextflowWorkflowWriter
    private let nextflowRunner: any PBAANextflowRunning
    private let referenceImporter: ReferenceBundleImportService

    public init(
        workflowWriter: PBAANextflowWorkflowWriter = PBAANextflowWorkflowWriter(),
        nextflowRunner: any PBAANextflowRunning = ProcessPBAANextflowRunner(),
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.workflowWriter = workflowWriter
        self.nextflowRunner = nextflowRunner
        self.referenceImporter = referenceImporter
    }

    public func run(_ request: PBAAClusteringRunRequest) async throws -> PBAAClusteringResult {
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let workflowDirectory = request.outputDirectory.appendingPathComponent("nextflow", isDirectory: true)
        _ = try workflowWriter.writeWorkflow(for: request, to: workflowDirectory)

        let rawOutputDirectory = request.rawPBAAOutputDirectory
        try FileManager.default.createDirectory(at: rawOutputDirectory, withIntermediateDirectories: true)

        let startedAt = Date()
        let runResult = try await nextflowRunner.run(request: request, workflowDirectory: workflowDirectory)
        let completedAt = Date()

        guard runResult.exitCode == 0 else {
            try writePBAAProvenance(
                request: request,
                runResult: runResult,
                referenceBundleURL: nil,
                workflowDirectory: workflowDirectory,
                startedAt: startedAt,
                completedAt: completedAt,
                workflowExitStatus: Int(runResult.exitCode),
                workflowStderr: runResult.stderr
            )
            throw PBAAClusteringError.nextflowFailed(status: runResult.exitCode, stderr: runResult.stderr)
        }

        let passedFASTA = runResult.rawOutputDirectory
            .appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
        guard FileManager.default.fileExists(atPath: passedFASTA.path) else {
            let error = PBAAClusteringError.missingPassedConsensusFASTA(passedFASTA)
            try writePBAAProvenance(
                request: request,
                runResult: runResult,
                referenceBundleURL: nil,
                workflowDirectory: workflowDirectory,
                startedAt: startedAt,
                completedAt: completedAt,
                workflowExitStatus: 1,
                workflowStderr: error.localizedDescription
            )
            throw error
        }
        let size = (try FileManager.default.attributesOfItem(atPath: passedFASTA.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else {
            let error = PBAAClusteringError.emptyPassedConsensusFASTA(passedFASTA)
            try writePBAAProvenance(
                request: request,
                runResult: runResult,
                referenceBundleURL: nil,
                workflowDirectory: workflowDirectory,
                startedAt: startedAt,
                completedAt: completedAt,
                workflowExitStatus: 1,
                workflowStderr: error.localizedDescription
            )
            throw error
        }

        let importResult = try await referenceImporter.importAsReferenceBundle(
            sourceURL: passedFASTA,
            outputDirectory: request.outputDirectory,
            preferredBundleName: request.outputName
        )
        do {
            try writePBAAProvenance(
                request: request,
                runResult: runResult,
                referenceBundleURL: importResult.bundleURL,
                workflowDirectory: workflowDirectory,
                startedAt: startedAt,
                completedAt: completedAt,
                workflowExitStatus: 0,
                workflowStderr: runResult.stderr
            )
        } catch {
            try? FileManager.default.removeItem(at: importResult.bundleURL)
            throw error
        }

        return PBAAClusteringResult(
            referenceBundleURL: importResult.bundleURL,
            rawOutputDirectory: runResult.rawOutputDirectory,
            passedConsensusFASTAURL: passedFASTA
        )
    }

    private func writePBAAProvenance(
        request: PBAAClusteringRunRequest,
        runResult: PBAANextflowRunResult,
        referenceBundleURL: URL?,
        workflowDirectory: URL,
        startedAt: Date,
        completedAt: Date,
        workflowExitStatus: Int,
        workflowStderr: String?
    ) throws {
        let argv = [
            CLICommandIdentity.executableName, "fastq", "pbaa-cluster",
            request.inputFASTQURL.path,
            "--guide", request.guideSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--threads", String(request.threads),
            "--seed", String(request.seed),
        ] + (request.extraArgumentsText.isEmpty ? [] : ["--extra-args", request.extraArgumentsText])

        let options = ProvenanceOptions(
            explicit: [
                "inputFASTQ": .file(request.inputFASTQURL),
                "inputFormat": .string(request.inputFormat.rawValue),
                "guide": .file(request.guideSourceURL),
                "outputDirectory": .file(request.outputDirectory),
                "outputName": .string(request.outputName),
                "prefix": .string(request.prefix),
                "threads": .integer(request.threads),
                "seed": .integer(request.seed),
                "extraArgs": .string(request.extraArgumentsText),
                "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
                "pbaaContainer": .string(request.containerPins.pbaa.reference),
                "pbaaContainerExpectedDigest": .string(request.containerPins.pbaa.expectedDigest),
                "pbaaContainerPinnedReference": .string(request.containerPins.pbaa.pinnedReference),
                "samtoolsContainer": .string(request.containerPins.samtools.reference),
                "samtoolsContainerExpectedDigest": .string(request.containerPins.samtools.expectedDigest),
                "samtoolsContainerPinnedReference": .string(request.containerPins.samtools.pinnedReference),
                "workflowSchemaVersion": .string(PBAAContainerPins.workflowSchemaVersion),
            ],
            defaults: [
                "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
                "seed": .integer(1984),
                "extraArguments": .array([]),
            ],
            resolvedDefaults: [
                "threads": .integer(request.threads),
                "seed": .integer(request.seed),
                "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
            ]
        )

        let readsFilename = request.inputFormat == .fasta ? "reads.fasta" : "reads.fastq"
        let inputFileFormat: FileFormat = request.inputFormat == .fasta ? .fasta : .fastq
        let pbaaStepArgv = [
            "pbaa", "cluster",
            "-j", String(request.threads),
            "--seed", String(request.seed),
        ] + request.extraArguments + ["guide.fasta", readsFilename, request.prefix]
        let nextflowArgv = runResult.argv.isEmpty
            ? ProcessPBAANextflowRunner.nextflowArguments(workflowDirectory: workflowDirectory)
            : runResult.argv
        let rawDirectoryDescriptor = ProvenanceFileDescriptor(path: runResult.rawOutputDirectory.path, role: .output)
        let rawOutputDescriptors = try rawPBAAOutputDescriptors(in: runResult.rawOutputDirectory)
        let bundleDescriptor = referenceBundleURL.map { ProvenanceFileDescriptor(path: $0.path, role: .output) }
        let outputDescriptors = try referenceBundleURL.map { try finalBundleOutputDescriptors(bundleURL: $0) } ?? []
        let finalBundleOutputs = [bundleDescriptor].compactMap { $0 } + outputDescriptors
        let stepOutputs = finalBundleOutputs + [rawDirectoryDescriptor] + rawOutputDescriptors
        let normalizedWorkflowStderr = workflowStderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil
            : workflowStderr

        let envelope = try ProvenanceRunBuilder(
            workflowName: "pbAA Amplicon Clustering",
            workflowVersion: PBAAContainerPins.workflowSchemaVersion,
            toolName: "pbaa",
            toolVersion: request.containerPins.pbaa.toolVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(argv.map(shellEscape).joined(separator: " "))
        .options(explicit: options.explicit, defaults: options.defaults, resolved: options.resolvedDefaults)
        .input(request.inputFASTQURL, format: inputFileFormat, role: .input)
        .input(request.guideSourceURL, format: .fasta, role: .input)
        .runtime(ProvenanceRuntimeIdentity(
            containerImage: request.containerPins.pbaa.reference,
            containerDigest: request.containerPins.pbaa.expectedDigest
        ))
        .step(ProvenanceStep(
            toolName: "nextflow",
            toolVersion: "unknown",
            argv: nextflowArgv,
            inputs: [
                try ProvenanceFileDescriptor.file(url: request.inputFASTQURL, format: inputFileFormat, role: .input),
                try ProvenanceFileDescriptor.file(url: request.guideSourceURL, format: .fasta, role: .input),
                try ProvenanceFileDescriptor.file(
                    url: workflowDirectory.appendingPathComponent("main.nf"),
                    format: .text,
                    role: .input
                ),
                try ProvenanceFileDescriptor.file(
                    url: workflowDirectory.appendingPathComponent("nextflow.config"),
                    format: .text,
                    role: .input
                ),
                try ProvenanceFileDescriptor.file(
                    url: workflowDirectory.appendingPathComponent("params.json"),
                    format: .json,
                    role: .input
                ),
            ],
            outputs: [rawDirectoryDescriptor] + rawOutputDescriptors,
            exitStatus: Int(runResult.exitCode),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: runResult.stderr.isEmpty ? nil : runResult.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        .step(ProvenanceStep(
            toolName: "pbaa",
            toolVersion: request.containerPins.pbaa.toolVersion,
            argv: pbaaStepArgv,
            inputs: [
                try ProvenanceFileDescriptor.file(url: request.inputFASTQURL, format: inputFileFormat, role: .input),
                try ProvenanceFileDescriptor.file(url: request.guideSourceURL, format: .fasta, role: .input),
            ],
            outputs: stepOutputs,
            exitStatus: Int(runResult.exitCode),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: runResult.stderr.isEmpty ? nil : runResult.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        .complete(
            exitStatus: workflowExitStatus,
            stderr: normalizedWorkflowStderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        let writer = ProvenanceWriter(signingProvider: nil)
        try writer.write(envelope, to: runResult.rawOutputDirectory)
        if let referenceBundleURL {
            try writer.write(envelope, to: referenceBundleURL)
        }
    }

    private func rawPBAAOutputDescriptors(in directory: URL) throws -> [ProvenanceFileDescriptor] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var descriptors: [ProvenanceFileDescriptor] = []
        for case let url as URL in enumerator {
            let descriptorURL = canonicalRawOutputURL(for: url, rootedAt: directory)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !descriptorURL.lastPathComponent.hasSuffix(".lungfish-provenance.json") else {
                continue
            }
            descriptors.append(try ProvenanceFileDescriptor.file(
                url: descriptorURL,
                format: rawOutputFormat(for: descriptorURL),
                role: rawOutputRole(for: descriptorURL)
            ))
        }
        return descriptors.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func canonicalRawOutputURL(for url: URL, rootedAt directory: URL) -> URL {
        let resolvedRootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedRootPath = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(normalizedRootPath) else {
            return url.standardizedFileURL
        }

        let relativePath = String(resolvedPath.dropFirst(normalizedRootPath.count))
        guard !relativePath.isEmpty else {
            return directory.standardizedFileURL
        }
        return directory.standardizedFileURL.appendingPathComponent(relativePath)
    }

    private func rawOutputFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "fa", "fasta", "fna", "fas":
            return .fasta
        case "fq", "fastq":
            return .fastq
        case "bam":
            return .bam
        case "sam":
            return .sam
        case "json":
            return .json
        case "txt", "tsv", "csv", "log", "fai", "bai", "pbi":
            return .text
        default:
            if filename.hasSuffix(".fastq.gz") || filename.hasSuffix(".fq.gz") {
                return .fastq
            }
            if filename.hasSuffix(".fasta.gz") || filename.hasSuffix(".fa.gz") {
                return .fasta
            }
            return .unknown
        }
    }

    private func rawOutputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "bai", "pbi", "csi":
            return .index
        case "log":
            return .log
        default:
            return .output
        }
    }

    private func finalBundleOutputDescriptors(bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        let manifest = try BundleManifest.load(from: bundleURL)
        var descriptors = [
            try ProvenanceFileDescriptor.file(
                url: bundleURL.appendingPathComponent(BundleManifest.filename),
                format: .json,
                role: .output
            ),
        ]

        if let genome = manifest.genome {
            descriptors.append(
                try ProvenanceFileDescriptor.file(
                    url: try BundleManifest.validatedBundleMemberURL(
                        for: genome.path,
                        in: bundleURL,
                        field: "genome.path"
                    ),
                    format: .fasta,
                    role: .output
                )
            )
            descriptors.append(
                try ProvenanceFileDescriptor.file(
                    url: try BundleManifest.validatedBundleMemberURL(
                        for: genome.indexPath,
                        in: bundleURL,
                        field: "genome.indexPath"
                    ),
                    format: .text,
                    role: .index
                )
            )
            if let gzipIndexPath = genome.gzipIndexPath {
                descriptors.append(
                    try ProvenanceFileDescriptor.file(
                        url: try BundleManifest.validatedBundleMemberURL(
                            for: gzipIndexPath,
                            in: bundleURL,
                            field: "genome.gzipIndexPath"
                        ),
                        format: .unknown,
                        role: .index
                    )
                )
            }
        }
        return descriptors
    }
}

public struct ProcessPBAANextflowRunner: PBAANextflowRunning {
    private let condaManager: CondaManager
    private let homeDirectoryProvider: @Sendable () -> URL
    private let appIdentity: LungfishAppIdentity

    public init(
        condaManager: CondaManager = .shared,
        homeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        },
        appIdentity: LungfishAppIdentity = .current
    ) {
        self.condaManager = condaManager
        self.homeDirectoryProvider = homeDirectoryProvider
        self.appIdentity = appIdentity
    }

    public func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult {
        guard let nextflowExecutableURL = try await nextflowExecutableURL() else {
            throw PBAAClusteringError.nextflowUnavailable
        }

        let launchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-pbaa-nextflow-\(UUID().uuidString)", isDirectory: true)
        let workDirectory = launchDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: launchDirectory) }

        let arguments = Self.nextflowArguments(
            workflowDirectory: workflowDirectory,
            workDirectory: workDirectory
        )
        let processArguments = Array(arguments.dropFirst())
        let result = try await runProcess(
            executableURL: nextflowExecutableURL,
            arguments: processArguments,
            workingDirectory: launchDirectory,
            environment: nextflowExecutionEnvironment(for: nextflowExecutableURL)
        )
        let copiedLogURL = try? copyNextflowLog(from: launchDirectory, to: workflowDirectory)
        let stderr = Self.stderrWithLogDiagnostics(
            stderr: result.stderr,
            copiedLogURL: copiedLogURL,
            exitCode: result.exitCode
        )
        return PBAANextflowRunResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: stderr,
            rawOutputDirectory: request.rawPBAAOutputDirectory,
            argv: [nextflowExecutableURL.path] + processArguments
        )
    }

    static func nextflowArguments(workflowDirectory: URL) -> [String] {
        nextflowArguments(
            workflowDirectory: workflowDirectory,
            workDirectory: workflowDirectory.appendingPathComponent("work", isDirectory: true)
        )
    }

    static func nextflowArguments(workflowDirectory: URL, workDirectory: URL) -> [String] {
        [
            "nextflow", "run", workflowDirectory.appendingPathComponent("main.nf").path,
            "-c", workflowDirectory.appendingPathComponent("nextflow.config").path,
            "-params-file", workflowDirectory.appendingPathComponent("params.json").path,
            "-work-dir", workDirectory.path,
            "-with-trace", workflowDirectory.appendingPathComponent("trace.txt").path,
        ]
    }

    private func copyNextflowLog(from launchDirectory: URL, to workflowDirectory: URL) throws -> URL? {
        let source = launchDirectory.appendingPathComponent(".nextflow.log")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = workflowDirectory.appendingPathComponent(".nextflow.log")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private static func stderrWithLogDiagnostics(stderr: String, copiedLogURL: URL?, exitCode: Int32) -> String {
        guard exitCode != 0 else { return stderr }
        guard let copiedLogURL else { return stderr }
        let logTail = nextflowLogTail(at: copiedLogURL)
        guard !logTail.isEmpty else { return stderr }
        if stderr.contains(logTail) { return stderr }
        let separator = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        return "\(stderr)\(separator)Nextflow log tail (\(copiedLogURL.path)):\n\(logTail)"
    }

    private static func nextflowLogTail(at url: URL, maxLines: Int = 80) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func nextflowExecutableURL() async throws -> URL? {
        let managed = CoreToolLocator.executableURL(
            environment: "nextflow",
            executableName: "nextflow",
            homeDirectory: homeDirectoryProvider()
        )
        if FileManager.default.isExecutableFile(atPath: managed.path) {
            await condaManager.repairManagedLaunchers(environment: "nextflow")
            return managed
        }

        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", "nextflow"],
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )
        guard result.exitCode == 0,
              let path = result.stdout
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func nextflowExecutionEnvironment(for executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = homeDirectoryProvider()
        let condaRoot = CoreToolLocator.condaRoot(homeDirectory: home)
        let condaBin = condaRoot.appendingPathComponent("bin", isDirectory: true)
        let existingPaths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        var mergedPaths: [String] = []
        let toolPaths = [
            executableURL.deletingLastPathComponent().path,
            condaBin.path,
            "/usr/local/bin",
        ]
        for path in toolPaths + existingPaths
            where !mergedPaths.contains(path) {
            mergedPaths.append(path)
        }
        environment["PATH"] = mergedPaths.joined(separator: ":")
        environment["HOME"] = home.path
        environment["MAMBA_ROOT_PREFIX"] = condaRoot.path
        environment["NXF_HOME"] = appIdentity.nextflowHomeURL(homeDirectory: home).path
        return environment
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> PBAAProcessResult {
        let cancellationHandle = NativeProcessCancellationHandle()
        let runState = NativeProcessRunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdoutBox = PBAADataBox()
                let stderrBox = PBAADataBox()
                let group = DispatchGroup()
                let startOutputDrain: @Sendable () -> Void = {
                    group.enter()
                    DispatchQueue.global().async {
                        stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                cancellationHandle.store(process)

                process.terminationHandler = { terminatedProcess in
                    group.notify(queue: .global(qos: .userInitiated)) {
                        cancellationHandle.clear(terminatedProcess)
                        runState.resumeOnce { reason in
                            switch reason {
                            case .cancelled:
                                continuation.resume(throwing: CancellationError())
                            case .timedOut:
                                continuation.resume(throwing: CancellationError())
                            case .completed:
                                continuation.resume(returning: PBAAProcessResult(
                                    exitCode: terminatedProcess.terminationStatus,
                                    stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
                                    stderr: String(data: stderrBox.value, encoding: .utf8) ?? ""
                                ))
                            }
                        }
                    }
                }

                do {
                    startOutputDrain()
                    try process.run()
                    cancellationHandle.terminateIfRequested()
                    if runState.isCancelled {
                        cancellationHandle.requestProcessTreeTermination()
                    }
                } catch {
                    cancellationHandle.clear(process)
                    stdoutPipe.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()
                    runState.resumeOnce { reason in
                        switch reason {
                        case .cancelled, .timedOut:
                            continuation.resume(throwing: CancellationError())
                        case .completed:
                            continuation.resume(throwing: PBAAClusteringError.nextflowUnavailable)
                        }
                    }
                }
            }
        } onCancel: {
            runState.markCancelled()
            cancellationHandle.requestProcessTreeTermination()
        }
    }
}

private final class PBAADataBox: @unchecked Sendable {
    var value = Data()
}

private struct PBAAProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
