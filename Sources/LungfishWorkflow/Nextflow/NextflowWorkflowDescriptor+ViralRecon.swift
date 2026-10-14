// NextflowWorkflowDescriptor+ViralRecon.swift - nf-core/viralrecon as a Nextflow workflow descriptor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension NextflowWorkflowDescriptor {
    /// nf-core/viralrecon, with the facts `lungfish-cli workflow run` launches it with.
    ///
    /// `workflow run` launches with this value's argv, built from the run's `NFCoreRunRequest` by
    /// ``NFCoreRunRequest/viralReconLaunch(samplesheet:configFiles:)`` (Phase 2.10 N1). Docker is the
    /// one executor that reaches a working run, so the profile is `docker`. The work folder goes with
    /// `-work-dir` ahead of the profile, and the parameters follow sorted by name, as `NFCoreRunRequest`
    /// writes them. The run writes no trace file, and the scratch prefix is the one the command uses.
    /// Release 3.0.0 needs the legacy syntax parser, as
    /// `NFCoreSupportedWorkflow.launchEnvironment(forVersion:)` says, and the parameter schema sits at
    /// the root of the pipeline checkout.
    package static let viralRecon = NextflowWorkflowDescriptor(
        toolID: .viralrecon,
        lockPipelineID: "nf-core-viralrecon",
        profile: "docker",
        containerRuntime: .docker,
        releaseEnvironment: ["3.0.0": ["NXF_SYNTAX_PARSER": "v1"]],
        parameterSchemaPath: "nextflow_schema.json",
        workDirectoryOption: "-work-dir",
        traceFileName: nil,
        argumentLayout: .sortedParameters,
        scratchPrefix: "nfcore-run-",
        keepWorkEnvironmentKey: nil,
        expectedTaskCountPerSample: nil,
        finalizeProgressShare: 0
    )
}

extension NFCoreRunRequest {
    /// The launch ``NextflowWorkflowDescriptor/viralRecon`` writes the argv of for this run, with
    /// `samplesheet` as the one `--input` and `configFiles` passed with `-c` before `run`.
    ///
    /// The samplesheet is one file by type, so a launch writes exactly one `--input` whatever the
    /// request's inputs are (Phase 2.10 N1, fit difference 1). The target is the workflow's repository
    /// at the request's version, which is the catalog's pinned release when the caller names none, so
    /// a lock without the Viral Recon pin still launches the catalog's fallback until B31 retires it
    /// (fit difference 3, N2). The profile is the executor. The workflow's options are the request's
    /// other effective parameters that have a value, the forced step skips among them, as `--name
    /// value` pairs.
    package func viralReconLaunch(samplesheet: URL, configFiles: [URL] = []) -> NextflowLaunchRequest {
        let options = effectiveParams
            .filter { $0.key != "input" && $0.key != "outdir" && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .flatMap { ["--\($0.key)", $0.value] }
        return NextflowLaunchRequest(
            configFiles: configFiles,
            target: .pinned(NextflowPipelinePin(
                pipelineID: NextflowWorkflowDescriptor.viralRecon.lockPipelineID,
                repository: workflow.fullName,
                revision: version,
                releaseVersion: version)),
            samplesheet: samplesheet,
            outputDirectory: outputDirectory,
            workDirectory: workDirectory,
            profile: executor.rawValue,
            resume: resume,
            pipelineArguments: options)
    }
}
