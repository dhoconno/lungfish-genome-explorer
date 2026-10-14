// ManagedAssemblyProvenanceInputs.swift - The input records and materialization steps a managed assembly records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The input records and the steps that wrote the execution inputs of a managed assembly run,
/// which the app's Reassemble route and `lungfish-cli assemble` both record (Phase 2.10 lane A46).
public enum ManagedAssemblyProvenanceInputs {}

public extension ManagedAssemblyProvenanceInputs {
    /// `originalInputURLs[i]` is the input `executionInputURLs[i]` came from.
    nonisolated static func managedAssemblyInputRecords(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [InputFileRecord] {
        AssemblyInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
    }

    /// The input records and the materialization steps of a finished run,
    /// computed on the concurrent executor. Both hash every input file, and
    /// every file of a joined bundle twice, which held the main thread for
    /// minutes after the assembler finished on a large ONT bundle (R10,
    /// final review S2). What they record is unchanged.
    @concurrent
    nonisolated static func managedAssemblyProvenanceInputs(
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        startedAt: Date?,
        endedAt: Date?,
        readSets: AssemblyResolvedInputs? = nil
    ) async throws -> (records: [InputFileRecord], steps: [ProvenanceStep]) {
        let records = managedAssemblyInputRecords(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        // A sample of pairs and single reads records the splits that wrote
        // its files, as `lungfish-cli assemble` does.
        if let readSets, readSets.inputRoles != nil {
            return (records, try readSets.provenanceSteps(workflowVersion: WorkflowRun.currentAppVersion))
        }
        let steps = try managedAssemblyMaterializationSteps(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return (records, steps)
    }

    /// The steps that wrote the execution files, as `lungfish-cli assemble`
    /// records them: one materialization step for the virtual bundles, then
    /// a `cat` step for each concatenation of a bundle's files.
    nonisolated static func managedAssemblyMaterializationSteps(
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        startedAt: Date?,
        endedAt: Date?
    ) throws -> [ProvenanceStep] {
        let concatenatedPairs = CLISequenceInputMaterialization.originalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        ).filter { CLISequenceInputMaterialization.concatenation(forExecutionURL: $0.executionURL) != nil }
        let recordedAt = Date()
        let concatenationSteps = try CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: WorkflowRun.currentAppVersion,
            originalInputURLs: concatenatedPairs.map(\.originalURL),
            executionInputURLs: concatenatedPairs.map(\.executionURL),
            startedAt: startedAt ?? recordedAt,
            endedAt: endedAt ?? startedAt ?? recordedAt
        )
        let materializationStep = try managedAssemblyMaterializationStep(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return (materializationStep.map { [$0] } ?? []) + concatenationSteps
    }

    /// `originalInputURLs[i]` is the input `executionInputURLs[i]` came from.
    nonisolated static func managedAssemblyMaterializationStep(
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        startedAt: Date?,
        endedAt: Date?
    ) throws -> ProvenanceStep? {
        let inputPairs = CLISequenceInputMaterialization.originalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        let materializedPairs = inputPairs.filter { originalURL, executionURL in
            AssemblyInputMaterialization.requiresMaterialization(originalURL)
                && originalURL.standardizedFileURL != executionURL.standardizedFileURL
        }
        guard !materializedPairs.isEmpty else { return nil }
        guard let startedAt else { return nil }

        let completedAt = endedAt ?? startedAt
        let inputs = try materializedPairs.flatMap { originalURL, _ in
            try AssemblyInputMaterialization.originalInputDescriptors(for: originalURL)
        }
        let outputs = try materializedPairs.map { originalURL, executionURL in
            try AssemblyInputMaterialization.executionInputDescriptor(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let materializationCommands = materializedPairs.map { originalURL, executionURL in
            CLISequenceInputMaterialization.materializationCommand(
                originalURL: originalURL,
                executionURL: executionURL
            )
        }
        let argv = materializationCommands.count == 1
            ? materializationCommands[0]
            : [
                "/bin/sh",
                "-lc",
                materializationCommands
                    .map { $0.map(shellEscape).joined(separator: " ") }
                    .joined(separator: " && "),
            ]

        return ProvenanceStep(
            toolName: CLISequenceInputMaterialization.materializationToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
