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
        help: "Output format: text, json, tsv (default: text)"
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

/// Output mode for rendering
enum OutputMode {
    case text
    case json
    case tsv
    case debug
}

// MARK: - Output Options (for commands that write files)

/// Options for commands that produce output files
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
        help: "Compress output with gzip"
    )
    var compress: Bool = false

    /// Validate that output can be written
    func validateOutput() throws {
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
}
