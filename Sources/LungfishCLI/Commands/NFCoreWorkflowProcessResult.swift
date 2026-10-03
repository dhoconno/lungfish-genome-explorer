// NFCoreWorkflowProcessResult.swift - The exit code and output of a Nextflow process run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct NFCoreWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}
