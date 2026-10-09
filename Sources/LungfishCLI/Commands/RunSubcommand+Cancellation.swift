// RunSubcommand+Cancellation.swift - SIGTERM cancels `workflow run` and stops the engine's process tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation

extension RunSubcommand {
    /// Launches the workflow so that SIGTERM cancels it instead of ending
    /// this command.
    ///
    /// The window's Cancel sends SIGTERM to `lungfish-cli`. Without a handler
    /// the CLI died at once, and Nextflow's JVM and its task processes kept
    /// running, because they are not this process's children to reap.
    /// Cancelling the task reaches the engine runner, which stops the engine's
    /// whole process tree through ToolProcess, and the run bundle records the
    /// cancel. Like `import fastq`, the command listens before the task
    /// starts, so a SIGTERM caught before then cancels the task as soon as it
    /// exists, and a second SIGTERM ends the command at once.
    func launchCancellingOnSIGTERM(
        workflowParams: [String: String],
        isViralRecon: Bool,
        isNextflow: Bool,
        isSnakemake: Bool,
        formatter: TerminalFormatter
    ) async throws {
        let pendingCancel = PendingTaskCancel<(any Error)?>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let task = Task { () -> (any Error)? in
            do {
                try await self.launch(
                    workflowParams: workflowParams,
                    isViralRecon: isViralRecon,
                    isNextflow: isNextflow,
                    isSnakemake: isSnakemake,
                    formatter: formatter
                )
                return nil
            } catch {
                return error
            }
        }
        pendingCancel.attach(task)
        guard let error = await task.value else { return }
        if error is CancellationError {
            FileHandle.standardError.write(Data((formatter.error("Workflow cancelled") + "\n").utf8))
            throw CLIExitCode.cancelled.exitCode
        }
        throw error
    }

    private func launch(
        workflowParams: [String: String],
        isViralRecon: Bool,
        isNextflow: Bool,
        isSnakemake: Bool,
        formatter: TerminalFormatter
    ) async throws {
        if workflow.contains("nf-core") || isViralRecon {
            try await runNFCoreWorkflow(
                workflowParams: workflowParams,
                formatter: formatter
            )
            return
        }

        if !globalOptions.quiet {
            let engine = isNextflow ? "Nextflow" : (isSnakemake ? "Snakemake" : "Unknown")
            print(formatter.info("Detected workflow engine: \(engine)"))
            print(formatter.info("Starting workflow execution..."))
        }

        try await runLocalWorkflow(
            workflowParams: workflowParams,
            isNextflow: isNextflow,
            isSnakemake: isSnakemake,
            formatter: formatter
        )
    }
}
