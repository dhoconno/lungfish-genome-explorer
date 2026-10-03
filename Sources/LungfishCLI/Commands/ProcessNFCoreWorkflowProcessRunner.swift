// ProcessNFCoreWorkflowProcessRunner.swift - Launches the managed Nextflow as a child process
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct ProcessNFCoreWorkflowProcessRunner: NFCoreWorkflowProcessRunning {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Only the managed Nextflow is ever launched: a copy on `PATH` is a
    /// different version and is not a substitute (see `WorkflowEngineLaunch.resolveManaged`).
    var resolveLaunch: WorkflowEngineLaunchResolver = { executableName, homeDirectory in
        try WorkflowEngineLaunch.resolveManaged(executableName: executableName, homeDirectory: homeDirectory)
    }

    func preflightEngine() throws {
        _ = try resolveLaunch("nextflow", homeDirectory)
    }

    func runNextflow(
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> NFCoreWorkflowProcessResult {
        let launch = try resolveLaunch("nextflow", homeDirectory)
        let processEnvironment = launch.environment.merging(environment) { _, override in override }
        if launch.usesManagedExecutable {
            await CondaManager.shared.repairManagedLaunchers(environment: "nextflow")
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                let stdoutURL = workingDirectory.appendingPathComponent(".nextflow-stdout.log")
                let stderrURL = workingDirectory.appendingPathComponent(".nextflow-stderr.log")
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                let process = Process()
                process.executableURL = launch.executableURL
                process.arguments = launch.arguments(arguments)
                process.environment = processEnvironment
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
                    continuation.resume(returning: NFCoreWorkflowProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: stdout,
                        standardError: stderr
                    ))
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
