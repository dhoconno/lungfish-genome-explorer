// AlignmentMarkdupPipeline.swift - Compatibility shims for workflow-owned markdup pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

public typealias AlignmentSamtoolsRunning = LungfishWorkflow.AlignmentSamtoolsRunning
public typealias NativeToolSamtoolsRunner = LungfishWorkflow.NativeToolSamtoolsRunner
public typealias AlignmentCommandExecutionRecord = LungfishWorkflow.AlignmentCommandExecutionRecord
public typealias AlignmentMarkdupIntermediateFiles = LungfishWorkflow.AlignmentMarkdupIntermediateFiles
public typealias AlignmentMarkdupPipelineResult = LungfishWorkflow.AlignmentMarkdupPipelineResult
public typealias AlignmentMarkdupPipelining = LungfishWorkflow.AlignmentMarkdupPipelining
public typealias AlignmentMarkdupPipelineError = LungfishWorkflow.AlignmentMarkdupPipelineError

public struct AlignmentMarkdupPipeline: AlignmentMarkdupPipelining, Sendable {
    private let workflowPipeline: LungfishWorkflow.AlignmentMarkdupPipeline

    public init(samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared) {
        self.workflowPipeline = LungfishWorkflow.AlignmentMarkdupPipeline(samtoolsRunner: samtoolsRunner)
    }

    public func run(
        inputURL: URL,
        outputURL: URL,
        removeDuplicates: Bool,
        referenceFastaPath: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> AlignmentMarkdupPipelineResult {
        do {
            return try await workflowPipeline.run(
                inputURL: inputURL,
                outputURL: outputURL,
                removeDuplicates: removeDuplicates,
                referenceFastaPath: referenceFastaPath,
                progressHandler: progressHandler
            )
        } catch let error as LungfishWorkflow.AlignmentMarkdupPipelineError {
            switch error {
            case .samtoolsFailed(let message):
                throw AlignmentDuplicateError.samtoolsFailed(message)
            }
        }
    }
}
