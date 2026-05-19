import Foundation
import LungfishCore

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
            throw PBAAClusteringError.nextflowFailed(status: runResult.exitCode, stderr: runResult.stderr)
        }

        let passedFASTA = runResult.rawOutputDirectory
            .appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
        guard FileManager.default.fileExists(atPath: passedFASTA.path) else {
            throw PBAAClusteringError.missingPassedConsensusFASTA(passedFASTA)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: passedFASTA.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else {
            throw PBAAClusteringError.emptyPassedConsensusFASTA(passedFASTA)
        }

        let importResult = try await referenceImporter.importAsReferenceBundle(
            sourceURL: passedFASTA,
            outputDirectory: request.outputDirectory,
            preferredBundleName: request.outputName
        )
        try writePBAAProvenance(
            request: request,
            runResult: runResult,
            referenceBundleURL: importResult.bundleURL,
            passedFASTA: passedFASTA,
            workflowDirectory: workflowDirectory,
            startedAt: startedAt,
            completedAt: completedAt
        )

        return PBAAClusteringResult(
            referenceBundleURL: importResult.bundleURL,
            rawOutputDirectory: runResult.rawOutputDirectory,
            passedConsensusFASTAURL: passedFASTA
        )
    }

    private func writePBAAProvenance(
        request: PBAAClusteringRunRequest,
        runResult: PBAANextflowRunResult,
        referenceBundleURL: URL,
        passedFASTA: URL,
        workflowDirectory: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv = [
            "lungfish", "fastq", "pbaa-cluster",
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

        let pbaaStepArgv = [
            "pbaa", "cluster",
            "-j", String(request.threads),
            "--seed", String(request.seed),
        ] + request.extraArguments + ["guide.fasta", "reads.fastq", request.prefix]
        let nextflowArgv = runResult.argv.isEmpty
            ? ProcessPBAANextflowRunner.nextflowArguments(workflowDirectory: workflowDirectory)
            : runResult.argv
        let bundleDescriptor = ProvenanceFileDescriptor(path: referenceBundleURL.path, role: .output)
        let outputDescriptors = try finalBundleOutputDescriptors(bundleURL: referenceBundleURL)
        let passedDescriptor = try ProvenanceFileDescriptor.file(url: passedFASTA, format: .fasta, role: .output)
        let stepOutputs = [bundleDescriptor] + outputDescriptors + [passedDescriptor]

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
        .input(request.inputFASTQURL, format: .fastq, role: .input)
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
                try ProvenanceFileDescriptor.file(url: request.inputFASTQURL, format: .fastq, role: .input),
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
            outputs: [passedDescriptor],
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
                try ProvenanceFileDescriptor.file(url: request.inputFASTQURL, format: .fastq, role: .input),
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
            exitStatus: Int(runResult.exitCode),
            stderr: runResult.stderr.isEmpty ? nil : runResult.stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: referenceBundleURL)
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
                    url: bundleURL.appendingPathComponent(genome.path),
                    format: .fasta,
                    role: .output
                )
            )
            descriptors.append(
                try ProvenanceFileDescriptor.file(
                    url: bundleURL.appendingPathComponent(genome.indexPath),
                    format: .text,
                    role: .index
                )
            )
            if let gzipIndexPath = genome.gzipIndexPath {
                descriptors.append(
                    try ProvenanceFileDescriptor.file(
                        url: bundleURL.appendingPathComponent(gzipIndexPath),
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
    public init() {}

    public func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult {
        guard try await nextflowIsAvailable() else {
            throw PBAAClusteringError.nextflowUnavailable
        }

        let arguments = Self.nextflowArguments(workflowDirectory: workflowDirectory)
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments,
            workingDirectory: workflowDirectory
        )
        return PBAANextflowRunResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            rawOutputDirectory: request.rawPBAAOutputDirectory,
            argv: ["/usr/bin/env"] + arguments
        )
    }

    static func nextflowArguments(workflowDirectory: URL) -> [String] {
        [
            "nextflow", "run", "main.nf",
            "-c", "nextflow.config",
            "-params-file", "params.json",
            "-work-dir", workflowDirectory.appendingPathComponent("work", isDirectory: true).path,
            "-with-trace", workflowDirectory.appendingPathComponent("trace.txt").path,
        ]
    }

    private func nextflowIsAvailable() async throws -> Bool {
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", "nextflow"],
            workingDirectory: nil
        )
        return result.exitCode == 0
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?
    ) async throws -> PBAAProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PBAAClusteringError.nextflowUnavailable)
                return
            }

            let stdoutBox = PBAADataBox()
            let stderrBox = PBAADataBox()
            let group = DispatchGroup()

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

            process.waitUntilExit()
            group.wait()

            continuation.resume(returning: PBAAProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutBox.value, encoding: .utf8) ?? "",
                stderr: String(data: stderrBox.value, encoding: .utf8) ?? ""
            ))
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
