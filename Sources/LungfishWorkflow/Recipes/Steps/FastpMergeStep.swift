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
    public var outputFormat: RecipeFileFormat { .merged }

    // MARK: - Parameters

    /// Minimum overlap length required for two mates to be merged.
    public let minOverlap: Int

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        minOverlap = params?["minOverlap"]?.intValue ?? 15
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let merged    = context.workspace.appendingPathComponent("\(context.sampleName)_merged.fq.gz")
        let unmergedR1 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R1.fq.gz")
        let unmergedR2 = context.workspace.appendingPathComponent("\(context.sampleName)_unmerged_R2.fq.gz")

        let args = [
            "-i", input.r1.path,
            "-I", r2.path,
            "--merge",
            "--merged_out", merged.path,
            "--out1", unmergedR1.path,
            "--out2", unmergedR2.path,
            "--overlap_len_require", "\(minOverlap)",
            "-A", "-G", "-Q", "-L",
            "-w", "\(context.threads)",
            "-j", "/dev/null",
            "-h", "/dev/null",
        ]

        let result = try await context.runner.run(
            .fastp,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .fastp, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "fastp", step: Self.typeID, stderr: result.stderr ?? "")
        }

        // r1 = merged reads, r2 = unmerged R1, r3 = unmerged R2
        return StepOutput(r1: merged, r2: unmergedR1, r3: unmergedR2, format: .merged, tool: .fastp, arguments: args)
    }
}
