// LocalWorkflowProcessResult.swift - The exit code, output and runtime evidence of a local workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct LocalWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let runtimeEvidence: LocalWorkflowRuntimeEvidence?

    init(exitCode: Int32, standardOutput: String, standardError: String,
         runtimeEvidence: LocalWorkflowRuntimeEvidence? = nil) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.runtimeEvidence = runtimeEvidence
    }
}
