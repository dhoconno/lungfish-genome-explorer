// FastpMergeStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recipe step that merges overlapping paired-end reads using fastp.
///
/// Unlike the other fastp steps this one is NOT `FastpFusible` because it
/// changes the output format from `.pairedR1R2` to `.merged`, making fusion
/// with upstream trim/dedup steps incorrect.
public struct FastpMergeStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "fastp-merge"
    public static let displayName: String = "Paired-End Merge"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { keepUnmerged ? .merged : .single }

    // MARK: - Parameters

    /// Minimum overlap length required for two mates to be merged.
    public let minOverlap: Int
    /// Whether unmerged R1/R2 records should be retained beside merged reads.
    public let keepUnmerged: Bool

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        minOverlap = params?["minOverlap"]?.intValue ?? 15
        keepUnmerged = params?["keepUnmerged"]?.boolValue ?? true
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        // The argv an executor plan names too (RecipePlannedInvocation.swift).
        let invocation = try plannedInvocation(
            input: input, workspace: context.workspace, sampleName: context.sampleName, threads: context.threads
        )
        let merged = invocation.output.r1
        let unmergedR1 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R1.fq.gz")
        let unmergedR2 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R2.fq.gz")
        let report = invocation.auxiliaryOutputs[0]

        let result = try await context.runner.run(
            .fastp,
            arguments: invocation.arguments,
            timeout: context.recipeToolTimeout(for: .fastp, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        let counts = RecipeToolReportCounts.fastpMerge(reportAt: report)
        if keepUnmerged {
            // r1 = merged reads, r2 = unmerged R1, r3 = unmerged R2
            return StepOutput(
                r1: merged,
                r2: unmergedR1,
                r3: unmergedR2,
                format: .merged,
                readCount: counts.map { $0.mergedReads + 2 * $0.unmergedPairs },
                inputReadCount: counts?.inputPairs,
                tool: .fastp,
                arguments: result.arguments,
                auxiliaryOutputs: [report]
            )
        }

        try? FileManager.default.removeItem(at: unmergedR1)
        try? FileManager.default.removeItem(at: unmergedR2)
        return StepOutput(
            r1: merged,
            format: .single,
            readCount: counts?.mergedReads,
            inputReadCount: counts?.inputPairs,
            tool: .fastp,
            arguments: result.arguments,
            auxiliaryOutputs: [report]
        )
    }
}
