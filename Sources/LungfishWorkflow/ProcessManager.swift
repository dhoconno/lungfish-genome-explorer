// ProcessManager.swift - Process management for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log
import LungfishCore
import Synchronization

// MARK: - ProcessManager Actor

/// Singleton actor for managing external process execution.
///
/// ProcessManager provides a thread-safe interface for spawning,
/// monitoring, and terminating external processes, mostly the Nextflow and
/// Snakemake engines. Every process runs on ``ToolProcess``, so it is the
/// leader of its own process group, its output is read until end of file,
/// and stopping it stops its whole tree.
///
/// ## Features
///
/// - Real-time stdout/stderr streaming via AsyncStream
/// - Automatic cleanup of terminated processes
/// - Graceful and forced termination of the whole process tree
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

    // MARK: - Policy

    /// The status a spawned handle reports when the process exited cleanly
    /// but its output is incomplete, because a child process, such as a
    /// daemon or JVM child of Nextflow or Snakemake, kept the output open
    /// past ToolProcess's drain grace period or reading it failed. It is the
    /// value `ProcessHandle.waitForExit()` already uses for "no exit status".
    static let incompleteOutputStatus: Int32 = -1

    // MARK: - Properties

    /// Logger for process management events.
    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "ProcessManager"
    )

    /// Active processes indexed by handle ID.
    private var activeProcesses: [UUID: ProcessEntry] = [:]

    /// A running process, its ToolProcess handle and the task that turns its
    /// result into the outcome.
    private struct ProcessEntry: Sendable {
        let handle: ProcessHandle
        let run: ToolProcessRun
        let outcome: Task<ProcessRunOutcome, Never>
        let record: ProcessRunRecord
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
    /// - Returns: A handle to the running process. Its streams deliver every
    ///   nonempty line, and `waitForExit()` returns the exit status once the
    ///   output is drained, or ``incompleteOutputStatus`` for a clean exit
    ///   whose output a child process kept open.
    /// - Throws: `WorkflowError.processError` if spawn fails
    public func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) async throws -> ProcessHandle {
        try await spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            drainGracePeriod: nil
        )
    }

    /// ``spawn(executable:arguments:workingDirectory:environment:)`` with the
    /// drain grace period set, or ToolProcess's default when it is nil.
    func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?,
        drainGracePeriod: Duration?
    ) async throws -> ProcessHandle {
        try await launch(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            keepsOutput: false,
            drainGracePeriod: drainGracePeriod
        ).handle
    }

    /// Starts a process with ``ToolProcess/start(_:onEvent:onLaunch:)`` and
    /// returns once it has launched, with the task that waits for its outcome.
    ///
    /// With `keepsOutput` the output is kept whole for ``runAndWait`` and the
    /// handle's streams stay empty. Without it the output is streamed line by
    /// line into the handle and not kept, because an engine can run for hours.
    private func launch(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?,
        keepsOutput: Bool,
        drainGracePeriod: Duration?
    ) async throws -> ProcessEntry {
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

        let output: ToolProcessOutput = keepsOutput ? .capture() : .capture(limit: 0)
        var spec = ToolProcessSpec(
            executableURL: executable,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(overriding: environment ?? [:]),
            workingDirectory: workingDirectory,
            stdout: output,
            stderr: output,
            label: executable.lastPathComponent
        )
        if let drainGracePeriod {
            spec.drainGracePeriod = drainGracePeriod
        }

        let (stdoutStream, stdoutContinuation) = AsyncStream.makeStream(of: String.self)
        let (stderrStream, stderrContinuation) = AsyncStream.makeStream(of: String.self)
        let (terminationStream, terminationContinuation) = AsyncStream.makeStream(of: Int32.self)
        let bridge = ProcessStreamBridge(
            stdout: stdoutContinuation,
            stderr: stderrContinuation,
            termination: terminationContinuation,
            streamsLines: !keepsOutput
        )
        let record = ProcessRunRecord()
        let startTime = Date()

        var onEvent: (@Sendable (ToolProcessEvent) -> Void)?
        if bridge.streamsLines {
            onEvent = { event in bridge.deliver(event) }
        }
        let run: ToolProcessRun
        let pid: Int32
        do {
            run = try ToolProcess.start(spec, onEvent: onEvent)
            guard let launched = run.pid else {
                // Nothing launched, so the run's error is the launch failure.
                _ = try await run.result()
                throw ToolProcessError.launchFailed(label: spec.label, reason: "No process was launched.", results: [])
            }
            pid = launched
        } catch {
            logger.error("Failed to launch process: \(error.localizedDescription)")
            throw WorkflowError.processError(
                operation: "spawn",
                underlying: error
            )
        }

        let handle = ProcessHandle(
            id: handleId,
            pid: pid,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            startTime: startTime,
            standardOutput: stdoutStream,
            standardError: stderrStream,
            terminationContinuation: terminationContinuation,
            terminationStream: terminationStream
        )
        let outcome = Task.detached(priority: Task.currentPriority) {
            await Self.outcome(of: run, label: spec.label, bridge: bridge, record: record)
        }
        let entry = ProcessEntry(handle: handle, run: run, outcome: outcome, record: record)
        activeProcesses[handleId] = entry

        // Registered first, so the cleanup always finds the entry.
        Task { [weak self] in
            _ = await outcome.value
            await self?.processDidTerminate(handleId: handleId)
        }

        logger.info(
            "Process spawned successfully: PID=\(pid), handle=\(handleId)"
        )

        return entry
    }

    /// Waits for a run to end and feeds the handle's streams. Never isolated
    /// to the actor, so output is never queued behind it.
    private nonisolated static func outcome(
        of run: ToolProcessRun,
        label: String,
        bridge: ProcessStreamBridge,
        record: ProcessRunRecord
    ) async -> ProcessRunOutcome {
        let logger = Logger(subsystem: LogSubsystem.workflow, category: "ProcessManager")
        let result: ToolProcessResult
        do {
            result = try await run.result()
        } catch {
            // A cancelled or stopped run still reports how the process ended.
            let results: [ToolProcessResult]
            switch error {
            case .cancelled(let stopped), .timedOut(_, let stopped), .launchFailed(_, _, let stopped):
                results = stopped
            case .invalidSpec:
                results = []
            }
            guard let first = results.first else {
                bridge.finish(status: nil)
                record.finish(status: -1)
                return ProcessRunOutcome(status: -1, stdout: Data(), stderr: Data(), incompleteOutput: nil)
            }
            result = first
        }

        // A run that was stopped on purpose is cut short by design, so only a
        // run that ended by itself reports incomplete output.
        let incomplete = result.stop == nil ? result.incompleteOutputReason : nil
        var reported = result.status
        if let incomplete {
            logger.error("\(incomplete, privacy: .public)")
            bridge.deliverNotice(incomplete)
            if result.termination == .exited(code: 0) {
                reported = Self.incompleteOutputStatus
            }
        }
        record.finish(status: reported)
        bridge.finish(status: reported)
        logger.info("\(label, privacy: .public) (pid \(result.pid)) finished with status \(reported)")
        return ProcessRunOutcome(
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            incompleteOutput: incomplete
        )
    }

    /// Called when a process has finished and its output is drained.
    private func processDidTerminate(handleId: UUID) {
        guard activeProcesses.removeValue(forKey: handleId) != nil else { return }
        logger.debug("Cleaned up process entry: \(handleId)")
    }

    // MARK: - Termination

    /// Terminates a running process and its whole tree.
    ///
    /// This sends SIGTERM to the process group and every descendant, then
    /// SIGKILL to whatever is left after a short grace period, and returns
    /// once the process has ended.
    ///
    /// - Parameter id: The process handle ID
    public func terminate(id: UUID) async {
        guard let entry = activeProcesses[id] else {
            logger.warning("Attempted to terminate unknown process: \(id)")
            return
        }

        logger.info("Terminating process: PID=\(entry.handle.pid), handle=\(id)")

        // Cancelling the run stops the process group and the descendant tree.
        entry.run.cancel()
        _ = await entry.outcome.value
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
        return entry.record.status == nil
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
        activeProcesses[id]?.record.status
    }
}

