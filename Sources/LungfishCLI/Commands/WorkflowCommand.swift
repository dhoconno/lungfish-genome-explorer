// WorkflowCommand.swift - Workflow execution command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension NFCoreExecutor: ExpressibleByArgument {}

/// Workflow execution commands
struct WorkflowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Execute and manage bioinformatics workflows",
        discussion: """
            Run Nextflow and Snakemake workflows using Apple Containerization
            for isolated execution of bioinformatics tools.

            Requires macOS 26 or later for container support.
            """,
        subcommands: [
            RunSubcommand.self,
            WorkflowBuilderRunSubcommand.self,
            ListSubcommand.self,
            WorkflowValidateSubcommand.self,
            WorkflowDiffSubcommand.self,
        ],
        defaultSubcommand: RunSubcommand.self
    )
}

struct WorkflowBuilderRunSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builder-run",
        abstract: "Run a native Workflow Builder graph"
    )

    @Option(name: .customLong("workflow"), help: "Workflow Builder .lungfishflow bundle or graph JSON")
    var workflow: String

    @Option(name: .customLong("project"), help: "Active .lungfish project directory")
    var project: String

    @Option(name: .customLong("run-directory"), help: "Directory for workflow run state and intermediate files")
    var runDirectory: String?

    @Option(name: .customLong("threads"), help: "CPU threads available to native FASTQ tools")
    var threads: Int = 4

    @Flag(name: .customLong("dry-run"), help: "Compile the executable plan and print JSON without running tools")
    var dryRun: Bool = false

    func run() async throws {
        let workflowURL = URL(fileURLWithPath: workflow).standardizedFileURL
        let projectURL = URL(fileURLWithPath: project).standardizedFileURL
        let runDirectoryURL = runDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? Self.defaultRunDirectory(workflowURL: workflowURL, projectURL: projectURL)
        let graph = try WorkflowLibraryStore.loadWorkflow(from: workflowURL)

        if dryRun {
            let plan = try WorkflowBuilderPlanCompiler().compile(
                graph: graph,
                projectURL: projectURL,
                runDirectoryURL: runDirectoryURL
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(plan)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        let argv = Self.reproducibleArgv(
            workflowURL: workflowURL,
            projectURL: projectURL,
            runDirectoryURL: runDirectoryURL,
            threads: threads,
            dryRun: false
        )
        let result = try await WorkflowBuilderNativeRunner().run(
            graph: graph,
            projectURL: projectURL,
            runDirectoryURL: runDirectoryURL,
            workflowBundleURL: workflowURL,
            argv: argv,
            threads: threads
        )
        print("Workflow Builder run completed")
        print("Output bundle: \(result.outputBundleURL.path)")
        print("Provenance: \(result.provenanceURL.path)")
    }

    private static func defaultRunDirectory(workflowURL: URL, projectURL: URL) -> URL {
        let runID = UUID()
        if workflowURL.pathExtension.lowercased() == WorkflowLibraryStore.workflowBundleExtension {
            return WorkflowBuilderRunStore.runDirectory(runID: runID, in: workflowURL)
        }
        return projectURL
            .appendingPathComponent("Workflow Runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    private static func reproducibleArgv(
        workflowURL: URL,
        projectURL: URL,
        runDirectoryURL: URL,
        threads: Int,
        dryRun: Bool
    ) -> [String] {
        var argv = [
            "lungfish-cli",
            "workflow",
            "builder-run",
            "--workflow",
            workflowURL.path,
            "--project",
            projectURL.path,
            "--run-directory",
            runDirectoryURL.path,
            "--threads",
            String(threads),
        ]
        if dryRun {
            argv.append("--dry-run")
        }
        return argv
    }
}

struct WorkflowDiffSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two saved Lungfish workflows"
    )

    @Argument(help: "First workflow file or .lungfishflow bundle")
    var first: String

    @Argument(help: "Second workflow file or .lungfishflow bundle")
    var second: String

    @Option(name: .customLong("format"), help: "Output format: text, json, or tsv")
    var format: OutputFormat = .text

    func run() async throws {
        let firstGraph = try Self.loadWorkflow(at: URL(fileURLWithPath: first))
        let secondGraph = try Self.loadWorkflow(at: URL(fileURLWithPath: second))
        let diff = WorkflowGraphDiff.compare(firstGraph, secondGraph)

        switch format {
        case .text:
            print(diff.textDescription)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(diff.jsonReport)
            print(String(data: data, encoding: .utf8) ?? "{}")
        case .tsv:
            print("field\tvalue")
            print("fromVersion\t\(diff.jsonReport.fromVersion)")
            print("toVersion\t\(diff.jsonReport.toVersion)")
            print("hasChanges\t\(diff.hasChanges)")
            for change in diff.changes {
                print("change\t\(change)")
            }
        }
    }

    private static func loadWorkflow(at url: URL) throws -> WorkflowGraph {
        let data = try Data(contentsOf: try workflowJSONURL(for: url))
        return try JSONDecoder().decode(WorkflowGraph.self, from: data)
    }

    private static func workflowJSONURL(for url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: url.path)
        }
        guard isDirectory.boolValue else { return url }
        let candidates = [
            url.appendingPathComponent("graph.json"),
            url.appendingPathComponent("workflow.json"),
            url.appendingPathComponent("manifest.json"),
        ]
        if let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return candidate
        }
        throw CLIError.inputFileNotFound(path: url.appendingPathComponent("workflow.json").path)
    }
}

