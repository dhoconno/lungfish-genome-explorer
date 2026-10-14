// ProcessNFCoreWorkflowProcessRunner.swift - Launches the managed Nextflow as a child process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Runs the managed Nextflow of `workflow run nf-core/viralrecon` on ``NextflowEngineProcess``, the one launch path
/// of every Nextflow workflow (Phase 2.10 N1), with the settings of ``NextflowWorkflowDescriptor/viralRecon``.
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

    /// The engine of a launch with `profile`, Viral Recon's scratch prefix and the 4 s grace (2.9 N6).
    static func engine(profile: String) -> NextflowEngineProcess {
        NextflowEngineProcess(configuration: NextflowWorkflowDescriptor.viralRecon.engineConfiguration(profile: profile))
    }

    /// Streams the engine's output into the launch's log and returns once its tree is gone.
    ///
    /// A cancel of the calling task stops the tree, TERM and then KILL after the 4 s grace, and is thrown as
    /// `CancellationError` once the tree is gone. The result holds the last lines of each stream the engine kept, 200
    /// at most, and the log holds every line. A log the engine could not write in full fails the run (2.9 N8).
    func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
        let engineLaunch = try resolveLaunch("nextflow", homeDirectory)
        if engineLaunch.usesManagedExecutable {
            await CondaManager.shared.repairManagedLaunchers(environment: "nextflow")
        }
        for folder in [launch.workingDirectory, launch.logFile.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let arguments = engineLaunch.arguments(launch.arguments)
        let outcome = try await Self.engine(profile: launch.profile).run(
            NextflowEngineLaunch(
                executable: engineLaunch.executableURL,
                arguments: arguments,
                environment: engineLaunch.environment.merging(launch.environment) { _, override in override },
                logFile: launch.logFile,
                logPreamble: Self.logPreamble(executable: engineLaunch.executableURL, arguments: arguments, launch: launch),
                traceFile: nil
            ),
            in: NextflowEngineScratch(
                launchDirectory: launch.workingDirectory,
                workDirectory: launch.workDirectory,
                removalRoot: nil
            ),
            hooks: NextflowEngineHooks()
        )
        try Task.checkCancellation()
        if let logFailure = outcome.logFailure {
            throw CLIError.workflowFailed(reason: logFailure)
        }
        return NFCoreWorkflowProcessResult(
            exitCode: outcome.exitCode,
            standardOutput: outcome.stdoutTail.map { $0 + "\n" }.joined(),
            standardError: outcome.stderrTail.map { $0 + "\n" }.joined()
        )
    }

    /// The first part of `logs/nextflow.log`, the command that ran and its two folders.
    static func logPreamble(executable: URL, arguments: [String], launch: NFCoreWorkflowLaunch) -> String {
        [
            "nextflow_command: " + ([executable.path] + arguments).map(shellEscape).joined(separator: " "),
            "launch_directory: \(launch.workingDirectory.path)",
            "work_directory: \(launch.workDirectory.path)",
        ].joined(separator: "\n")
    }
}

/// Runs a local workflow's engine for `workflow run`, with its output in two log
/// files that are read and removed when it ends.
///
/// The engine runs on ``ToolProcess`` as the leader of its own process group,
/// so cancelling the calling task stops the engine and everything it started,
/// such as Nextflow's JVM and its task processes. The tree gets TERM and then
/// KILL after the Nextflow engine's 4 s grace, so Nextflow can stop its tasks
/// and finish its own shutdown (Phase 2.9, decision N6).
enum WorkflowEngineProcess {
    /// How long the engine's process group has to empty after the engine
    /// exits. Nextflow and Snakemake can leave a child running for a moment,
    /// and ToolProcess's default grace covers it.
    static let drainGracePeriod = ToolProcessSpec.defaultDrainGracePeriod

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
            terminationGracePeriod: NextflowEngineProcess.terminationGracePeriod
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
        if let incomplete = result.incompleteOutputReason {
            throw CLIError.workflowFailed(
                reason: "\(spec.label) exited with status \(result.status). \(incomplete)"
            )
        }
        return Output(
            exitCode: result.status,
            standardOutput: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }
}
