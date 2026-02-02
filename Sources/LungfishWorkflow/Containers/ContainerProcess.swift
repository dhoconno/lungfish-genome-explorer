// ContainerProcess.swift - Container process model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation

// MARK: - ContainerProcess

/// Represents a process executing inside a container.
///
/// `ContainerProcess` provides a unified interface for managing process execution
/// across different container runtimes. It supports async/await patterns for
/// starting processes, streaming I/O, and waiting for completion.
///
/// ## Process Lifecycle
///
/// 1. Create the process via `runtime.exec(in:command:arguments:environment:workingDirectory:)`
/// 2. Call `start()` to begin execution
/// 3. Optionally stream stdout/stderr via the async streams
/// 4. Call `wait()` to get the exit code
///
/// ## Example Usage
///
/// ```swift
/// // Execute a command
/// let process = try await runtime.exec(
///     in: container,
///     command: "bwa",
///     arguments: ["mem", "ref.fa", "reads.fq"],
///     environment: ["THREADS": "4"],
///     workingDirectory: "/workspace"
/// )
///
/// // Start the process
/// try await process.start()
///
/// // Stream output
/// Task {
///     for await line in process.stdoutLines {
///         print("[stdout] \(line)")
///     }
/// }
///
/// // Wait for completion
/// let exitCode = try await process.wait()
/// print("Process exited with code: \(exitCode)")
/// ```
///
/// ## I/O Streaming
///
/// Both stdout and stderr are provided as `AsyncStream<Data>` for raw bytes
/// or as line-based async sequences via `stdoutLines` and `stderrLines`.
public final class ContainerProcess: Sendable {
    // MARK: - Properties

    /// Unique identifier for this process.
    public let id: String

    /// The command being executed.
    public let command: String

    /// Arguments passed to the command.
    public let arguments: [String]

    /// Environment variables for the process.
    public let environment: [String: String]

    /// Working directory for the process.
    public let workingDirectory: String

    /// The container this process is running in.
    public let containerID: String

    /// Async stream of stdout data.
    public nonisolated var stdout: AsyncStream<Data> {
        _stdoutStream
    }

    /// Async stream of stderr data.
    public nonisolated var stderr: AsyncStream<Data> {
        _stderrStream
    }

    /// Internal storage for stdout stream and continuation.
    private let _stdoutStream: AsyncStream<Data>
    private let _stdoutContinuation: AsyncStream<Data>.Continuation

    /// Internal storage for stderr stream and continuation.
    private let _stderrStream: AsyncStream<Data>
    private let _stderrContinuation: AsyncStream<Data>.Continuation

    /// Callback to start the process (runtime-specific).
    private let startHandler: @Sendable () async throws -> Void

    /// Callback to wait for the process (runtime-specific).
    private let waitHandler: @Sendable () async throws -> Int32

    /// Callback to send signal to the process.
    private let signalHandler: @Sendable (Int32) async throws -> Void

    /// Process state tracking.
    private let stateStorage = ProcessStateStorage()

    // MARK: - Initialization

    /// Creates a new container process.
    ///
    /// This is typically called by runtime implementations.
    ///
    /// - Parameters:
    ///   - id: Unique process identifier
    ///   - command: The command to execute
    ///   - arguments: Command arguments
    ///   - environment: Environment variables
    ///   - workingDirectory: Working directory
    ///   - containerID: ID of the parent container
    ///   - startHandler: Runtime-specific start implementation
    ///   - waitHandler: Runtime-specific wait implementation
    ///   - signalHandler: Runtime-specific signal implementation
    public init(
        id: String = UUID().uuidString,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String = "/",
        containerID: String,
        startHandler: @escaping @Sendable () async throws -> Void,
        waitHandler: @escaping @Sendable () async throws -> Int32,
        signalHandler: @escaping @Sendable (Int32) async throws -> Void = { _ in }
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.containerID = containerID
        self.startHandler = startHandler
        self.waitHandler = waitHandler
        self.signalHandler = signalHandler

        // Create stdout stream
        var stdoutCont: AsyncStream<Data>.Continuation!
        self._stdoutStream = AsyncStream { continuation in
            stdoutCont = continuation
        }
        self._stdoutContinuation = stdoutCont

        // Create stderr stream
        var stderrCont: AsyncStream<Data>.Continuation!
        self._stderrStream = AsyncStream { continuation in
            stderrCont = continuation
        }
        self._stderrContinuation = stderrCont
    }

    // MARK: - Process Control

    /// Starts the process.
    ///
    /// This begins execution of the command in the container. After calling `start()`,
    /// output will begin flowing through `stdout` and `stderr` streams.
    ///
    /// - Throws: `ContainerRuntimeError.execFailed` if the process cannot be started
    public func start() async throws {
        guard stateStorage.transition(to: .running) else {
            return  // Already started
        }
        try await startHandler()
    }

    /// Waits for the process to complete.
    ///
    /// Blocks until the process exits and returns its exit code.
    ///
    /// - Returns: The process exit code (0 typically indicates success)
    /// - Throws: `ContainerRuntimeError.execFailed` if wait fails
    public func wait() async throws -> Int32 {
        let exitCode = try await waitHandler()
        _ = stateStorage.transition(to: .exited(exitCode))
        finishStreams()
        return exitCode
    }

    /// Sends a signal to the process.
    ///
    /// - Parameter signal: The signal number (e.g., SIGTERM=15, SIGKILL=9)
    /// - Throws: Error if the signal cannot be sent
    public func signal(_ signal: Int32) async throws {
        try await signalHandler(signal)
    }

    /// Terminates the process gracefully (SIGTERM).
    public func terminate() async throws {
        try await signal(15)  // SIGTERM
    }