struct RunHeadlessSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-headless",
        abstract: "Run a workflow quietly without the GUI",
        discussion: """
            Thin alias for `lungfish workflow run --quiet <workflow>`.
            Use `lungfish workflow run --help` for the full workflow run option set.
            """
    )

    @Argument(help: "Workflow file (*.nf, Snakefile) or supported nf-core workflow to pass to workflow run")
    var workflow: String

    func run() async throws {
        let command = try RunSubcommand.parse([workflow, "--quiet"])
        try await command.run()
    }
}

// MARK: - Run Subcommand

/// Execute a workflow
struct RunSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a workflow pipeline",
        discussion: """
            Run a Nextflow or Snakemake workflow with the specified parameters.
            Workflows are executed using Apple Containerization (macOS 26+).
            The only built-in nf-core workflow supported by this command is
            nf-core/viralrecon, also accepted as viralrecon.

            Examples:
              lungfish workflow run pipeline.nf --param reads=data/*.fastq.gz
              lungfish workflow run Snakefile --cpus 8 --memory 16.GB
              lungfish workflow run nf-core/viralrecon --input samplesheet.csv --param platform=illumina
            """
    )

    nonisolated(unsafe) static var localWorkflowProcessRunner: LocalWorkflowProcessRunning = ProcessLocalWorkflowProcessRunner()

    @Argument(help: "Workflow file (*.nf, Snakefile) or supported nf-core workflow: nf-core/viralrecon")
    var workflow: String

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
        help: "Input file selected for the workflow; repeat for multiple inputs"
    )
    var input: [String] = []

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
        help: "Maximum execution time in minutes"
    )
    var timeout: Int?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

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
                throw CLIError.workflowFailed(reason: "--timeout is not supported for nf-core/viralrecon runs yet")
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

        let request = LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            engine: isNextflow ? .nextflow : .snakemake,
            inputURLs: inputURLs,
            outputDirectory: URL(fileURLWithPath: resultsDir),
            params: workflowParams,
            resume: resume,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) },
            cpus: cpus,
            memory: memory
        )
        let runBundleURL = try resolveRunBundleURL(workflowName: request.workflowName)
        let bundleCreatedAt = Date()
        let preparedEvent = LocalWorkflowRunStatusEvent(status: .prepared, timestamp: bundleCreatedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
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
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                executionStatus: .running,
                statusHistory: [preparedEvent, runningEvent],
                startedAt: processStartedAt
            ),
            to: runBundleURL
        )
        let launch = request.processLaunch
        let processResult = try await Self.localWorkflowProcessRunner.runWorkflow(
            executableName: launch.executableName,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory
        )
        try writeLocalProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
        let processCompletedAt = Date()
        let executionStatus: NFCoreRunExecutionStatus = processResult.exitCode == 0 ? .completed : .failed
        let completedEvent = LocalWorkflowRunStatusEvent(status: executionStatus, timestamp: processCompletedAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
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
            bundleURL: runBundleURL,
            prepareOnly: false,
            status: processResult.exitCode == 0 ? .completed : .failed,
            exitCode: processResult.exitCode,
            wallTime: processCompletedAt.timeIntervalSince(processStartedAt),
            stderr: processResult.standardError
        )
        if processResult.exitCode != 0 {
            throw CLIError.workflowFailed(
                reason: "\(request.engine.displayName) exited with status \(processResult.exitCode). See \(runBundleURL.appendingPathComponent("logs/stderr.log").path)"
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
        guard input.count == 1 else {
            throw CLIError.workflowFailed(reason: "Exactly one --input samplesheet is required for nf-core/viralrecon")
        }

        let inputURLs = input.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            throw CLIError.inputFileNotFound(path: inputURL.path)
        }

        let outputURL = URL(fileURLWithPath: resultsDir).standardizedFileURL
        let request = NFCoreRunRequest(
            workflow: supportedWorkflow,
            version: version,
            executor: executor,
            inputURLs: inputURLs,
            outputDirectory: outputURL,
            params: workflowParams,
            resume: resume,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) }
        )
        let runBundleURL = try resolveRunBundleURL(workflowName: supportedWorkflow.name)
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
                stderr: nil
            )
            print(runBundleURL.path)
            return
        }

        let processStartedAt = Date()
        try NFCoreRunBundleStore.write(
            request.manifest(
                createdAt: bundleCreatedAt,
                executionStatus: .running,
                startedAt: processStartedAt
            ),
            to: runBundleURL
        )
        let processResult = try await runNextflow(
            arguments: request.nextflowArguments,
            workingDirectory: runBundleURL.appendingPathComponent("outputs", isDirectory: true)
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
            stderr: processResult.standardError
        )
        if processResult.exitCode != 0 {
            throw CLIError.workflowFailed(reason: "Nextflow exited with status \(processResult.exitCode). See \(runBundleURL.appendingPathComponent("logs/stderr.log").path)")
        }
        print(runBundleURL.path)
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    private func runNextflow(arguments: [String], workingDirectory: URL) async throws -> NFCoreWorkflowProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                let stdoutURL = workingDirectory.appendingPathComponent(".nextflow-stdout.log")
                let stderrURL = workingDirectory.appendingPathComponent(".nextflow-stderr.log")
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["nextflow"] + arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { process in
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                    continuation.resume(returning: NFCoreWorkflowProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: stdout,
                        standardError: stderr
                    ))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func writeProcessLogs(_ result: NFCoreWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try result.standardOutput.write(to: logsURL.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
        try result.standardError.write(to: logsURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
    }

    private func writeLocalProcessLogs(_ result: LocalWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try result.standardOutput.write(to: logsURL.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
        try result.standardError.write(to: logsURL.appendingPathComponent("stderr.log"), atomically: true, encoding: .utf8)
    }

    private func writeRunBundleProvenance(
        request: NFCoreRunRequest,
        bundleURL: URL,
        prepareOnly: Bool,
        status: RunStatus,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) throws {
        let command = ["lungfish-cli"] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = request.inputURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .input)
        }
        let outputs = [
            FileRecord(path: bundleURL.path, format: .unknown, role: .output),
            FileRecord(path: request.outputDirectory.path, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            )
        ]
        var parameters = request.effectiveParams.mapValues { ParameterValue.string($0) }
        parameters["executor"] = .string(request.executor.rawValue)
        parameters["resume"] = .boolean(request.resume)
        parameters["prepareOnly"] = .boolean(prepareOnly)
        if let workDirectory = request.workDirectory {
            parameters["workDirectory"] = .file(workDirectory)
        }

        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: LungfishCLI.configuration.version,
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try data.write(to: provenanceURL, options: .atomic)
        try signProvenanceIfConfigured(at: provenanceURL)
    }

    private func writeLocalRunBundleProvenance(
        request: LocalWorkflowRunRequest,
        bundleURL: URL,
        prepareOnly: Bool,
        status: RunStatus,
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) throws {
        let command = ["lungfish-cli"] + request.cliArguments(
            bundlePath: bundleURL,
            prepareOnly: prepareOnly
        ) + (globalOptions.quiet ? ["--quiet"] : [])
        let inputs = [ProvenanceRecorder.fileRecord(url: request.workflowURL, format: .text, role: .input)]
            + request.inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) }
        let outputs = [
            FileRecord(path: bundleURL.path, format: .unknown, role: .output),
            FileRecord(path: request.outputDirectory.path, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            ),
        ]
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

        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: LungfishCLI.configuration.version,
            command: command,
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try data.write(to: provenanceURL, options: .atomic)
        try signProvenanceIfConfigured(at: provenanceURL)
    }

    private func signProvenanceIfConfigured(at provenanceURL: URL) throws {
        guard let provider = ProvenanceSigningConfiguration.defaultProvider() else { return }
        _ = try provider.sign(provenanceURL: provenanceURL)
    }
}

private struct NFCoreWorkflowProcessResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

struct LocalWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

protocol LocalWorkflowProcessRunning: Sendable {
    func runWorkflow(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowProcessResult
}

struct ProcessLocalWorkflowProcessRunner: LocalWorkflowProcessRunning {
    func runWorkflow(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                let stdoutURL = workingDirectory.appendingPathComponent(".lungfish-workflow-stdout.log")
                let stderrURL = workingDirectory.appendingPathComponent(".lungfish-workflow-stderr.log")
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executableName] + arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { process in
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                    continuation.resume(returning: LocalWorkflowProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: stdout,
                        standardError: stderr
                    ))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - List Subcommand

/// List available workflows
struct ListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available workflows"
    )

    @Flag(
        name: .customLong("nf-core"),
        help: "List the supported nf-core Viral Recon pipeline"
    )
    var nfCore: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if nfCore {
            print(formatter.header("Supported nf-core Pipeline"))
            if let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon") {
                print("  \(formatter.colored(workflow.fullName, .cyan)): \(workflow.description)")
            }
        } else {
            print(formatter.info("Use --nf-core to list the supported nf-core Viral Recon pipeline"))
            print(formatter.info("Or provide a local workflow file path to 'workflow run'"))
        }
    }
}

// MARK: - Validate Subcommand (Workflow)

