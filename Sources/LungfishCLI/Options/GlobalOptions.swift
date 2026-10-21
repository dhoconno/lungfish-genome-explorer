// GlobalOptions.swift - Shared CLI options
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation

/// Global options available to all CLI commands
struct GlobalOptions: ParsableArguments {

    // MARK: - Output Options

    @Option(
        name: .customLong("format"),
        help: "Output format"
    )
    var outputFormat: OutputFormat = .text

    // MARK: - Verbosity Options

    @Flag(
        name: [.customLong("verbose"), .customShort("v")],
        help: "Increase output verbosity (can be repeated: -v, -vv, -vvv)"
    )
    var verbosity: Int

    @Flag(
        name: [.customLong("quiet"), .customShort("q")],
        help: "Suppress non-essential output (errors only)"
    )
    var quiet: Bool = false

    // MARK: - Progress Options

    @Flag(
        name: .customLong("progress"),
        help: "Show progress bar (default: auto-detect TTY)"
    )
    var showProgress: Bool = false

    @Flag(
        name: .customLong("no-progress"),
        help: "Disable progress bar"
    )
    var noProgress: Bool = false

    // MARK: - Debug Options

    @Flag(
        name: .customLong("debug"),
        help: "Enable debug output with detailed logging"
    )
    var debug: Bool = false

    @Option(
        name: .customLong("log-file"),
        help: "Write detailed logs to file"
    )
    var logFile: String?

    // MARK: - Display Options

    @Flag(
        name: .customLong("no-color"),
        help: "Disable colored output"
    )
    var noColor: Bool = false

    // MARK: - Threading Options

    @Option(
        name: [.customLong("threads"), .customShort("t")],
        help: "Number of threads to use (default: auto)"
    )
    var threads: Int?

    // MARK: - Computed Properties

    /// Effective verbosity level (0 = normal, 1+ = verbose, -1 = quiet)
    var effectiveVerbosity: Int {
        if quiet { return -1 }
        return verbosity
    }

    /// Whether to show progress indicators
    var shouldShowProgress: Bool {
        if noProgress { return false }
        if showProgress { return true }
        // Auto-detect: show progress if stdout is a TTY
        return isatty(STDOUT_FILENO) != 0
    }

    /// Whether to use colored output
    var useColors: Bool {
        if noColor { return false }
        // Auto-detect: use colors if stdout is a TTY
        return isatty(STDOUT_FILENO) != 0
    }

    /// Number of threads to use
    var effectiveThreads: Int {
        threads ?? ProcessInfo.processInfo.activeProcessorCount
    }

    /// Output mode based on format and debug settings
    var outputMode: OutputMode {
        if debug { return .debug }
        switch outputFormat {
        case .json: return .json
        case .tsv: return .tsv
        case .text: return .text
        }
    }
}

/// Global options for commands that only support text and json output.
struct TextAndJSONGlobalOptions: ParsableArguments {

    // MARK: - Output Options

    @Option(
        name: .customLong("format"),
        help: "Output format"
    )
    private var selectedOutputFormat: TextAndJSONOutputFormat = .text

    var outputFormat: OutputFormat {
        selectedOutputFormat.outputFormat
    }

    // MARK: - Verbosity Options

    @Flag(
        name: [.customLong("verbose"), .customShort("v")],
        help: "Increase output verbosity (can be repeated: -v, -vv, -vvv)"
    )
    var verbosity: Int

    @Flag(
        name: [.customLong("quiet"), .customShort("q")],
        help: "Suppress non-essential output (errors only)"
    )
    var quiet: Bool = false

    // MARK: - Progress Options

    @Flag(
        name: .customLong("progress"),
        help: "Show progress bar (default: auto-detect TTY)"
    )
    var showProgress: Bool = false

    @Flag(
        name: .customLong("no-progress"),
        help: "Disable progress bar"
    )
    var noProgress: Bool = false

    // MARK: - Debug Options

    @Flag(
        name: .customLong("debug"),
        help: "Enable debug output with detailed logging"
    )
    var debug: Bool = false

    @Option(
        name: .customLong("log-file"),
        help: "Write detailed logs to file"
    )
    var logFile: String?

    // MARK: - Display Options

    @Flag(
        name: .customLong("no-color"),
        help: "Disable colored output"
    )
    var noColor: Bool = false

    // MARK: - Threading Options

    @Option(
        name: [.customLong("threads"), .customShort("t")],
        help: "Number of threads to use (default: auto)"
    )
    var threads: Int?

    // MARK: - Computed Properties

    var effectiveVerbosity: Int {
        if quiet { return -1 }
        return verbosity
    }

    var shouldShowProgress: Bool {
        if noProgress { return false }
        if showProgress { return true }
        return isatty(STDOUT_FILENO) != 0
    }

    var useColors: Bool {
        if noColor { return false }
        return isatty(STDOUT_FILENO) != 0
    }

    var effectiveThreads: Int {
        threads ?? ProcessInfo.processInfo.activeProcessorCount
    }

    var outputMode: OutputMode {
        if debug { return .debug }
        switch outputFormat {
        case .json: return .json
        case .text: return .text
        case .tsv: return .text
        }
    }

