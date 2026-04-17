// SnakemakeRunner.swift - Snakemake workflow execution engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log
import LungfishCore

// MARK: - SnakemakeRunner

/// Actor for executing Snakemake workflows.
///
/// SnakemakeRunner manages the execution of Snakemake pipelines, handling
/// container runtime selection, configuration injection, and DAG generation.
///
/// ## Example
///
/// ```swift
/// let runner = SnakemakeRunner()
/// await WorkflowRunnerRegistry.shared.register(runner)
///
/// // Check if Snakemake is available
/// if await runner.isAvailable() {
///     let version = await runner.getVersion()
///     print("Snakemake \(version ?? "unknown") is installed")
/// }
///
/// // Generate workflow DAG
/// let dagSVG = try await runner.generateDAG(workflow: definition)
///
/// // Execute a workflow
/// let result = try await runner.run(
///     workflow: definition,
///     parameters: params,
///     outputDirectory: outputDir
/// ) { progress in
///     print("Rule: \(progress.process), Status: \(progress.status)")
/// }
/// ```
public actor SnakemakeRunner: WorkflowRunner {

    // MARK: - Properties

    public nonisolated let engineType: WorkflowEngineType = .snakemake

    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "SnakemakeRunner"
    )

    /// Base workflow runner for common functionality.
    private let baseRunner: BaseWorkflowRunner
    private let homeDirectoryProvider: @Sendable () -> URL

    /// Path to the Snakemake executable.
    private var executablePath: URL?

    /// Cached version string.
    private var cachedVersion: String?

    /// Minimum required Snakemake version.
    public static let minimumVersion = "7.0.0"

    // MARK: - Initialization

    /// Creates a new Snakemake runner.
    ///
    /// - Parameter processManager: Optional process manager (defaults to shared)
    public init(
        processManager: ProcessManager = .shared,
        homeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        }
    ) {
        self.baseRunner = BaseWorkflowRunner(
            category: "SnakemakeRunner",
            processManager: processManager
        )
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    // MARK: - WorkflowRunner Protocol

    public func isAvailable() async -> Bool {
        Self.logger.debug("Checking Snakemake availability")

        if let path = resolveExecutablePath() {
            executablePath = path
            Self.logger.info("Snakemake found at \(path.path)")
            return true
        }

        Self.logger.info("Snakemake not found in PATH")
        return false
    }

    public func getVersion() async -> String? {
        if let cached = cachedVersion {
            return cached
        }

        Self.logger.debug("Getting Snakemake version")

        guard let execPath = resolveExecutablePath() else {
            return nil
        }

        let workDir = FileManager.default.temporaryDirectory

        do {
            let environment = managedExecutionEnvironment(for: execPath)
            let (_, stdout, stderr) = try await baseRunner.processManager.runAndWait(
                executable: execPath,
                arguments: ["--version"],
                workingDirectory: workDir,
                environment: environment
            )

            let output = [stdout, stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            cachedVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.info("Snakemake version: \(self.cachedVersion ?? "unknown")")
            return cachedVersion
        } catch {
            Self.logger.error("Failed to get Snakemake version: \(error.localizedDescription)")
        }

        return nil
    }

    public func run(
        workflow: WorkflowDefinition,
        parameters: WorkflowParameters,
        outputDirectory: URL,
        progress: @escaping @Sendable (WorkflowProgressUpdate) -> Void
    ) async throws -> WorkflowResult {
        Self.logger.info("Starting Snakemake execution for workflow: \(workflow.name)")

        // Ensure Snakemake is available
        guard let execPath = executablePath ?? resolveExecutablePath() else {
            throw WorkflowError.engineNotFound(
                engine: "snakemake",
                searchedPaths: getSearchPaths()
            )
        }
        executablePath = execPath

        // Validate workflow file exists
        guard FileManager.default.fileExists(atPath: workflow.path.path) else {
            throw WorkflowError.invalidWorkflowDefinition(
                path: workflow.path,
                reason: "Snakefile not found"
            )
        }

        // Get working directory
        let workDir = workflow.effectiveWorkDirectory

        // Setup directories
        try baseRunner.setupDirectories(
            outputDirectory: outputDirectory,
            logDirectory: nil,
            workDirectory: workDir
        )

        // Register execution for tracking
        let (executionId, stateMachine) = await baseRunner.registerExecution(workflowId: workflow.id)

        // Mark as running
        try await stateMachine.transition(to: .running)

        // Build command arguments
        var arguments = [
            "--snakefile", workflow.path.path,
            "--directory", workDir.path,
            "--cores", "all"
        ]

        // Add container runtime flags
        if let containerArgs = await getContainerArguments() {
            arguments.append(contentsOf: containerArgs)
        }

        // Write config file with parameters
        if !parameters.isEmpty {
            let configFile = workDir.appendingPathComponent("lungfish_config.yaml")
            try writeConfigFile(parameters: parameters, to: configFile)
            arguments.append("--configfile")
            arguments.append(configFile.path)
            Self.logger.debug("Wrote config file: \(configFile.path)")
        }

        // Add printshellcmds for progress tracking
        arguments.append("--printshellcmds")

        // Log file
        let logFile = workDir.appendingPathComponent("snakemake.log")

        Self.logger.info("Executing: snakemake \(arguments.joined(separator: " "))")

        let environment = managedExecutionEnvironment(for: execPath)

        let startTime = Date()

        // Spawn the process
        let handle: ProcessHandle
        do {
            handle = try await baseRunner.processManager.spawn(
                executable: execPath,
                arguments: arguments,
                workingDirectory: workDir,
                environment: environment
            )
        } catch {
            try await stateMachine.markFailed(error: error)
            await baseRunner.unregisterExecution(executionId)
            throw WorkflowError.processError(
                operation: "start Snakemake",
                underlying: error
            )
        }

        // Store process handle
        await baseRunner.setProcessHandle(executionId: executionId, handle: handle)

        Self.logger.info("Snakemake process started with PID \(handle.pid)")

        // Process output streams concurrently
        async let stdoutProcessing: Void = processOutputStream(
            handle.standardOutput,
            executionId: executionId,
            progress: progress,
            isStderr: false
        )

        async let stderrProcessing: Void = processOutputStream(
            handle.standardError,
            executionId: executionId,
            progress: progress,
            isStderr: true
        )

        // Wait for streams to complete
        await stdoutProcessing
        await stderrProcessing

        // Wait for process to complete
        var exitCode: Int32 = -1
        for await code in handle.terminationStream {
            exitCode = code
            break
        }

        let endTime = Date()

        // Collect output
        let stdout = await baseRunner.getStdout(executionId: executionId)
        let stderr = await baseRunner.getStderr(executionId: executionId)

        // Write log file
        try? (stdout + "\n" + stderr).write(to: logFile, atomically: true, encoding: .utf8)

        // Update state
        if exitCode == 0 {
            try await stateMachine.markCompleted()
            Self.logger.info("Snakemake execution completed successfully")
        } else {
            let error = WorkflowError.executionFailed(
                workflowName: workflow.name,
                exitCode: exitCode,
                stderr: stderr,
                logFile: logFile
            )
            try await stateMachine.markFailed(error: error)
            Self.logger.error("Snakemake execution failed with exit code \(exitCode)")
        }

        // Unregister execution
        await baseRunner.unregisterExecution(executionId)

        // Discover output files
        let outputFiles = baseRunner.discoverOutputFiles(
            in: outputDirectory,
            extensions: nil
        )

        let result = WorkflowResult(
            exitCode: exitCode,
            outputFiles: outputFiles,
            outputDirectory: outputDirectory,
            duration: endTime.timeIntervalSince(startTime),
            logFile: logFile,
            stdout: String(stdout.suffix(10000)),
            stderr: String(stderr.suffix(10000)),
            metrics: nil
        )

        if exitCode != 0 {
            throw WorkflowError.executionFailed(
                workflowName: workflow.name,
                exitCode: exitCode,
                stderr: stderr,
                logFile: logFile
            )
        }

        return result
    }

    public func cancel(executionId: UUID) async {
        Self.logger.info("Cancelling execution: \(executionId)")
        await baseRunner.cancelExecution(executionId)
    }

    // MARK: - DAG Generation

    /// Generates a DAG (Directed Acyclic Graph) visualization of the workflow.
    ///
    /// This creates a DOT or image representation of the workflow's rule dependencies.
    ///
    /// - Parameters:
    ///   - workflow: The workflow to visualize
    ///   - parameters: Optional parameters that may affect the DAG
    ///   - format: Output format (default: svg)
    /// - Returns: The DAG visualization data
    public func generateDAG(
        workflow: WorkflowDefinition,
        parameters: WorkflowParameters = WorkflowParameters(),
        format: DAGFormat = .svg
    ) async throws -> Data {
        Self.logger.info("Generating DAG for workflow: \(workflow.name)")

        guard let execPath = executablePath ?? resolveExecutablePath() else {
            throw WorkflowError.engineNotFound(
                engine: "snakemake",
                searchedPaths: getSearchPaths()
            )
        }

        let workDir = workflow.effectiveWorkDirectory

        var arguments = [
            "--snakefile", workflow.path.path,
            "--directory", workDir.path
        ]

        // Add DAG generation flag
        switch format {
        case .dag:
            arguments.append("--dag")
        case .rulegraph:
            arguments.append("--rulegraph")
        case .filegraph:
            arguments.append("--filegraph")
        case .svg, .png:
            arguments.append("--dag")
        }

        // Write config if needed
        if !parameters.isEmpty {
            let configFile = workDir.appendingPathComponent("lungfish_dag_config.yaml")
            try writeConfigFile(parameters: parameters, to: configFile)
            arguments.append("--configfile")
            arguments.append(configFile.path)
        }

        let environment = managedExecutionEnvironment(for: execPath)
        let (exitCode, stdout, stderr) = try await baseRunner.processManager.runAndWait(
            executable: execPath,
            arguments: arguments,
            workingDirectory: workDir,
            environment: environment
        )

        if exitCode != 0 {
            Self.logger.error("DAG generation failed: \(stderr)")
            throw WorkflowError.executionFailed(
                workflowName: workflow.name,
                exitCode: exitCode,
                stderr: stderr,
                logFile: nil
            )
        }

        guard let dotData = stdout.data(using: .utf8) else {
            throw WorkflowError.outputParsingFailed(
                format: "DOT",
                details: "Failed to encode DOT output"
            )
        }

        // Convert DOT to image format if needed
        if format == .svg || format == .png {
            return try await convertDotToFormat(dotData: dotData, format: format)
        }

        return dotData
    }

    // MARK: - Private Methods

    /// Gets container arguments based on available runtime.
    private func getContainerArguments() async -> [String]? {
        // Use the preferred container runtime (Apple Containerization or Docker)
        if let runtime = await ContainerRuntimeFactory.createRuntime() {
            let runtimeType = await runtime.runtimeType
            return runtimeType.snakemakeArguments
        }
        return nil
    }

    /// Writes workflow parameters to a YAML config file.
    private func writeConfigFile(parameters: WorkflowParameters, to url: URL) throws {
        var lines: [String] = ["# Generated by Lungfish Genome Explorer"]

        for (name, value) in parameters {
            let yamlValue = formatYAMLValue(value)
            lines.append("\(name): \(yamlValue)")
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Formats a parameter value for YAML output.
    private func formatYAMLValue(_ value: ParameterValue) -> String {
        switch value {
        case .string(let s):
            if s.contains(":") || s.contains("#") || s.hasPrefix("@") || s.contains("\"") {
                return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
            }
            return s
        case .integer(let i):
            return String(i)
        case .number(let n):
            return String(n)
        case .boolean(let b):
            return b ? "true" : "false"
        case .file(let url):
            return "\"\(url.path)\""
        case .array(let arr):
            let elements = arr.map { formatYAMLValue($0) }
            return "[\(elements.joined(separator: ", "))]"
        case .dictionary(let dict):
            var items: [String] = []
            for (k, v) in dict {
                items.append("\(k): \(formatYAMLValue(v))")
            }
            return "{\(items.joined(separator: ", "))}"
        case .null:
            return "null"
        }
    }

    /// Converts DOT graph data to the specified format.
    private func convertDotToFormat(dotData: Data, format: DAGFormat) async throws -> Data {
        // Try to find graphviz dot command
        let dotPath = baseRunner.processManager.findExecutable(named: "dot")

        guard let path = dotPath else {
            Self.logger.warning("Graphviz not found, returning raw DOT data")
            return dotData
        }

        let formatArg: String
        switch format {
        case .svg:
            formatArg = "-Tsvg"
        case .png:
            formatArg = "-Tpng"
        default:
            return dotData
        }

        // Write DOT data to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let dotFile = tempDir.appendingPathComponent("dag.dot")
        try dotData.write(to: dotFile)

        let outputFile = tempDir.appendingPathComponent("dag.\(format.rawValue)")

        let (exitCode, _, stderr) = try await baseRunner.processManager.runAndWait(
            executable: path,
            arguments: [formatArg, "-o", outputFile.path, dotFile.path],
            workingDirectory: tempDir
        )

        if exitCode != 0 {
            Self.logger.error("Graphviz conversion failed: \(stderr)")
            return dotData
        }

        return try Data(contentsOf: outputFile)
    }

    /// Processes an output stream and parses progress updates.
    private func processOutputStream(
        _ stream: AsyncStream<String>,
        executionId: UUID,
        progress: @escaping @Sendable (WorkflowProgressUpdate) -> Void,
        isStderr: Bool
    ) async {
        for await line in stream {
            if isStderr {
                await baseRunner.recordStderr(executionId: executionId, line: line)
            } else {
                await baseRunner.recordStdout(executionId: executionId, line: line)
            }

            // Parse Snakemake progress lines
            if let update = parseSnakemakeProgress(line) {
                progress(update)
            }
        }
    }

    /// Parses a Snakemake output line for progress information.
    private func parseSnakemakeProgress(_ line: String) -> WorkflowProgressUpdate? {
        // Snakemake outputs lines like:
        // rule rule_name:
        //     input: file1, file2
        //     output: file3
        // Finished job 0.
        // 1 of 10 steps (10%) done

        // Check for rule execution start
        if line.hasPrefix("rule ") {
            let ruleName = line
                .replacingOccurrences(of: "rule ", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)

            return WorkflowProgressUpdate(
                process: ruleName,
                status: .running,
                progress: nil,
                message: "Running rule: \(ruleName)"
            )
        }

        // Check for job completion
        if line.contains("Finished job") {
            return WorkflowProgressUpdate(
                process: "job",
                status: .completed,
                progress: nil,
                message: line.trimmingCharacters(in: .whitespaces)
            )
        }

        // Check for progress percentage
        if line.contains("steps") && line.contains("done") {
            // Pattern: "5 of 10 steps (50%) done"
            if let match = line.range(of: #"(\d+) of (\d+) steps \((\d+)%\)"#, options: .regularExpression) {
                let matched = String(line[match])
                let components = matched.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .filter { !$0.isEmpty }

                if components.count >= 3,
                   let percentage = Double(components[2]) {
                    return WorkflowProgressUpdate(
                        process: "workflow",
                        status: .running,
                        progress: percentage,
                        message: line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        return nil
    }

    /// Gets the search paths for executables.
    private nonisolated func getSearchPaths() -> [String] {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathEnv.components(separatedBy: ":")
    }

    private func resolveExecutablePath() -> URL? {
        preferredExecutablePath()
    }

    private func preferredExecutablePath() -> URL? {
        let home = homeDirectoryProvider()
        let url = CoreToolLocator.executableURL(
            environment: engineType.executableName,
            executableName: engineType.executableName,
            homeDirectory: home
        )
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func managedExecutionEnvironment(for executablePath: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executablePath.deletingLastPathComponent().path):\(existingPath)"
        return environment
    }
}

// MARK: - DAGFormat

/// Output format for Snakemake DAG generation.
public enum DAGFormat: String, Sendable, CaseIterable {
    /// Raw DOT format (Graphviz)
    case dag

    /// Rule dependency graph (DOT format)
    case rulegraph

    /// File dependency graph (DOT format)
    case filegraph

    /// SVG vector graphic
    case svg

    /// PNG raster image
    case png

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .dag: return "Task DAG (DOT)"
        case .rulegraph: return "Rule Graph (DOT)"
        case .filegraph: return "File Graph (DOT)"
        case .svg: return "SVG Image"
        case .png: return "PNG Image"
        }
    }
}
