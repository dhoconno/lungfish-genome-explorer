// STARIndexSubmit.swift - The submit values of the index job and its batch (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The memory, CPUs and disk the index job asks for, and the batch that carries them through EX-SUBMIT's core. They are
/// values of the submit side and never reach a plan byte (`docs/formats/executor-plan.md`, Request figures stay on the
/// submit side).
package enum STARIndexSubmit {
    package struct Figures: Sendable, Equatable {
        package var memoryMiB: Int64
        package var cpus: Int
        package var diskGiB: Int

        package init(memoryMiB: Int64, cpus: Int, diskGiB: Int) {
            self.memoryMiB = memoryMiB
            self.cpus = cpus
            self.diskGiB = diskGiB
        }
    }

    /// The genomes with measured figures, by assembly name. Macaca_fascicularis_6.0 with `--genomeSAsparseD 2` peaked at
    /// 29.79 GB in STAR 2.7.11b on a CHTC node and used 37.3 GiB of disk (REF, `SCR/lanes/LINUX-HOST.md`), so the job asks
    /// for 8 CPUs, 40,960 MiB and 120 GiB. The memory is STAR's own peak and never CHTC's `MemoryUsage` (BIO-LINUX-HOST item 9).
    package static let measured: [String: Figures] = [
        "Macaca_fascicularis_6.0": Figures(memoryMiB: 40_960, cpus: 8, diskGiB: 120),
    ]

    /// The person's value for each figure, else the measured one of the set's genome. A genome with no measured figure
    /// and no value from the person is refused in words.
    package static func figures(
        for manifest: ReferenceSetManifest, memoryMiB: Int64? = nil, cpus: Int? = nil, diskGiB: Int? = nil
    ) throws -> Figures {
        let known = measured[manifest.assembly.name]
        let missing = [("--request-memory-mib", (memoryMiB ?? known?.memoryMiB) == nil),
                       ("--request-cpus", (cpus ?? known?.cpus) == nil),
                       ("--request-disk-gib", (diskGiB ?? known?.diskGiB) == nil)].filter(\.1).map(\.0)
        guard missing.isEmpty, let memory = memoryMiB ?? known?.memoryMiB, let cpu = cpus ?? known?.cpus,
              let disk = diskGiB ?? known?.diskGiB else {
            throw STARIndexError("LGE has no measured figures for a STAR index of \(manifest.assembly.name), which is the genome of the "
                + "set \(manifest.id). It has them for \(measured.keys.sorted().joined(separator: ", ")) only, and another genome "
                + "needs its own SMOKE figures: build the index once on a small job and read STAR's own peak memory and the job's "
                + "disk, never the pool's MemoryUsage. Give \(missing.joined(separator: ", ")).")
        }
        return Figures(memoryMiB: memory, cpus: cpu, diskGiB: disk)
    }

    /// The job of `made` with `figures`, as a batch of one node named `index`.
    package static func job(_ made: STARIndexPlanOutcome, figures: Figures) -> ExecutorPlanBatchJob {
        ExecutorPlanBatchJob(
            emission: ExecutorPlanEmission(plan: made.plan, sources: made.sources),
            submit: ExecutorPlanSubmitValues(
                sampleName: STARIndexPlan.sampleName, requestDiskGiB: figures.diskGiB, requestMemoryMiB: figures.memoryMiB,
                requestCpus: figures.cpus))
    }

    /// Writes the batch folder through ``ExecutorPlanBatchWriter``, which remaps each `staged` file to
    /// `<batch>/index/staged/<plan path>`.
    @discardableResult
    package static func write(
        _ made: STARIndexPlanOutcome, figures: Figures, image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout,
        requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        try ExecutorPlanBatchWriter.write(
            [job(made, figures: figures)], image: image, layout: layout, requirements: requirements, into: folder)
    }
}
