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
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                let stdoutURL = workingDirectory.appendingPathComponent(".lungfish-workflow-stdout.log")
                let stderrURL = workingDirectory.appendingPathComponent(".lungfish-workflow-stderr.log")
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                let process = Process()
                process.executableURL = launch.executableURL
                process.arguments = launch.arguments(arguments)
                process.environment = launch.environment
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { process in
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                    continuation.resume(returning: LocalWorkflowProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: stdout,
                        standardError: stderr,
                        runtimeEvidence: runtimeEvidence
                    ))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
