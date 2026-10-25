// ExecutorPlanLoneFastpSteps.swift - The plan forms of a fastp trim or dedup step that runs on its own (CHTC C5 lane BF M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// A fastp step with no fastp step beside it runs on its own, as the built-in recipe's trim does when duplicates are kept
// (`--no-remove-duplicates`). Its plan form is the argv its `execute` runs on the Mac: the fused call's frame around the
// step's own flags (`RecipeEngine.fusedFastpArguments`). Only the trim's report name differs, a fixed name in the plan
// in place of the Mac's per-run UUID name, which XC-10's one strip function maps (D18, BI:29).

extension FastpTrimStep: RecipePlannableStep {
    /// The lone trim run, which writes its pairs and the fastp report the Mac's run takes its pair counts from.
    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }
        let outR1 = workspace.appendingPathComponent("\(sampleName)_trim_R1.fq.gz")
        let outR2 = workspace.appendingPathComponent("\(sampleName)_trim_R2.fq.gz")
        let report = workspace.appendingPathComponent("\(sampleName)_trim_fastp_report.json")
        let arguments = RecipeEngine.fusedFastpArguments(
            extraArgs: fastpArgs(), r1: input.r1, r2: r2, outR1: outR1, outR2: outR2, report: report, threads: threads
        )
        return RecipePlannedRun(RecipePlannedInvocation(
            tool: .fastp, arguments: arguments, inputs: [input.r1, r2],
            output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2), auxiliaryOutputs: [report]
        ))
    }
}

extension FastpDedupStep: RecipePlannableStep {
    /// The lone dedup run of a user recipe, which removes duplicates and nothing else and, as on the Mac, writes no
    /// report (`-j /dev/null`).
    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }
        let outR1 = workspace.appendingPathComponent("\(sampleName)_dedup_R1.fq.gz")
        let outR2 = workspace.appendingPathComponent("\(sampleName)_dedup_R2.fq.gz")
        let arguments = RecipeEngine.fusedFastpArguments(
            extraArgs: fastpArgs() + Self.dedupOnlyArgs, r1: input.r1, r2: r2, outR1: outR1, outR2: outR2,
            report: URL(fileURLWithPath: "/dev/null"), threads: threads
        )
        return RecipePlannedRun(RecipePlannedInvocation(
            tool: .fastp, arguments: arguments, inputs: [input.r1, r2],
            output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2)
        ))
    }
}
