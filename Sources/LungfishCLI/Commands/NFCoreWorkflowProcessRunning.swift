// NFCoreWorkflowProcessRunning.swift - The seam that launches Nextflow for a workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

protocol NFCoreWorkflowProcessRunning: Sendable {
    /// Confirms the engine can be launched before the run bundle is marked
    /// running; throws a `MissingToolError` (exit 126) when it cannot.
    func preflightEngine() throws
    /// Runs Nextflow with `arguments`; `environment` overlays the launch environment.
    func runNextflow(
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> NFCoreWorkflowProcessResult
}

extension NFCoreWorkflowProcessRunning {
    func preflightEngine() throws {}
}
