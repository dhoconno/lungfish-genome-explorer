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
        argumentLayout: .inputFirst,
        scratchPrefix: "taxtriage-run-",
        keepWorkEnvironmentKey: "LUNGFISH_TAXTRIAGE_KEEP_WORK",
        expectedTaskCountPerSample: nil,
        finalizeProgressShare: 0.1
    )
}

extension TaxTriageConfig {
    /// TaxTriage's own options, the launch's ``NextflowLaunchRequest/pipelineArguments``, in the order
    /// `TaxTriagePipeline.buildNextflowArguments` passes them after LGE's options.
    ///
    /// The Kraken2 database when one is set, the classification settings, the assembly and Krona
    /// switches, the host taxa to remove, the resource limits, and last the extra arguments verbatim.
    package func nextflowPipelineArguments() -> [String] {
        var args: [String] = []
        if let kraken2DatabasePath {
            args += ["--db", kraken2DatabasePath.path]
        }
        args += ["--top_hits_count", String(topHitsCount)]
        args += ["--k2_confidence", String(k2Confidence)]
        args += ["--rank", rank]
        if skipAssembly {
            args.append("--skip_assembly")
        }
        if skipKrona {
            args.append("--skip_krona")
        }
        // A `--remove_taxids` among the extra arguments wins, so the effective list is nil then.
        if let effectiveRemoveTaxids {
            args += ["--remove_taxids", effectiveRemoveTaxids]
        }
        args += ["--max_memory", maxMemory]
        args += ["--max_cpus", String(maxCpus)]
        args += extraArguments
        return args
    }
}
