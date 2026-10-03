// ProcessManaging.swift - Protocol for process management operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import Darwin

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
