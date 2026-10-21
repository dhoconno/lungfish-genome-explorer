// RunSubcommand.swift - Execute a workflow
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Run Subcommand

/// Execute a workflow
struct RunSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a workflow pipeline",
        discussion: """
            Run a Nextflow or Snakemake workflow with the specified parameters.
            Containerised steps run through Docker Desktop (-profile docker);
            `lungfish-cli debug container` reports whether the daemon is reachable.
            The only built-in nf-core workflow supported by this command is
            nf-core/viralrecon, also accepted as viralrecon.

            Examples:
              lungfish-cli workflow run pipeline.nf --param reads=data/*.fastq.gz
              lungfish-cli workflow run Snakefile --cpus 8 --memory 16.GB
              lungfish-cli workflow run nf-core/viralrecon --input samplesheet.csv --param platform=illumina
            """
    )

    /// The runner of a local workflow's engine. A test binds its own for one run with
    /// `$localWorkflowProcessRunner.withValue`, so nothing can assign it (SWIFT 1).
    @TaskLocal static var localWorkflowProcessRunner: any LocalWorkflowProcessRunning = ProcessLocalWorkflowProcessRunner()
    nonisolated(unsafe) static var localWorkflowDirectoryReserver: @Sendable (URL) throws -> Void = {
        try LocalWorkflowReplayReservation.reserveDirectory(at: $0)
    }
    /// The runner of the managed Nextflow for nf-core/viralrecon. A test binds its own for one run with
    /// `$nfCoreWorkflowProcessRunner.withValue`, so nothing can assign it (SWIFT 1).
    @TaskLocal static var nfCoreWorkflowProcessRunner: any NFCoreWorkflowProcessRunning = ProcessNFCoreWorkflowProcessRunner()

    @Argument(help: "Workflow file (*.nf, Snakefile) or supported nf-core workflow: nf-core/viralrecon")
    var workflow: String

    @Option(name: .customLong("repeat-from"), help: "Validate an original local run bundle before starting a fresh attempt")
    var repeatFrom: String?

    @Option(
        name: .customLong("results-dir"),
        help: "Output directory for results"
    )
    var resultsDir: String = "./results"

    @Option(
        name: .customLong("executor"),
        help: "Execution profile for nf-core workflows: docker, conda, or local"
    )
    var executor: NFCoreExecutor = .docker

    @Option(
        name: .customLong("input"),
        parsing: .singleValue,
        help: ArgumentHelp(
            "Input file selected for the workflow; repeat for multiple inputs",
            discussion: "For nf-core/viralrecon, give one samplesheet.csv, or one or more .lungfishfastq bundles or FASTQ files, from which the same samplesheet the app writes is built. An Illumina samplesheet row may name a .lungfishfastq bundle, which the run plans and stages as gzip files, so a paired, merged, repaired or virtual bundle gives every read. A strictly interleaved Illumina file is split into gzip R1/R2 inside the run so viralrecon gets fastq_1 and fastq_2. A sample that mixes merged reads with pairs runs single-end with every read and a warning."
        )
    )
    var input: [String] = []

    @Option(
        name: .customLong("expected-output"),
        parsing: .singleValue,
        help: "Final output bundle or file path; required for executed runs and repeatable for every scientific output that must receive provenance"
    )
    var expectedOutput: [String] = []

    @Option(
        name: .customLong("bundle-root"),
        help: "Directory where the .lungfishrun bundle should be created"
    )
    var bundleRoot: String?

    @Option(
        name: .customLong("bundle-path"),
        help: "Exact .lungfishrun bundle path to create or update"
    )
    var bundlePath: String?

    @Option(
        name: .customLong("version"),
        help: "nf-core workflow version or tag"
    )
    var version: String = ""

    @Option(
        name: [.customLong("workdir"), .customShort("w")],
        help: "Working directory for execution"
    )
    var workDir: String?

    @Option(
        name: .customLong("param"),
        parsing: .singleValue,
        help: "Workflow parameter (key=value, can be repeated)"
    )
    var params: [String] = []

    @Option(
        name: .customLong("params-file"),
        help: "Parameters from JSON/YAML file"
    )
    var paramsFile: String?

    @Option(
        name: .customLong("cpus"),
        help: "Maximum CPUs per process"
    )
    var cpus: Int?

    @Option(
        name: .customLong("memory"),
        help: "Maximum memory per process (e.g., 8.GB)"
    )
    var memory: String?

    @Flag(
        name: .customLong("resume"),
        help: "Resume from last checkpoint"
    )
    var resume: Bool = false

    @Flag(
        name: .customLong("dry-run"),
        help: "Validate workflow without executing"
    )
    var dryRun: Bool = false

    @Flag(
        name: .customLong("prepare-only"),
        help: "Create the Lungfish run bundle and command preview without launching Nextflow"
    )
    var prepareOnly: Bool = false

    @Option(
        name: .customLong("timeout"),
        help: ArgumentHelp(
            "Maximum execution time in minutes. Not supported yet: refused for nf-core/viralrecon (exit status 3) and not enforced for a local workflow.",
            discussion: "Use the CI service's own limit, or the shell's `timeout`, to bound a run for now."
        )
    )
    var timeout: Int?

    /// Printed when `--timeout` is given for an nf-core run (exit status 3).
    static let timeoutUnsupportedForViralRecon =
        "--timeout is not supported for nf-core/viralrecon runs yet; bound the run with the CI service's limit or the shell's `timeout` instead."

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        // The app reads stdout from a pipe and logs each line to the
        // Operations Panel as it arrives. On a pipe print holds lines in a
        // block buffer until the command exits, so a read-pairing split that
        // takes minutes showed nothing until the end. Line buffering writes
        // each line as it is printed. Only this command sets it, because
        // other commands write bulk data to stdout.
        setvbuf(stdout, nil, _IOLBF, 0)
        let output = WorkflowRunOutput(
            formatter: TerminalFormatter(useColors: globalOptions.useColors),
            quiet: globalOptions.quiet,
            eventsOn: globalOptions.outputFormat == .json
        )
        // Under --format json the first line is `start` and the last `complete` or `failed` (ARCH's ruling on A30 M3).
        // The start has no words, because the bridge shows a start message as the row's detail for the whole run.
        // The words come next, as an info event (A30 M3 review, fix 3).
        output.events?.emitStart("")
        output.events?.emitLog(.info, "Preparing workflow: \(workflow)")
        do {
            try await execute(output: output)
        } catch {
            output.failed(error)
            throw error
        }
    }

    private func execute(output: WorkflowRunOutput) async throws {
        let formatter = output.formatter
        if repeatFrom != nil, workflow.contains("nf-core") || Self.normalizedViralReconWorkflowName(workflow) != nil {
            throw CLIError.workflowFailed(reason: "--repeat-from supports identified local workflow packages only.")
        }

        if output.events == nil, !globalOptions.quiet {
            print(formatter.info("Preparing workflow: \(workflow)"))
        }

        // Parse parameters
        var workflowParams: [String: String] = [:]
        for param in params {
            let parts = param.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw CLIError.workflowFailed(reason: "Invalid parameter format: \(param). Expected key=value")
            }
            workflowParams[String(parts[0])] = String(parts[1])
        }

        // Load params file if provided
        if let paramsFilePath = paramsFile {
            guard FileManager.default.fileExists(atPath: paramsFilePath) else {
                throw CLIError.inputFileNotFound(path: paramsFilePath)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: paramsFilePath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in json {
                    workflowParams[key] = String(describing: value)
                }
            }
        }

        let isViralReconWorkflow = Self.normalizedViralReconWorkflowName(workflow) != nil
        if workflow.contains("nf-core") || isViralReconWorkflow {
            _ = try validateViralReconWorkflowName()
            if timeout != nil {
                // A refused option is an input error (documented exit status
                // 3), not a failed workflow (64); the help text says so.
                throw CLIError.validationFailed(errors: [Self.timeoutUnsupportedForViralRecon])
            }
            // A results folder an earlier run used is an input error too (Phase 2.13 lane 13.21, UX words W1).
            try requireUnusedViralReconResultsFolder()
            if let cpus {
                workflowParams["max_cpus"] = String(cpus)
            }
            if let memory {
                workflowParams["max_memory"] = memory
            }
        }

        if dryRun {
            var lines = ["  Workflow: \(workflow)", "  Results: \(resultsDir)", "  Executor: \(executor.rawValue)"]
            if !input.isEmpty {
                lines.append("  Inputs: \(input.joined(separator: ", "))")
            }
            lines.append("  Parameters: \(workflowParams.count)")
            lines += workflowParams.sorted(by: { $0.key < $1.key }).map { "    \($0.key) = \($0.value)" }
            if let events = output.events {
                // A dry run writes nothing, so it completes with no output.
                for line in ["Dry run - workflow would execute with:"] + lines { events.emitLog(.info, line) }
                events.emitComplete(outputs: [])
            } else {
                print(formatter.info("Dry run - workflow would execute with:"))
                lines.forEach { print($0) }
            }
            return
        }

        // Determine workflow type
        let workflowURL = URL(fileURLWithPath: workflow)
        let isNextflow = workflowURL.pathExtension == "nf" || workflow.contains("nf-core") || isViralReconWorkflow
        let isSnakemake = workflowURL.lastPathComponent.lowercased().contains("snakefile")

        // SIGTERM (the window's Cancel) cancels the run. See the extension.
        try await launchCancellingOnSIGTERM(
            workflowParams: workflowParams,
            isViralRecon: isViralReconWorkflow,
            isNextflow: isNextflow,
            isSnakemake: isSnakemake,
            output: output
        )
    }

    func runLocalWorkflow(
        workflowParams: [String: String],
        isNextflow: Bool,
        isSnakemake: Bool,
        output: WorkflowRunOutput
    ) async throws {
        guard isNextflow || isSnakemake else {
            throw CLIError.unsupportedFormat(format: "Unknown workflow format")
        }

        let workflowURL = URL(fileURLWithPath: workflow).standardizedFileURL
        guard FileManager.default.fileExists(atPath: workflowURL.path) else {
            throw CLIError.inputFileNotFound(path: workflowURL.path)
        }

        let inputURLs = input.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            throw CLIError.inputFileNotFound(path: inputURL.path)
        }
        try requireExpectedOutputsForExecution()
        let expectedOutputURLs = expectedOutput.map { URL(fileURLWithPath: $0).standardizedFileURL }

        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            engine: isNextflow ? .nextflow : .snakemake,
            inputURLs: inputURLs,
            outputDirectory: URL(fileURLWithPath: resultsDir),
            expectedOutputURLs: expectedOutputURLs,
            params: workflowParams,
            resume: resume,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) },
            cpus: cpus,
            memory: memory,
            replaySourceBundleURL: repeatFrom.map { URL(fileURLWithPath: $0) }
        )
        // A repeat retains its original snapshot; recapture is validation, never a new baseline.
        let sourceConfiguration = try request.replaySourceBundleURL.map { try LocalWorkflowReplayPreflight.load(from: $0) }
        let runBundleURL: URL
        if let sourceConfiguration, let sourceURL = request.replaySourceBundleURL {
            runBundleURL = try resolveRunBundleURL(workflowName: request.workflowName)
            try LocalWorkflowReplayPreflight.validate(request: request, configuration: sourceConfiguration,
                sourceBundleURL: sourceURL,
                runtimeURL: Self.localWorkflowProcessRunner.runtimeExecutableURL(named: request.engine.executableName),
                runBundleURL: runBundleURL)
        } else {
            runBundleURL = try resolveRunBundleURL(workflowName: request.workflowName)
        }
        // Unsupported raw scripts keep ordinary execution, with no claimed package replay identity.
        let replayIdentity = sourceConfiguration?.identity ?? (try? LocalWorkflowReplayIdentity.capture(for: request))
        try Task.checkCancellation()
        let capturedInputs = [ProvenanceRecorder.fileRecord(url: request.workflowURL, format: .text, role: .input)]
            + request.inputURLs.map { ProvenanceRecorder.fileOrDirectoryRecord(url: $0, role: .input) }
        let inputBindings = capturedInputs.dropFirst().map { LocalWorkflowInputBinding(record: $0) }
        try replayIdentity?.validateCurrentInputs(for: request)
        if request.replaySourceBundleURL != nil {
            try FileManager.default.createDirectory(at: runBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.localWorkflowDirectoryReserver(runBundleURL)
        }
        let bundleClock = ProvenanceRunClock()
        let preparedEvent = LocalWorkflowRunStatusEvent(status: .prepared, timestamp: bundleClock.startedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleClock.startedAt,
                replayIdentity: replayIdentity,
                inputBindings: inputBindings,
                executionStatus: .prepared,
                statusHistory: [preparedEvent]
            ),
            to: runBundleURL
        )

        output.info("Created run bundle: \(runBundleURL.path)")
        output.info(request.commandPreview)
        if prepareOnly {
            try writeLocalRunBundleProvenance(
                request: request,
                capturedInputs: capturedInputs,
                bundleURL: runBundleURL,
                prepareOnly: true,
                status: .completed,
                exitCode: 0,
                wallTime: bundleClock.elapsed,
                stderr: nil
            )
            output.complete([runBundleURL])
            return
        }

        let processClock = ProvenanceRunClock()
        let runningEvent = LocalWorkflowRunStatusEvent(status: .running, timestamp: processClock.startedAt)
        var statusHistory = [preparedEvent]
        var ownsOutputDirectory = request.replaySourceBundleURL == nil
        let launch = request.processLaunch
        let processResult: LocalWorkflowProcessResult
        do {
            if request.replaySourceBundleURL != nil {
                try Self.localWorkflowDirectoryReserver(request.outputDirectory)
                ownsOutputDirectory = true
            }
            statusHistory.append(runningEvent)
            try LocalWorkflowRunBundleStore.write(request.manifest(createdAt: bundleClock.startedAt,
                replayIdentity: replayIdentity, inputBindings: inputBindings, executionStatus: .running,
                statusHistory: statusHistory, startedAt: processClock.startedAt), to: runBundleURL)
            processResult = try await Self.localWorkflowProcessRunner.runWorkflow(
                executableName: launch.executableName,
                arguments: launch.arguments,
                workingDirectory: launch.workingDirectory
            )
        } catch {
            let cancelled = error is CancellationError
            let endedAt = processClock.now
            let terminalStatus: NFCoreRunExecutionStatus = cancelled ? .cancelled : .failed
            let message = cancelled ? "Workflow launch was cancelled before an exit status was returned." : error.localizedDescription
            let stderrLogURL = runBundleURL.appendingPathComponent("logs/stderr.log")
            try PortablePath.sanitize(text: message, forFileAt: stderrLogURL).write(to: stderrLogURL, atomically: true, encoding: .utf8)
            try LocalWorkflowRunBundleStore.write(request.manifest(createdAt: bundleClock.startedAt,
                replayIdentity: replayIdentity, inputBindings: inputBindings, executionStatus: terminalStatus,
                statusHistory: statusHistory + [.init(status: terminalStatus, timestamp: endedAt)],
                startedAt: processClock.startedAt, completedAt: endedAt, exitCode: nil), to: runBundleURL)
            try writeLocalRunBundleProvenance(request: request, capturedInputs: capturedInputs,
                includeResultOutputs: ownsOutputDirectory, bundleURL: runBundleURL, prepareOnly: false, status: cancelled ? .cancelled : .failed,
                exitCode: nil, wallTime: endedAt.timeIntervalSince(processClock.startedAt), stderr: message)
            throw error
        }
        try writeLocalProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
        let processCompletedAt = processClock.now
        let executionStatus: NFCoreRunExecutionStatus = processResult.exitCode == 0 ? .completed : .failed
        let completedEvent = LocalWorkflowRunStatusEvent(status: executionStatus, timestamp: processCompletedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleClock.startedAt,
                replayIdentity: replayIdentity,
                inputBindings: inputBindings,
                executionStatus: executionStatus,
                statusHistory: [preparedEvent, runningEvent, completedEvent],
                startedAt: processClock.startedAt,
                completedAt: processCompletedAt,
                exitCode: processResult.exitCode,
                stdoutLogPath: "logs/stdout.log",
                stderrLogPath: "logs/stderr.log"
            ),
            to: runBundleURL
        )
        try writeLocalRunBundleProvenance(
            request: request,
            capturedInputs: capturedInputs,
            runtimeEvidence: processResult.runtimeEvidence,
            bundleURL: runBundleURL,
            prepareOnly: false,
            status: processResult.exitCode == 0 ? .completed : .failed,
            exitCode: processResult.exitCode,
            wallTime: processCompletedAt.timeIntervalSince(processClock.startedAt),
            stderr: processResult.standardError
        )
        if processResult.exitCode != 0 {
            throw CLIError.workflowFailed(
                reason: Self.engineFailureReason(
                    engineName: request.engine.displayName,
                    exitCode: processResult.exitCode,
                    stderr: processResult.standardError,
                    runBundleURL: runBundleURL
                )
            )
        }
        output.complete([runBundleURL, request.outputDirectory])
    }

    func requireExpectedOutputsForExecution() throws {
        guard !prepareOnly, expectedOutput.isEmpty else { return }
        throw CLIError.workflowFailed(
            reason: "workflow run executions require at least one --expected-output so every final scientific output receives focused provenance. Use --prepare-only or --dry-run for planning-only runs."
        )
    }

    func validateViralReconWorkflowName() throws -> String {
        guard let normalized = Self.normalizedViralReconWorkflowName(workflow) else {
            throw CLIError.workflowFailed(reason: "Unsupported nf-core workflow: \(workflow). Only nf-core/viralrecon is supported.")
        }
        return normalized
    }

    private static func normalizedViralReconWorkflowName(_ workflow: String) -> String? {
        switch workflow.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "viralrecon", "nf-core/viralrecon":
            return "viralrecon"
        default:
            return nil
        }
    }

    func resolveRunBundleURL(workflowName: String) throws -> URL {
        if let bundlePath {
            return URL(fileURLWithPath: bundlePath).standardizedFileURL
        }
        let root = URL(fileURLWithPath: bundleRoot ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        if repeatFrom == nil { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let base = root.appendingPathComponent("\(workflowName).\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        for index in 2...999 {
            let candidate = root.appendingPathComponent("\(workflowName)-\(index).\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw CLIError.outputWriteFailed(path: base.path, reason: "Could not allocate a unique run bundle path")
    }

    /// Engine output kept in a run bundle names project files project-relatively
    /// and never the account's home, the tool root or scratch directories.
    static func writePortableLog(_ text: String, to url: URL) throws {
        try PortablePath.sanitize(text: text, forFileAt: url).write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeLocalProcessLogs(_ result: LocalWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try Self.writePortableLog(result.standardOutput, to: logsURL.appendingPathComponent("stdout.log"))
        try Self.writePortableLog(result.standardError, to: logsURL.appendingPathComponent("stderr.log"))
    }

    private func writeLocalRunBundleProvenance(
        request: LocalWorkflowRunRequest,
        capturedInputs: [FileRecord],
        runtimeEvidence: LocalWorkflowRuntimeEvidence? = nil,
        includeResultOutputs: Bool = true,
        bundleURL: URL,
        prepareOnly: Bool,
        status: RunStatus,
        exitCode: Int32?,
        wallTime: TimeInterval,
        stderr: String?
    ) throws {
        let command = [CLICommandIdentity.executableName] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = capturedInputs
        let outputs = [
            ProvenanceRecorder.fileOrDirectoryRecord(url: bundleURL, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            ),
        ] + (includeResultOutputs ? [ProvenanceRecorder.fileOrDirectoryRecord(url: request.outputDirectory, role: .output)]
            + expectedOutputRecords(for: request.expectedOutputURLs) : [])
        var parameters = request.effectiveParams.mapValues { ParameterValue.string($0) }
        parameters["engine"] = .string(request.engine.rawValue)
        parameters["workflowPath"] = .file(request.workflowURL)
        parameters["resume"] = .boolean(request.resume)
        parameters["prepareOnly"] = .boolean(prepareOnly)
        if let workDirectory = request.workDirectory {
            parameters["workDirectory"] = .file(workDirectory)
        }
        if let cpus = request.cpus {
            parameters["cpus"] = .integer(cpus)
        }
        if let memory = request.memory {
            parameters["memory"] = .string(memory)
        }

        var runtimeDefaults: [String: ParameterValue] = [:]
        if let runtimeEvidence {
            runtimeDefaults["runtimeExecutablePath"] = .file(URL(fileURLWithPath: runtimeEvidence.executable.path))
            if let sha = runtimeEvidence.executable.sha256 { runtimeDefaults["runtimeExecutableSHA256"] = .string(sha) }
            if let size = runtimeEvidence.executable.sizeBytes { runtimeDefaults["runtimeExecutableSizeBytes"] = .string(String(size)) }
            runtimeDefaults["runtimeEnvironment"] = .dictionary(runtimeEvidence.environment.mapValues(ParameterValue.string))
        }
        let recordedAt = Date(), step = StepExecution(
            toolName: "\(CLICommandIdentity.executableName) workflow run",
            toolVersion: LungfishCLI.configuration.version,
            command: command,
            resolvedOptions: runtimeDefaults,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            startTime: recordedAt, endTime: recordedAt
        )
        let run = WorkflowRun(
            name: "Run \(request.workflowDisplayName)",
            startTime: recordedAt, endTime: recordedAt,
            status: status,
            steps: [step],
            parameters: parameters
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(resolvedDefaults: runtimeDefaults), to: bundleURL)
        if !prepareOnly, status == .completed {
            try writeExpectedOutputProvenance(run, to: request.expectedOutputURLs, resolvedDefaults: runtimeDefaults)
        }
    }

    func expectedOutputRecords(for outputURLs: [URL]) -> [FileRecord] {
        outputURLs.map { outputURL in
            ProvenanceRecorder.fileOrDirectoryRecord(url: outputURL, role: .output)
        }
    }

    func writeExpectedOutputProvenance(
        _ run: WorkflowRun,
        to outputURLs: [URL],
        resolvedDefaults: [String: ParameterValue] = [:]
    ) throws {
        guard !outputURLs.isEmpty else { return }
        let writer = ProvenanceWriter()
        let envelope = run.canonicalEnvelope(resolvedDefaults: resolvedDefaults)
        for outputURL in outputURLs {
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw CLIError.outputWriteFailed(
                    path: outputURL.path,
                    reason: "Expected workflow output was not created"
                )
            }

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
            let outputPath = outputURL.standardizedFileURL.path
            guard let outputDescriptor = envelope.outputs.first(where: { $0.path == outputPath }) else {
                throw CLIError.outputWriteFailed(
                    path: outputURL.path,
                    reason: "Expected workflow output was not recorded in run provenance"
                )
            }
            let focusedEnvelope = envelope.focusedOnOutput(outputDescriptor)
            if isDirectory.boolValue {
                try writer.write(focusedEnvelope, to: outputURL)
            } else {
                try writer.write(
                    focusedEnvelope,
                    toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
                )
            }
        }
    }

}
