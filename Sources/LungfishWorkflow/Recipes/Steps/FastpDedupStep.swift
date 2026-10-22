// FastpDedupStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recipe step that removes PCR duplicates using fastp.
///
/// Conforms to `FastpFusible` so the recipe engine can merge consecutive fastp
/// steps into a single invocation, avoiding redundant compression/decompression.
public struct FastpDedupStep: FastpFusible {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "fastp-dedup"
    public static let displayName: String = "PCR Duplicate Removal"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    public init(params: [String: AnyCodableValue]?) throws {
        // No parameters needed for dedup
    }

    // MARK: - FastpFusible

    /// The dedup flags a fused call takes. Accuracy 3 is fastp's dedup default, written out so that a new default
    /// cannot move it. The fused call no longer turns adapter, poly-G, quality and length processing off, because
    /// the trim step beside it names each of them (ruling BIO-PRESET P1, owner answer O11).
    public func fastpArgs() -> [String] {
        ["--dedup", "--dup_calc_accuracy", "3"]
    }

    /// What a dedup step run alone adds, so that it removes duplicates and nothing else.
    public static let dedupOnlyArgs = ["-A", "-G", "-Q", "-L"]

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_dedup_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_dedup_R2.fq.gz")

        var args = [
            "-i", input.r1.path,
            "-I", r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
        ]
        args += fastpArgs() + Self.dedupOnlyArgs
        args += [
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
                tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2, tool: .fastp, arguments: result.arguments)
    }
}
