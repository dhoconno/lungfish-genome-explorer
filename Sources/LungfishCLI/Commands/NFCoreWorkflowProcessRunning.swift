// NFCoreWorkflowProcessRunning.swift - The seam that launches Nextflow for a workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// One launch of the managed Nextflow for `workflow run nf-core/viralrecon`, in the run's launch scratch.
struct NFCoreWorkflowLaunch: Sendable, Equatable {
    /// The arguments of `nextflow`.
    let arguments: [String]
    /// The profile the arguments pass with `-profile`, which gives the engine its settings.
    let profile: String
    /// The scratch's launch folder, which holds Nextflow's `.nextflow/` (2.9 N7).
    let workingDirectory: URL
    /// The work folder the arguments name.
    let workDirectory: URL
    /// The settings the release needs, laid over the managed launch's own environment.
    let environment: [String: String]
    /// The run bundle's `logs/nextflow.log`, which the engine writes while it runs (2.9 N8).
    let logFile: URL
}

protocol NFCoreWorkflowProcessRunning: Sendable {
    /// Confirms the engine can be launched before the run bundle is marked
    /// running; throws a `MissingToolError` (exit 126) when it cannot.
    func preflightEngine() throws
    /// Waits for the Docker daemon when a launch with `profile` runs its tasks in Docker (2.9 N9).
    ///
    /// `progress` gets the engine's three lines and their fractions, `Docker daemon unavailable. Launching Docker
    /// Desktop...` at 0.01, `Docker daemon ready` at 0.02 and `Starting the pipeline...` at 0.03, which the command
    /// prints (ARCH's ruling on A30 M3, and 2.11 U64).
    ///
    /// - Throws: `CancellationError` at once on a cancel, and a `NextflowEngineError` when Docker Desktop
    ///   cannot be started or the daemon does not answer in time.
    func waitForDocker(profile: String, progress: (@Sendable (Double, String) -> Void)?) async throws
    /// Runs Nextflow for `launch` and returns once the engine's process tree is gone.
    ///
    /// - Throws: `CancellationError` when the calling task was cancelled, once the tree is gone.
    func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult
}

extension NFCoreWorkflowProcessRunning {
    func preflightEngine() throws {}
    func waitForDocker(profile: String, progress: (@Sendable (Double, String) -> Void)?) async throws {}
}
