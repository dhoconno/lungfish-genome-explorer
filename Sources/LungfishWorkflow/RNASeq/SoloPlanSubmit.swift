// SoloPlanSubmit.swift - The request figures of the STARsolo job and its batch (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The memory, CPUs and disk a STARsolo job asks for, values of the submit side and never plan bytes
/// (`docs/formats/executor-plan.md`, Request figures stay on the submit side).
package enum SoloPlanSubmit {
    /// LGE has measured STARsolo on no genome, so every set takes the person's three figures, as the STAR index does
    /// (`docs/formats/reference-set.md`, STAR indexes on Linux). CPUs are STAR's `--runThreadN` in the argv.
    package static func figures(
        for manifest: ReferenceSetManifest, made: SoloPlanOutcome, memoryMiB: Int64? = nil, cpus: Int? = nil, diskGiB: Int? = nil
    ) throws -> SalmonPlanSubmit.Figures {
        guard let memoryMiB, let cpus, let diskGiB else {
            let missing = [("--request-memory-mib", memoryMiB == nil), ("--request-cpus", cpus == nil), ("--request-disk-gib", diskGiB == nil)]
                .filter(\.1).map(\.0)
            throw SoloPlanError("LGE has no measured figures for STARsolo on \(manifest.assembly.name), which is the genome of the "
                + "set \(manifest.id), or on any genome. Run one library on a small job, read STAR's own peak memory and the job's "
                + "disk, and give \(missing.joined(separator: ", ")).")
        }
        guard cpus == made.threads else {
            throw SoloPlanError("The job asks for \(cpus) CPUs and its plan runs STAR with --runThreadN \(made.threads). Write the "
                + "plan with the CPUs the job asks for.")
        }
        return SalmonPlanSubmit.Figures(memoryMiB: memoryMiB, cpus: cpus, diskGiB: diskGiB)
    }

    /// The job of `made` with `figures`: its staged reads and each index file read where the index run left them.
    package static func job(_ made: SoloPlanOutcome, figures: SalmonPlanSubmit.Figures) -> ExecutorPlanBatchJob {
        ExecutorPlanBatchJob(
            emission: ExecutorPlanEmission(plan: made.plan, sources: made.sources),
            submit: ExecutorPlanSubmitValues(
                sampleName: made.sample.name, requestDiskGiB: figures.diskGiB, requestMemoryMiB: figures.memoryMiB,
                requestCpus: figures.cpus),
            stagedPaths: made.sample.stagedPaths, stagedReferencePaths: made.stagedReferencePaths)
    }

    /// Writes the batch folder of the libraries' plans through ``ExecutorPlanBatchWriter``, which returns each `home`
    /// output into `<batch>/<sample>/result/`.
    @discardableResult
    package static func write(
        _ jobs: [(made: SoloPlanOutcome, figures: SalmonPlanSubmit.Figures)], image: ExecutorPlanImageRecord,
        layout: ExecutorPlanStagingLayout, requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        try ExecutorPlanBatchWriter.write(
            jobs.map { job($0.made, figures: $0.figures) }, image: image, layout: layout, requirements: requirements, into: folder)
    }
}
