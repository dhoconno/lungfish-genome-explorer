// LungfishCLIRunner.swift — Locates and invokes the `lungfish-cli` subprocess.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "LungfishCLIRunner")

/// Locates and runs the `lungfish-cli` binary as a subprocess from the GUI app.
///
/// The CLI is the canonical implementation of heavyweight operations like
/// `build-db` that the GUI would otherwise have to duplicate. Reusing the CLI
/// via a subprocess keeps the logic in one place and avoids pulling large
/// parsing/SQL code into the GUI target.
enum LungfishCLIRunner {

    struct Output: Sendable, Equatable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// An error returned from a CLI invocation.
    enum RunError: Error, LocalizedError {
        case cliNotFound
        case nonZeroExit(status: Int32, stderr: String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The `lungfish-cli` binary could not be found in the app bundle or build products."
            case .nonZeroExit(let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "lungfish-cli exited with status \(status)"
                    : "lungfish-cli exited with status \(status): \(trimmed)"
            case .launchFailed(let message):
                return "Failed to launch lungfish-cli: \(message)"
            }
        }
    }

    /// Locates the `lungfish-cli` binary.
    ///
    /// Delegates to ``CLIImportRunner/cliBinaryPath()``, the canonical CLI
    /// resolver already used by the FASTQ import pipeline. That implementation
    /// handles all three launch layouts:
    ///   * Plain SPM debug binary (`.build/debug/Lungfish`) — CLI found in the
    ///     same directory as the GUI binary.
    ///   * Xcode debug `.app` (`DerivedData/.../Debug/Lungfish.app`) — CLI
    ///     found by walking from the current workspace to `<repo>/.build/debug/lungfish-cli`.
    ///   * Release `.app` with bundled CLI — found adjacent to the main executable
    ///     inside `Lungfish.app/Contents/MacOS/`.
    ///   * System install — found via `which lungfish-cli` (`/usr/local/bin`, Homebrew, etc.).
    ///
    /// **Important:** only searches for the exact name `lungfish-cli`. An
    /// earlier version of this code used a `lungfish` fallback, which on
    /// case-insensitive filesystems accidentally matched the `Lungfish` GUI
    /// binary and ran it as the CLI.
    static func findCLI() -> URL? {
        CLIImportRunner.cliBinaryPath()
    }

    /// Runs the CLI with the supplied arguments and captures stdout/stderr.
    ///
    /// - Parameter arguments: Arguments passed to `lungfish-cli`.
    /// - Returns: The process output and termination status.
    /// - Throws: ``RunError`` on missing CLI, launch failure, or non-zero exit.
    static func run(arguments: [String]) throws -> Output {
        guard let cliURL = findCLI() else {
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "<nil>"
            let bundleDir = Bundle.main.bundleURL.path
            logger.error(
                "run: lungfish-cli not found. executableDirectory=\(execDir, privacy: .public), bundleURL=\(bundleDir, privacy: .public)"
            )
            throw RunError.cliNotFound
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let outputGroup = DispatchGroup()
        let stdoutCapture = OutputCapture()
        let stderrCapture = OutputCapture()

        outputGroup.enter()
        DispatchQueue(label: "com.lungfish.app.cli-runner-stdout", qos: .userInitiated).async {
            stdoutCapture.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue(label: "com.lungfish.app.cli-runner-stderr", qos: .userInitiated).async {
            stderrCapture.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        do {
            try process.run()
        } catch {
            logger.error("run: Failed to launch CLI: \(error.localizedDescription, privacy: .public)")
            throw RunError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        outputGroup.wait()

        let stdoutText = String(data: stdoutCapture.data, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrCapture.data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            logger.error(
                "run: CLI exited with status \(process.terminationStatus, privacy: .public): \(stderrText, privacy: .public)"
            )
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: stderrText)
        }

        return Output(stdout: stdoutText, stderr: stderrText, status: process.terminationStatus)
    }

    /// Runs `lungfish-cli build-db <tool> <resultDir>` synchronously.
    ///
    /// Intended to be called from a background `Task.detached` context at the
    /// end of a batch pipeline so the SQLite database is present on disk before
    /// the user opens the batch in the sidebar.
    ///
    /// - Parameters:
    ///   - tool: Classifier tool name (`kraken2`, `esviritu`, `taxtriage`).
    ///   - resultURL: The batch result directory that the CLI should operate on.
    /// - Throws: ``RunError`` on missing CLI, launch failure, or non-zero exit.
    static func buildClassifierDatabase(tool: String, resultURL: URL, force: Bool = false) throws {
        guard let cliURL = findCLI() else {
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "<nil>"
            let bundleDir = Bundle.main.bundleURL.path
            logger.error(
                "buildClassifierDatabase: lungfish-cli not found. executableDirectory=\(execDir, privacy: .public), bundleURL=\(bundleDir, privacy: .public)"
            )
            throw RunError.cliNotFound
        }

        logger.info(
            "buildClassifierDatabase: Launching '\(cliURL.path, privacy: .public)' build-db \(tool, privacy: .public) '\(resultURL.path, privacy: .public)'"
        )
        var arguments = ["build-db", tool, resultURL.path]
        if force {
            arguments.append("--force")
        }

        let output = try run(arguments: arguments)
        if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("buildClassifierDatabase: CLI stdout: \(output.stdout, privacy: .public)")
        }

        logger.info("buildClassifierDatabase: Build succeeded for \(tool, privacy: .public)")
    }
}

private final class OutputCapture: @unchecked Sendable {
    var data = Data()
}
