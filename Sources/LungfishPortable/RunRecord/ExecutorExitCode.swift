// ExecutorExitCode.swift - The exit codes of lungfish-executor, which the Mac's orchestration layer reads (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// The executor's exit codes. A refused run has a code of its own, distinct from a failed and an interrupted run, so the
/// orchestration layer can retry by code (tally-r2 K3-4). They live in Portable beside the run record, since the layer
/// that reads them is Workflow code and may not import the executor (ARCH-r3 ruling 2).
package enum ExecutorExitCode {
    package static let succeeded: Int32 = 0
    package static let failed: Int32 = 1
    package static let refused: Int32 = 2
    package static let interrupted: Int32 = 3
    package static let usage: Int32 = 64

    /// The outcome a run record states for `code`, or nil for `usage` and any code the executor never returns.
    package static func outcome(for code: Int32) -> ExecutorRunOutcome? {
        switch code {
        case succeeded: return .succeeded
        case failed: return .failed
        case refused: return .refused
        case interrupted: return .interrupted
        default: return nil
        }
    }
}

/// How a run or a step ended. `refused` means no tool ran for it.
package enum ExecutorRunOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded
    case failed
    case refused
    case interrupted

    /// The exit code the executor ends with for this outcome.
    package var exitCode: Int32 {
        switch self {
        case .succeeded: return ExecutorExitCode.succeeded
        case .failed: return ExecutorExitCode.failed
        case .refused: return ExecutorExitCode.refused
        case .interrupted: return ExecutorExitCode.interrupted
        }
    }
}