// MARK: - Run plumbing

/// What one ProcessManager run ended with.
struct ProcessRunOutcome: Sendable {
    /// The exit code, or the signal number for a process a signal ended.
    let status: Int32
    /// Captured standard output, kept only for ``ProcessManager/runAndWait``.
    let stdout: Data
    /// Captured standard error, kept only for ``ProcessManager/runAndWait``.
    let stderr: Data
    /// Why the output is incomplete, or nil when it is complete.
    let incompleteOutput: String?
}

/// Feeds a handle's three streams from a run's events.
private struct ProcessStreamBridge: Sendable {
    let stdout: AsyncStream<String>.Continuation
    let stderr: AsyncStream<String>.Continuation
    let termination: AsyncStream<Int32>.Continuation
    let streamsLines: Bool

    /// Empty lines are dropped, as they always were.
    func deliver(_ event: ToolProcessEvent) {
        guard case .output(let stream, let line) = event, !line.isEmpty else { return }
        switch stream {
        case .stdout: stdout.yield(line)
        case .stderr: stderr.yield(line)
        }
    }

    /// Tells a reader of the error stream why the output stopped short.
    func deliverNotice(_ notice: String) {
        guard streamsLines else { return }
        stderr.yield(notice)
    }

    /// Ends the output streams, then reports the status, if there is one.
    func finish(status: Int32?) {
        stdout.finish()
        stderr.finish()
        if let status {
            termination.yield(status)
        }
        termination.finish()
    }
}

