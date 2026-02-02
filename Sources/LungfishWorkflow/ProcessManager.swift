// ProcessManager.swift - Process management for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log

// MARK: - ProcessHandle

/// A handle to a running process.
///
/// ProcessHandle provides an identifier and control interface for
/// a spawned process, including access to its output streams and
/// termination capabilities.
///
/// ## Example
///
/// ```swift
/// let handle = try await ProcessManager.shared.spawn(
///     executable: "/usr/bin/nextflow",
///     arguments: ["run", "pipeline.nf"],
///     workingDirectory: workDir
/// )
///
/// // Stream output
/// for await line in handle.standardOutput {
///     print(line)
/// }
///
/// // Wait for completion
/// let exitCode = await handle.waitForExit()
/// ```
public struct ProcessHandle: Sendable, Identifiable {
    /// Unique identifier for this process handle.
    public let id: UUID

    /// The process identifier (PID).
    public let pid: Int32

    /// The executable path.
    public let executable: URL

    /// The command-line arguments.
    public let arguments: [String]

    /// The working directory.
    public let workingDirectory: URL

    /// When the process was started.
    public let startTime: Date

    /// Stream of standard output lines.
    public let standardOutput: AsyncStream<String>

    /// Stream of standard error lines.
    public let standardError: AsyncStream<String>

    /// Continuation for termination notification.
    internal let terminationContinuation: AsyncStream<Int32>.Continuation

    /// Stream that yields the exit code when the process terminates.
    public let terminationStream: AsyncStream<Int32>

    /// Creates a new process handle.
    internal init(
        id: UUID = UUID(),
        pid: Int32,
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        startTime: Date = Date(),
        standardOutput: AsyncStream<String>,
        standardError: AsyncStream<String>,
        terminationContinuation: AsyncStream<Int32>.Continuation,
        terminationStream: AsyncStream<Int32>
    ) {
        self.id = id
        self.pid = pid
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.startTime = startTime
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationContinuation = terminationContinuation
        self.terminationStream = terminationStream
    }

    /// The full command line as a string.
    public var commandLine: String {
        ([executable.path] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// How long the process has been running.
    public var runningDuration: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

// MARK: - ProcessManaging Protocol

/// Protocol for process management operations.
///
/// This protocol defines the interface for spawning and managing
/// external processes. Use this for dependency injection in tests.
public protocol ProcessManaging: Actor {
    /// Spawns a new process.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Working directory for the process
    ///   - environment: Additional environment variables
    /// - Returns: A handle to the running process
    /// - Throws: `WorkflowError.processError` if spawn fails
    func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?
    ) async throws -> ProcessHandle

    /// Terminates a running process.
    ///
    /// - Parameter id: The process handle ID
    func terminate(id: UUID) async

    /// Terminates all running processes.
    func terminateAll() async

    /// Gets the current status of a process.
    ///
    /// - Parameter id: The process handle ID
    /// - Returns: True if the process is still running
    func isRunning(id: UUID) -> Bool
}

// MARK: - ProcessManager Actor

/// Singleton actor for managing external process execution.
///
/// ProcessManager provides a thread-safe interface for spawning,
/// monitoring, and terminating external processes. It uses Foundation's
/// Process (NSTask) under the hood.
///
/// ## Features
///
/// - Real-time stdout/stderr streaming via AsyncStream
/// - Automatic cleanup of terminated processes
/// - Graceful and forced termination support
/// - Environment variable injection
/// - Working directory configuration
///
/// ## Usage
///
/// ```swift
/// let manager = ProcessManager.shared
///
/// // Spawn a process
/// let handle = try await manager.spawn(
///     executable: URL(fileURLWithPath: "/usr/bin/nextflow"),
///     arguments: ["run", "main.nf", "--input", "data.csv"],
///     workingDirectory: pipelineDir
/// )
///
/// // Process output in parallel
/// async let stdout: Void = {
///     for await line in handle.standardOutput {
///         print("[stdout] \(line)")
///     }
/// }()
///
/// async let stderr: Void = {
///     for await line in handle.standardError {
///         print("[stderr] \(line)")
///     }
/// }()
///
/// // Wait for completion
/// await stdout
/// await stderr
/// ```
public actor ProcessManager: ProcessManaging {

    // MARK: - Singleton

    /// Shared singleton instance.
    public static let shared = ProcessManager()

    // MARK: - Properties

    /// Logger for process management events.
    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ProcessManager"
    )

    /// Active processes indexed by handle ID.
    private var activeProcesses: [UUID: ProcessEntry] = [:]

    /// Internal struct to track process state.
    private struct ProcessEntry: @unchecked Sendable {
        let handle: ProcessHandle
        let process: Process
        var stdoutContinuation: AsyncStream<String>.Continuation?
        var stderrContinuation: AsyncStream<String>.Continuation?
    }

    // MARK: - Initialization

    /// Private initializer for singleton pattern.
    private init() {
        logger.debug("ProcessManager initialized")
    }

    // MARK: - Spawn

    /// Spawns a new process.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Working directory for the process
    ///   - environment: Additional environment variables (merged with current environment)
    /// - Returns: A handle to the running process
    /// - Throws: `WorkflowError.processError` if spawn fails
    public func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) async throws -> ProcessHandle {
        let handleId = UUID()

        logger.info(
            "Spawning process: \(executable.path) \(arguments.joined(separator: " "))"
        )

        // Verify executable exists
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            logger.error("Executable not found or not executable: \(executable.path)")
            throw WorkflowError.engineNotFound(
                engine: executable.lastPathComponent,
                searchedPaths: [executable.path]
            )
        }

