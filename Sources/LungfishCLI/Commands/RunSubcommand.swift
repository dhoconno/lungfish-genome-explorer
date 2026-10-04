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

    nonisolated(unsafe) static var localWorkflowProcessRunner: LocalWorkflowProcessRunning = ProcessLocalWorkflowProcessRunner()
    nonisolated(unsafe) static var localWorkflowDirectoryReserver: @Sendable (URL) throws -> Void = {
        try LocalWorkflowReplayReservation.reserveDirectory(at: $0)
    }
    nonisolated(unsafe) static var nfCoreWorkflowProcessRunner: NFCoreWorkflowProcessRunning = ProcessNFCoreWorkflowProcessRunner()

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
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        if repeatFrom != nil, workflow.contains("nf-core") || Self.normalizedViralReconWorkflowName(workflow) != nil {
            throw CLIError.workflowFailed(reason: "--repeat-from supports identified local workflow packages only.")
        }

        if !globalOptions.quiet {
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
            if let cpus {
                workflowParams["max_cpus"] = String(cpus)
            }
            if let memory {
                workflowParams["max_memory"] = memory
            }
        }

        if dryRun {
            print(formatter.info("Dry run - workflow would execute with:"))
            print("  Workflow: \(workflow)")
            print("  Results: \(resultsDir)")
            print("  Executor: \(executor.rawValue)")
            if !input.isEmpty {
                print("  Inputs: \(input.joined(separator: ", "))")
            }
            print("  Parameters: \(workflowParams.count)")
            for (key, value) in workflowParams.sorted(by: { $0.key < $1.key }) {
                print("    \(key) = \(value)")
            }
            return
        }

        // Determine workflow type
        let workflowURL = URL(fileURLWithPath: workflow)
        let isNextflow = workflowURL.pathExtension == "nf" || workflow.contains("nf-core") || isViralReconWorkflow
        let isSnakemake = workflowURL.lastPathComponent.lowercased().contains("snakefile")

        if workflow.contains("nf-core") || isViralReconWorkflow {
            try await runNFCoreWorkflow(
                workflowParams: workflowParams,
                formatter: formatter
            )
            return
        }

        if !globalOptions.quiet {
            let engine = isNextflow ? "Nextflow" : (isSnakemake ? "Snakemake" : "Unknown")
            print(formatter.info("Detected workflow engine: \(engine)"))
            print(formatter.info("Starting workflow execution..."))
        }

        try await runLocalWorkflow(
            workflowParams: workflowParams,
            isNextflow: isNextflow,
            isSnakemake: isSnakemake,
            formatter: formatter
        )
    }

    private func runLocalWorkflow(
        workflowParams: [String: String],
        isNextflow: Bool,
        isSnakemake: Bool,
        formatter: TerminalFormatter
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
        let bundleCreatedAt = Date()
        let preparedEvent = LocalWorkflowRunStatusEvent(status: .prepared, timestamp: bundleCreatedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                replayIdentity: replayIdentity,
                inputBindings: inputBindings,
                executionStatus: .prepared,
                statusHistory: [preparedEvent]
            ),
            to: runBundleURL
        )

        if !globalOptions.quiet {
            print(formatter.info("Created run bundle: \(runBundleURL.path)"))
            print(formatter.info(request.commandPreview))
        }
        if prepareOnly {
            try writeLocalRunBundleProvenance(
                request: request,
                capturedInputs: capturedInputs,
                bundleURL: runBundleURL,
                prepareOnly: true,
                status: .completed,
                exitCode: 0,
                wallTime: Date().timeIntervalSince(bundleCreatedAt),
                stderr: nil
            )
            print(runBundleURL.path)
            return
        }

        let processStartedAt = Date()
        let runningEvent = LocalWorkflowRunStatusEvent(status: .running, timestamp: processStartedAt)
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
            try LocalWorkflowRunBundleStore.write(request.manifest(createdAt: bundleCreatedAt,
                replayIdentity: replayIdentity, inputBindings: inputBindings, executionStatus: .running,
                statusHistory: statusHistory, startedAt: processStartedAt), to: runBundleURL)
            processResult = try await Self.localWorkflowProcessRunner.runWorkflow(
                executableName: launch.executableName,
                arguments: launch.arguments,
                workingDirectory: launch.workingDirectory
            )
        } catch {
            let cancelled = error is CancellationError
            let endedAt = Date()
            let terminalStatus: NFCoreRunExecutionStatus = cancelled ? .cancelled : .failed
            let message = cancelled ? "Workflow launch was cancelled before an exit status was returned." : error.localizedDescription
            let stderrLogURL = runBundleURL.appendingPathComponent("logs/stderr.log")
            try PortablePath.sanitize(text: message, forFileAt: stderrLogURL).write(to: stderrLogURL, atomically: true, encoding: .utf8)
            try LocalWorkflowRunBundleStore.write(request.manifest(createdAt: bundleCreatedAt,
                replayIdentity: replayIdentity, inputBindings: inputBindings, executionStatus: terminalStatus,
                statusHistory: statusHistory + [.init(status: terminalStatus, timestamp: endedAt)],
                startedAt: processStartedAt, completedAt: endedAt, exitCode: nil), to: runBundleURL)
            try writeLocalRunBundleProvenance(request: request, capturedInputs: capturedInputs,
                includeResultOutputs: ownsOutputDirectory, bundleURL: runBundleURL, prepareOnly: false, status: cancelled ? .cancelled : .failed,
                exitCode: nil, wallTime: endedAt.timeIntervalSince(processStartedAt), stderr: message)
            throw error
        }
        try writeLocalProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
        let processCompletedAt = Date()
        let executionStatus: NFCoreRunExecutionStatus = processResult.exitCode == 0 ? .completed : .failed
        let completedEvent = LocalWorkflowRunStatusEvent(status: executionStatus, timestamp: processCompletedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                replayIdentity: replayIdentity,
                inputBindings: inputBindings,
                executionStatus: executionStatus,
                statusHistory: [preparedEvent, runningEvent, completedEvent],
                startedAt: processStartedAt,
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
            wallTime: processCompletedAt.timeIntervalSince(processStartedAt),
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
        print(runBundleURL.path)
    }

    private func runNFCoreWorkflow(
        workflowParams: [String: String],
        formatter: TerminalFormatter
    ) async throws {
        let normalizedWorkflow = try validateViralReconWorkflowName()
        guard let supportedWorkflow = NFCoreSupportedWorkflowCatalog.workflow(named: normalizedWorkflow) else {
            throw CLIError.workflowFailed(reason: "Unsupported nf-core workflow: \(workflow)")
        }
        guard !input.isEmpty else {
            throw CLIError.workflowFailed(reason: "nf-core/viralrecon needs one --input samplesheet.csv, or one or more --input .lungfishfastq bundles or FASTQ files")
        }

        let inputURLs = input.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            throw CLIError.inputFileNotFound(path: inputURL.path)
        }

        try requireExpectedOutputsForExecution()
        let outputURL = URL(fileURLWithPath: resultsDir).standardizedFileURL
        let expectedOutputURLs = expectedOutput.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let runBundleURL = try resolveRunBundleURL(workflowName: supportedWorkflow.name)

        // The app hands over a samplesheet it built from the chosen bundles;
        // a bare CLI call may hand over the bundles and get the same
        // samplesheet. Either way the Illumina rows are read back so the
        // read pairing decisions below are made from the same data.
        var params = workflowParams
        let resolvedInputs: ViralReconCLIInputs.Resolved
        do {
            resolvedInputs = try ViralReconCLIInputs.resolve(
                inputURLs: inputURLs,
                runBundleURL: runBundleURL,
                params: &params
            )
        } catch let error as ViralReconCLIInputs.InputError {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        } catch let error as ViralReconReadPairing.PairingError {
            throw CLIError.workflowFailed(reason: error.localizedDescription)
        }
        let callerSamplesheetURL = resolvedInputs.samplesheetURL

        // Read pairing (Illumina): a strictly interleaved bundle file is split
        // into R1/R2 inside the run so viralrecon sees fastq_1 AND fastq_2;
        // the decision for every row is recorded before anything else runs.
        var pairingDecisions = resolvedInputs.illuminaSamples.map(ViralReconReadPairing.decisions(for:)) ?? []
        let decisionsURL = runBundleURL
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent(ViralReconReadPairing.decisionsFilename)
        if !pairingDecisions.isEmpty {
            try ViralReconReadPairing.writeDecisions(pairingDecisions, to: decisionsURL)
            reportReadPairing(pairingDecisions, formatter: formatter)
        }

        let request = NFCoreRunRequest(
            workflow: supportedWorkflow,
            version: version,
            executor: executor,
            inputURLs: [callerSamplesheetURL],
            outputDirectory: outputURL,
            expectedOutputURLs: expectedOutputURLs,
            params: params,
            resume: resume,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) }
        )
        // Same gate the app applies (ViralReconWorkflowExecutionService):
        // only Docker reaches a working run, so refuse conda/local before a
        // run bundle is written rather than letting Nextflow fail later.
        try Self.requireSupportedExecutor(request)
        let stagedAnnotation = try NFCoreLaunchStaging.stageAnnotation(for: request, runBundleURL: runBundleURL)
        if let stagedAnnotation, !globalOptions.quiet { print(formatter.info(stagedAnnotation.summary)) }
        let bundleCreatedAt = Date()
        try NFCoreRunBundleStore.write(
            request.manifest(createdAt: bundleCreatedAt, executionStatus: .prepared),
            to: runBundleURL
        )

        if !globalOptions.quiet {
            print(formatter.info("Created run bundle: \(runBundleURL.path)"))
            print(formatter.info(request.commandPreview))
        }
        if prepareOnly {
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: true,
                status: .completed,
                exitCode: 0,
                wallTime: Date().timeIntervalSince(bundleCreatedAt),
                stderr: nil,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            print(runBundleURL.path)
            return
        }

        // The managed Nextflow must exist before the bundle is marked
        // running: a missing engine is reported as such (exit 126, naming
        // Required Setup) with the bundle recorded as failed, instead of
        // launching whatever `nextflow` is on PATH and failing inside it.
        let processStartedAt = Date()
        do {
            try Self.nfCoreWorkflowProcessRunner.preflightEngine()
        } catch {
            let endedAt = Date()
            let stderrLogURL = runBundleURL.appendingPathComponent("logs/stderr.log")
            try PortablePath.sanitize(text: error.localizedDescription, forFileAt: stderrLogURL)
                .write(to: stderrLogURL, atomically: true, encoding: .utf8)
            try NFCoreRunBundleStore.write(
                request.manifest(
                    createdAt: bundleCreatedAt,
                    executionStatus: .failed,
                    startedAt: processStartedAt,
                    completedAt: endedAt,
                    exitCode: CLIExitCode.dependency.rawValue,
                    stderrLogPath: "logs/stderr.log"
                ),
                to: runBundleURL
            )
            try writeRunBundleProvenance(
                request: request,
                bundleURL: runBundleURL,
                prepareOnly: false,
                status: .failed,
                exitCode: CLIExitCode.dependency.rawValue,
                wallTime: endedAt.timeIntervalSince(processStartedAt),
                stderr: error.localizedDescription,
                readPairing: pairingDecisions,
                effectiveSamplesheetURL: nil,
                stagedAnnotation: stagedAnnotation
            )
            throw error
        }
        try NFCoreRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                executionStatus: .running,
                startedAt: processStartedAt
            ),
            to: runBundleURL
        )
        // Nextflow's `.nextflow/` cache + history need POSIX file locks and
        // a volume free of AppleDouble `._` xattr sidecars (see
        // NextflowScratchVolumeProbe). The scratch stays on the bundle's
        // volume when it qualifies (external SSDs usually dwarf the boot
        // volume) and moves to local storage only when it does not; when the
        // caller did not pin --work-dir, the work tree follows the scratch.
        let launchScratch = try ProjectTempDirectory.create(
            prefix: "nfcore-run-",
            contextURL: runBundleURL,
            policy: NextflowScratchVolumeProbe.volumeSupportsNextflowScratch(at: runBundleURL) ? .preferProjectContext : .systemOnly
        )
        defer { try? FileManager.default.removeItem(at: launchScratch) }
        // Tasks run inside the work tree, and QUAST refuses a path containing a
        // space, so the tree leaves the scratch when the project name has one.
        let scratchWork = try NFCoreLaunchStaging.workDirectory(preferring: launchScratch)
        defer {
            if scratchWork.isFallback {
                try? FileManager.default.removeItem(at: scratchWork.root)
            }
        }
        let scratchWorkDirectory = scratchWork.root
        // nf-core schemas reject path parameters containing whitespace, and a
        // Lungfish project directory routinely has spaces in its name, so the
        // engine gets whitespace-free copies under the launch scratch. Only the
        // engine's view changes: the manifest and provenance written above and
        // below still record the caller's real paths.
        // The scratch itself may carry the project's whitespace, in which case
        // the staged copies go to a system temp directory of their own.
        let stagingRoot = try NFCoreLaunchStaging.stagingRoot(preferring: launchScratch)
        defer {
            if stagingRoot.isFallback {
                try? FileManager.default.removeItem(at: stagingRoot.root)
            }
        }

        // Split interleaved pairs now, inside the run: the mate files are
        // large, so they live under the whitespace-free staging root (the
        // samplesheet schema rejects a FASTQ path with a space) and go away
        // with it. The samplesheet viralrecon reads is kept in the bundle.
        // Nextflow also reads the staged annotation in place of the caller's.
        var launchRequest = request.replacing(params: ViralReconAnnotationStaging.launchParams(request.params, using: stagedAnnotation))
        var effectiveSamplesheetURL: URL?
        if let samples = resolvedInputs.illuminaSamples, pairingDecisions.contains(where: \.needsSplit) {
            let splitRoot = stagingRoot.root.appendingPathComponent(
                ViralReconReadPairing.splitDirectoryName,
                isDirectory: true
            )
            let quiet = globalOptions.quiet
            let prepared: ViralReconPreparedIlluminaSamples
            do {
                prepared = try await ViralReconReadPairing.prepareIlluminaSamples(
                    samples,
                    splitRoot: splitRoot,
                    progress: { message in
                        if !quiet { print(message) }
                    }
                )
            } catch let error as ViralReconReadPairing.PairingError {
                try NFCoreRunBundleStore.write(
                    request.manifest(
                        createdAt: bundleCreatedAt,
                        executionStatus: .failed,
                        startedAt: processStartedAt,
                        completedAt: Date(),
                        exitCode: 1
                    ),
                    to: runBundleURL
                )
                try writeRunBundleProvenance(
                    request: request,
                    bundleURL: runBundleURL,
                    prepareOnly: false,
                    status: .failed,
                    exitCode: 1,
                    wallTime: Date().timeIntervalSince(processStartedAt),
                    stderr: error.localizedDescription,
                    readPairing: pairingDecisions,
                    effectiveSamplesheetURL: nil,
                    stagedAnnotation: stagedAnnotation
                )
                throw CLIError.workflowFailed(reason: error.localizedDescription)
            }
            pairingDecisions = prepared.decisions
            try ViralReconReadPairing.writeDecisions(pairingDecisions, to: decisionsURL)
            let pairedSamplesheetURL = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(
                samples: prepared.samples,
                in: runBundleURL.appendingPathComponent("inputs", isDirectory: true),
                filename: ViralReconReadPairing.pairedSamplesheetFilename
            )
            effectiveSamplesheetURL = pairedSamplesheetURL
            reportReadPairing(pairingDecisions, formatter: formatter)
            launchRequest = launchRequest.replacing(inputURLs: [pairedSamplesheetURL])
        }

        let stagedRequest = try NFCoreLaunchStaging.stage(launchRequest, in: stagingRoot.root)
        // Newer nf-core releases express resource caps as Nextflow's
        // process.resourceLimits instead of --max_cpus / --max_memory.
        let resourcePlan = try NFCoreResourceLimits.plan(for: stagedRequest, in: launchScratch)
        let plannedRequest = resourcePlan.request
        var launchArguments = resourcePlan.nextflowArguments(base: plannedRequest.nextflowArguments)
        if plannedRequest.workDirectory == nil {
            launchArguments += ["-work-dir", scratchWorkDirectory.path]
        }
        let processResult = try await Self.nfCoreWorkflowProcessRunner.runNextflow(
            arguments: launchArguments,
            workingDirectory: launchScratch,
            environment: plannedRequest.launchEnvironment
        )
        try writeProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
        let processCompletedAt = Date()
        let executionStatus: NFCoreRunExecutionStatus = processResult.exitCode == 0 ? .completed : .failed
        try NFCoreRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                executionStatus: executionStatus,
                startedAt: processStartedAt,
                completedAt: processCompletedAt,
                exitCode: processResult.exitCode,
                stdoutLogPath: "logs/stdout.log",
                stderrLogPath: "logs/stderr.log"
            ),
            to: runBundleURL
        )
        try writeRunBundleProvenance(
            request: request,
            bundleURL: runBundleURL,
            prepareOnly: false,
            status: processResult.exitCode == 0 ? .completed : .failed,
            exitCode: processResult.exitCode,
            wallTime: processCompletedAt.timeIntervalSince(processStartedAt),
            stderr: processResult.standardError,
            readPairing: pairingDecisions,
            effectiveSamplesheetURL: effectiveSamplesheetURL,
            stagedAnnotation: stagedAnnotation
        )
        if processResult.exitCode != 0 {
            throw CLIError.workflowFailed(
                reason: Self.engineFailureReason(
                    engineName: "Nextflow",
                    exitCode: processResult.exitCode,
                    stderr: processResult.standardError,
                    runBundleURL: runBundleURL
                )
            )
        }
        print(runBundleURL.path)
    }

    /// Prints one line per samplesheet row saying how viralrecon gets its
    /// reads. Warnings (a mixed file that must run single-end) go to stderr
    /// even under --quiet, the same way the fastq subcommands report a
    /// pairing fallback.
    private func reportReadPairing(_ decisions: [ViralReconReadPairingDecision], formatter: TerminalFormatter) {
        for decision in decisions {
            if !globalOptions.quiet {
                print(formatter.info("Read pairing: \(decision.summary)"))
            }
            if let warning = decision.warning {
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
        }
    }

    /// Rejects an executor the nf-core run cannot use, with the message the
    /// app shows for the same request.
    static func requireSupportedExecutor(_ request: NFCoreRunRequest) throws {
        do {
            try request.validateExecutorSupported()
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    private func requireExpectedOutputsForExecution() throws {
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

    private func resolveRunBundleURL(workflowName: String) throws -> URL {
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

    /// Builds the failure reason for a non-zero engine exit.
    ///
    /// The app overwrites `logs/stderr.log` with the CLI's own stderr once the
    /// command returns, so pointing at that file is not enough: the engine's
    /// last stderr lines ride along in the reason so the operation report shows
    /// the actual cause (for example a launcher that could not be found).
    static func engineFailureReason(
        engineName: String,
        exitCode: Int32,
        stderr: String,
        runBundleURL: URL,
        maxLines: Int = 20
    ) -> String {
        var reason = "\(engineName) exited with status \(exitCode). See \(runBundleURL.appendingPathComponent("logs/stderr.log").path)"
        let tail = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(maxLines)
        if !tail.isEmpty {
            reason += "\n" + tail.joined(separator: "\n")
        }
        return reason
    }

    /// Engine output kept in a run bundle names project files project-relatively
    /// and never the account's home, the tool root or scratch directories.
    private static func writePortableLog(_ text: String, to url: URL) throws {
        try PortablePath.sanitize(text: text, forFileAt: url).write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeProcessLogs(_ result: NFCoreWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try Self.writePortableLog(result.standardOutput, to: logsURL.appendingPathComponent("stdout.log"))
        try Self.writePortableLog(result.standardError, to: logsURL.appendingPathComponent("stderr.log"))
    }

    private func writeLocalProcessLogs(_ result: LocalWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try Self.writePortableLog(result.standardOutput, to: logsURL.appendingPathComponent("stdout.log"))
        try Self.writePortableLog(result.standardError, to: logsURL.appendingPathComponent("stderr.log"))
    }

    private func writeRunBundleProvenance(
        request: NFCoreRunRequest,
        bundleURL: URL,
        prepareOnly: Bool,
        status: RunStatus,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?,
        readPairing: [ViralReconReadPairingDecision] = [],
        effectiveSamplesheetURL: URL? = nil,
        stagedAnnotation: ViralReconStagedAnnotation? = nil
    ) throws {
        let command = [CLICommandIdentity.executableName] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = request.inputURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input)
        }
        let outputs = [
            ProvenanceRecorder.fileOrDirectoryRecord(url: bundleURL, role: .output),
            ProvenanceRecorder.fileOrDirectoryRecord(url: request.outputDirectory, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            )
        ] + expectedOutputRecords(for: request.expectedOutputURLs)
        var parameters = request.effectiveParams.mapValues { ParameterValue.string($0) }
        parameters["executor"] = .string(request.executor.rawValue)
        parameters["github_release_version"] = .string(request.version)
        parameters["resume"] = .boolean(request.resume)
        parameters["prepareOnly"] = .boolean(prepareOnly)
        if !request.expectedOutputURLs.isEmpty {
            parameters["expectedOutputs"] = .array(request.expectedOutputURLs.map { .file($0) })
        }
        if let workDirectory = request.workDirectory {
            parameters["workDirectory"] = .file(workDirectory)
        }
        if !readPairing.isEmpty {
            parameters["readPairing"] = .array(readPairing.map(\.provenanceValue))
        }
        if let effectiveSamplesheetURL {
            parameters["effectiveSamplesheet"] = .file(effectiveSamplesheetURL)
        }
        if let stagedAnnotation {
            parameters[ViralReconAnnotationStaging.provenanceKey] = stagedAnnotation.provenanceValue
        }

        let step = StepExecution(
            toolName: "\(CLICommandIdentity.executableName) workflow run",
            toolVersion: LungfishCLI.configuration.version,
            githubReleaseVersion: request.version,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            endTime: Date()
        )
        let run = WorkflowRun(
            name: request.displayTitle,
            endTime: Date(),
            status: status,
            steps: [step],
            parameters: parameters
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(), to: bundleURL)
        if !prepareOnly, status == .completed {
            try writeExpectedOutputProvenance(run, to: request.expectedOutputURLs)
        }
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
        let step = StepExecution(
            toolName: "\(CLICommandIdentity.executableName) workflow run",
            toolVersion: LungfishCLI.configuration.version,
            command: command,
            resolvedOptions: runtimeDefaults,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            endTime: Date()
        )
        let run = WorkflowRun(
            name: "Run \(request.workflowDisplayName)",
            endTime: Date(),
            status: status,
            steps: [step],
            parameters: parameters
        )
        try ProvenanceWriter().write(run.canonicalEnvelope(resolvedDefaults: runtimeDefaults), to: bundleURL)
        if !prepareOnly, status == .completed {
            try writeExpectedOutputProvenance(run, to: request.expectedOutputURLs, resolvedDefaults: runtimeDefaults)
        }
    }

    private func expectedOutputRecords(for outputURLs: [URL]) -> [FileRecord] {
        outputURLs.map { outputURL in
            ProvenanceRecorder.fileOrDirectoryRecord(url: outputURL, role: .output)
        }
    }

    private func writeExpectedOutputProvenance(
        _ run: WorkflowRun,
        to outputURLs: [URL],
        resolvedDefaults: [String: ParameterValue] = [:]
    ) throws {
        guard !outputURLs.isEmpty else { return }
        let writer = ProvenanceWriter(signingProvider: nil)
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
