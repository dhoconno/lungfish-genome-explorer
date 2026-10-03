// GATKPipelineExecutionResult.swift - Exit code, output and provenance location of a GATK run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKPipelineExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let provenanceURL: URL
}
