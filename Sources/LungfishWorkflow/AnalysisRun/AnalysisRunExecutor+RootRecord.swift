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
    /// The record's argv is the command that ran, its replay argv the one a unit recorded or else the
    /// request's, its run-level files only those that still exist, its options are the plan's with what the units
    /// and the finalize recorded merged in and hold the read-set plan under `resolvedDefaults`
    /// (E13), its status and exit status say how the run ended, and its stderr
    /// holds the reason a run did not complete and every warning. A completed run lists the
    /// finalize's outputs, which are hashed here once, and the files the finalize names as a step
    /// of the run recorded them, which are not. Every other descriptor is one the tool already
    /// took, such as those of the steps the units and then the finalize recorded as each ended, so
    /// a failed or cancelled run hashes nothing and keeps those steps (2.9 R6), and a cancelled
    /// run's record is written within the grace its command has after the cancel.
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
        let replayArgv = journal.recordedDurableReplayArgv ?? input.request.durableReplayArgv
        do {
            let envelope = try rootEnvelope(
                input,
                ending: ending,
                inputs: inputs,
                steps: steps,
                outputs: ending == .completed ? input.finalization?.outputs ?? [] : [],
                recordedFiles: ending == .completed ? input.finalization?.recordedFiles ?? [] : [],
                warnings: journal.warnings,
                replayArgv: replayArgv
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
                    recordedFiles: [],
                    warnings: journal.warnings,
                    replayArgv: replayArgv
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
        recordedFiles: [ProvenanceFileDescriptor],
        warnings: [String],
        replayArgv: [String]?
    ) throws -> ProvenanceEnvelope {
        var builder = ProvenanceRunBuilder(
            workflowName: input.identity.workflowName,
            workflowVersion: LungfishAppVersion.short,
            toolName: CLICommandIdentity.executableName,
            toolVersion: LungfishAppVersion.short
        )
        .argv(input.request.commandLine)
        .durableReplayArgv(replayArgv)
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
        // After the finalize's outputs, so the run's output stays the first of them.
        for descriptor in recordedFiles {
            builder = descriptor.role == .input
                ? try Self.adding(recordedInput: descriptor, to: builder)
                : try Self.adding(recordedOutput: descriptor, to: builder)
        }

        let stderr = ([ending.message(displayName: input.identity.displayName)].compactMap { $0 } + warnings)
            .joined(separator: "\n")
        // A step keeps the files it wrote as they were when it ran, such as a per-read output that a
        // later step compressed and removed. The run level names only files the result still holds.
        return try builder.complete(
            exitStatus: Int(ending.exitCode),
            status: ending.status,
            stderr: stderr.isEmpty ? nil : stderr,
            startedAt: input.clock.startedAt,
            endedAt: input.clock.now
        ).droppingMissingRunLevelFiles()
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

    /// Adds an output a step of the run already hashed, such as a staged input a batch's sample
    /// keeps, with that step's digest and size and without hashing it again, as
    /// ``adding(recordedInput:to:)`` adds an input. A remote reference or a folder with a
    /// checksum goes in as it is.
    static func adding(
        recordedOutput descriptor: ProvenanceFileDescriptor,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if let snapshot = try? builder.recordedOutputSnapshot(descriptor) {
            return snapshot
        }
        return try builder.output(descriptor)
    }
}

public extension ProvenanceEnvelope {
    /// The record with a run level that names each file as the run left it (2.8 B3, 2.10 A39). A step keeps
    /// the files as they were when it ran, and a removal step names what went (`RecordedRemovalStep`), but
    /// the run level, which the record writes after every step, names neither a file that is gone, as
    /// ``droppingMissingRunLevelFiles()`` drops, nor the bytes a removal step of the record names, such as
    /// a BAM that a markdup rewrote in place and the index it replaced. The `output` pointer moves to the
    /// last kept output when it named such a file. A path compares with its deepest existing folder
    /// resolved, so a file named under `/var` and under `/private/var` is one file, and nothing is hashed.
    func droppingRemovedRunLevelFiles() -> ProvenanceEnvelope {
        let kept = droppingMissingRunLevelFiles()
        let removed = Set(kept.steps
            .filter { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) }
            .flatMap(\.inputs)
            .compactMap { file in file.checksumSHA256.map { Self.removedBytesKey(path: file.path, digest: $0) } })
        guard !removed.isEmpty else { return kept }
        let survives: (ProvenanceFileDescriptor) -> Bool = { file in
            guard let digest = file.checksumSHA256 else { return true }
            return !removed.contains(Self.removedBytesKey(path: file.path, digest: digest))
        }
        let keptFiles = kept.files.filter(survives)
        let keptOutputs = kept.outputs.filter(survives)
        let keptOutput = kept.output.flatMap { survives($0) ? $0 : keptOutputs.last }
        guard keptFiles.count != kept.files.count
            || keptOutputs.count != kept.outputs.count
            || keptOutput?.path != kept.output?.path else {
            return kept
        }
        return ProvenanceEnvelope(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            tool: tool,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: options,
            runtimeIdentity: runtimeIdentity,
            files: keptFiles,
            output: keptOutput,
            outputs: keptOutputs,
            steps: steps,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr,
            signatures: signatures,
            status: status,
            legacyWorkflowRun: legacyRun
        )
    }

    /// The bytes at a path, with the path's deepest existing folder resolved, since a removed file or folder
    /// cannot be.
    private static func removedBytesKey(path: String, digest: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        return resolved.path + "\u{0}" + digest
    }
}
