// SequenceExportCompressor+Record.swift - The provenance step of a managed compression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `convert --compress zstd` records one step for the compressor beside the step of `convert` itself. The step
// names the tool and its lock entry and holds the version that the environment which ran it reports in its
// conda-meta, through the same evidence type the other managed tools use (lane 13.17 M3, BIO 4).

import Foundation
import LungfishIO

extension SequenceExportCompressor {
    /// The completed step of the managed compressor that `receipt` describes. The environment is the folder two
    /// levels above `<environment>/bin/<tool>`, and the version is read from its conda-meta in the writer, after
    /// the run. An executable outside a `bin` folder has no environment to read, so the lock's pin stands in.
    package static func provenanceStep(
        for receipt: Receipt,
        wallTimeSeconds: TimeInterval,
        lock: ManagedToolLock = .bundled
    ) -> ProvenanceStep {
        let id = ManagedToolID(rawValue: receipt.toolName)
        let bin = receipt.executable.deletingLastPathComponent()
        let evidence: ToolVersionEvidence = bin.lastPathComponent == "bin"
            ? .condaMeta(id: id, environment: bin.deletingLastPathComponent(), lock: lock)
            : .lockPin(for: id, in: lock)
        return ProvenanceStep(
            toolName: receipt.toolName,
            toolVersion: evidence.recordedString,
            argv: [receipt.executable.path] + receipt.arguments,
            inputs: [],
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: "",
            managedToolID: id,
            toolVersionEvidence: evidence
        )
    }
}
