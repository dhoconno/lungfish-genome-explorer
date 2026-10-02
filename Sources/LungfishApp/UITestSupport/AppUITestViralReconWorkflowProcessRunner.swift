// AppUITestViralReconWorkflowProcessRunner.swift - Deterministic Viral Recon CLI runner for XCUI launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// Stands in for the `lungfish-cli workflow viralrecon` process when the app
/// is launched for an XCUI test with the deterministic backend.
///
/// The Tools menu selects it when `AppUITestConfiguration.current` is enabled
/// and its backend mode is `.deterministic`. Only the CLI process is faked.
/// `ViralReconWorkflowExecutionService` still stages the inputs and the primer
/// scheme for real, so the Viral Recon XCUI tests check the real staging.
@MainActor
internal struct AppUITestViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        AppUITestConfiguration.current.appendEvent("viralrecon.cli.invoked \(arguments.joined(separator: " "))")
        outputHandler?(.standardOutput("deterministic Viral Recon completed"))
        return ViralReconWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "deterministic Viral Recon completed",
            standardError: "",
            didStreamOutput: true
        )
    }

    func cancel() {
        AppUITestConfiguration.current.appendEvent("viralrecon.cli.cancelled")
    }
}
