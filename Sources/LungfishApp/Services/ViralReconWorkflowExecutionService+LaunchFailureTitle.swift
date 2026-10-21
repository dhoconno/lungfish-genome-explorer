// ViralReconWorkflowExecutionService+LaunchFailureTitle.swift - The headline of a Viral Recon launch failure row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension ViralReconWorkflowExecutionService {
    /// The headline of the failed row that reports a launch failure. A results folder that already holds files gets
    /// the title UX fixed (W1, Phase 2.13 lane 13.21), and any other failure keeps the generic one.
    nonisolated static func launchFailureTitle(for error: Error) -> String {
        ViralReconRunRequest.ResultsFolder.title(for: error) ?? "Viral Recon could not start"
    }
}
