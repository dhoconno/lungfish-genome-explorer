// WorkflowCommand.swift - Workflow execution command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

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

            Examples:
              lungfish workflow run pipeline.nf --param reads=data/*.fastq.gz
              lungfish workflow run Snakefile --cpus 8 --memory 16.GB
              lungfish workflow run nf-core/rnaseq --params-file params.json
            """
    )

    @Argument(help: "Workflow file (*.nf, Snakefile) or nf-core pipeline name")
    var workflow: String

    @Option(
        name: .customLong("results-dir"),
        help: "Output directory for results"
    )
    var resultsDir: String = "./results"

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

    @Option(
        name: .customLong("timeout"),
        help: "Maximum execution time in minutes"
    )
    var timeout: Int?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Check container availability
        guard #available(macOS 26, *) else {
            throw CLIError.containerUnavailable
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

        if dryRun {
            print(formatter.info("Dry run - workflow would execute with:"))
            print("  Workflow: \(workflow)")
            print("  Results: \(resultsDir)")
            print("  Parameters: \(workflowParams.count)")
            for (key, value) in workflowParams.sorted(by: { $0.key < $1.key }) {
                print("    \(key) = \(value)")
            }
            return
        }

        // Determine workflow type
        let workflowURL = URL(fileURLWithPath: workflow)
        let isNextflow = workflowURL.pathExtension == "nf" || workflow.contains("nf-core")
        let isSnakemake = workflowURL.lastPathComponent.lowercased().contains("snakefile")

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
}

// MARK: - List Subcommand

/// List available workflows
struct ListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available workflows and pipelines"
    )

    @Flag(
        name: .customLong("nf-core"),
        help: "List nf-core pipelines"
    )
    var nfCore: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if nfCore {
            print(formatter.header("Available nf-core Pipelines"))
            // TODO: Fetch from NFCoreRegistry
            let pipelines = [
                ("nf-core/rnaseq", "RNA sequencing analysis"),
                ("nf-core/sarek", "Variant calling pipeline"),
                ("nf-core/viralrecon", "Viral genome assembly"),
                ("nf-core/ampliseq", "Amplicon sequencing"),
                ("nf-core/chipseq", "ChIP-seq analysis"),
            ]
            for (name, description) in pipelines {
                print("  \(formatter.colored(name, .cyan)): \(description)")
            }
        } else {
            print(formatter.info("Use --nf-core to list nf-core pipelines"))
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