        // Verify working directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            logger.error("Working directory does not exist: \(workingDirectory.path)")
            throw WorkflowError.invalidWorkingDirectory(path: workingDirectory)
        }

        // Create the process
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Set up environment
        var processEnvironment = ProcessInfo.processInfo.environment
        if let additionalEnv = environment {
            processEnvironment.merge(additionalEnv) { _, new in new }
        }
        process.environment = processEnvironment

        // Set up stdout pipe and stream
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        var stdoutContinuation: AsyncStream<String>.Continuation?
        let stdoutStream = AsyncStream<String> { continuation in
            stdoutContinuation = continuation
        }

        // Set up stderr pipe and stream
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        var stderrContinuation: AsyncStream<String>.Continuation?
        let stderrStream = AsyncStream<String> { continuation in
            stderrContinuation = continuation
        }

        // Set up termination stream
        var terminationContinuation: AsyncStream<Int32>.Continuation!
        let terminationStream = AsyncStream<Int32> { continuation in
            terminationContinuation = continuation
        }

        // Capture the continuation for use in the termination handler
        let capturedTerminationContinuation = terminationContinuation!

        // Start reading stdout asynchronously
        self.setupPipeReader(
            pipe: stdoutPipe,
            continuation: stdoutContinuation
        )

        // Start reading stderr asynchronously
        self.setupPipeReader(
            pipe: stderrPipe,
            continuation: stderrContinuation
        )

        // Set up termination handler
        process.terminationHandler = { [weak self, logger, handleId] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            logger.info("Process \(handleId) terminated with exit code: \(exitCode)")

            capturedTerminationContinuation.yield(exitCode)
            capturedTerminationContinuation.finish()

            // Clean up
            Task { [weak self] in
                await self?.processDidTerminate(handleId: handleId)
            }
        }

        // Create the handle
        let handle = ProcessHandle(
            id: handleId,
            pid: 0, // Will be updated after launch
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            standardOutput: stdoutStream,
            standardError: stderrStream,
            terminationContinuation: terminationContinuation,
            terminationStream: terminationStream
        )

        // Launch the process
        do {
            try process.run()
        } catch {
            logger.error("Failed to launch process: \(error.localizedDescription)")

            // Clean up continuations
            stdoutContinuation?.finish()
            stderrContinuation?.finish()
            terminationContinuation.finish()

            throw WorkflowError.processError(
                operation: "spawn",
                underlying: error
            )
        }

        // Update handle with actual PID and store
        let updatedHandle = ProcessHandle(
            id: handleId,
            pid: process.processIdentifier,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            startTime: handle.startTime,
            standardOutput: stdoutStream,
            standardError: stderrStream,
            terminationContinuation: terminationContinuation,
            terminationStream: terminationStream
        )

        let entry = ProcessEntry(
            handle: updatedHandle,
            process: process,
            stdoutContinuation: stdoutContinuation,
            stderrContinuation: stderrContinuation
        )
        activeProcesses[handleId] = entry

        logger.info(
            "Process spawned successfully: PID=\(process.processIdentifier), handle=\(handleId)"
        )

        return updatedHandle
    }

    /// Sets up asynchronous reading from a pipe.
    private nonisolated func setupPipeReader(
        pipe: Pipe,
        continuation: AsyncStream<String>.Continuation?
    ) {
        let fileHandle = pipe.fileHandleForReading
        let capturedContinuation = continuation

        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData

            if data.isEmpty {
                // EOF reached
                handle.readabilityHandler = nil
                capturedContinuation?.finish()
                return
            }

            if let string = String(data: data, encoding: .utf8) {
                // Split by newlines and yield each line
                let lines = string.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                for line in lines {
                    capturedContinuation?.yield(line)
                }
            }
        }
    }

    /// Called when a process terminates.
    private func processDidTerminate(handleId: UUID) {
        guard let entry = activeProcesses[handleId] else { return }

        // Finish the continuations
        entry.stdoutContinuation?.finish()
        entry.stderrContinuation?.finish()

        // Remove from active processes
        activeProcesses.removeValue(forKey: handleId)

        logger.debug("Cleaned up process entry: \(handleId)")
    }

    // MARK: - Termination

    /// Terminates a running process.
    ///
    /// This sends SIGTERM first, giving the process a chance to clean up.
    /// If the process doesn't terminate within a short period, SIGKILL is sent.
    ///
    /// - Parameter id: The process handle ID
    public func terminate(id: UUID) async {
        guard let entry = activeProcesses[id] else {
            logger.warning("Attempted to terminate unknown process: \(id)")
            return
        }

        let process = entry.process
        let pid = process.processIdentifier

        logger.info("Terminating process: PID=\(pid), handle=\(id)")

        // Send SIGTERM first
        process.terminate()

        // Wait briefly for graceful termination
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Check if still running and force kill if necessary
        if process.isRunning {
            logger.warning("Process \(pid) did not terminate gracefully, sending SIGKILL")
            kill(pid, SIGKILL)
        }

        // Clean up will happen in terminationHandler
    }

    /// Terminates all running processes.
    ///
    /// Use this for cleanup when shutting down the application.
    public func terminateAll() async {
        let processCount = self.activeProcesses.count
        logger.info("Terminating all processes: \(processCount) active")

        let handleIds = Array(activeProcesses.keys)
        for handleId in handleIds {
            await terminate(id: handleId)
        }
    }

    /// Checks if a process is still running.
    ///
    /// - Parameter id: The process handle ID
    /// - Returns: True if the process is still running
    public func isRunning(id: UUID) -> Bool {
        guard let entry = activeProcesses[id] else {
            return false
        }
        return entry.process.isRunning
    }

    // MARK: - Query

    /// Returns all active process handles.
    public var allActiveHandles: [ProcessHandle] {
        activeProcesses.values.map { $0.handle }
    }

    /// Returns the number of active processes.
    public var activeProcessCount: Int {
        activeProcesses.count
    }

    /// Gets a process handle by ID.
    ///
    /// - Parameter id: The handle ID
    /// - Returns: The process handle, or nil if not found
    public func handle(for id: UUID) -> ProcessHandle? {
        activeProcesses[id]?.handle
    }

    /// Gets the exit code for a terminated process.
    ///
    /// - Parameter id: The handle ID
    /// - Returns: The exit code, or nil if process is still running or not found
    public func exitCode(for id: UUID) -> Int32? {
        guard let entry = activeProcesses[id] else {
            return nil
        }

        if entry.process.isRunning {
            return nil
        }

        return entry.process.terminationStatus
    }
}

