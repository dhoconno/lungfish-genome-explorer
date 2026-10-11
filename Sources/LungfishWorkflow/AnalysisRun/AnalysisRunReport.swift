// AnalysisRunReport.swift - How an analysis run ended, its exit codes and its setup errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// How one analysis run ended, for the command that ran it.
public struct AnalysisRunReport: Sendable, Equatable {
    /// The result folder, or nil when the run ended before it existed.
    public let analysisDirectory: URL?
    /// `completed` (with or without warnings), `failed` or `cancelled`.
    public let status: RunStatus
    /// Every warning line of the run, in order. A completed run with warnings reads Completed
    /// with Warnings.
    public let warnings: [String]
    /// The exit code the command ends with (``AnalysisRunExitCode``). A plan that refused the
    /// request exits with the code its error carries (``AnalysisRunExitCoding``).
    public let exitCode: Int32
    /// The root record, or nil when none was written.
    public let recordURL: URL?
    /// The message of the last event, the completion detail or the reason the run did not complete.
    public let message: String

    public init(
        analysisDirectory: URL?,
        status: RunStatus,
        warnings: [String],
        exitCode: Int32,
        recordURL: URL?,
        message: String
    ) {
        self.analysisDirectory = analysisDirectory
        self.status = status
        self.warnings = warnings
        self.exitCode = exitCode
        self.recordURL = recordURL
        self.message = message
    }
}

/// The exit codes an analysis run ends with. They equal `CLIExitCode` in LungfishCLI, which this
/// module cannot import. A run that failed exits with ``workflowError``, except a run whose plan
/// refused it with an error that carries its own code (``AnalysisRunExitCoding``).
public enum AnalysisRunExitCode {
    /// A completed run, with or without warnings.
    public static let completed: Int32 = 0
    /// A failed run, `CLIExitCode.workflowError`.
    public static let workflowError: Int32 = 64
    /// A cancelled run, `CLIExitCode.cancelled`.
    public static let cancelled: Int32 = 125

    /// The exit code of a run that ended with `status`. A run still running has none, so it reads
    /// as a failure.
    public static func code(for status: RunStatus) -> Int32 {
        switch status {
        case .completed:
            return completed
        case .cancelled:
            return cancelled
        case .failed, .running:
            return workflowError
        }
    }
}

/// An error a plan refuses a request with that says which code its command exits with, such as
/// `CLIExitCode.inputError` (3) for a refused input or `CLIExitCode.dependency` (126) for a
/// missing database. LungfishCLI conforms its refusal errors, which this module cannot import.
///
/// Only an error thrown by ``AnalysisRunTool/plan(_:context:)`` sets the exit code, and only when
/// no cancel was requested. A code of 0, 125 or one outside 1 to 255 reads as
/// ``AnalysisRunExitCode/workflowError``, so a failed run never exits as a success or a cancel.
/// Every failure after the plan exits with ``AnalysisRunExitCode/workflowError``.
public protocol AnalysisRunExitCoding: Error {
    /// The code the command exits with when its plan refuses the request with this error.
    var analysisRunExitCode: Int32 { get }
}

/// Why the executor itself stopped a run.
public enum AnalysisRunError: Error, LocalizedError, Sendable, Equatable {
    /// The request named no command to record.
    case missingCommandLine
    /// The tool planned no unit.
    case emptyPlan(AnalysisToolID)
    /// The finalize asked for a viewer index and the executor has no index builder.
    case noResultIndexer(AnalysisToolID)
    /// The destination is a project folder or its `Analyses` folder, which a result never fills.
    case destinationIsProjectFolder(path: String)

    public var errorDescription: String? {
        switch self {
        case .missingCommandLine:
            return "The analysis run names no command to record."
        case .emptyPlan(let toolID):
            return "The \(toolID.rawValue) plan holds no samples to run."
        case .noResultIndexer(let toolID):
            return "No viewer index builder is available for \(toolID.rawValue) results."
        case .destinationIsProjectFolder(let path):
            return "A result cannot be written into the project folder itself: \(path)"
        }
    }
}
