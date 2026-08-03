// ProcessManager.swift - Process management for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log
import LungfishCore
import Darwin

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
        subsystem: LogSubsystem.workflow,
        category: "ProcessManager"
    )

    /// Active processes indexed by handle ID.
    private var activeProcesses: [UUID: ProcessEntry] = [:]

    /// Internal struct to track process state.
    private struct ProcessEntry: @unchecked Sendable {
        let handle: ProcessHandle
        let process: Process
        let stdoutReader: PipeOutputReader
        let stderrReader: PipeOutputReader
    }

    private final class PipeOutputLineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            lock.lock()
            pending.append(data)
            let lines = drainCompleteLines()
            lock.unlock()
            return lines
        }

        func finish() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return [] }
            let line = decodeLine(pending)
            pending.removeAll(keepingCapacity: false)
            return [line]
        }

        private func drainCompleteLines() -> [String] {
            var lines: [String] = []
            while let newlineIndex = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pending[..<newlineIndex]
                lines.append(decodeLineSlice(lineData))

                var removalEnd = pending.index(after: newlineIndex)
                if pending[newlineIndex] == 0x0D,
                   removalEnd < pending.endIndex,
                   pending[removalEnd] == 0x0A {
                    removalEnd = pending.index(after: removalEnd)
                }
                pending.removeSubrange(pending.startIndex..<removalEnd)
            }
            return lines
        }

        private func decodeLineSlice(_ data: Data.SubSequence) -> String {
            decodeLine(Data(data))
        }

        private func decodeLine(_ data: Data) -> String {
            String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }

    private final class PipeOutputReader: @unchecked Sendable {
        private static let callbackReadLimit = 1024 * 1024
        // Darwin's FIONREAD (`_IOR('f', 127, int)`) is not imported into Swift.
        private static let bytesAvailableIOControlRequest: UInt = 0x4004_667F

        private let fileHandle: FileHandle
        private let continuation: AsyncStream<String>.Continuation?
        private let lineBuffer = PipeOutputLineBuffer()
        private let queue = DispatchQueue(label: "org.lungfish.process-output-reader.\(UUID().uuidString)")
        private let schedulingLock = NSLock()
        private var readScheduled = false
        private var isFinished = false

        init(
            pipe: Pipe,
            continuation: AsyncStream<String>.Continuation?
        ) throws {
            self.fileHandle = pipe.fileHandleForReading
            self.continuation = continuation
            let descriptor = fileHandle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0 else {
                throw Self.posixError(operation: "read pipe flags")
            }
            guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw Self.posixError(operation: "enable nonblocking pipe reads")
            }
            fileHandle.readabilityHandler = { [weak self] _ in
                self?.scheduleRead()
            }
        }

        func finishAfterProcessTermination() {
            queue.sync {
                guard !isFinished else { return }
                fileHandle.readabilityHandler = nil
                let availableByteCount = bufferedByteCount()
                if availableByteCount > 0 {
                    _ = drainAvailableData(maximumBytes: availableByteCount)
                }
                finish()
            }
        }

        func cancel() {
            queue.sync {
                guard !isFinished else { return }
                fileHandle.readabilityHandler = nil
                isFinished = true
                continuation?.finish()
            }
        }

        private func scheduleRead() {
            schedulingLock.lock()
            guard !readScheduled else {
                schedulingLock.unlock()
                return
            }
            readScheduled = true
            schedulingLock.unlock()

            queue.async { [weak self] in
                self?.performScheduledRead()
            }
        }

        private func performScheduledRead() {
            guard !isFinished else {
                completeScheduledRead()
                return
            }
            let result = drainAvailableData(maximumBytes: Self.callbackReadLimit)
            completeScheduledRead()
            if result.reachedEOF {
                finish()
            } else if result.exhaustedBudget {
                scheduleRead()
            }
        }

        private func completeScheduledRead() {
            schedulingLock.lock()
            readScheduled = false
            schedulingLock.unlock()
        }

        /// Reads every byte currently available without waiting for a writer
        /// inherited by a detached descendant to close its copy of the pipe.
        private func drainAvailableData(
            maximumBytes: Int
        ) -> (reachedEOF: Bool, exhaustedBudget: Bool) {
            let descriptor = fileHandle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var drainedByteCount = 0

            while drainedByteCount < maximumBytes {
                let requestedByteCount = min(buffer.count, maximumBytes - drainedByteCount)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, requestedByteCount)
                }
                if count > 0 {
                    consume(Data(buffer.prefix(count)))
                    drainedByteCount += count
                    continue
                }
                if count == 0 {
                    return (true, false)
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return (false, false)
                }

                // The stream cannot surface a read error separately. Complete
                // it with every byte already delivered instead of hanging the
                // workflow indefinitely.
                return (true, false)
            }
            return (false, true)
        }

        private func bufferedByteCount() -> Int {
            var availableByteCount: Int32 = 0
            guard ioctl(
                fileHandle.fileDescriptor,
                Self.bytesAvailableIOControlRequest,
                &availableByteCount
            ) != -1 else {
                return Self.callbackReadLimit
            }
            return max(0, Int(availableByteCount))
        }

        private func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            for line in lineBuffer.append(data) where !line.isEmpty {
                continuation?.yield(line)
            }
        }

        private func finish() {
            guard !isFinished else { return }
            isFinished = true
            fileHandle.readabilityHandler = nil
            for line in lineBuffer.finish() where !line.isEmpty {
                continuation?.yield(line)
            }
            continuation?.finish()
        }

        private static func posixError(operation: String) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(errno)))"]
            )
        }
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
        let (terminationStream, terminationContinuation) = AsyncStream.makeStream(of: Int32.self)

        // Capture the continuation for use in the termination handler
        let capturedTerminationContinuation = terminationContinuation

        // Start reading stdout asynchronously
        let stdoutReader: PipeOutputReader
        let stderrReader: PipeOutputReader
        do {
            stdoutReader = try self.setupPipeReader(
                pipe: stdoutPipe,
                continuation: stdoutContinuation
            )
            do {
                stderrReader = try self.setupPipeReader(
                    pipe: stderrPipe,
                    continuation: stderrContinuation
                )
            } catch {
                stdoutReader.cancel()
                throw error
            }
        } catch {
            stdoutContinuation?.finish()
            stderrContinuation?.finish()
            terminationContinuation.finish()
            throw WorkflowError.processError(
                operation: "configure process output pipes",
                underlying: error
            )
        }

        // Set up termination handler
        process.terminationHandler = { [weak self, logger, handleId] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            logger.info("Process \(handleId) terminated with exit code: \(exitCode)")
            NativeProcessRegistry.shared.unregister(terminatedProcess)

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
            stdoutReader.cancel()
            stderrReader.cancel()
            terminationContinuation.finish()

            throw WorkflowError.processError(
                operation: "spawn",
                underlying: error
            )
        }
        NativeProcessRegistry.shared.register(process)

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
            stdoutReader: stdoutReader,
            stderrReader: stderrReader
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
    ) throws -> PipeOutputReader {
        try PipeOutputReader(pipe: pipe, continuation: continuation)
    }

    /// Called when a process terminates.
    private func processDidTerminate(handleId: UUID) {
        guard let entry = activeProcesses[handleId] else { return }
        NativeProcessRegistry.shared.unregister(entry.process)

        // A process can terminate before FileHandle delivers its final
        // readability callback. Drain both pipes explicitly before completing
        // their streams so callers receive every buffered byte without waiting
        // indefinitely for a later EOF notification.
        entry.stdoutReader.finishAfterProcessTermination()
        entry.stderrReader.finishAfterProcessTermination()

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

        ProcessTreeTerminator.terminate(rootProcess: process)

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

private final class RunAndWaitCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: ProcessManager
    private var handleID: UUID?
    private var cancellationRequested = false

    init(manager: ProcessManager) {
        self.manager = manager
    }

    func store(handleID: UUID) {
        let shouldTerminate: Bool
        lock.lock()
        self.handleID = handleID
        shouldTerminate = cancellationRequested
        lock.unlock()

        if shouldTerminate {
            terminate(handleID: handleID)
        }
    }

    func cancel() {
        let id: UUID?
        lock.lock()
        cancellationRequested = true
        id = handleID
        lock.unlock()

        guard let id else { return }
        terminate(handleID: id)
    }

    private func terminate(handleID: UUID) {
        Task {
            await manager.terminate(id: handleID)
        }
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
        let cancellationState = RunAndWaitCancellationState(manager: self)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            let handle = try await spawn(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
            cancellationState.store(handleID: handle.id)
            try Task.checkCancellation()

            // Collect output in parallel
            async let stdoutTask = handle.collectStdout()
            async let stderrTask = handle.collectStderr()
            async let exitCodeTask = handle.waitForExit()

            let stdout = await stdoutTask
            let stderr = await stderrTask
            let exitCode = await exitCodeTask

            try Task.checkCancellation()
            return (exitCode, stdout, stderr)
        } onCancel: {
            cancellationState.cancel()
        }
    }

    /// Checks if an executable is available in PATH.
    ///
    /// - Parameter name: The executable name
    /// - Returns: The full path to the executable, or nil if not found
    public nonisolated func findExecutable(named name: String) -> URL? {
        let fm = FileManager.default

        // Check common locations first
        let commonPaths = [
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]

        for basePath in commonPaths {
            let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: fullPath.path) {
                return fullPath
            }
        }

        let condaEnvsDir = ManagedStorageConfigStore()
            .currentCondaRootURL()
            .appendingPathComponent("envs", isDirectory: true)
        if let envDirs = try? fm.contentsOfDirectory(
            at: condaEnvsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for envDir in envDirs {
                let fullPath = envDir.appendingPathComponent("bin/\(name)")
                if fm.isExecutableFile(atPath: fullPath.path) {
                    return fullPath
                }
            }
        }

        // Check PATH environment variable
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathEnv.split(separator: ":").map(String.init)
            for pathDir in paths {
                let fullPath = URL(fileURLWithPath: pathDir).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: fullPath.path) {
                    return fullPath
                }
            }
        }

        return nil
    }
}
