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

    /// Asks whether the Docker daemon answers before a docker launch, and finds a cancelled run's task containers
    /// (2.9 N5, N9). A Debug build asks the stand-in ``dockerStandInVariable`` names, when it names one.
    var containerRuntimeProbe: any ContainerRuntimeProbing = ProcessNFCoreWorkflowProcessRunner.defaultProbe()
    /// How the wait polls and starts Docker Desktop. A Debug build starts the stand-in in its place.
    var dockerWait: NextflowDockerWait = ProcessNFCoreWorkflowProcessRunner.defaultDockerWait()

    func preflightEngine() throws {
        _ = try resolveLaunch("nextflow", homeDirectory)
    }

    func waitForDocker(profile: String) async throws {
        var engine = Self.engine(profile: profile)
        engine.dockerWait = dockerWait
        try await engine.waitForDocker(probe: containerRuntimeProbe, progress: nil)
    }

    /// The engine of a launch with `profile`, Viral Recon's scratch prefix and the 4 s grace (2.9 N6). Only the
    /// descriptor's own docker profile waits for Docker and stops a cancelled run's containers.
    static func engine(profile: String) -> NextflowEngineProcess {
        NextflowEngineProcess(configuration: NextflowWorkflowDescriptor.viralRecon.engineConfiguration(profile: profile))
    }

    // MARK: - The Docker stand-in (Q33 R4)

    /// The variable a test gives a spawned `lungfish-cli` so its Docker wait and container cleanup ask a stand-in.
    ///
    /// It names an executable that stands in for the `docker` CLI and for `open -g -a Docker`, so the wait can never
    /// start Docker Desktop. Only a Debug build reads it, as `LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS`, so a
    /// release build ignores it whatever a user's environment holds (SWIFT 6).
    static let dockerStandInVariable = "LUNGFISH_DOCKER_STANDIN"

    /// The path `environment` names in ``dockerStandInVariable``, or nil when it names none or in a release build.
    ///
    /// A set variable always names the stand-in, so a relative or missing path fails the Docker wait
    /// (``NextflowEngineError/dockerDesktopNotStarted(detail:)``) and never reaches the real daemon (SWIFT's
    /// ruling on A30 deviation 2).
    static func dockerStandIn(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        guard let path = environment[dockerStandInVariable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }

    static func defaultProbe() -> any ContainerRuntimeProbing {
        #if DEBUG
        if let standIn = dockerStandIn() { return StandInDockerProbe(executable: standIn) }
        #endif
        return SystemContainerRuntimeProbe()
    }

    static func defaultDockerWait() -> NextflowDockerWait {
        dockerStandIn().map { NextflowDockerWait(openExecutable: $0) } ?? .standard
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
        let engine = Self.engine(profile: launch.profile)
        let outcome = try await engine.run(
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
            // A cancel stops the run's task containers once the host tree is gone, within 1.5 s (2.9 N5).
            hooks: NextflowEngineHooks(cleanup: engine.containerCleanup(probe: containerRuntimeProbe))
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

#if DEBUG
/// The stand-in `docker` CLI a Debug build's ``ProcessNFCoreWorkflowProcessRunner/dockerStandInVariable`` names, asked
/// as the system probe asks the real one. A release build has no such type.
struct StandInDockerProbe: ContainerRuntimeProbing {
    let executable: URL

    func dockerCLIPath() -> String? {
        executable.path
    }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: dockerPath, timeout: timeout)
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: "not asked of a Docker stand-in")
    }
}
#endif

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
