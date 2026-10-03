// ManagedGATKCommandRunner.swift - Runs a GATK command in the managed conda environment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct ManagedGATKCommandRunner: GATKCommandRunning {
    public let condaManager: CondaManager
    public let timeout: TimeInterval

    public init(
        condaManager: CondaManager = .shared,
        timeout: TimeInterval = 24 * 60 * 60
    ) {
        self.condaManager = condaManager
        self.timeout = timeout
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            timeout: timeout
        )
        return GATKCommandExecutionResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            wallTime: Date().timeIntervalSince(startedAt)
        )
    }
}
