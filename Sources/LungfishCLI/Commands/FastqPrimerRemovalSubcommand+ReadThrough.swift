// FastqPrimerRemovalSubcommand+ReadThrough.swift - The bbduk pass that removes a primer a read runs through at its 3' end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FastqPrimerRemovalSubcommand {
    /// The second bbduk pass, which removes a primer that a read runs
    /// through at its 3' end (final review A note 7, L5 item 3).
    ///
    /// The 5' pass matches each primer only as written (`rcomp=f`), because a
    /// reverse-complement match left-trimmed a read-through mate down to the
    /// bases after its far primer. So a read that runs through the far end of
    /// its amplicon kept that primer's reverse complement at its 3' end.
    struct ReadThroughPass: Sendable {
        /// `literal=` or `ref=` with every primer's reverse complement.
        let primers: String
        /// The shortest primer's length, at most 31 and at least `mink`, so a
        /// match away from the read's tip needs nearly a whole primer.
        let kmerSize: Int
        /// The longest primer's length. Only a primer that ends at the read's
        /// 3' end is trimmed.
        let window: Int
    }
}

extension FastqPrimerRemovalSubcommand.ToolArguments {
    /// Whether the engine runs a read-through pass after its 5' pass.
    var hasReadThroughPass: Bool {
        if case .bbduk = engine { return true }
        return false
    }

    /// The read-through pass's argv, or nil for an engine without one.
    ///
    /// Pairs are trimmed where their mates overlap (`tbo=t`). After the 5'
    /// pass each mate starts after its primer, so a mate that runs past its
    /// partner's start runs into the partner's primer, and the overlap says
    /// exactly where. Any adapter the pair reads into goes with it. A single
    /// read has no partner, so it loses a primer's reverse complement found
    /// within its last (longest primer) bases, `ktrim=r rcomp=f` with k-mers
    /// as long as the shortest primer and `mink` for a primer cut short at the
    /// tip. A wider window, the 5' pass's (longest primer + 67), cut reads of a
    /// tiled scheme at the primer site of the overlapping amplicon, 28 of 150
    /// bases left on ARTIC amplicon 6 (L5 design).
    func readThroughArguments(input: String, output: String, paired: Bool) -> [String]? {
        guard case .bbduk(_, _, let minKmer, let hammingDistance, _, let readThrough) = engine else { return nil }
        if paired {
            return ["in=\(input)", "out=\(output)", "tbo=t", "interleaved=t"]
        }
        return [
            "in=\(input)",
            "out=\(output)",
            "ktrim=r",
            "k=\(readThrough.kmerSize)",
            "mink=\(minKmer)",
            "hdist=\(hammingDistance)",
            "rcomp=f",
            "restrictright=\(readThrough.window)",
            "interleaved=f",
            readThrough.primers,
        ]
    }
}

/// Runs the primer engine on one input in its passes, the 5' pass into a
/// scratch file when the read-through pass follows, and makes the
/// provenance steps of the passes after the first.
struct PrimerRemovalPasses: Sendable {
    let toolArguments: FastqPrimerRemovalSubcommand.ToolArguments
    let runner: NativeToolRunner
    let environment: [String: String]?
    /// Holds each 5' pass's output, removed with ``removeScratch()``.
    let scratchDirectory: URL

    /// Runs every pass from `input` to `output` and returns the runs, the
    /// first one alone when it failed.
    func run(input: URL, output: URL, paired: Bool) async throws -> [FASTQSplitByNameRunner.PartRun] {
        let tool = toolArguments.tool
        let firstOutput: URL
        if toolArguments.hasReadThroughPass {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            firstOutput = scratchDirectory.appendingPathComponent(
                "\(output.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)-five-prime.fastq"
            )
        } else {
            firstOutput = output
        }
        let firstArguments = toolArguments.arguments(input: input.path, output: firstOutput.path, paired: paired)
        let firstClock = ProvenanceRunClock()
        let first = try await runner.run(tool, arguments: firstArguments, environment: environment, timeout: 1800)
        var runs = [FASTQSplitByNameRunner.PartRun(
            result: first,
            arguments: firstArguments,
            inputURL: input,
            outputURL: firstOutput,
            startedAt: firstClock.startedAt,
            completedAt: firstClock.now
        )]
        guard first.isSuccess,
              let secondArguments = toolArguments.readThroughArguments(
                input: firstOutput.path,
                output: output.path,
                paired: paired
              ) else {
            return runs
        }
        let secondClock = ProvenanceRunClock()
        let second = try await runner.run(tool, arguments: secondArguments, environment: environment, timeout: 1800)
        runs.append(FASTQSplitByNameRunner.PartRun(
            result: second,
            arguments: secondArguments,
            inputURL: firstOutput,
            outputURL: output,
            startedAt: secondClock.startedAt,
            completedAt: secondClock.now
        ))
        return runs
    }

    /// The provenance steps of `runs`, the passes after `first`, each after
    /// the one before it and the first after the step `firstStepID` records.
    func provenanceSteps(
        after first: FASTQSplitByNameRunner.PartRun,
        runs: [FASTQSplitByNameRunner.PartRun],
        firstStepID: UUID,
        toolVersion: String
    ) -> [ProvenanceStep] {
        let tool = toolArguments.tool
        var steps: [ProvenanceStep] = []
        var previous = firstStepID
        for run in runs {
            let step = ProvenanceStep(
                toolName: tool.rawValue,
                toolVersion: toolVersion,
                argv: run.result.arguments.isEmpty ? [tool.executableName] + run.arguments : run.result.arguments,
                inputs: [Self.descriptor(run.inputURL, role: .input)],
                outputs: [Self.descriptor(run.outputURL, role: .output)],
                exitStatus: Int(run.result.exitCode),
                wallTimeSeconds: run.completedAt.timeIntervalSince(run.startedAt),
                stderr: run.result.stderr.isEmpty ? nil : run.result.stderr,
                dependsOn: [previous],
                startedAt: run.startedAt,
                completedAt: run.completedAt
            )
            steps.append(step)
            previous = step.id
        }
        return steps
    }

    func removeScratch() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    private static func descriptor(_ url: URL, role: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: role))
    }
}
