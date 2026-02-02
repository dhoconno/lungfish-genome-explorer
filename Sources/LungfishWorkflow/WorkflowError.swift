// WorkflowError.swift - Error types for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation

// MARK: - WorkflowError

/// Errors that can occur during workflow operations.
///
/// WorkflowError provides comprehensive error handling for the workflow
/// execution system, covering engine discovery, execution failures,
/// timeouts, and container issues.
///
/// ## Error Categories
///
/// - **Engine Errors**: Engine not found, configuration issues
/// - **Execution Errors**: Runtime failures, cancellation, timeouts
/// - **Parameter Errors**: Invalid or missing parameters
/// - **Container Errors**: Docker/Apptainer availability issues
///
/// ## Example
///
/// ```swift
/// do {
///     try await runner.execute(workflow)
/// } catch WorkflowError.engineNotFound(let engine) {
///     print("Please install \(engine)")
/// } catch WorkflowError.timeout(let duration) {
///     print("Execution exceeded \(duration) seconds")
/// }
/// ```
public enum WorkflowError: Error, Sendable {
    /// The workflow engine executable was not found in the system PATH.
    ///
    /// - Parameters:
    ///   - engine: The type of workflow engine that was not found
    ///   - searchedPaths: The paths that were searched
    case engineNotFound(engine: String, searchedPaths: [String])

    /// Workflow execution failed with an error.
    ///
    /// - Parameters:
    ///   - workflowName: Name of the workflow that failed
    ///   - exitCode: The process exit code
    ///   - stderr: Standard error output from the process
    ///   - logFile: Optional path to the log file for more details
    case executionFailed(
        workflowName: String,
        exitCode: Int32,
        stderr: String,
        logFile: URL?
    )

    /// Workflow execution was cancelled by the user or system.
    ///
    /// - Parameters:
    ///   - workflowName: Name of the cancelled workflow
    ///   - reason: Reason for cancellation
    case cancelled(workflowName: String, reason: CancellationReason)

    /// Workflow execution exceeded the allowed time limit.
    ///
    /// - Parameters:
    ///   - workflowName: Name of the workflow that timed out
    ///   - duration: The timeout duration in seconds
    case timeout(workflowName: String, duration: TimeInterval)

    /// Invalid or missing workflow parameters.
    ///
    /// - Parameters:
    ///   - parameterName: Name of the problematic parameter
    ///   - reason: Description of what is wrong with the parameter
    case invalidParameters(parameterName: String, reason: String)

    /// Required container runtime is not available.
    ///
    /// - Parameters:
    ///   - containerType: The type of container runtime (docker, apptainer)
    ///   - reason: Why the container is not available
    case containerNotAvailable(containerType: String, reason: String)

    /// Workflow definition file not found or invalid.
    ///
    /// - Parameters:
    ///   - path: Path to the workflow definition
    ///   - reason: Description of the issue
    case invalidWorkflowDefinition(path: URL, reason: String)

    /// Working directory does not exist or is not accessible.
    ///
    /// - Parameters:
    ///   - path: Path to the working directory
    case invalidWorkingDirectory(path: URL)

    /// Failed to parse workflow output.
    ///
    /// - Parameters:
    ///   - format: Expected output format
    ///   - details: Details about the parsing failure
    case outputParsingFailed(format: String, details: String)

    /// A process management error occurred.
    ///
    /// - Parameters:
    ///   - operation: The operation that failed
    ///   - underlying: The underlying system error
    case processError(operation: String, underlying: Error)

    /// State transition error in the workflow state machine.
    ///
    /// - Parameters:
    ///   - from: Current state
    ///   - to: Attempted target state
    case invalidStateTransition(from: String, to: String)
}

// MARK: - CancellationReason

/// Reasons why a workflow may be cancelled.
public enum CancellationReason: String, Sendable, Codable {
    /// User requested cancellation
    case userRequested = "User requested cancellation"

    /// System is shutting down
    case systemShutdown = "System shutdown"

    /// Dependency workflow failed
    case dependencyFailed = "Dependency workflow failed"

    /// Resource constraints (memory, disk, etc.)
    case resourceConstraints = "Resource constraints exceeded"

    /// Parent task was cancelled
    case parentCancelled = "Parent task cancelled"
}

// MARK: - LocalizedError Conformance

