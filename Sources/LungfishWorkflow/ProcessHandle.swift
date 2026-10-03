// ProcessHandle.swift - A handle to a running process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
