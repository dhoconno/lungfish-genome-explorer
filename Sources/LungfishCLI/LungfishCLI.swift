// LungfishCLI.swift - Main CLI entry point
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation

/// Lungfish Genome Explorer Command-Line Interface
///
/// Provides headless access to Lungfish functionality for:
/// - File format conversion
/// - Sequence analysis and statistics
/// - Workflow execution via Apple Containerization
/// - Debugging and troubleshooting
@main
struct LungfishCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lungfish",
        abstract: "Lungfish Genome Explorer CLI - Bioinformatics tools for sequence analysis",
        discussion: """
            The Lungfish CLI provides headless access to the Lungfish Genome Explorer's
            bioinformatics capabilities. Use it for scripting, automation, pipeline
            integration, and debugging workflows.

            Container support uses Apple Containerization framework (macOS 26+) for
            running bioinformatics tools in isolated OCI containers.

            For more information, see: https://github.com/lungfish/genome-browser
            """,
        version: "1.0.0",
        subcommands: [
            ConvertCommand.self,
            AnalyzeCommand.self,
            FastqCommand.self,
            WorkflowCommand.self,
            FetchCommand.self,
            BundleCommand.self,
            ProvisionToolsCommand.self,
            DebugCommand.self,
        ],
        defaultSubcommand: nil
    )

    @OptionGroup var globalOptions: GlobalOptions
}

// MARK: - Exit Codes

/// Standard exit codes for CLI operations
enum CLIExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case inputError = 3
    case outputError = 4
    case formatError = 5
    case workflowError = 64
    case containerError = 65
    case networkError = 66
    case timeout = 124
    case cancelled = 125
    case dependency = 126
    case notFound = 127

    var exitCode: ExitCode {
        ExitCode(rawValue: rawValue)
    }
}

// MARK: - CLI Error

/// Errors thrown by CLI commands
enum CLIError: Error, LocalizedError {
    case inputFileNotFound(path: String)
    case outputWriteFailed(path: String, reason: String)
    case formatDetectionFailed(path: String)
    case unsupportedFormat(format: String)
    case conversionFailed(reason: String)
    case validationFailed(errors: [String])
    case workflowFailed(reason: String)
    case containerUnavailable
    case networkError(reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let path):
            return "Input file not found: \(path)"
        case .outputWriteFailed(let path, let reason):
            return "Failed to write output file '\(path)': \(reason)"
        case .formatDetectionFailed(let path):
            return "Could not detect format for file: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format)"
        case .conversionFailed(let reason):
            return "Conversion failed: \(reason)"
        case .validationFailed(let errors):
            return "Validation failed:\n" + errors.map { "  - \($0)" }.joined(separator: "\n")
        case .workflowFailed(let reason):
            return "Workflow execution failed: \(reason)"
        case .containerUnavailable:
            return "Apple Containerization is not available. Requires macOS 26 or later."
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .cancelled:
            return "Operation cancelled"
        }
    }

    var exitCode: CLIExitCode {
        switch self {
        case .inputFileNotFound:
            return .inputError
        case .outputWriteFailed:
            return .outputError
        case .formatDetectionFailed, .unsupportedFormat:
            return .formatError
        case .conversionFailed, .validationFailed:
            return .failure
        case .workflowFailed:
            return .workflowError
        case .containerUnavailable:
            return .containerError
        case .networkError:
            return .networkError
        case .cancelled:
            return .cancelled
        }
    }
}
