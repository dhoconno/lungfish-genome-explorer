// ProvenanceRunBuilder+Recorded.swift - The builder entry that completes a run ProvenanceRecorder gathered
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The entry through which `ProvenanceRecorder` completes a run it gathered one step at a time.
///
/// A recorded run keeps the rules its records have always followed, which differ from
/// ``complete(exitStatus:status:stderr:startedAt:endedAt:)`` in four ways.
///
/// - `files` lists each step's inputs and then its outputs, step after step, and `outputs` lists each
///   step's outputs, and neither drops a repeated path. The EsViritu golden record repeats four.
/// - The run's exit status, stderr and top-level output come from its steps, through the outcome
///   step: the last step, or for a failed run the last step whose exit status is not 0.
/// - The run takes the status it was completed with, `running` for a run saved before it ended. No
///   check that a completed run holds an argv, an output with a checksum and size or a runtime
///   identity refuses the record, because a refusal at the last step would fail a finished analysis
///   (`docs/contracts/RECORDING-PROVENANCE.md`).
/// - A run that never ended has no wall time.
///
/// The run names its first step's tool, version, argv and durable argv as its own, through
/// ``leadingRecordedStep(_:reportedVersion:fallbackVersion:)``.
extension ProvenanceRunBuilder {
    /// This builder naming `step`, the run's first recorded step, as the run's tool: its name, the
    /// version it reported or `fallbackVersion` when it reported none, its argv and its durable argv.
    ///
    /// `reportedVersion` is the version as the caller gave it. The step itself holds `unknown` for a
    /// blank one, while the run names `fallbackVersion`, the app's version, as its records always have.
    func leadingRecordedStep(_ step: ProvenanceStep, reportedVersion: String, fallbackVersion: String) -> Self {
        Self(
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: step.toolName,
            toolVersion: ProvenanceVersion.required(reportedVersion, fallback: fallbackVersion),
            arguments: step.argv,
            durableArguments: step.durableReplayArgv,
            // The run's shell line is its first step's argv, never that step's durable argv, and the
            // envelope makes that line from `argv` when it is given none.
            command: nil,
            provenanceOptions: provenanceOptions,
            inputs: inputs,
            outputs: outputs,
            runtimeIdentity: runtimeIdentity,
            provenanceSteps: provenanceSteps
        )
    }

    /// The record of a run that `ProvenanceRecorder` gathered, with `steps` as its steps.
    ///
    /// It reads this builder's workflow, tool, argv, options and runtime identity. A recorded run adds
    /// no files or steps to the builder itself, so the builder's own inputs, outputs and steps are not
    /// part of the record. The explicit options are the run's parameters, which also give the release
    /// version when the first step names none.
    ///
    /// - Parameters:
    ///   - id: The run's id, which the record keeps.
    ///   - steps: The steps in the order they were recorded.
    ///   - status: How the run ended, or `running` when it is saved before it ended.
    ///   - startedAt: When the run began.
    ///   - endedAt: When the run was completed, or nil when it was not.
    func completeRecordedRun(
        id: UUID,
        steps: [ProvenanceStep],
        status: RunStatus,
        startedAt: Date,
        endedAt: Date?
    ) -> ProvenanceEnvelope {
        let outcome = Self.recordedOutcomeStep(of: steps, status: status)
        return ProvenanceEnvelope(
            id: id,
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: steps.first?.githubReleaseVersion
                ?? provenanceOptions.explicit["github_release_version"]?.stringValue,
            tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: toolKind),
            argv: arguments,
            durableReplayArgv: durableArguments,
            reproducibleCommand: command,
            options: provenanceOptions,
            runtimeIdentity: runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: steps.flatMap { $0.inputs + $0.outputs },
            output: Self.recordedOutput(of: steps, outcome: outcome),
            outputs: steps.flatMap(\.outputs),
            steps: steps,
            wallTimeSeconds: endedAt.map { $0.timeIntervalSince(startedAt) },
            exitStatus: Self.recordedExitStatus(outcome: outcome, status: status),
            stderr: Self.recordedStderr(of: steps, outcome: outcome, status: status),
            status: status
        )
    }

    /// The step whose exit status and stderr the run reports: for a failed run the last step whose
    /// exit status is not 0, and otherwise the last step.
    private static func recordedOutcomeStep(of steps: [ProvenanceStep], status: RunStatus) -> ProvenanceStep? {
        if status == .failed, let failed = steps.last(where: { ($0.exitStatus ?? 0) != 0 }) {
            return failed
        }
        return steps.last
    }

    /// The first output of the latest step that no later step reads. When every output is read
    /// later, the outcome step's first output, then the last step's, then the first step's.
    private static func recordedOutput(
        of steps: [ProvenanceStep],
        outcome: ProvenanceStep?
    ) -> ProvenanceFileDescriptor? {
        for index in steps.indices.reversed() {
            let laterInputPaths = Set(steps.dropFirst(index + 1).flatMap { $0.inputs.map(\.path) })
            if let terminal = steps[index].outputs.first(where: { !laterInputPaths.contains($0.path) }) {
                return terminal
            }
        }
        return outcome?.outputs.first ?? steps.last?.outputs.first ?? steps.first?.outputs.first
    }

    /// A completed run reports the outcome step's exit status, or 0 without steps. A failed run reports
    /// the outcome step's when it is not 0, and 1 otherwise. A running or cancelled run reports the
    /// outcome step's, which is 0 for a run cancelled after a step that exited 0.
    private static func recordedExitStatus(outcome: ProvenanceStep?, status: RunStatus) -> Int? {
        switch status {
        case .completed:
            return outcome?.exitStatus ?? 0
        case .failed:
            if let exitStatus = outcome?.exitStatus, exitStatus != 0 {
                return exitStatus
            }
            return 1
        case .running, .cancelled:
            return outcome?.exitStatus
        }
    }

    /// The outcome step's stderr. For a failed run whose outcome step kept none, the stderr of the
    /// latest step whose stderr is not empty.
    private static func recordedStderr(
        of steps: [ProvenanceStep],
        outcome: ProvenanceStep?,
        status: RunStatus
    ) -> String? {
        if status == .failed {
            return outcome?.stderr ?? steps.last(where: { !($0.stderr ?? "").isEmpty })?.stderr
        }
        return outcome?.stderr
    }
}
