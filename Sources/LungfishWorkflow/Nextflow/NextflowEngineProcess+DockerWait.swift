// NextflowEngineProcess+DockerWait.swift - The one wait for the Docker daemon before a Nextflow launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "NextflowEngineProcess")

extension NextflowEngineProcess {
    /// Waits until the Docker daemon answers, for a launch whose effective profile runs its tasks in Docker (N9).
    ///
    /// When the daemon does not answer, the engine asks macOS to start Docker Desktop with
    /// `open -g -a Docker` and polls the daemon until it answers or the wait runs out. It reports
    /// TaxTriage's words at 0.01 and 0.02. A launch whose configuration does not wait returns at once.
    ///
    /// - Throws: `CancellationError` at once when the task is cancelled, with Docker Desktop never
    ///   started after the cancel (E9). ``NextflowEngineError/dockerDesktopNotStarted(detail:)`` at
    ///   once when `open` fails, and ``NextflowEngineError/dockerUnavailable`` when the wait runs out.
    package func waitForDocker(
        probe: any ContainerRuntimeProbing,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        guard configuration.waitsForDocker else { return }
        try Task.checkCancellation()
        if await Self.dockerAnswers(probe) { return }
        try Task.checkCancellation()

        progress?(0.01, "Docker daemon unavailable. Launching Docker Desktop...")
        logger.warning("Docker daemon unavailable, asking macOS to start Docker Desktop")
        try await openDockerDesktop()

        var waited: Duration = .zero
        while waited < dockerWait.timeout {
            try await Task.sleep(for: dockerWait.pollInterval)
            waited += dockerWait.pollInterval
            let answers = await Self.dockerAnswers(probe)
            try Task.checkCancellation()
            if answers {
                logger.info("Docker daemon answered after \(String(describing: waited), privacy: .public)")
                progress?(0.02, "Docker daemon ready")
                return
            }
        }
        throw NextflowEngineError.dockerUnavailable
    }

    /// Asks macOS to start Docker Desktop and returns once `open` has ended.
    ///
    /// - Throws: `CancellationError` when the task is cancelled before or while `open` runs, and
    ///   ``NextflowEngineError/dockerDesktopNotStarted(detail:)`` when `open` cannot run or fails.
    private func openDockerDesktop() async throws {
        try Task.checkCancellation()
        let result: (exitCode: Int32, stdout: String, stderr: String)
        do {
            result = try await processManager.runAndWait(
                executable: dockerWait.openExecutable,
                arguments: dockerWait.openArguments,
                workingDirectory: FileManager.default.temporaryDirectory
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Could not start Docker Desktop: \(error.localizedDescription, privacy: .public)")
            throw NextflowEngineError.dockerDesktopNotStarted(detail: error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "\(dockerWait.openExecutable.lastPathComponent) exited with status \(result.exitCode)" : stderr
            logger.warning("Could not start Docker Desktop: \(detail, privacy: .public)")
            throw NextflowEngineError.dockerDesktopNotStarted(detail: detail)
        }
        logger.info("Asked macOS to start Docker Desktop")
    }

    /// Whether the Docker daemon answers right now, by the probe every container verdict uses.
    private static func dockerAnswers(_ probe: any ContainerRuntimeProbing) async -> Bool {
        let status = await PipelineContainerRuntimeStatus.check(probe: probe)
        if !status.available {
            logger.warning("Docker daemon unavailable: \(status.detail ?? status.unavailableMessage, privacy: .public)")
        }
        return status.available
    }
}

/// How the engine waits for the Docker daemon (N9). The defaults are TaxTriage's since before 2.9, a
/// poll every 2 s for 90 s after `open -g -a Docker`.
package struct NextflowDockerWait: Sendable, Equatable {
    package var pollInterval: Duration
    package var timeout: Duration
    /// The program that asks macOS to start Docker Desktop, and its arguments.
    package var openExecutable: URL
    package var openArguments: [String]

    package init(
        pollInterval: Duration = .seconds(2),
        timeout: Duration = .seconds(90),
        openExecutable: URL = URL(fileURLWithPath: "/usr/bin/open"),
        openArguments: [String] = ["-g", "-a", "Docker"]
    ) {
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.openExecutable = openExecutable
        self.openArguments = openArguments
    }

    package static let standard = NextflowDockerWait()
}
