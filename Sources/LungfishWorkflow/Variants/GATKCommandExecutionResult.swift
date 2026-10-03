// GATKCommandExecutionResult.swift - Exit code, output and wall time of one GATK command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKCommandExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let wallTime: TimeInterval

    public init(exitCode: Int32, stdout: String, stderr: String, wallTime: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.wallTime = wallTime
    }

    public var isSuccess: Bool {
        exitCode == 0
    }
}
