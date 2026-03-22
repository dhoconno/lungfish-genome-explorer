// WorkflowRunner.swift - Base execution infrastructure for workflows
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log
import LungfishCore

// MARK: - WorkflowResult

/// The result of a completed workflow execution.
///
/// WorkflowResult contains the exit code, output files, and other
/// information from a completed workflow run.
public struct WorkflowResult: Sendable {
    /// The exit code from the workflow process.
    public let exitCode: Int32

    /// Whether the workflow completed successfully (exit code 0).
    public var isSuccess: Bool {
        exitCode == 0
    }

    /// Output files produced by the workflow.
    public let outputFiles: [URL]

    /// The output directory.
    public let outputDirectory: URL

    /// Total execution duration.
    public let duration: TimeInterval

    /// Log file path.
    public let logFile: URL?

    /// Standard output (last N lines).
    public let stdout: String

    /// Standard error (last N lines).
    public let stderr: String

    /// Process metrics (CPU, memory, etc.) if available.
    public let metrics: ExecutionMetrics?

    /// Creates a new workflow result.
    public init(
        exitCode: Int32,
        outputFiles: [URL],
        outputDirectory: URL,
        duration: TimeInterval,
        logFile: URL? = nil,
        stdout: String = "",
        stderr: String = "",
        metrics: ExecutionMetrics? = nil
    ) {
        self.exitCode = exitCode
        self.outputFiles = outputFiles
        self.outputDirectory = outputDirectory
        self.duration = duration
        self.logFile = logFile
        self.stdout = stdout
        self.stderr = stderr
        self.metrics = metrics
    }
}

// MARK: - ExecutionMetrics

/// Metrics collected during workflow execution.
public struct ExecutionMetrics: Sendable, Codable {
    /// Peak memory usage in bytes.
    public var peakMemoryBytes: UInt64?

    /// Total CPU time in seconds.
    public var cpuTimeSeconds: Double?

    /// Number of processes spawned.
    public var processCount: Int?

    /// Total data read in bytes.
    public var bytesRead: UInt64?

    /// Total data written in bytes.
    public var bytesWritten: UInt64?

    /// Creates empty metrics.
    public init() {}
}

// MARK: - WorkflowProgressUpdate

/// A progress update from a running workflow.
///
/// Progress updates are emitted during workflow execution to provide
/// real-time feedback on execution status.
public struct WorkflowProgressUpdate: Sendable {
    /// The process or task name.
    public let process: String

    /// Current status of the process.
    public let status: ProcessStatus

    /// Progress percentage (0-100) if known.
    public let progress: Double?

    /// Human-readable message.
    public let message: String?

    /// When this update was generated.
    public let timestamp: Date

    /// Process status values.
    public enum ProcessStatus: String, Sendable {
        case pending
        case submitted
        case running
        case completed
        case failed
        case cached
    }

