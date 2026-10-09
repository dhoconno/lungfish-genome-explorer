// ProcessNFCoreWorkflowProcessRunner.swift - Launches the managed Nextflow as a child process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct ProcessNFCoreWorkflowProcessRunner: NFCoreWorkflowProcessRunning {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Only the managed Nextflow is ever launched: a copy on `PATH` is a
    /// different version and is not a substitute (see `WorkflowEngineLaunch.resolveManaged`).
    var resolveLaunch: WorkflowEngineLaunchResolver = { executableName, homeDirectory in
        try WorkflowEngineLaunch.resolveManaged(executableName: executableName, homeDirectory: homeDirectory)
    }

    func preflightEngine() throws {
        _ = try resolveLaunch("nextflow", homeDirectory)
    }

    func runNextflow(
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> NFCoreWorkflowProcessResult {
        let launch = try resolveLaunch("nextflow", homeDirectory)
        let processEnvironment = launch.environment.merging(environment) { _, override in override }
        if launch.usesManagedExecutable {
            await CondaManager.shared.repairManagedLaunchers(environment: "nextflow")
        }
        let output = try await WorkflowEngineProcess.run(
            executableURL: launch.executableURL,
            arguments: launch.arguments(arguments),
            environment: processEnvironment,
            workingDirectory: workingDirectory,
            stdoutFileName: ".nextflow-stdout.log",
            stderrFileName: ".nextflow-stderr.log"
        )
        return NFCoreWorkflowProcessResult(
            exitCode: output.exitCode,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }
}

/// Runs a workflow engine for `workflow run`, with its output in two log
/// files that are read and removed when it ends.
///
/// The engine runs on ``ToolProcess`` as the leader of its own process group,
/// so cancelling the calling task stops the engine and everything it started,
/// such as Nextflow's JVM and its task processes.
enum WorkflowEngineProcess {
    /// How long the engine's process group has to empty after the engine
    /// exits. Nextflow and Snakemake can leave a child running for a moment.
    static let drainGracePeriod: Duration = .seconds(5)

    struct Output: Sendable, Equatable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs the engine to its end.
    ///
    /// - Returns: The exit status, or the signal number for an engine a
    ///   signal ended, and the text of both logs, each empty when it is not
    ///   valid UTF-8.
    /// - Throws: `CancellationError` when the calling task is cancelled,
    ///   after the engine's process tree is stopped. `CLIError.workflowFailed`
    ///   when a process the engine started was still running
    ///   ``drainGracePeriod`` after the engine exited, because the logs and
    ///   results may then be incomplete. A `ToolProcessError` when the engine
    ///   cannot be launched.
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdoutFileName: String,
        stderrFileName: String
    ) async throws -> Output {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let stdoutURL = workingDirectory.appendingPathComponent(stdoutFileName)
        let stderrURL = workingDirectory.appendingPathComponent(stderrFileName)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        let spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            stdout: .file(stdoutURL),
            stderr: .file(stderrURL),
            drainGracePeriod: drainGracePeriod
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch {
            if case .cancelled = error {
                throw CancellationError()
            }
            throw error
        }
        guard result.outputComplete else {
            throw CLIError.workflowFailed(
                reason: "\(spec.label) exited with status \(result.status), but its output and results may be incomplete because a process it started kept running after it exited. That process was stopped."
            )
        }
        return Output(
            exitCode: result.status,
            standardOutput: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }
}
