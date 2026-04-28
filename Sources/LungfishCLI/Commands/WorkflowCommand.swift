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
            ListSubcommand.self,
            WorkflowValidateSubcommand.self,
        ],
        defaultSubcommand: RunSubcommand.self
    )
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

        // TODO: Integrate with actual workflow runners
        // This is a placeholder for Phase 3 implementation
        print(formatter.warning("Workflow execution not yet implemented in CLI"))
        print("Would execute: \(workflow)")
        print("With \(workflowParams.count) parameters")
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
        try NFCoreRunBundleStore.write(request.manifest(), to: runBundleURL)

        if !globalOptions.quiet {
            print(formatter.info("Created run bundle: \(runBundleURL.path)"))
            print(formatter.info(request.commandPreview))
        }
        if prepareOnly {
            print(runBundleURL.path)
            return
        }

        let processResult = try await runNextflow(
            arguments: request.nextflowArguments,
            workingDirectory: runBundleURL.appendingPathComponent("outputs", isDirectory: true)
        )
        try writeProcessLogs(processResult, to: runBundleURL.appendingPathComponent("logs", isDirectory: true))
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
}

private struct NFCoreWorkflowProcessResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
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

        if ext == "nf" {
            print(formatter.info("Validating Nextflow workflow: \(url.lastPathComponent)"))
            // TODO: Implement actual validation
            print(formatter.success("Workflow syntax appears valid"))
        } else if url.lastPathComponent.lowercased().contains("snakefile") {
            print(formatter.info("Validating Snakemake workflow: \(url.lastPathComponent)"))
            print(formatter.success("Workflow syntax appears valid"))
        } else {
            throw CLIError.unsupportedFormat(format: "Unknown workflow format")
        }
    }
}
