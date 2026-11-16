// SalmonPlanSubmit.swift - The request rule of the salmon job and its batch (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The memory, CPUs and disk a salmon job asks for. They are values of the submit side, set with the plan and never in a
/// plan byte (`docs/formats/executor-plan.md`, Request figures stay on the submit side, ruling ARCH-SCHEMA-SPIKE item 4).
package enum SalmonPlanSubmit {
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

    private static let gib: Int64 = 1_073_741_824

    /// salmon's peak resident memory at 8 threads by genome, galah's until a node measures it: 5,960,744,960 bytes for
    /// SRR23580170 (71.9 M pairs) on the Macaca_fascicularis_6.0 set (`SCR/lanes/SPIKE-SALMON.md:124`).
    package static let measuredPeakBytes: [String: Int64] = ["Macaca_fascicularis_6.0": 5_960_744_960]
    /// Added to the peak for the executor and Trim Galore, which runs before salmon on one core in about 5 MB.
    package static let memoryMarginBytes: Int64 = 2 * 1_073_741_824
    /// The temporary files salmon wrote in its folder on the macaque quant, 1.08 GB (`SPIKE-SALMON.md:112,124`).
    package static let salmonTemporaryBytes: Int64 = 1_077_186_560
    /// The trimmed reads take up to twice the reads, since Trim Galore 2.3.0 writes gzip level 1 by default (its `--help`).
    package static let trimmedReadsFactor: Int64 = 2

    /// The person's value for each figure, else the rule's. CPUs are salmon's `-p` in the argv. Memory is the measured
    /// peak plus ``memoryMarginBytes``, rounded up to a whole GiB. Disk is 1.25 times the reads, the trimmed reads, the
    /// index and salmon's temporary files, rounded up to a whole GiB, plus 8 GiB for the plan and the work files, as C4's
    /// rule adds. A set with no measured peak takes all three from the person, or is refused in words.
    package static func figures(
        for manifest: ReferenceSetManifest, made: SalmonPlanOutcome, memoryMiB: Int64? = nil, cpus: Int? = nil, diskGiB: Int? = nil
    ) throws -> Figures {
        guard cpus == nil || cpus == made.threads else {
            throw SalmonPlanError("The job asks for \(cpus ?? 0) CPUs and its plan runs salmon with -p \(made.threads). Write the "
                + "plan with the CPUs the job asks for.")
        }
        let peak = measuredPeakBytes[manifest.assembly.name]
        guard peak != nil || (memoryMiB != nil && cpus != nil && diskGiB != nil) else {
            let missing = [("--request-memory-mib", memoryMiB == nil), ("--request-cpus", cpus == nil), ("--request-disk-gib", diskGiB == nil)]
                .filter(\.1).map(\.0)
            throw SalmonPlanError("LGE has no measured figures for salmon on \(manifest.assembly.name), which is the genome of the "
                + "set \(manifest.id). It has them for \(measuredPeakBytes.keys.sorted().joined(separator: ", ")) only, and another "
                + "genome needs its own: run one sample on a small job and read salmon's own peak memory and the job's disk. "
                + "Give \(missing.joined(separator: ", ")).")
        }
        let plan = made.plan
        let reads = plan.entries.filter { $0.role == .input }.reduce(Int64(0)) { $0 + $1.size }
        let index = plan.entries.filter { $0.role == .reference }.reduce(Int64(0)) { $0 + $1.size }
        let trimmed = plan.steps.contains { $0.tool?.id == "trim_galore" } ? trimmedReadsFactor * reads : 0
        let bytes = Double(reads + trimmed + index + salmonTemporaryBytes) * 1.25
        let disk = Int((bytes / Double(gib)).rounded(.up)) + 8
        let memory = peak.map { (($0 + memoryMarginBytes + gib - 1) / gib) * 1024 }
        return Figures(memoryMiB: memoryMiB ?? memory ?? 0, cpus: made.threads, diskGiB: diskGiB ?? disk)
    }

    /// The job of `made` with `figures`, its sample's staged reads read where they sit.
    package static func job(_ made: SalmonPlanOutcome, figures: Figures) -> ExecutorPlanBatchJob {
        ExecutorPlanBatchJob(
            emission: ExecutorPlanEmission(plan: made.plan, sources: made.sources),
            submit: ExecutorPlanSubmitValues(
                sampleName: made.sample.name, requestDiskGiB: figures.diskGiB, requestMemoryMiB: figures.memoryMiB,
                requestCpus: figures.cpus),
            stagedPaths: made.sample.stagedPaths)
    }

    /// Writes the batch folder of the samples' plans through ``ExecutorPlanBatchWriter``, which returns each `home` output
    /// into `<batch>/<sample>/result/`.
    @discardableResult
    package static func write(
        _ jobs: [(made: SalmonPlanOutcome, figures: Figures)], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout,
        requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        try ExecutorPlanBatchWriter.write(
            jobs.map { job($0.made, figures: $0.figures) }, image: image, layout: layout, requirements: requirements, into: folder)
    }
}
