// SeqkitLengthFilterStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Recipe step that filters reads by length.
///
/// Single reads (`.single`, or the merged stream of a `.merged` layout) go
/// through `seqkit seq -m/-M`, which judges each record on its own. Mates are
/// never judged on their own: an R1/R2 pair (`.pairedR1R2`, or the unmerged
/// files of a `.merged` layout) goes through `fastp -A -G -Q -l/--length_limit`,
/// which drops BOTH mates when either fails, so no orphan is ever left
/// behind. The output keeps the input's layout, so a merged layout leaves
/// this step still merged and the engine writes the mixed file afterwards.
///
/// Before 2026-09-27 the engine flattened a merged layout to one single-end
/// file before this step; the per-record filter then left orphans and the
/// flattening itself had already separated every mate from its partner.
public struct SeqkitLengthFilterStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "seqkit-length-filter"
    public static let displayName: String = "Length Filter"

    public var inputFormat: RecipeFileFormat { .single }
    public var outputFormat: RecipeFileFormat { .single }

    /// The format this step wants for a given upstream format.
    ///
    /// `.merged` and `.pairedR1R2` are taken as they are; `.interleaved`
    /// still comes in as a single stream (the planner has no interleaved
    /// producer today); `.mixed` is refused at execution because its pairs
    /// cannot be told apart from its merged reads without another scan.
    func inputFormat(for upstream: RecipeFileFormat) -> RecipeFileFormat {
        switch upstream {
        case .merged, .pairedR1R2, .mixed:
            return upstream
        case .single, .interleaved:
            return .single
        }
    }

    /// The format this step produces for the input it was given.
    func outputFormat(for input: RecipeFileFormat) -> RecipeFileFormat {
        switch input {
        case .merged, .pairedR1R2:
            return input
        case .single, .interleaved, .mixed:
            return .single
        }
    }

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
        switch input.format {
        case .single, .interleaved:
            return try await filterSingleStream(input.r1, input: input, context: context)

        case .pairedR1R2:
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(
                    expected: .pairedR1R2, got: input.format, step: Self.typeID)
            }
            let pairs = try await filterPairs(
                r1: input.r1, r2: r2, input: input, context: context, label: "pairs")
            return StepOutput(
                r1: pairs.r1,
                r2: pairs.r2,
                format: .pairedR1R2,
                readCount: pairs.counts?.output,
                inputReadCount: pairs.counts?.input,
                tool: .fastp,
                arguments: pairs.invocation.arguments,
                auxiliaryOutputs: pairs.invocation.auxiliaryOutputs,
                exitStatus: pairs.invocation.exitStatus,
                stderr: pairs.invocation.stderr,
                startedAt: pairs.invocation.startedAt,
                completedAt: pairs.invocation.completedAt
            )

        case .merged:
            guard let unmergedR1 = input.r2, let unmergedR2 = input.r3 else {
                throw RecipeEngineError.formatMismatch(
                    expected: .merged, got: input.format, step: Self.typeID)
            }
            let merged = try await filterSingleStream(input.r1, input: input, context: context)
            let pairs = try await filterPairs(
                r1: unmergedR1, r2: unmergedR2, input: input, context: context, label: "unmerged pairs")
            // seqkit reports no count, so its merged reads are counted from
            // their lines; fastp's report gives the pairs.
            let mergedReads = try? await RecipeEngine.countReadsForRecipeStep(
                StepOutput(r1: merged.r1, format: .single))
            let readCount = mergedReads.flatMap { mergedCount in
                pairs.counts.map { mergedCount + 2 * $0.output }
            }
            return StepOutput(
                r1: merged.r1,
                r2: pairs.r1,
                r3: pairs.r2,
                format: .merged,
                readCount: readCount,
                tool: merged.tool,
                arguments: merged.arguments,
                exitStatus: merged.exitStatus,
                stderr: merged.stderr,
                startedAt: merged.startedAt,
                completedAt: merged.completedAt,
                supplementaryInvocations: [pairs.invocation]
            )

        case .mixed:
            throw RecipeEngineError.formatMismatch(
                expected: .merged, got: input.format, step: Self.typeID)
        }
    }

    // MARK: - seqkit on single reads

    private func filterSingleStream(
        _ source: URL,
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        // The argv an executor plan names too (RecipePlannedInvocation.swift).
        let invocation = singleStreamInvocation(
            source, inputFormat: input.format, workspace: context.workspace, sampleName: context.sampleName,
            threads: context.threads
        )
        let output = invocation.output.r1

        let seqkitClock = ProvenanceRunClock()
        let result = try await context.runner.run(
            .seqkit,
            arguments: invocation.arguments,
            timeout: context.recipeToolTimeout(for: .seqkit, inputURLs: [source])
        )
        let completedAt = seqkitClock.now
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "seqkit", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(
            r1: output,
            format: .single,
            tool: .seqkit,
            arguments: result.arguments,
            exitStatus: Int(result.exitCode),
            stderr: result.stderr,
            startedAt: seqkitClock.startedAt,
            completedAt: completedAt
        )
    }

    // MARK: - fastp on pairs

    /// The fastp argv that keeps a pair only when both mates satisfy the
    /// length bounds. Adapter trimming, poly-G trimming, and quality
    /// filtering are all off so length is the only criterion.
    static func fastpPairArguments(
        r1: URL, r2: URL, outR1: URL, outR2: URL, report: URL,
        minLength: Int, maxLength: Int?, threads: Int
    ) -> [String] {
        var args = [
            "-i", r1.path,
            "-I", r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "-A", "-G", "-Q",
            "-l", "\(max(0, minLength))",
        ]
        if let maxLength {
            args += ["--length_limit", "\(maxLength)"]
        }
        args += [
            "-w", "\(threads)",
            "-j", report.path,
            "-h", "/dev/null",
        ]
        return args
    }

    private func filterPairs(
        r1: URL,
        r2: URL,
        input: StepInput,
        context: StepContext,
        label: String
    ) async throws -> (
        r1: URL, r2: URL, invocation: RecipeSupplementaryInvocation, counts: (input: Int, output: Int)?
    ) {
        // The argv an executor plan names too (RecipePlannedInvocation.swift).
        let planned = pairInvocation(
            r1: r1, r2: r2, inputFormat: input.format, workspace: context.workspace, sampleName: context.sampleName,
            threads: context.threads, label: label
        )
        let outR1 = planned.output.r1
        guard let outR2 = planned.output.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: planned.output.format, step: Self.typeID)
        }
        let report = planned.auxiliaryOutputs[0]

        let fastpClock = ProvenanceRunClock()
        let result = try await context.runner.run(
            .fastp,
            arguments: planned.arguments,
            timeout: context.recipeToolTimeout(for: .fastp, inputURLs: [r1, r2])
        )
        let completedAt = fastpClock.now
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "fastp", step: Self.typeID, stderr: result.stderr)
        }

        let invocation = RecipeSupplementaryInvocation(
            label: label,
            tool: .fastp,
            arguments: result.arguments,
            exitStatus: Int(result.exitCode),
            stderr: result.stderr,
            startedAt: fastpClock.startedAt,
            completedAt: completedAt,
            outputFiles: [outR1, outR2],
            auxiliaryOutputs: [report]
        )
        return (outR1, outR2, invocation, RecipeToolReportCounts.fastpPairs(reportAt: report))
    }
}
