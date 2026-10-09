// ProcessLocalWorkflowProcessRunner.swift - Launches a managed local workflow engine as a child process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct ProcessLocalWorkflowProcessRunner: LocalWorkflowProcessRunning {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Managed engines only; see `ProcessNFCoreWorkflowProcessRunner.resolveLaunch`.
    var resolveLaunch: WorkflowEngineLaunchResolver = { executableName, homeDirectory in
        try WorkflowEngineLaunch.resolveManaged(executableName: executableName, homeDirectory: homeDirectory)
    }

    func runtimeExecutableURL(named executableName: String) -> URL? {
        try? resolveLaunch(executableName, homeDirectory).resolvedExecutableURL()
    }

    func runWorkflow(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowProcessResult {
        let launch = try resolveLaunch(executableName, homeDirectory)
        if launch.usesManagedExecutable {
            await CondaManager.shared.repairManagedLaunchers(environment: executableName)
        }
        let runtimeEvidence = LocalWorkflowRuntimeEvidence.capture(afterRepair: launch)
        let output = try await WorkflowEngineProcess.run(
            executableURL: launch.executableURL,
            arguments: launch.arguments(arguments),
            environment: launch.environment,
            workingDirectory: workingDirectory,
            stdoutFileName: ".lungfish-workflow-stdout.log",
            stderrFileName: ".lungfish-workflow-stderr.log"
        )
        return LocalWorkflowProcessResult(
            exitCode: output.exitCode,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            runtimeEvidence: runtimeEvidence
        )
    }
}
