// LungfishCLIRunner.swift — Locates and invokes the `lungfish-cli` subprocess.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "LungfishCLIRunner")

/// Locates and runs the `lungfish-cli` binary as a subprocess from the GUI app.
///
/// The CLI is the canonical implementation of heavyweight operations like
/// `build-db` that the GUI would otherwise have to duplicate. Reusing the CLI
/// via a subprocess keeps the logic in one place and avoids pulling large
/// parsing/SQL code into the GUI target.
public enum LungfishCLIRunner {
    /// Cancels a ``run(arguments:executableURL:cancellation:)`` call from any
    /// thread, before it starts, while it runs or never.
    ///
    /// ``cancel()`` returns at once. ToolProcess stops the CLI's process group
    /// and its descendants, and the run then throws ``RunError/cancelled``.
    public final class CancellationHandle: Sendable {
        fileprivate let cancellation = CLIRunCancellation()

        public init() {}

        public func cancel() {
            cancellation.cancel()
        }
    }

    public struct Output: Sendable, Equatable {
        public let stdout: String
        public let stderr: String
        public let status: Int32

        public init(stdout: String, stderr: String, status: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.status = status
        }
    }

    /// An error returned from a CLI invocation.
    public enum RunError: Error, LocalizedError {
        case cliNotFound
        case cancelled
        case nonZeroExit(status: Int32, stderr: String)
        case launchFailed(String)
        case invalidInvocation(String)

        public var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The `lungfish-cli` binary could not be found in the app bundle or build products."
            case .cancelled:
                return "Operation cancelled"
            case .nonZeroExit(let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "lungfish-cli exited with status \(status)"
                    : "lungfish-cli exited with status \(status): \(trimmed)"
            case .launchFailed(let message):
                return "Failed to launch lungfish-cli: \(message)"
            case .invalidInvocation(let message):
                return message
            }
        }
    }

    /// Locates the `lungfish-cli` binary.
    ///
    /// Delegates to ``CLIBinaryLocator/cliBinaryPath()``, the canonical CLI
    /// resolver already used by the FASTQ import pipeline. That implementation
    /// handles all three launch layouts:
    ///   * Plain SPM debug binary (`.build/debug/Lungfish`) — CLI found in the
    ///     same directory as the GUI binary.
    ///   * Xcode debug `.app` (`DerivedData/.../Debug/Lungfish.app`) — CLI
    ///     found by walking to the package root and asking SwiftPM for its
    ///     active binary directory.
    ///   * Release `.app` with bundled CLI — found adjacent to the main executable
    ///     inside `Lungfish.app/Contents/MacOS/`.
    ///   * System install — found via `which lungfish-cli` (`/usr/local/bin`, Homebrew, etc.).
    ///
    /// **Important:** only searches for the exact name `lungfish-cli`. An
    /// earlier version of this code used a `lungfish` fallback, which on
    /// case-insensitive filesystems accidentally matched the `Lungfish` GUI
    /// binary and ran it as the CLI.
    public static func findCLI() -> URL? {
        CLIBinaryLocator.cliBinaryPath()
    }

    /// Runs the CLI with the supplied arguments and captures stdout/stderr.
    ///
    /// The call suspends until the CLI has exited and its output is drained,
    /// so it holds no thread while it waits. The process runs on
    /// ``ToolProcess``, which reads both pipes until end of file and stops the
    /// whole process tree when the calling task or the `cancellation` handle
    /// is cancelled.
    ///
    /// - Parameter arguments: Arguments passed to `lungfish-cli`.
    /// - Returns: The process output and termination status.
    /// - Throws: ``RunError`` on missing CLI, launch failure, or non-zero exit.
    public static func run(
        arguments: [String],
        executableURL: URL? = nil,
        cancellation: CancellationHandle? = nil
    ) async throws -> Output {
        guard let cliURL = executableURL ?? findCLI() else {
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "<nil>"
            let bundleDir = Bundle.main.bundleURL.path
            logger.error(
                "run: lungfish-cli not found. executableDirectory=\(execDir, privacy: .public), bundleURL=\(bundleDir, privacy: .public)"
            )
            throw RunError.cliNotFound
        }

        let spec = ToolProcessSpec(
            executableURL: cliURL,
            arguments: arguments,
            environment: ManagedStorageConfigStore().subprocessEnvironment(),
            terminationGracePeriod: .zero,
            label: "lungfish-cli"
        )
        let outcome = await (cancellation?.cancellation ?? CLIRunCancellation()).run(spec)

        let result: ToolProcessResult
        switch outcome.result {
        case .success(let finished):
            result = finished
        case .failure(.cancelled):
            throw RunError.cancelled
        case .failure(let error):
            logger.error("run: Failed to launch CLI: \(error.localizedDescription, privacy: .public)")
            throw RunError.launchFailed(error.cliLaunchFailureReason)
        }

        if outcome.cancelRequested || result.stop == .cancelled {
            throw RunError.cancelled
        }

        let stdoutText = result.cliStdoutText
        let stderrText = result.cliStderrText

        if let incomplete = result.cliIncompleteOutputNote {
            logger.error("run: \(incomplete, privacy: .public)")
            throw RunError.nonZeroExit(
                status: result.status,
                stderr: [stderrText, incomplete].filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }

        if result.status != 0 {
            logger.error(
                "run: CLI exited with status \(result.status, privacy: .public): \(stderrText, privacy: .public)"
            )
            throw RunError.nonZeroExit(status: result.status, stderr: stderrText)
        }

        return Output(stdout: stdoutText, stderr: stderrText, status: result.status)
    }

    /// Runs `lungfish-cli build-db <tool> <resultDir>` and waits for it.
    ///
    /// Intended to be called from a background task at the end of a batch
    /// pipeline so the SQLite database is present on disk before the user
    /// opens the batch in the sidebar.
    ///
    /// - Parameters:
    ///   - tool: Classifier tool name (`kraken2`, `esviritu`, `taxtriage`).
    ///   - resultURL: The batch result directory that the CLI should operate on.
    ///   - sampleDirectories: Kraken2 sample result directories to include. When
    ///     provided, sibling directories under `resultURL` are ignored.
    /// - Throws: ``RunError`` on missing CLI, launch failure, or non-zero exit.
    public static func buildClassifierDatabase(
        tool: String,
        resultURL: URL,
        force: Bool = false,
        sampleDirectories: [URL] = []
    ) async throws {
        if !sampleDirectories.isEmpty && tool != "kraken2" {
            throw RunError.invalidInvocation("Explicit sample directories are only supported for Kraken2 database builds.")
        }

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
        for sampleDirectory in sampleDirectories {
            arguments += ["--sample-dir", sampleDirectory.standardizedFileURL.path]
        }

        let output = try await run(arguments: arguments)
        if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("buildClassifierDatabase: CLI stdout: \(output.stdout, privacy: .public)")
        }

        logger.info("buildClassifierDatabase: Build succeeded for \(tool, privacy: .public)")
    }
}
