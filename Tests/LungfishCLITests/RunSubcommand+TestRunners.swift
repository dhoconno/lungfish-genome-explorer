// RunSubcommand+TestRunners.swift - Runs `workflow run` with a test's engine runner bound for that run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M2 (plan N1, SWIFT 1). The runner seams of `RunSubcommand` are task-local, so a test binds its
// runner for one run of the command and nothing outlives the test.

@testable import LungfishCLI

extension RunSubcommand {
    /// Runs the command with `runner` as the engine runner of an nf-core workflow.
    func run(nfCoreRunner runner: any NFCoreWorkflowProcessRunning) async throws {
        try await Self.$nfCoreWorkflowProcessRunner.withValue(runner) {
            try await run()
        }
    }

    /// Runs the command with `runner` as the engine runner of a local workflow.
    func run(localRunner runner: any LocalWorkflowProcessRunning) async throws {
        try await Self.$localWorkflowProcessRunner.withValue(runner) {
            try await run()
        }
    }
}
