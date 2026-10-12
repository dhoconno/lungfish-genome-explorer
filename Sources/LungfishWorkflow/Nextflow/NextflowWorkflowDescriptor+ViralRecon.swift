// NextflowWorkflowDescriptor+ViralRecon.swift - nf-core/viralrecon as a Nextflow workflow descriptor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension NextflowWorkflowDescriptor {
    /// nf-core/viralrecon, with the facts `lungfish-cli workflow run` launches it with today.
    ///
    /// It shows that a second workflow fits the descriptor (N12). Its runs still go through
    /// `NFCoreRunRequest`, and nothing launches from this value in Phase 2.9. Docker is the one executor
    /// that reaches a working run, so the profile is `docker`. The work folder goes with `-work-dir`, the
    /// run writes no trace file, and the scratch prefix is the one the command uses. Release 3.0.0 needs
    /// the legacy syntax parser, as `NFCoreSupportedWorkflow.launchEnvironment(forVersion:)` says, and
    /// the parameter schema sits at the root of the pipeline checkout.
    package static let viralRecon = NextflowWorkflowDescriptor(
        toolID: .viralrecon,
        lockPipelineID: "nf-core-viralrecon",
        profile: "docker",
        containerRuntime: .docker,
        releaseEnvironment: ["3.0.0": ["NXF_SYNTAX_PARSER": "v1"]],
        parameterSchemaPath: "nextflow_schema.json",
        workDirectoryOption: "-work-dir",
        traceFileName: nil,
        scratchPrefix: "nfcore-run-",
        keepWorkEnvironmentKey: nil,
        expectedTaskCountPerSample: nil,
        finalizeProgressShare: 0
    )
}
