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
    /// The files the run reads, reads first and then any database index.
    package let inputs: [URL]
    /// The files the run leaves for the next step, in their format.
    package let output: StepInput
    /// Machine-readable files the run writes beside its reads, such as a fastp JSON report.
    package let auxiliaryOutputs: [URL]
    /// The words the in-process record adds to the step's label for a second run, such as "unmerged pairs".
    package let label: String?

    package init(
        tool: NativeTool, arguments: [String], inputs: [URL], output: StepInput, auxiliaryOutputs: [URL] = [],
        label: String? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.inputs = inputs
        self.output = output
        self.auxiliaryOutputs = auxiliaryOutputs
        self.label = label
    }
}

/// Every tool run of one recipe step, in the order the in-process run starts them, and the files the step leaves.
package struct RecipePlannedRun: Sendable {
    package let invocations: [RecipePlannedInvocation]
    package let output: StepInput

    package init(invocations: [RecipePlannedInvocation], output: StepInput) {
        self.invocations = invocations
        self.output = output
    }

    package init(_ invocation: RecipePlannedInvocation) {
        self.init(invocations: [invocation], output: invocation.output)
    }
}

/// A recipe step whose tool runs can be built before they run, so an executor plan can name them.
package protocol RecipePlannableStep: RecipeStepExecutor {
    /// The registry ids of the databases the step reads, each a `database` entry of the plan.
    var plannedDatabaseIDs: [String] { get }

    /// The step's runs on `input`, with `databases` giving each id of ``plannedDatabaseIDs`` its index file.
    func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun
}

extension RecipePlannableStep {
    package var plannedDatabaseIDs: [String] { [] }

    /// The index file of `databaseID`, or the engine's own refusal when the caller gave none.
    func plannedDatabase(_ databaseID: String, in databases: [String: URL]) throws -> URL {
        guard let path = databases[databaseID] else {
            throw RecipeEngineError.databaseNotFound(id: databaseID, step: Self.typeID)
        }
        return path
    }
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
        return RecipePlannedInvocation(
            tool: .fastp, arguments: arguments, inputs: [input.r1, r2], output: output, auxiliaryOutputs: [report]
        )
    }

    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        RecipePlannedRun(try plannedInvocation(input: input, workspace: workspace, sampleName: sampleName, threads: threads))
    }
}

extension DeaconScrubStep: RecipePlannableStep {
    package var plannedDatabaseIDs: [String] { [databaseID] }

    /// The `deacon filter` run that keeps the pairs with no human k-mer hit in the index at `databasePath`.
    package func plannedInvocation(
        input: StepInput, databasePath: URL, workspace: URL, sampleName: String, threads: Int
    ) throws -> RecipePlannedInvocation {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }
        let outR1 = workspace.appendingPathComponent("\(sampleName)_scrubbed_R1.fq.gz")
        let outR2 = workspace.appendingPathComponent("\(sampleName)_scrubbed_R2.fq.gz")
        let summary = workspace.appendingPathComponent("\(sampleName)_deacon_summary.json")
        let arguments = [
            "filter",
            "-d", databasePath.path,
            input.r1.path,
            r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "--summary", summary.path,
            "-t", "\(threads)",
        ]
        return RecipePlannedInvocation(
            tool: .deacon, arguments: arguments, inputs: [input.r1, r2, databasePath],
            output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2), auxiliaryOutputs: [summary]
        )
    }

    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        RecipePlannedRun(try plannedInvocation(
            input: input, databasePath: plannedDatabase(databaseID, in: databases), workspace: workspace,
            sampleName: sampleName, threads: threads
        ))
    }
}

extension DeaconRiboFilterStep: RecipePlannableStep {
    package var plannedDatabaseIDs: [String] { [databaseID] }