/// Validate workflow definition
struct WorkflowValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a workflow definition"
    )

    @Argument(help: "Workflow file to validate")
    var workflow: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        guard FileManager.default.fileExists(atPath: workflow) else {
            throw CLIError.inputFileNotFound(path: workflow)
        }

        let url = URL(fileURLWithPath: workflow)
        let ext = url.pathExtension.lowercased()
        let source = try String(contentsOf: url, encoding: .utf8)

        if ext == "nf" {
            try validateNextflow(source, fileName: url.lastPathComponent)
            emitValidationSuccess(
                workflowURL: url,
                engine: .nextflow,
                formatter: formatter
            )
        } else if url.lastPathComponent.lowercased().contains("snakefile") {
            try validateSnakemake(source, fileName: url.lastPathComponent)
            emitValidationSuccess(
                workflowURL: url,
                engine: .snakemake,
                formatter: formatter
            )
        } else {
            throw CLIError.unsupportedFormat(format: "Unknown workflow format")
        }
    }

    private func validateNextflow(_ source: String, fileName: String) throws {
        let validationSource = sourceForValidation(source, engine: .nextflow)
        var errors = commonSyntaxErrors(in: validationSource, fileName: fileName)
        if validationSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Nextflow workflow \(fileName) is empty")
        }

        let nextflowPattern = #"\b(nextflow\.enable\.dsl|process\s+[A-Za-z_][A-Za-z0-9_]*|workflow\s*(\{|[A-Za-z_][A-Za-z0-9_]*\s*\{))"#
        if validationSource.range(of: nextflowPattern, options: .regularExpression) == nil {
            errors.append("Nextflow workflow \(fileName) must contain a Nextflow DSL declaration, process block, or workflow block")
        }

        if !errors.isEmpty {
            throw CLIError.validationFailed(errors: errors)
        }
    }

    private func validateSnakemake(_ source: String, fileName: String) throws {
        let validationSource = sourceForValidation(source, engine: .snakemake)
        var errors = commonSyntaxErrors(in: validationSource, fileName: fileName)
        if validationSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Snakemake workflow \(fileName) is empty")
        }

        let snakemakePattern = #"(?m)^\s*(rule|checkpoint|include:|configfile:|module|use\s+rule|subworkflow)\b"#
        if validationSource.range(of: snakemakePattern, options: .regularExpression) == nil {
            errors.append("Snakemake workflow \(fileName) must contain at least one rule, checkpoint, include, configfile, module, use rule, or subworkflow declaration")
        }

        if !errors.isEmpty {
            throw CLIError.validationFailed(errors: errors)
        }
    }

    private func commonSyntaxErrors(in source: String, fileName: String) -> [String] {
        var errors: [String] = []
        if source.contains("<<<<<<<") || source.contains("=======") || source.contains(">>>>>>>") {
            errors.append("\(fileName) contains unresolved merge conflict markers")
        }

        let delimiters: [(open: Character, close: Character, name: String)] = [
            (open: "(", close: ")", name: "parentheses"),
            (open: "[", close: "]", name: "brackets"),
            (open: "{", close: "}", name: "braces"),
        ]
        for delimiter in delimiters {
            if !hasOrderedDelimiters(in: source, open: delimiter.open, close: delimiter.close) {
                errors.append("\(fileName) has unbalanced \(delimiter.name)")
            }
        }
        return errors
    }

    private func hasOrderedDelimiters(in source: String, open: Character, close: Character) -> Bool {
        var depth = 0
        for character in source {
            if character == open {
                depth += 1
            } else if character == close {
                guard depth > 0 else { return false }
                depth -= 1
            }
        }
        return depth == 0
    }

    private func sourceForValidation(_ source: String, engine: WorkflowValidationEngine) -> String {
        let withoutBlockComments = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/"#,
            with: "",
            options: .regularExpression
        )
        let lineCommentPrefix: String = engine == .nextflow ? "//" : "#"
        return withoutBlockComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = line.range(of: lineCommentPrefix) else {
                    return line
                }
                return line[..<commentStart.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func emitValidationSuccess(
        workflowURL: URL,
        engine: WorkflowValidationEngine,
        formatter: TerminalFormatter
    ) {
        guard !globalOptions.quiet else { return }

        let report = WorkflowValidationReport(
            workflow: workflowURL.path,
            engine: engine,
            valid: true,
            errors: []
        )

        switch globalOptions.outputFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        case .tsv:
            print("workflow\tengine\tvalid\terrors")
            print("\(workflowURL.path)\t\(engine.rawValue)\ttrue\t")
        case .text:
            print(formatter.info("Validating \(engine.displayName) workflow: \(workflowURL.lastPathComponent)"))
            print(formatter.success("Workflow syntax appears valid"))
        }
    }

    private struct WorkflowValidationReport: Encodable {
        let workflow: String
        let engine: WorkflowValidationEngine
        let valid: Bool
        let errors: [String]
    }

    private enum WorkflowValidationEngine: String, Encodable {
        case nextflow
        case snakemake

        var displayName: String {
            switch self {
            case .nextflow: return "Nextflow"
            case .snakemake: return "Snakemake"
            }
        }
    }
}
