// NextflowWorkflowDescriptor+TaxTriage.swift - TaxTriage as a Nextflow workflow descriptor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension NextflowWorkflowDescriptor {
    /// TaxTriage (jhuapl-bio/taxtriage), with the facts its pipeline launches with today.
    ///
    /// The profile is `TaxTriageConfig`'s default, the work folder goes with `-w` and the trace into the
    /// output folder as `trace.txt` (`TaxTriagePipeline.buildNextflowArguments`), and the scratch prefix
    /// and keep-work key are the ones `makeLocalLaunchScratch` uses. No task count is set, so the bar
    /// keeps the engine's estimate (W2), and the finalize takes the last tenth of it (W3).
    package static let taxTriage = NextflowWorkflowDescriptor(
        toolID: .taxtriage,
        lockPipelineID: "taxtriage",
        profile: "docker",
        containerRuntime: .docker,
        releaseEnvironment: [:],
        parameterSchemaPath: nil,
        workDirectoryOption: "-w",
        traceFileName: "trace.txt",
        scratchPrefix: "taxtriage-run-",
        keepWorkEnvironmentKey: "LUNGFISH_TAXTRIAGE_KEEP_WORK",
        expectedTaskCountPerSample: nil,
        finalizeProgressShare: 0.1
    )
}
