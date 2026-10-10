// ProvenanceEnvelope+RunLevelFiles.swift - Drops run-level files that no longer exist on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension ProvenanceEnvelope {
    /// Removes run-level `files`/`outputs` entries whose path is gone, and clears
    /// the top-level `output` pointer when it names a deleted file.
    public func droppingMissingRunLevelFiles() -> ProvenanceEnvelope {
        let fm = FileManager.default
        let survives: (ProvenanceFileDescriptor) -> Bool = { fm.fileExists(atPath: $0.path) }
        let keptFiles = files.filter(survives)
        let keptOutputs = outputs.filter(survives)
        let keptOutput = output.flatMap { survives($0) ? $0 : keptOutputs.last }
        guard keptFiles.count != files.count
            || keptOutputs.count != outputs.count
            || keptOutput?.path != output?.path else {
            return self
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
}