    /// The `deacon filter --deplete` run that drops the pairs with a ribosomal k-mer hit in the index at `databasePath`.
    package func plannedInvocation(
        input: StepInput, databasePath: URL, workspace: URL, sampleName: String, threads: Int
    ) throws -> RecipePlannedInvocation {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }
        let outR1 = workspace.appendingPathComponent("\(sampleName)_norrna_R1.fastq.gz")
        let outR2 = workspace.appendingPathComponent("\(sampleName)_norrna_R2.fastq.gz")
        let summary = workspace.appendingPathComponent("\(sampleName)_deacon_ribo_summary.json")
        let arguments = [
            "filter",
            "--deplete",
            "-a", "\(absoluteThreshold)",
            "-r", "\(relativeThreshold)",
            databasePath.path,
            input.r1.path,
            r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "--summary", summary.path,
            "-t", "\(threads)",
        ]
        return RecipePlannedInvocation(
            tool: .deacon, arguments: arguments, inputs: [input.r1, r2, databasePath],
            output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2), auxiliaryOutputs: [summary]
        )
    }

    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        RecipePlannedRun(try plannedInvocation(
            input: input, databasePath: plannedDatabase(databaseID, in: databases), workspace: workspace,
            sampleName: sampleName, threads: threads
        ))
    }
}

extension SeqkitLengthFilterStep: RecipePlannableStep {
    /// The `seqkit seq` run on one stream of single or merged reads.
    func singleStreamInvocation(
        _ source: URL, inputFormat: RecipeFileFormat, workspace: URL, sampleName: String, threads: Int
    ) -> RecipePlannedInvocation {
        let suffix = inputFormat == .merged ? "_lengthfilter_merged" : "_lengthfilter"
        let output = workspace.appendingPathComponent("\(sampleName)\(suffix).fq.gz")
        var arguments = ["seq", "-j", "\(threads)", "-m", "\(minLength)"]
        if let maxLength { arguments += ["-M", "\(maxLength)"] }
        arguments += [source.path, "-o", output.path]
        return RecipePlannedInvocation(
            tool: .seqkit, arguments: arguments, inputs: [source], output: StepInput(r1: output, format: .single)
        )
    }

    /// The fastp run that keeps a pair only when both mates satisfy the length bounds.
    func pairInvocation(
        r1: URL, r2: URL, inputFormat: RecipeFileFormat, workspace: URL, sampleName: String, threads: Int,
        label: String
    ) -> RecipePlannedInvocation {
        let prefix = inputFormat == .merged ? "_lengthfilter_unmerged" : "_lengthfilter"
        let outR1 = workspace.appendingPathComponent("\(sampleName)\(prefix)_R1.fq.gz")
        let outR2 = workspace.appendingPathComponent("\(sampleName)\(prefix)_R2.fq.gz")
        let report = workspace.appendingPathComponent("\(sampleName)\(prefix)_fastp_report.json")
        let arguments = Self.fastpPairArguments(
            r1: r1, r2: r2, outR1: outR1, outR2: outR2, report: report,
            minLength: minLength, maxLength: maxLength, threads: threads
        )
        return RecipePlannedInvocation(
            tool: .fastp, arguments: arguments, inputs: [r1, r2],
            output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2), auxiliaryOutputs: [report], label: label
        )
    }

    package func plannedRun(
        input: StepInput, workspace: URL, sampleName: String, threads: Int, databases: [String: URL]
    ) throws -> RecipePlannedRun {
        switch input.format {
        case .single, .interleaved:
            return RecipePlannedRun(singleStreamInvocation(
                input.r1, inputFormat: input.format, workspace: workspace, sampleName: sampleName, threads: threads
            ))
        case .pairedR1R2:
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: Self.typeID)
            }
            return RecipePlannedRun(pairInvocation(
                r1: input.r1, r2: r2, inputFormat: input.format, workspace: workspace, sampleName: sampleName,
                threads: threads, label: "pairs"
            ))
        case .merged:
            guard let unmergedR1 = input.r2, let unmergedR2 = input.r3 else {
                throw RecipeEngineError.formatMismatch(expected: .merged, got: input.format, step: Self.typeID)
            }
            let merged = singleStreamInvocation(
                input.r1, inputFormat: .merged, workspace: workspace, sampleName: sampleName, threads: threads
            )
            let pairs = pairInvocation(
                r1: unmergedR1, r2: unmergedR2, inputFormat: .merged, workspace: workspace, sampleName: sampleName,
                threads: threads, label: "unmerged pairs"
            )
            return RecipePlannedRun(
                invocations: [merged, pairs],
                output: StepInput(r1: merged.output.r1, r2: pairs.output.r1, r3: pairs.output.r2, format: .merged)
            )
        case .mixed:
            throw RecipeEngineError.formatMismatch(expected: .merged, got: input.format, step: Self.typeID)
        }
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