    func resolved(with arguments: [String]? = nil) throws -> ResolvedTextAndJSONGlobalOptions {
        var resolved = ResolvedTextAndJSONGlobalOptions(
            outputFormat: outputFormat,
            quiet: quiet
        )

        guard let arguments else {
            return resolved
        }

        let overrides = try TextAndJSONGlobalOptionOverrides.parse(arguments)
        if let outputFormat = overrides.outputFormat {
            resolved.outputFormat = outputFormat
        }
        resolved.quiet = resolved.quiet || overrides.quiet
        return resolved
    }
}

struct ResolvedTextAndJSONGlobalOptions {
    var outputFormat: OutputFormat
    var quiet: Bool
}

// MARK: - Output Format

/// Output format for CLI results
enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    case tsv

    static var allValueStrings: [String] {
        allCases.map { $0.rawValue }
    }
}

enum TextAndJSONOutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json

    var outputFormat: OutputFormat {
        switch self {
        case .text: return .text
        case .json: return .json
        }
    }

    static var allValueStrings: [String] {
        allCases.map { $0.rawValue }
    }
}

private struct TextAndJSONGlobalOptionOverrides {
    var outputFormat: OutputFormat?
    var quiet: Bool = false

    static func parse(_ arguments: [String]) throws -> TextAndJSONGlobalOptionOverrides {
        var overrides = TextAndJSONGlobalOptionOverrides()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            if argument == "--" {
                break
            }

            if argument == "--format" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    break
                }
                overrides.outputFormat = try parseOutputFormat(arguments[valueIndex])
                index += 2
                continue
            }

            if argument.hasPrefix("--format=") {
                let value = String(argument.dropFirst("--format=".count))
                overrides.outputFormat = try parseOutputFormat(value)
                index += 1
                continue
            }

            if argument == "--quiet" {
                overrides.quiet = true
                index += 1
                continue
            }

            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1,
               argument.dropFirst().contains("q") {
                overrides.quiet = true
            }

            index += 1
        }

        return overrides
    }

    private static func parseOutputFormat(_ rawValue: String) throws -> OutputFormat {
        switch rawValue {
        case OutputFormat.text.rawValue:
            return .text
        case OutputFormat.json.rawValue:
            return .json
        case OutputFormat.tsv.rawValue:
            throw ValidationError(
                "The value 'tsv' is invalid for '--format <format>'. Please provide one of 'text' and 'json'."
            )
        default:
            return .text
        }
    }
}

/// Output mode for rendering
enum OutputMode {
    case text
    case json
    case tsv
    case debug
}

// MARK: - Output Options (for commands that write files)

/// Options for a `fastq` subcommand that writes one plain output file.
///
/// `--compress` still parses but is private to every help screen, so a subcommand without a gzip step refuses
/// it with `rejectCompress(subcommand:)` in `validate()` and no help line promises gzip. A subcommand that does
/// gzip its output takes `GzipOutputOptions`.
struct OutputOptions: ParsableArguments {

    @Option(
        name: [.customLong("output"), .customShort("o")],
        help: "Output file path (required)"
    )
    var output: String

    @Flag(
        name: .customLong("force"),
        help: "Overwrite existing output file"
    )
    var force: Bool = false

    @Flag(
        name: .customLong("compress"),
        help: ArgumentHelp("Refused. These commands write plain output.", visibility: .private)
    )
    var compress: Bool = false

    /// Validate that output can be written
    func validateOutput() throws {
        try Self.validateOutputPath(output, force: force)
    }

    /// The checks of `validateOutput()`, which `GzipOutputOptions` shares.
    static func validateOutputPath(_ output: String, force: Bool) throws {
        let url = URL(fileURLWithPath: output)

        // Check if file exists
        if FileManager.default.fileExists(atPath: output) && !force {
            throw ValidationError("Output file already exists: \(output). Use --force to overwrite.")
        }

        // Check if parent directory exists
        let parentDir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            throw ValidationError("Output directory does not exist: \(parentDir.path)")
        }
    }

    /// Refuses `--compress` for a subcommand that writes plain output. A subcommand calls it from `validate()`,
    /// so the refusal comes before any file or record is written and the exit status is 64. The words are the
    /// refusal the UX ruling of lane 13.39 sets for every `fastq` subcommand that has no gzip step.
    func rejectCompress(subcommand: String) throws {
        guard compress else { return }
        throw ValidationError("--compress is not supported by fastq \(subcommand). Remove it to write plain output.")
    }
}

/// Options for a `fastq` subcommand that gzips its output when `--compress` is set, which is `merge`,
/// `materialize` and `scrub-human`. The flag is real here, so its help line is true.
struct GzipOutputOptions: ParsableArguments {

    @Option(
        name: [.customLong("output"), .customShort("o")],
        help: "Output file path (required)"
    )
    var output: String

    @Flag(
        name: .customLong("force"),
        help: "Overwrite existing output file"
    )
    var force: Bool = false

    @Flag(
        name: .customLong("compress"),
        help: "Compress output with gzip"
    )
    var compress: Bool = false

    /// Validate that output can be written
    func validateOutput() throws {
        try OutputOptions.validateOutputPath(output, force: force)
    }
}

extension FASTQSubcommandInput {
    /// The prologue of a single-input subcommand that takes `GzipOutputOptions`, the same as the one for
    /// `OutputOptions` in `FASTQSubcommandInput.swift`.
    static func resolve(
        _ path: String,
        operationName: String,
        output: GzipOutputOptions
    ) async throws -> FASTQSubcommandInput {
        try output.validateOutput()
        return try await resolve(path, operationName: operationName, contextURL: URL(fileURLWithPath: output.output))
    }
}