extension WorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineNotFound(let engine, _):
            return "Workflow engine '\(engine)' not found"

        case .executionFailed(let name, let code, _, _):
            return "Workflow '\(name)' failed with exit code \(code)"

        case .cancelled(let name, let reason):
            return "Workflow '\(name)' was cancelled: \(reason.rawValue)"

        case .timeout(let name, let duration):
            return "Workflow '\(name)' exceeded timeout of \(Int(duration)) seconds"

        case .invalidParameters(let param, let reason):
            return "Invalid parameter '\(param)': \(reason)"

        case .containerNotAvailable(let type, let reason):
            return "Container runtime '\(type)' not available: \(reason)"

        case .invalidWorkflowDefinition(let path, let reason):
            return "Invalid workflow at '\(path.lastPathComponent)': \(reason)"

        case .invalidWorkingDirectory(let path):
            return "Working directory not accessible: \(path.path)"

        case .outputParsingFailed(let format, let details):
            return "Failed to parse \(format) output: \(details)"

        case .processError(let operation, let underlying):
            return "Process error during \(operation): \(underlying.localizedDescription)"

        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from '\(from)' to '\(to)'"
        }
    }

    public var failureReason: String? {
        switch self {
        case .engineNotFound(_, let paths):
            return "Searched paths: \(paths.joined(separator: ", "))"

        case .executionFailed(_, _, let stderr, _):
            if stderr.isEmpty {
                return "No error output captured"
            }
            return "Error output: \(stderr.prefix(500))"

        case .cancelled(_, let reason):
            return reason.rawValue

        case .timeout(_, let duration):
            return "Maximum execution time of \(Int(duration)) seconds exceeded"

        case .invalidParameters(_, let reason):
            return reason

        case .containerNotAvailable(_, let reason):
            return reason

        case .invalidWorkflowDefinition(_, let reason):
            return reason

        case .invalidWorkingDirectory(let path):
            return "Path: \(path.path)"

        case .outputParsingFailed(_, let details):
            return details

        case .processError(_, let underlying):
            return underlying.localizedDescription

        case .invalidStateTransition(let from, let to):
            return "Cannot transition from \(from) to \(to)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .engineNotFound(let engine, _):
            return "Install \(engine) and ensure it is in your PATH"

        case .executionFailed(_, _, _, let logFile):
            if let log = logFile {
                return "Check the log file at \(log.path) for details"
            }
            return "Check the workflow configuration and input files"

        case .cancelled:
            return "Restart the workflow when ready"

        case .timeout:
            return "Increase the timeout duration or optimize the workflow"

        case .invalidParameters:
            return "Check parameter values and types"

        case .containerNotAvailable(let type, _):
            return "Install \(type) or use a different execution profile"

        case .invalidWorkflowDefinition:
            return "Verify the workflow file exists and is valid"

        case .invalidWorkingDirectory:
            return "Create the directory or choose a different working directory"

        case .outputParsingFailed:
            return "Check the workflow for errors and verify output format"

        case .processError:
            return "Check system resources and permissions"

        case .invalidStateTransition:
            return "This is likely a bug; please report it"
        }
    }

    public var helpAnchor: String? {
        switch self {
        case .engineNotFound:
            return "workflow-engine-installation"
        case .executionFailed:
            return "workflow-troubleshooting"
        case .cancelled:
            return "workflow-cancellation"
        case .timeout:
            return "workflow-timeout-configuration"
        case .invalidParameters:
            return "workflow-parameters"
        case .containerNotAvailable:
            return "container-runtime-setup"
        case .invalidWorkflowDefinition:
            return "workflow-definition-format"
        case .invalidWorkingDirectory:
            return "workflow-directories"
        case .outputParsingFailed:
            return "workflow-output-formats"
        case .processError:
            return "process-management"
        case .invalidStateTransition:
            return "workflow-state-machine"
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension WorkflowError: CustomDebugStringConvertible {
    public var debugDescription: String {
        var description = "WorkflowError.\(caseName): \(errorDescription ?? "Unknown error")"
        if let reason = failureReason {
            description += "\n  Reason: \(reason)"
        }
        if let suggestion = recoverySuggestion {
            description += "\n  Suggestion: \(suggestion)"
        }
        return description
    }

    private var caseName: String {
        switch self {
        case .engineNotFound: return "engineNotFound"
        case .executionFailed: return "executionFailed"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .invalidParameters: return "invalidParameters"
        case .containerNotAvailable: return "containerNotAvailable"
        case .invalidWorkflowDefinition: return "invalidWorkflowDefinition"
        case .invalidWorkingDirectory: return "invalidWorkingDirectory"
        case .outputParsingFailed: return "outputParsingFailed"
        case .processError: return "processError"
        case .invalidStateTransition: return "invalidStateTransition"
        }
    }
}
