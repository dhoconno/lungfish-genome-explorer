// RunSubcommand+ViralReconRecord.swift - The facts of a Viral Recon run's record on the one Nextflow record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension RunSubcommand {
    /// The Nextflow facts of a Viral Recon step on the record shape of 2.9 R1 (Phase 2.10 lane B31).
    ///
    /// The step's tool is the lock's pipeline id, `nf-core-viralrecon`, at the revision `-r` takes, with the release tag
    /// that names that revision beside it (``NFCoreRunRequest/viralReconReleaseVersion(pin:)``). `workflow run` always
    /// launches the repository with `-r`, never a snapshot, so the code came from `remote`. LGE's own command stays the
    /// argv of the run.
    static func viralReconStepFacts(for request: NFCoreRunRequest) -> NextflowRecordFacts {
        NextflowRecordFacts(
            toolName: NextflowWorkflowDescriptor.viralRecon.lockPipelineID,
            toolVersion: request.version,
            githubReleaseVersion: request.viralReconReleaseVersion(
                pin: try? NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()),
            pipelineSource: .remote
        )
    }
}
