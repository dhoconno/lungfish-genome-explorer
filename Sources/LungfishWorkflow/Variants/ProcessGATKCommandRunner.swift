// ProcessGATKCommandRunner.swift - Runs a GATK command as a local process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Why ``ProcessGATKCommandRunner`` produced no result for a command that ran.
public enum ProcessGATKCommandRunnerError: Error, LocalizedError, Sendable, Equatable {
    /// The command exited, but a child process kept its output open past the
    /// drain grace period, or reading the output failed, so the captured
    /// output and any file the command wrote may be incomplete.
    case outputIncomplete(executable: String, exitCode: Int32, detail: String)
    /// The command ran past the runner's timeout and its process tree was stopped.
    case timedOut(executable: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .outputIncomplete(_, _, let detail):
            return detail
        case .timedOut(let executable, let seconds):
            return "\(executable) timed out after \(Int(seconds)) seconds and was stopped."
        }
    }
}

public struct ProcessGATKCommandRunner: GATKCommandRunning {
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(environment: [String: String] = [:], timeout: TimeInterval = 24 * 60 * 60) {
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        try await runGATKProcess(command, environment: environment, timeout: timeout)
    }
}

/// Runs a GATK command through ``ToolProcess``, which reads both streams while
/// the command runs and stops its whole process tree, the JVM included, when
/// the calling task is cancelled or the timeout passes. A cancellation throws
/// `CancellationError` and a timeout throws
/// ``ProcessGATKCommandRunnerError/timedOut(executable:seconds:)``.
private func runGATKProcess(
    _ command: GATKCommand,
    environment: [String: String],
    timeout: TimeInterval
) async throws -> GATKCommandExecutionResult {
    let commandClock = ProvenanceRunClock()
    let executableURL: URL
    let arguments: [String]
    if command.executable.contains("/") {
        executableURL = URL(fileURLWithPath: command.executable)
        arguments = command.arguments
    } else {
        executableURL = URL(fileURLWithPath: "/usr/bin/env")
        arguments = [command.executable] + command.arguments
    }
    let spec = ToolProcessSpec(
        executableURL: executableURL,
        arguments: arguments,
        environment: ToolProcessSpec.inheritedEnvironment(overriding: environment),
        workingDirectory: command.workingDirectory,
        timeout: CondaFamilyProcess.limit(seconds: timeout),
        terminationGracePeriod: CondaFamilyProcess.terminationGracePeriod,
        label: command.executable
    )

    let result: ToolProcessResult
    do {
        result = try await ToolProcess.run(spec)
    } catch ToolProcessError.cancelled {
        throw CancellationError()
    } catch ToolProcessError.timedOut {
        throw ProcessGATKCommandRunnerError.timedOut(executable: command.executable, seconds: timeout)
    }
    if let reason = result.incompleteOutputReason {
        throw ProcessGATKCommandRunnerError.outputIncomplete(
            executable: command.executable,
            exitCode: result.status,
            detail: reason
        )
    }
    return GATKCommandExecutionResult(
        exitCode: result.status,
        stdout: result.stdoutText,
        stderr: result.stderrText,
        wallTime: commandClock.elapsed
    )
}
