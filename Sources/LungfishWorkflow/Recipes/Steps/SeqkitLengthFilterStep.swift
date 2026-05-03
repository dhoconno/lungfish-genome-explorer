// SeqkitLengthFilterStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recipe step that filters reads by length using seqkit.
///
/// Accepts any single-stream input (`.single`, `.interleaved`, or the merged
/// stream from a `.merged` layout) and produces `.single` output.
public struct SeqkitLengthFilterStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "seqkit-length-filter"
    public static let displayName: String = "Length Filter"

    public var inputFormat: RecipeFileFormat { .single }
    public var outputFormat: RecipeFileFormat { .single }

    // MARK: - Parameters

    /// Minimum read length to keep (inclusive). 0 means no lower bound.
    public let minLength: Int

    /// Maximum read length to keep (inclusive). `nil` means no upper bound.
    public let maxLength: Int?

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        minLength = params?["minLength"]?.intValue ?? 0

        if let raw = params?["maxLength"] {
            maxLength = raw.intValue
        } else {
            maxLength = nil
        }
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        let output = context.workspace.appendingPathComponent(
            "\(context.sampleName)_lengthfilter.fq.gz")

        var args = [
            "seq",
            "-j", "\(context.threads)",
            "-m", "\(minLength)",
        ]

        if let max = maxLength {
            args += ["-M", "\(max)"]
        }

        args += [input.r1.path, "-o", output.path]

        let result = try await context.runner.run(
            .seqkit,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .seqkit, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "seqkit", step: Self.typeID, stderr: result.stderr ?? "")
        }

        return StepOutput(r1: output, format: .single, tool: .seqkit, arguments: args)
    }
}
