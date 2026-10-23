// RecipePlannedInvocation.swift - The argv of a recipe tool run, built before it runs (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One tool run of a recipe as it is decided before anything starts: the tool, its argv and the files it leaves.
///
/// The in-process run and the executor plan build a run through the same function, so a plan's argv is the argv
/// the Mac runs, with the plan's work root in place of the Mac's workspace (CHTC lane K4, SWIFT N8).
package struct RecipePlannedInvocation: Sendable {
    package let tool: NativeTool
    package let arguments: [String]
    /// The files the run leaves for the next step, in their format.
    package let output: StepInput
    /// Machine-readable files the run writes beside its reads, such as a fastp JSON report.
    package let auxiliaryOutputs: [URL]

    package init(tool: NativeTool, arguments: [String], output: StepInput, auxiliaryOutputs: [URL] = []) {
        self.tool = tool
        self.arguments = arguments
        self.output = output
        self.auxiliaryOutputs = auxiliaryOutputs
    }
}

/// A recipe step whose one tool run can be built before it runs, so an executor plan can name it.
package protocol RecipePlannableStep: RecipeStepExecutor {
    func plannedInvocation(
        input: StepInput, workspace: URL, sampleName: String, threads: Int
    ) throws -> RecipePlannedInvocation
}

extension FastpMergeStep: RecipePlannableStep {
    package func plannedInvocation(
        input: StepInput, workspace: URL, sampleName: String, threads: Int
    ) throws -> RecipePlannedInvocation {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }
        let merged = workspace.appendingPathComponent("\(sampleName)_merged.fq.gz")
        let unmergedR1 = workspace.appendingPathComponent("\(sampleName)_unmerged_R1.fq.gz")
        let unmergedR2 = workspace.appendingPathComponent("\(sampleName)_unmerged_R2.fq.gz")
        let report = workspace.appendingPathComponent("\(sampleName)_merge_fastp_report.json")
        let arguments = [
            "-i", input.r1.path,
            "-I", r2.path,
            "--merge",
            "--merged_out", merged.path,
            "--out1", unmergedR1.path,
            "--out2", unmergedR2.path,
            "--overlap_len_require", "\(minOverlap)",
            "-A", "-G", "-Q", "-L",
            "-w", "\(threads)",
            "-j", report.path,
            "-h", "/dev/null",
        ]
        let output = keepUnmerged
            ? StepInput(r1: merged, r2: unmergedR1, r3: unmergedR2, format: .merged)
            : StepInput(r1: merged, format: .single)
        return RecipePlannedInvocation(tool: .fastp, arguments: arguments, output: output, auxiliaryOutputs: [report])
    }
}

extension RecipeEngine {
    /// The fused fastp run's two outputs in `workspace`.
    static func fusedFastpOutputs(workspace: URL, sampleName: String) -> (r1: URL, r2: URL) {
        (workspace.appendingPathComponent("\(sampleName)_fused_R1.fq.gz"),
         workspace.appendingPathComponent("\(sampleName)_fused_R2.fq.gz"))
    }

    /// The argv of the fused fastp run, `extraArgs` being the fused steps' own flags.
    static func fusedFastpArguments(
        extraArgs: [String], r1: URL, r2: URL, outR1: URL, outR2: URL, report: URL, threads: Int
    ) -> [String] {
        ["-i", r1.path, "-I", r2.path, "-o", outR1.path, "-O", outR2.path]
            + extraArgs
            + ["-w", "\(threads)", "-j", report.path, "-h", "/dev/null"]
    }

    /// The interleaved file the paired-to-interleaved conversion writes.
    static func interleavedOutput(workspace: URL, sampleName: String) -> URL {
        workspace.appendingPathComponent("\(sampleName)_interleaved.fq.gz")
    }

    /// The `reformat.sh` argv that interleaves an R1/R2 pair.
    static func pairedToInterleavedArguments(r1: URL, r2: URL, output: URL, threads: Int) -> [String] {
        ["in=\(r1.path)", "in2=\(r2.path)", "out=\(output.path)", "interleaved=t", "threads=\(threads)", "ow=t"]
    }

    /// The one file the merged-to-mixed conversion writes.
    static func mixedOutput(workspace: URL, sampleName: String) -> URL {
        workspace.appendingPathComponent("\(sampleName)_mixed.fastq")
    }
}
