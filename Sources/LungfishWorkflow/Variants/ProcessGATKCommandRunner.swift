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

    public var errorDescription: String? {
        switch self {
        case .outputIncomplete(_, _, let detail):
            return detail
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
/// the calling task is cancelled or the timeout passes. Both of those throw
/// `CancellationError`, as this runner always has.
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
    let drainGrace: Duration = .seconds(2)
    let spec = ToolProcessSpec(
        executableURL: executableURL,
        arguments: arguments,
        environment: ToolProcessSpec.inheritedEnvironment(overriding: environment),
        workingDirectory: command.workingDirectory,
        timeout: CondaFamilyProcess.limit(seconds: timeout),
        drainGracePeriod: drainGrace,
        label: command.executable
    )

    let result: ToolProcessResult
    do {
        result = try await ToolProcess.run(spec)
    } catch ToolProcessError.cancelled, ToolProcessError.timedOut {
        throw CancellationError()
    }
    if let reason = CondaFamilyProcess.incompleteOutputReason(result, drainGrace: drainGrace) {
        throw ProcessGATKCommandRunnerError.outputIncomplete(
            executable: command.executable,
            exitCode: result.status,
            detail: reason
        )
    }
    return GATKCommandExecutionResult(
        exitCode: result.status,
        stdout: CondaFamilyProcess.text(result.stdout),
        stderr: CondaFamilyProcess.text(result.stderr),
        wallTime: commandClock.elapsed
    )
}