/// The status of a run once it has ended, readable without waiting.
private final class ProcessRunRecord: Sendable {
    private let finishedStatus = Mutex<Int32?>(nil)

    var status: Int32? {
        finishedStatus.withLock { $0 }
    }

    func finish(status: Int32) {
        finishedStatus.withLock { $0 = status }
    }
}

/// The output of a ``ProcessManager/runAndWait`` run was cut short.
struct ProcessOutputIncompleteError: LocalizedError, Sendable {
    let reason: String

    var errorDescription: String? { reason }
}

// MARK: - Convenience Functions

extension ProcessManager {
    /// Spawns a process and waits for completion.
    ///
    /// The output is every nonempty line of each stream, joined with "\n".
    /// Blank lines and a trailing line break are not kept.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Working directory for the process
    ///   - environment: Additional environment variables
    /// - Returns: A tuple of (exitCode, stdout, stderr)
    /// - Throws: `WorkflowError.processError` if spawn fails, or if the output
    ///   is incomplete because a child process kept it open after the process
    ///   exited. `CancellationError` when the calling task is cancelled.
    public func runAndWait(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await runAndWait(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            drainGracePeriod: nil
        )
    }

    /// ``runAndWait(executable:arguments:workingDirectory:environment:)``
    /// with the drain grace period set, or ToolProcess's default when it is nil.
    func runAndWait(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?,
        drainGracePeriod: Duration?
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try Task.checkCancellation()
        let launched = try await launch(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            keepsOutput: true,
            drainGracePeriod: drainGracePeriod
        )
        // The handler runs at once when the caller was cancelled during the
        // launch, so no cancellation is lost between the check and here.
        let outcome = await withTaskCancellationHandler {
            await launched.outcome.value
        } onCancel: {
            launched.run.cancel()
        }

        try Task.checkCancellation()
        if let reason = outcome.incompleteOutput {
            throw WorkflowError.processError(
                operation: "read the output of \(executable.lastPathComponent)",
                underlying: ProcessOutputIncompleteError(reason: reason)
            )
        }
        return (
            outcome.status,
            Self.joinedNonemptyLines(outcome.stdout),
            Self.joinedNonemptyLines(outcome.stderr)
        )
    }

    /// Splits output into lines at LF, CR and CRLF, drops the empty ones and
    /// joins the rest with "\n". Each line decodes as UTF-8, with invalid
    /// bytes replaced. This is the text `runAndWait` has always returned.
    nonisolated static func joinedNonemptyLines(_ data: Data) -> String {
        var lines: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            var index = 0
            func appendLine(_ end: Int) {
                guard end > start else { return }
                let line = Data(bytes[start..<end])
                lines.append(String(data: line, encoding: .utf8) ?? String(decoding: line, as: UTF8.self))
            }
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == 0x0A || byte == 0x0D else {
                    index += 1
                    continue
                }
                appendLine(index)
                index += 1
                if byte == 0x0D, index < bytes.count, bytes[index] == 0x0A {
                    index += 1
                }
                start = index
            }
            appendLine(bytes.count)
        }
        return lines.joined(separator: "\n")
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