    /// Kills the process immediately (SIGKILL).
    public func kill() async throws {
        try await signal(9)  // SIGKILL
    }

    // MARK: - Stream Management

    /// Writes data to the stdout stream.
    ///
    /// Called by runtime implementations to provide stdout data.
    ///
    /// - Parameter data: The data to write
    public func writeStdout(_ data: Data) {
        _stdoutContinuation.yield(data)
    }

    /// Writes data to the stderr stream.
    ///
    /// Called by runtime implementations to provide stderr data.
    ///
    /// - Parameter data: The data to write
    public func writeStderr(_ data: Data) {
        _stderrContinuation.yield(data)
    }

    /// Finishes the I/O streams.
    ///
    /// Called when the process exits to signal end of streams.
    public func finishStreams() {
        _stdoutContinuation.finish()
        _stderrContinuation.finish()
    }

    // MARK: - Computed Properties

    /// The full command line as a string.
    public var commandLine: String {
        ([command] + arguments).joined(separator: " ")
    }

    /// Current state of the process.
    public var state: ProcessState {
        stateStorage.state
    }

    /// Whether the process is currently running.
    public var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    /// The exit code if the process has exited.
    public var exitCode: Int32? {
        if case .exited(let code) = state {
            return code
        }
        return nil
    }
}

// MARK: - Line-based Output

extension ContainerProcess {
    /// Async sequence of stdout lines.
    public var stdoutLines: AsyncLineSequence {
        AsyncLineSequence(stream: stdout)
    }

    /// Async sequence of stderr lines.
    public var stderrLines: AsyncLineSequence {
        AsyncLineSequence(stream: stderr)
    }
}

// MARK: - AsyncLineSequence

/// Async sequence that yields lines from a data stream.
public struct AsyncLineSequence: AsyncSequence {
    public typealias Element = String

    private let stream: AsyncStream<Data>

    public init(stream: AsyncStream<Data>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(stream: stream)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<Data>.AsyncIterator
        private var buffer = Data()

        init(stream: AsyncStream<Data>) {
            self.iterator = stream.makeAsyncIterator()
        }

        public mutating func next() async -> String? {
            while true {
                // Check for newline in buffer
                if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[..<newlineIndex]
                    buffer = Data(buffer[(buffer.index(after: newlineIndex))...])

                    // Handle CR-LF
                    var line = lineData
                    if line.last == UInt8(ascii: "\r") {
                        line = line.dropLast()
                    }

                    return String(decoding: line, as: UTF8.self)
                }

                // Need more data
                guard let chunk = await iterator.next() else {
                    // End of stream - return remaining buffer if non-empty
                    if !buffer.isEmpty {
                        let remaining = String(decoding: buffer, as: UTF8.self)
                        buffer = Data()
                        return remaining
                    }
                    return nil
                }

                buffer.append(chunk)
            }
        }
    }
}

// MARK: - ProcessState

/// State of a container process.
public enum ProcessState: Sendable, Equatable {
    /// Process has been created but not started.
    case created

    /// Process is running.
    case running

    /// Process has exited with the given code.
    case exited(Int32)

    /// Process was terminated by a signal.
    case signaled(Int32)

    /// Human-readable description.
    public var description: String {
        switch self {
        case .created:
            return "Created"
        case .running:
            return "Running"
        case .exited(let code):
            return "Exited(\(code))"
        case .signaled(let signal):
            return "Signaled(\(signal))"
        }
    }
}

// MARK: - ProcessStateStorage

/// Thread-safe storage for process state.
private final class ProcessStateStorage: @unchecked Sendable {
    private var _state: ProcessState = .created
    private let lock = NSLock()

    var state: ProcessState {
        lock.withLock { _state }
    }

    func transition(to newState: ProcessState) -> Bool {
        lock.withLock {
            switch (_state, newState) {
            case (.created, .running),
                 (.running, .exited),
                 (.running, .signaled):
                _state = newState
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - ContainerProcess + Identifiable

extension ContainerProcess: Identifiable {}

// MARK: - ContainerProcess + CustomStringConvertible

extension ContainerProcess: CustomStringConvertible {
    public var description: String {
        "ContainerProcess(id: \(id.prefix(8)), command: \(command), state: \(state.description))"
    }
}

// MARK: - ProcessOutput

/// Collected output from a process execution.
public struct ProcessOutput: Sendable {
    /// Combined stdout output.
    public let stdout: Data

    /// Combined stderr output.
    public let stderr: Data

    /// Process exit code.
    public let exitCode: Int32

    /// Stdout as a string.
    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    /// Stderr as a string.
    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }

    /// Whether the process succeeded (exit code 0).
    public var isSuccess: Bool {
        exitCode == 0
    }

    /// Creates process output.
    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// Creates process output from strings.
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = Data(stdout.utf8)
        self.stderr = Data(stderr.utf8)
        self.exitCode = exitCode
    }
}

// MARK: - Convenience Extensions

extension ContainerProcess {
    /// Runs the process and collects all output.
    ///
    /// This is a convenience method that starts the process, collects all
    /// stdout and stderr, and waits for completion.
    ///
    /// - Returns: The collected process output
    /// - Throws: If the process cannot be started or wait fails
    public func run() async throws -> ProcessOutput {
        try await start()

        var stdoutData = Data()
        var stderrData = Data()

        // Collect output concurrently
        async let stdoutTask: () = {
            for await chunk in self.stdout {
                stdoutData.append(chunk)
            }
        }()

        async let stderrTask: () = {
            for await chunk in self.stderr {
                stderrData.append(chunk)
            }
        }()

        // Wait for output collection
        _ = await (stdoutTask, stderrTask)

        // Wait for process
        let exitCode = try await wait()

        return ProcessOutput(stdout: stdoutData, stderr: stderrData, exitCode: exitCode)
    }
}
