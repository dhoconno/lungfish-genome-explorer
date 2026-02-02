// NextflowRunner.swift - Nextflow workflow execution engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log

// MARK: - NextflowRunner

/// Actor for executing Nextflow workflows.
///
/// NextflowRunner manages the execution of Nextflow pipelines, handling
/// container runtime selection, parameter injection, and log streaming.
///
/// ## Example
///
/// ```swift
/// let runner = NextflowRunner()
/// await WorkflowRunnerRegistry.shared.register(runner)
///
/// // Check if Nextflow is available
/// if await runner.isAvailable() {
///     let version = await runner.getVersion()
///     print("Nextflow \(version ?? "unknown") is installed")
/// }
///
/// // Execute a workflow
/// let result = try await runner.run(
///     workflow: definition,
///     parameters: params,
///     outputDirectory: outputDir
/// ) { progress in
///     print("Process: \(progress.process), Status: \(progress.status)")
/// }
/// ```
public actor NextflowRunner: WorkflowRunner {

    // MARK: - Properties

    public nonisolated let engineType: WorkflowEngineType = .nextflow

    private static let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "NextflowRunner"
    )

    /// Base workflow runner for common functionality.
    private let baseRunner: BaseWorkflowRunner

    /// Path to the Nextflow executable.
    private var executablePath: URL?

    /// Cached version string.
    private var cachedVersion: String?

    /// Minimum required Nextflow version.
    public static let minimumVersion = "23.04.0"

    // MARK: - Initialization

    /// Creates a new Nextflow runner.
    ///
    /// - Parameter processManager: Optional process manager (defaults to shared)
    public init(processManager: ProcessManager = .shared) {
        self.baseRunner = BaseWorkflowRunner(
            category: "NextflowRunner",
            processManager: processManager
        )
    }

    // MARK: - WorkflowRunner Protocol

    public func isAvailable() async -> Bool {
        Self.logger.debug("Checking Nextflow availability")

        if let path = baseRunner.findEngine(.nextflow) {
            executablePath = path
            Self.logger.info("Nextflow found at \(path.path)")
            return true
        }

        Self.logger.info("Nextflow not found in PATH")
        return false
    }

    public func getVersion() async -> String? {
        if let cached = cachedVersion {
            return cached
        }

        Self.logger.debug("Getting Nextflow version")

        if let version = await baseRunner.getEngineVersion(.nextflow) {
            // Parse version from output like "nextflow version 23.10.0.5889"
            cachedVersion = parseVersion(from: version)
            Self.logger.info("Nextflow version: \(self.cachedVersion ?? "unknown")")
            return cachedVersion
        }

        return nil
    }

    public func run(
        workflow: WorkflowDefinition,
        parameters: WorkflowParameters,
        outputDirectory: URL,
        progress: @escaping @Sendable (WorkflowProgressUpdate) -> Void
    ) async throws -> WorkflowResult {
        Self.logger.info("Starting Nextflow execution for workflow: \(workflow.name)")

        // Ensure Nextflow is available
        guard let execPath = executablePath ?? baseRunner.findEngine(.nextflow) else {
            throw WorkflowError.engineNotFound(
                engine: "nextflow",
                searchedPaths: getSearchPaths()
            )
        }
        executablePath = execPath

        // Validate workflow file exists
        guard FileManager.default.fileExists(atPath: workflow.path.path) else {
            throw WorkflowError.invalidWorkflowDefinition(
                path: workflow.path,
                reason: "Workflow file not found"
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
        var arguments = ["run", workflow.path.path]

        // Add container profile based on available runtime
        if let containerArgs = await getContainerArguments() {
            arguments.append(contentsOf: containerArgs)
        }

        // Add parameters
        let paramArgs = parameters.toNextflowArguments()
        arguments.append(contentsOf: paramArgs)

        // Add work directory
        arguments.append("-work-dir")
        arguments.append(workDir.appendingPathComponent("work").path)

        // Add output directory
        arguments.append("--outdir")
        arguments.append(outputDirectory.path)

        // Enable trace file for progress tracking
        let traceFile = workDir.appendingPathComponent("trace.txt")
        arguments.append("-with-trace")
        arguments.append(traceFile.path)

        // Log file
        let logFile = workDir.appendingPathComponent("nextflow.log")

        Self.logger.info("Executing: nextflow \(arguments.joined(separator: " "))")

        // Prepare environment
        var environment = ProcessInfo.processInfo.environment
        environment["NXF_ANSI_LOG"] = "false"  // Disable ANSI colors

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
                operation: "start Nextflow",
                underlying: error
            )
        }

        // Store process handle
        await baseRunner.setProcessHandle(executionId: executionId, handle: handle)

        Self.logger.info("Nextflow process started with PID \(handle.pid)")

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
            Self.logger.info("Nextflow execution completed successfully")
        } else {
            let error = WorkflowError.executionFailed(
                workflowName: workflow.name,
                exitCode: exitCode,
                stderr: stderr,
                logFile: logFile
            )
            try await stateMachine.markFailed(error: error)
            Self.logger.error("Nextflow execution failed with exit code \(exitCode)")
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
            stdout: String(stdout.suffix(10000)),  // Last ~10KB
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

    // MARK: - Private Methods

    /// Parses the version string from Nextflow output.
    private func parseVersion(from output: String) -> String? {
        // Output format: "nextflow version 23.10.0.5889"
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.lowercased().contains("version") {
                let components = line.components(separatedBy: .whitespaces)
                if let versionIndex = components.firstIndex(of: "version"),
                   versionIndex + 1 < components.count {
                    return components[versionIndex + 1]
                }
                // Try to find version-like pattern
                if let match = line.range(of: #"(\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(line[match])
                }
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gets container arguments based on available runtime.
    private func getContainerArguments() async -> [String]? {
        if let runtime = await ContainerRuntimeFactory.createRuntime() {
            return ["-profile", runtime.nextflowProfile]
        }
        return nil
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

            // Parse Nextflow progress lines
            if let update = parseNextflowProgress(line) {
                progress(update)
            }
        }
    }

    /// Parses a Nextflow output line for progress information.
    private func parseNextflowProgress(_ line: String) -> WorkflowProgressUpdate? {
        // Nextflow outputs lines like:
        // executor >  local (1)
        // [ab/cd1234] process > PROCESS_NAME (1) [100%] 1 of 1

        // Check for process line format
        if line.contains("process >") {
            let processPattern = #"\[([a-f0-9]+/[a-f0-9]+)\]\s*process\s*>\s*(\w+)"#
            if let match = line.range(of: processPattern, options: .regularExpression) {
                let matched = String(line[match])
                let parts = matched.components(separatedBy: ">")
                if parts.count >= 2 {
                    let processName = parts[1].trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces).first ?? "unknown"

                    var status: WorkflowProgressUpdate.ProcessStatus = .running
                    if line.contains("[100%]") {
                        status = .completed
                    } else if line.contains("CACHED") || line.contains("cached") {
                        status = .cached
                    }

                    return WorkflowProgressUpdate(
                        process: processName,
                        status: status,
                        progress: nil,
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
}

// MARK: - ContainerRuntimeFactory

/// Factory for creating container runtimes.
///
/// Provides convenience methods for detecting and selecting container
/// runtimes for workflow execution.
public enum ContainerRuntimeFactory {

    private static let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerRuntimeFactory"
    )

    /// Creates the preferred container runtime for the current system.
    ///
    /// On macOS, prefers Docker if available and running.
    /// On Linux/HPC, prefers Apptainer/Singularity.
    ///
    /// - Returns: The detected runtime, or nil if none available
    public static func createRuntime() async -> ContainerRuntime? {
        logger.info("Detecting container runtime")

        #if os(macOS)
        // On macOS, Docker is preferred for desktop use
        let runtimes = await ContainerRuntime.detect()

        if let docker = runtimes.first(where: { $0.type == .docker && $0.isRunning }) {
            logger.info("Using Docker container runtime")
            return docker
        }

        if let apptainer = runtimes.first(where: { $0.type == .apptainer }) {
            logger.info("Using Apptainer container runtime")
            return apptainer
        }
        #else
        // On Linux/HPC, Apptainer is preferred (rootless)
        let runtimes = await ContainerRuntime.detect()

        if let apptainer = runtimes.first(where: { $0.type == .apptainer }) {
            logger.info("Using Apptainer container runtime")
            return apptainer
        }

        if let docker = runtimes.first(where: { $0.type == .docker && $0.isRunning }) {
            logger.info("Using Docker container runtime")
            return docker
        }
        #endif

        logger.warning("No container runtime detected")
        return nil
    }

    /// Creates a specific container runtime by type.
    ///
    /// - Parameter type: The type of runtime to create
    /// - Returns: The detected runtime, or nil if not available
    public static func createRuntime(type: RuntimeType) async -> ContainerRuntime? {
        logger.info("Looking for \(type.displayName) runtime")

        let runtimes = await ContainerRuntime.detect()
        return runtimes.first { $0.type == type }
    }
}
