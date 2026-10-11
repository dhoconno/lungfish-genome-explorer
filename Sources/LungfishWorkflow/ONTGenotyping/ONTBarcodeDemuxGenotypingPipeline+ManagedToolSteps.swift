// ONTBarcodeDemuxGenotypingPipeline+ManagedToolSteps.swift - The managed tool steps of a demux genotyping record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The amplicon genotyping run launches minimap2, samtools and a pysam script from three managed conda
// environments. Its provenance record holds one step per launch. Until Phase 2.7 each step wrote the literal
// `unknown` as its version and named no lock entry. A step now names its lock entry in `managedToolID` and keeps
// the version the environment that ran it holds in `toolVersionEvidence` (decision P12). The version is read
// from the environment's `conda-meta` in the writer, after the run, and the lock's pin stands in when the
// environment holds no record of the package.

import Foundation
import LungfishIO

/// A managed tool one amplicon genotyping run launched, with the evidence for the version that ran.
struct DemuxManagedTool: Sendable, Equatable {
    /// The tool's lock entry, such as `samtools`.
    let id: ManagedToolID
    /// What the step's `toolVersion` is known from.
    let evidence: ToolVersionEvidence

    /// Reads the evidence from the conda environment that holds `executable`, the one the run launched it from.
    /// An executable outside a `bin` folder has no environment to read, so the lock's pin stands in.
    init(id: String, executable: URL, lock: ManagedToolLock = .bundled) {
        let toolID = ManagedToolID(rawValue: id)
        self.id = toolID
        if let environment = Self.environment(ofExecutable: executable) {
            evidence = .condaMeta(id: toolID, environment: environment, lock: lock)
        } else {
            evidence = .lockPin(for: toolID, in: lock)
        }
    }

    /// The conda environment folder of an executable in its `bin` folder, nil for any other location.
    static func environment(ofExecutable executable: URL) -> URL? {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : nil
    }

    /// A completed step of this tool. The version is the evidence's version, and `unknown` when none is known.
    func step(
        _ toolName: String,
        argv: [String],
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        wallTimeSeconds: TimeInterval,
        stderr: String
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: toolName,
            toolVersion: evidence.recordedString,
            argv: argv,
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: stderr,
            managedToolID: id,
            toolVersionEvidence: evidence
        )
    }
}
