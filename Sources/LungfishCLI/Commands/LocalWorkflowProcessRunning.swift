// LocalWorkflowProcessRunning.swift - The seam that launches a local workflow engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

protocol LocalWorkflowProcessRunning: Sendable {
    func runtimeExecutableURL(named executableName: String) -> URL?
    func runWorkflow(
        executableName: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> LocalWorkflowProcessResult
}

extension LocalWorkflowProcessRunning {
    /// The managed engine, or nil: a copy on `PATH` is never launched, so it
    /// is never reported as the runtime either.
    func runtimeExecutableURL(named executableName: String) -> URL? {
        try? WorkflowEngineLaunch.resolveManaged(executableName: executableName,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser).resolvedExecutableURL()
    }
}
