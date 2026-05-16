// LungfishCLI.swift - Main CLI entry point
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Darwin
import Foundation

/// Lungfish Genome Explorer Command-Line Interface
///
/// Provides headless access to Lungfish functionality for:
/// - File format conversion
/// - Sequence analysis and statistics
/// - Sequence translation, search, and extraction
/// - Workflow execution via Apple Containerization
/// - Debugging and troubleshooting
struct LungfishCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lungfish",
        abstract: "Lungfish Genome Explorer CLI - Bioinformatics tools for sequence analysis",
        discussion: """
            The `lungfish` command provides headless access to the Lungfish Genome Explorer's
            bioinformatics capabilities. Use it for scripting, automation, pipeline
            integration, and debugging workflows.

            Container support uses Apple Containerization framework (macOS 26+) for
            running bioinformatics tools in isolated OCI containers.

            For more information, see: https://github.com/dhoconno/lungfish-genome-explorer
            """,
        version: "0.4.0-alpha.16",
        subcommands: [
            VersionCommand.self,
            ConvertCommand.self,
            AnalyzeCommand.self,
            TranslateCommand.self,
            SequenceCommand.self,
            SearchCommand.self,
            UniversalSearchCommand.self,
            ExtractCommand.self,
            FastqCommand.self,
            WorkflowCommand.self,
            RunHeadlessSubcommand.self,
            FetchCommand.self,
            BundleCommand.self,
            ProjectCommand.self,
            ProvisionToolsCommand.self,
            CondaCommand.self,
            BlastCommand.self,
            EsVirituCommand.self,
            TaxTriageCommand.self,
            AlignCommand.self,
            MSACommand.self,
            TreeCommand.self,
            AssembleCommand.self,
            OrientCommand.self,
            MapCommand.self,
            ImportCommand.self,
            ImportFastqCommand.self,
            OpsCommand.self,
            ProvenanceCommand.self,
            BAMCommand.self,
            VariantsCommand.self,
            GATKCLICommand.self,
            NaoMgsCommand.self,
            FreyjaCommand.self,
            NvdCommand.self,
            CzIdCommand.self,
            MetadataCommand.self,
            BuildDbCommand.self,
            MarkdupCommand.self,
            PrimerCommand.self,
            DebugCommand.self,
        ],
        defaultSubcommand: nil
    )

    @OptionGroup var globalOptions: GlobalOptions

    static func normalizedArgumentsForParsing(_ arguments: [String]) -> [String] {
        guard let provenanceIndex = arguments.firstIndex(of: "provenance") else {
            return arguments
        }
        let exportIndex = arguments.index(after: provenanceIndex)
        guard arguments.indices.contains(exportIndex),
              arguments[exportIndex] == "export" else {
            return arguments
        }

        var normalized = arguments
        var index = arguments.index(after: exportIndex)
        while normalized.indices.contains(index) {
            if normalized[index] == "--" {
                break
            }
            if normalized[index] == "--format" {
                normalized[index] = "--export-format"
            } else if normalized[index].hasPrefix("--format=") {
                normalized[index] = "--export-format=" + String(normalized[index].dropFirst("--format=".count))
            }
            index += 1
        }
        return normalized
    }
}

@main
enum LungfishCLIMain {
    static func main() async {
        let arguments = LungfishCLI.normalizedArgumentsForParsing(Array(CommandLine.arguments.dropFirst()))
        do {
            var command = try LungfishCLI.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            Darwin.exit(CLIExitCode.success.rawValue)
        } catch let error as CLIError {
            LungfishCLI.exit(withCLIError: error)
        } catch {
            LungfishCLI.exit(withError: error)
        }
    }
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

extension LungfishCLI {
    static func exit(withCLIError error: CLIError) -> Never {
        let fullText = fullMessage(for: error)
        if !fullText.isEmpty {
            FileHandle.standardError.write(Data((fullText + "\n").utf8))
        }
        Darwin.exit(error.exitCode.exitCode.rawValue)
    }
}