    /// Creates a new progress update.
    public init(
        process: String,
        status: ProcessStatus,
        progress: Double? = nil,
        message: String? = nil,
        timestamp: Date = Date()
    ) {
        self.process = process
        self.status = status
        self.progress = progress
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - WorkflowRunner Protocol

/// Protocol for workflow execution engines.
///
/// WorkflowRunner defines the interface for running workflows with
/// different execution engines (Nextflow, Snakemake, etc.). Each
/// engine implementation provides its own runner conforming to this
/// protocol.
///
/// ## Implementation Example
///
/// ```swift
/// actor NextflowRunner: WorkflowRunner {
///     nonisolated let engineType: WorkflowEngineType = .nextflow
///
///     func isAvailable() async -> Bool {
///         // Check if nextflow is installed
///     }
///
///     func run(
///         workflow: WorkflowDefinition,
///         parameters: WorkflowParameters,
///         progress: @escaping (WorkflowProgressUpdate) -> Void
///     ) async throws -> WorkflowResult {
///         // Execute the workflow
///     }
/// }
/// ```
public protocol WorkflowRunner: Actor {
    /// The workflow engine type this runner handles.
    nonisolated var engineType: WorkflowEngineType { get }

    /// Checks if the workflow engine is available on the system.
    ///
    /// - Returns: True if the engine executable is found and runnable
    func isAvailable() async -> Bool

    /// Gets the version of the installed workflow engine.
    ///
    /// - Returns: Version string, or nil if not available
    func getVersion() async -> String?

    /// Runs a workflow with the given parameters.
    ///
    /// - Parameters:
    ///   - workflow: The workflow definition to execute
    ///   - parameters: Parameters to pass to the workflow
    ///   - outputDirectory: Directory for workflow outputs
    ///   - progress: Callback for progress updates
    /// - Returns: The workflow result
    /// - Throws: `WorkflowError` if execution fails
    func run(
        workflow: WorkflowDefinition,
        parameters: WorkflowParameters,
        outputDirectory: URL,
        progress: @escaping @Sendable (WorkflowProgressUpdate) -> Void
    ) async throws -> WorkflowResult

    /// Cancels a running workflow execution.
    ///
    /// - Parameter executionId: The execution ID to cancel
    func cancel(executionId: UUID) async
}

// MARK: - BaseWorkflowRunner

/// Base actor implementation for workflow runners.
///
/// BaseWorkflowRunner provides common functionality shared by all
/// workflow engine implementations, including process management,
/// state tracking, and logging.
///
/// ## Subclassing
///
/// Engine-specific runners should use BaseWorkflowRunner's functionality
/// while implementing engine-specific execution logic.
public actor BaseWorkflowRunner {

    // MARK: - Properties

    /// Logger for workflow runner events.
    public let logger: Logger

    /// The process manager for spawning processes.
    public let processManager: ProcessManager

    /// Active executions indexed by execution ID.
    private var activeExecutions: [UUID: ExecutionContext] = [:]

    /// Internal context for tracking execution state.
    private struct ExecutionContext {
        let workflowId: UUID
        let stateMachine: WorkflowStateMachine
        var processHandle: ProcessHandle?
        var outputCollector: OutputCollector
    }

    /// Collects and buffers output from workflow execution.
    private struct OutputCollector {
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        let maxLines: Int = 1000

        mutating func appendStdout(_ line: String) {
            stdoutLines.append(line)
            if stdoutLines.count > maxLines {
                stdoutLines.removeFirst()
            }
        }

        mutating func appendStderr(_ line: String) {
            stderrLines.append(line)
            if stderrLines.count > maxLines {
                stderrLines.removeFirst()
            }
        }
    }

    // MARK: - Initialization

    /// Creates a new base workflow runner.
    ///
    /// - Parameters:
    ///   - category: Logger category name
    ///   - processManager: Process manager instance (defaults to shared)
    public init(
        category: String,
        processManager: ProcessManager = .shared
    ) {
        self.logger = Logger(
            subsystem: LogSubsystem.workflow,
            category: category
        )
        self.processManager = processManager

        logger.debug("BaseWorkflowRunner initialized")
    }

    // MARK: - Execution Management

    /// Registers a new execution.
    ///
    /// - Parameter workflowId: The workflow ID being executed
    /// - Returns: A tuple of (execution ID, state machine)
    public func registerExecution(workflowId: UUID) -> (UUID, WorkflowStateMachine) {
        let executionId = UUID()
        let stateMachine = WorkflowStateMachine()

        let context = ExecutionContext(
            workflowId: workflowId,
            stateMachine: stateMachine,
            processHandle: nil,
            outputCollector: OutputCollector()
        )

        activeExecutions[executionId] = context

        logger.info("Registered execution: \(executionId) for workflow: \(workflowId)")

        return (executionId, stateMachine)
    }

    /// Updates the process handle for an execution.
    ///
    /// - Parameters:
    ///   - executionId: The execution ID
    ///   - handle: The process handle
    public func setProcessHandle(executionId: UUID, handle: ProcessHandle) {
        activeExecutions[executionId]?.processHandle = handle
        logger.debug("Set process handle for execution: \(executionId)")
    }

    /// Gets the state machine for an execution.
    ///
    /// - Parameter executionId: The execution ID
    /// - Returns: The state machine, or nil if not found
    public func stateMachine(for executionId: UUID) -> WorkflowStateMachine? {
        activeExecutions[executionId]?.stateMachine
    }

    /// Records stdout output for an execution.
    public func recordStdout(executionId: UUID, line: String) {
        activeExecutions[executionId]?.outputCollector.appendStdout(line)
    }

    /// Records stderr output for an execution.
    public func recordStderr(executionId: UUID, line: String) {
        activeExecutions[executionId]?.outputCollector.appendStderr(line)
    }

    /// Gets collected stdout for an execution.
    public func getStdout(executionId: UUID) -> String {
        activeExecutions[executionId]?.outputCollector.stdoutLines.joined(separator: "\n") ?? ""
    }

    /// Gets collected stderr for an execution.
    public func getStderr(executionId: UUID) -> String {
        activeExecutions[executionId]?.outputCollector.stderrLines.joined(separator: "\n") ?? ""
    }

    /// Removes a completed execution from tracking.
    ///
    /// - Parameter executionId: The execution ID
    public func unregisterExecution(_ executionId: UUID) {
        activeExecutions.removeValue(forKey: executionId)
        logger.debug("Unregistered execution: \(executionId)")
    }

    /// Cancels an execution by terminating its process.
    ///
    /// - Parameter executionId: The execution ID
    public func cancelExecution(_ executionId: UUID) async {
        guard let context = activeExecutions[executionId] else {
            logger.warning("Attempted to cancel unknown execution: \(executionId)")
            return
        }

        logger.info("Cancelling execution: \(executionId)")

        // Mark as cancelled in state machine
        do {
            try await context.stateMachine.markCancelled(reason: .userRequested)
        } catch {
            logger.error("Failed to mark execution as cancelled: \(error.localizedDescription)")
        }

        // Terminate the process
        if let handle = context.processHandle {
            await processManager.terminate(id: handle.id)
        }
    }

    /// Gets all active execution IDs.
    public var activeExecutionIds: [UUID] {
        Array(activeExecutions.keys)
    }

    /// Gets the number of active executions.
    public var activeExecutionCount: Int {
        activeExecutions.count
    }

    // MARK: - Engine Discovery

    /// Finds the executable path for a workflow engine.
    ///
    /// - Parameter engine: The engine type
    /// - Returns: The executable URL, or nil if not found
    public nonisolated func findEngine(_ engine: WorkflowEngineType) -> URL? {
        processManager.findExecutable(named: engine.executableName)
    }

    /// Gets the version of an installed engine.
    ///
    /// - Parameter engine: The engine type
    /// - Returns: The version string, or nil if not available
    public func getEngineVersion(_ engine: WorkflowEngineType) async -> String? {
        guard let executablePath = findEngine(engine) else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory

        do {
            let (exitCode, stdout, _) = try await processManager.runAndWait(
                executable: executablePath,
                arguments: ["-version"],
                workingDirectory: tempDir
            )

            if exitCode == 0 {
                // Extract version from first line
                let firstLine = stdout.components(separatedBy: .newlines).first ?? ""
                return firstLine.trimmingCharacters(in: .whitespaces)
            }
        } catch {
            logger.error("Failed to get engine version: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Output File Discovery

    /// Discovers output files in a directory.
    ///
    /// - Parameters:
    ///   - directory: The output directory
    ///   - extensions: File extensions to look for (nil = all files)
    /// - Returns: Array of discovered file URLs
    public nonisolated func discoverOutputFiles(
        in directory: URL,
        extensions: Set<String>? = nil
    ) -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []

        while let url = enumerator.nextObject() as? URL {
            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            if let validExtensions = extensions {
                if validExtensions.contains(url.pathExtension.lowercased()) {
                    files.append(url)
                }
            } else {
                files.append(url)
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Directory Setup

    /// Creates required directories for workflow execution.
    ///
    /// - Parameters:
    ///   - outputDirectory: Output directory path
    ///   - logDirectory: Log directory path
    ///   - workDirectory: Working directory path
    /// - Throws: If directory creation fails
    public nonisolated func setupDirectories(
        outputDirectory: URL,
        logDirectory: URL?,
        workDirectory: URL
    ) throws {
        let fileManager = FileManager.default

        // Create output directory
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // Create log directory
        if let logDir = logDirectory {
            try fileManager.createDirectory(
                at: logDir,
                withIntermediateDirectories: true
            )
        }

        // Create work directory if needed
        if !fileManager.fileExists(atPath: workDirectory.path) {
            try fileManager.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Logging

    /// Writes a log entry to a file for an execution.
    ///
    /// - Parameters:
    ///   - logFile: The log file URL
    ///   - message: The log message
    ///   - level: Log level (info, warning, error)
    public nonisolated func writeLogEntry(
        to logFile: URL,
        message: String,
        level: OSLogType = .info
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelString: String
        switch level {
        case .error: levelString = "ERROR"
        case .fault: levelString = "FAULT"
        case .debug: levelString = "DEBUG"
        default: levelString = "INFO"
        }

        let logLine = "[\(timestamp)] [\(levelString)] \(message)\n"

        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}

// MARK: - WorkflowRunnerRegistry

/// Registry for workflow runners.
///
/// The registry maintains a collection of available workflow runners
/// and provides lookup by engine type.
public actor WorkflowRunnerRegistry {

    // MARK: - Singleton

    /// Shared registry instance.
    public static let shared = WorkflowRunnerRegistry()

    // MARK: - Properties

    /// Logger for registry events.
    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "WorkflowRunnerRegistry"
    )

    /// Registered runners by engine type.
    private var runners: [WorkflowEngineType: any WorkflowRunner] = [:]

    // MARK: - Initialization

    private init() {
        logger.debug("WorkflowRunnerRegistry initialized")
    }

    // MARK: - Registration

    /// Registers a workflow runner.
    ///
    /// - Parameter runner: The runner to register
    public func register(_ runner: any WorkflowRunner) {
        let engineType = runner.engineType
        runners[engineType] = runner
        logger.info("Registered runner for engine: \(engineType.rawValue)")
    }

    /// Unregisters a workflow runner.
    ///
    /// - Parameter engineType: The engine type to unregister
    public func unregister(_ engineType: WorkflowEngineType) {
        runners.removeValue(forKey: engineType)
        logger.info("Unregistered runner for engine: \(engineType.rawValue)")
    }

    // MARK: - Lookup

    /// Gets the runner for an engine type.
    ///
    /// - Parameter engineType: The engine type
    /// - Returns: The registered runner, or nil if not found
    public func runner(for engineType: WorkflowEngineType) -> (any WorkflowRunner)? {
        runners[engineType]
    }

    /// Gets the runner for a workflow definition.
    ///
    /// - Parameter workflow: The workflow definition
    /// - Returns: The appropriate runner, or nil if not found
    public func runner(for workflow: WorkflowDefinition) -> (any WorkflowRunner)? {
        runners[workflow.engineType]
    }

    /// All registered engine types.
    public var registeredEngines: [WorkflowEngineType] {
        Array(runners.keys)
    }

    /// Checks if a runner is available for an engine type.
    ///
    /// - Parameter engineType: The engine type
    /// - Returns: True if a runner is registered
    public func hasRunner(for engineType: WorkflowEngineType) -> Bool {
        runners[engineType] != nil
    }

    /// Gets all available runners (those with engines installed).
    ///
    /// - Returns: Array of available runners
    public func availableRunners() async -> [any WorkflowRunner] {
        var available: [any WorkflowRunner] = []

        for runner in runners.values {
            if await runner.isAvailable() {
                available.append(runner)
            }
        }

        return available
    }
}
