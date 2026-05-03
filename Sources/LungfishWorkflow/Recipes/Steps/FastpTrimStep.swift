// FastpTrimStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recipe step that trims adapters and low-quality bases using fastp.
///
/// Conforms to `FastpFusible` so the recipe engine can merge consecutive fastp
/// steps into a single invocation.
public struct FastpTrimStep: FastpFusible {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "fastp-trim"
    public static let displayName: String = "Adapter + Quality Trim"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    // MARK: - Parameters

    /// Whether to enable fastp's automatic adapter detection for paired-end reads.
    public let detectAdapter: Bool

    /// Minimum base quality threshold for sliding-window trimming.
    public let quality: Int

    /// Sliding-window size for quality trimming.
    public let window: Int

    /// End(s) of the read to trim. Valid values: "right", "front", "tail", "both".
    public let cutMode: String

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        detectAdapter = params?["detectAdapter"]?.boolValue ?? true
        quality       = params?["quality"]?.intValue       ?? 20
        window        = params?["window"]?.intValue        ?? 4
        cutMode       = params?["cutMode"]?.stringValue    ?? "right"

        let validModes: Set<String> = ["right", "front", "tail", "both"]
        guard validModes.contains(cutMode) else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID, param: "cutMode", value: cutMode)
        }
    }

    // MARK: - FastpFusible

    public func fastpArgs() -> [String] {
        var args: [String] = []

        if detectAdapter {
            args.append("--detect_adapter_for_pe")
        }

        args += ["-q", "\(quality)", "-W", "\(window)"]

        switch cutMode {
        case "front":
            args.append("--cut_front")
        case "tail":
            args.append("--cut_tail")
        case "both":
            args += ["--cut_front", "--cut_right"]
        default: // "right"
            args.append("--cut_right")
        }

        return args
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_trim_R2.fq.gz")

        var args = [
            "-i", input.r1.path,
            "-I", r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
        ]
        args += fastpArgs()
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
                tool: "fastp", step: Self.typeID, stderr: result.stderr ?? "")
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2, tool: .fastp, arguments: args)
    }
}
