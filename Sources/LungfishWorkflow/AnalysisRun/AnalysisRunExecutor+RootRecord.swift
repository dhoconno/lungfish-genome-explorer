// AnalysisRunExecutor+RootRecord.swift - The root record of an analysis run, written last in phase P4
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the root record is made from besides what the tool recorded during the run.
struct RootRecordInput: Sendable {
    let identity: AnalysisRunIdentity
    let request: AnalysisRunRequest
    /// The plan's options with every contribution of the units and the finalize merged in.
    let options: AnalysisRootRecordOptions
    let finalization: AnalysisRunFinalization?
    let clock: ProvenanceRunClock
}

/// The root record that was written, and how the run ends once it was.
struct RootRecordResult: Sendable {
    let ending: AnalysisRunEnding
    let url: URL?
}

extension AnalysisRunExecutor {
    /// Phase P4. Writes the root record into the result folder through `ProvenanceRunBuilder` and
    /// `ProvenanceWriter`, after every other record of the run, so a record written during the run
    /// (a unit's record in a one-folder layout or a shared batch root, or an index builder's)
    /// never wins.
    ///
    /// The record's argv is the command that ran, its options are the plan's with what the units
    /// and the finalize recorded merged in and hold the read-set plan under `resolvedDefaults`
    /// (E13), its status and exit status say how the run ended, and its stderr
    /// holds the reason a run did not complete and every warning. A completed run lists the
    /// finalize's outputs, which are hashed here once. Every other descriptor is one the tool
    /// already took, so a failed or cancelled run hashes nothing, and a cancelled run's record is
    /// written within the grace its command has after the cancel.
    ///
    /// A completed run whose record cannot be built or written becomes a failed run. A record of a
    /// run that did not complete is tried with what the tool recorded, then without it, so a
    /// result folder holds a record whenever its file system takes one.
    func writeRootRecord(
        _ input: RootRecordInput,
        ending: AnalysisRunEnding,
        folder: AnalysisRunFolder,
        journal: AnalysisRunJournal
    ) -> RootRecordResult {
        let inputs = journal.recordedInputs
        let steps = journal.recordedSteps + (input.finalization?.steps ?? [])
        do {
            let envelope = try rootEnvelope(
                input,
                ending: ending,
                inputs: inputs,
                steps: steps,
                outputs: ending == .completed ? input.finalization?.outputs ?? [] : [],
                warnings: journal.warnings
            )
            return RootRecordResult(ending: ending, url: try services.writer.write(envelope, to: folder.root))
        } catch {
            let settled: AnalysisRunEnding = ending == .completed
                ? .failed(
                    reason: "The run's provenance record could not be written: \(Self.reason(for: error))",
                    exitCode: AnalysisRunExitCode.workflowError
                )
                : ending
            for attempt in [(inputs, steps), ([], [])] {
                if let envelope = try? rootEnvelope(
                    input,
                    ending: settled,
                    inputs: attempt.0,
                    steps: attempt.1,
                    outputs: [],
                    warnings: journal.warnings
                ),
                    let url = try? services.writer.write(envelope, to: folder.root) {
                    return RootRecordResult(ending: settled, url: url)
                }
            }
            return RootRecordResult(ending: settled, url: nil)
        }
    }

    private func rootEnvelope(
        _ input: RootRecordInput,
        ending: AnalysisRunEnding,
        inputs: [ProvenanceFileDescriptor],
        steps: [ProvenanceStep],
        outputs: [AnalysisRunOutput],
        warnings: [String]
    ) throws -> ProvenanceEnvelope {
        var builder = ProvenanceRunBuilder(
            workflowName: input.identity.workflowName,
            workflowVersion: LungfishAppVersion.short,
            toolName: CLICommandIdentity.executableName,
            toolVersion: LungfishAppVersion.short
        )
        .argv(input.request.commandLine)
        .durableReplayArgv(input.request.durableReplayArgv)
        .options(
            explicit: input.options.explicit,
            defaults: input.options.defaults,
            resolved: input.options.resolvedIncludingReadSetPlan
        )
        .runtime(ProvenanceRuntimeIdentity(appVersion: LungfishAppVersion.short))

        for descriptor in inputs {
            builder = try Self.adding(recordedInput: descriptor, to: builder)
        }
        for step in steps {
            builder = builder.step(step)
        }
        for output in outputs {
            builder = try builder.output(output.url, format: output.format, role: output.role)
        }

        let stderr = ([ending.message(displayName: input.identity.displayName)].compactMap { $0 } + warnings)
            .joined(separator: "\n")
        return try builder.complete(
            exitStatus: Int(ending.exitCode),
            status: ending.status,
            stderr: stderr.isEmpty ? nil : stderr,
            startedAt: input.clock.startedAt,
            endedAt: input.clock.now
        )
    }

    /// Adds a descriptor the tool already took, without hashing it. A local file goes in as a
    /// consumed snapshot, which needs an absolute path, a SHA-256 and a size. A remote reference
    /// or a folder with a checksum goes in as it is.
    static func adding(
        recordedInput descriptor: ProvenanceFileDescriptor,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if let snapshot = try? builder.consumedInputSnapshot(descriptor) {
            return snapshot
        }
        return try builder.input(descriptor)
    }
}