// MARK: - ProcessHandle Extensions

extension ProcessHandle {
    /// Waits for the process to exit and returns the exit code.
    ///
    /// - Returns: The process exit code
    public func waitForExit() async -> Int32 {
        for await exitCode in terminationStream {
            return exitCode
        }
        return -1 // Should not reach here
    }

    /// Collects all stdout into a single string.
    ///
    /// - Returns: All standard output as a string
    public func collectStdout() async -> String {
        var lines: [String] = []
        for await line in standardOutput {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Collects all stderr into a single string.
    ///
    /// - Returns: All standard error as a string
    public func collectStderr() async -> String {
        var lines: [String] = []
        for await line in standardError {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Convenience Functions

extension ProcessManager {
    /// Spawns a process and waits for completion.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Working directory for the process
    ///   - environment: Additional environment variables
    /// - Returns: A tuple of (exitCode, stdout, stderr)
    /// - Throws: `WorkflowError.processError` if spawn fails
    public func runAndWait(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let handle = try await spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )

        // Collect output in parallel
        async let stdoutTask = handle.collectStdout()
        async let stderrTask = handle.collectStderr()
        async let exitCodeTask = handle.waitForExit()

        let stdout = await stdoutTask
        let stderr = await stderrTask
        let exitCode = await exitCodeTask

        return (exitCode, stdout, stderr)
    }

    /// Checks if an executable is available in PATH.
    ///
    /// - Parameter name: The executable name
    /// - Returns: The full path to the executable, or nil if not found
    public nonisolated func findExecutable(named name: String) -> URL? {
        // Check common locations first
        let commonPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin"
        ]

        for basePath in commonPaths {
            let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath.path) {
                return fullPath
            }
        }

        // Check PATH environment variable
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathEnv.split(separator: ":").map(String.init)
            for pathDir in paths {
                let fullPath = URL(fileURLWithPath: pathDir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: fullPath.path) {
                    return fullPath
                }
            }
        }

        return nil
    }
}
