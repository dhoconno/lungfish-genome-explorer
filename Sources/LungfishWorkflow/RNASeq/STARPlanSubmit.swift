// STARPlanSubmit.swift - The request rule of a STAR job and its batch (Phase 5.3 lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The memory, CPUs and disk a STAR job asks for, values of the submit side that never reach a plan byte.
package enum STARPlanSubmit {
    /// A genome's least-squares fit on measured jobs: STAR's own peak and the job's disk, each a fixed part plus a part a
    /// million pairs.
    package struct Fit: Sendable, Equatable {
        package var peakBytes: Double
        package var peakBytesPerMillionPairs: Double
        package var diskGiB: Double
        package var diskGiBPerMillionPairs: Double
    }

    /// LINUX-HOST's four GSE225770 samples on two node types (BIO-LINUX-HOST item 9, `lanes/LINUX-HOST.md:200-206`):
    /// STAR's own peak, never CHTC's rounded `MemoryUsage`, and `DiskUsage_RAW`.
    package static let measured: [String: Fit] = [
        "Macaca_fascicularis_6.0": Fit(peakBytes: 23.7e9, peakBytesPerMillionPairs: 0.023e9, diskGiB: 14.4, diskGiBPerMillionPairs: 0.488),
    ]
    package static let memoryFactor = 1.25
    package static let diskFactor = 1.5
    /// gzip FASTQ bytes a pair: LINUX-HOST's jobs read 10.40 GB for 71.85 M pairs, 144.7 bytes, taken down to 140 so an
    /// estimate errs toward more pairs. Plain reads take more bytes a pair, so their estimate errs the same way.
    package static let bytesPerPair = 140.0

    /// Millions of pairs, or of reads for single reads, from the bytes of the plan's reads.
    package static func estimatedMillionPairs(_ plan: ExecutionPlan) -> Double {
        Double(plan.entries.filter { $0.role == .input }.reduce(Int64(0)) { $0 + $1.size }) / bytesPerPair / 1e6
    }

    /// The person's value for each figure, else the rule's. CPUs are STAR's `--runThreadN`. Memory is 1.25 times the fit's
    /// peak, rounded up to a whole GiB, and disk 1.5 times the fit's disk, rounded up to 10 GiB, so a 50 M pair cynomolgus
    /// sample asks for 8 CPUs, 29,696 MiB and 60 GiB. A genome with no fit takes all three from the person or is refused.
    package static func figures(
        for manifest: ReferenceSetManifest, made: STARPlanOutcome, millionPairs: Double? = nil, memoryMiB: Int64? = nil,
        cpus: Int? = nil, diskGiB: Int? = nil
    ) throws -> SalmonPlanSubmit.Figures {
        guard cpus == nil || cpus == made.threads else {
            throw STARPlanError("The job asks for \(cpus ?? 0) CPUs and its plan runs STAR with --runThreadN \(made.threads). "
                + "Write the plan with the CPUs the job asks for.")
        }
        let fit = measured[manifest.assembly.name]
        guard fit != nil || (memoryMiB != nil && cpus != nil && diskGiB != nil) else {
            let missing = [("--request-memory-mib", memoryMiB == nil), ("--request-cpus", cpus == nil), ("--request-disk-gib", diskGiB == nil)]
                .filter(\.1).map(\.0)
            throw STARPlanError("LGE has no measured figures for STAR on \(manifest.assembly.name), which is the genome of the set "
                + "\(manifest.id). It has them for \(measured.keys.sorted().joined(separator: ", ")) only, and another genome needs "
                + "its own: run one sample on a small job and read STAR's own peak memory and the job's disk. "
                + "Give \(missing.joined(separator: ", ")).")
        }
        let pairs = millionPairs ?? estimatedMillionPairs(made.plan)
        let memory = fit.map { fit -> Int64 in
            let bytes = memoryFactor * (fit.peakBytes + fit.peakBytesPerMillionPairs * pairs)
            return Int64((bytes / 1_073_741_824).rounded(.up)) * 1024
        }
        let disk = fit.map { fit -> Int in
            Int((diskFactor * (fit.diskGiB + fit.diskGiBPerMillionPairs * pairs) / 10).rounded(.up)) * 10
        }
        return SalmonPlanSubmit.Figures(memoryMiB: memoryMiB ?? memory ?? 0, cpus: made.threads, diskGiB: diskGiB ?? disk ?? 0)
    }

    /// The job of `made` with `figures`: the frame's job (``SalmonPlanSubmit/job(_:figures:)``), whose staged reads are
    /// read where they sit, with each index file read where the earlier run left it.
    package static func job(_ made: STARPlanOutcome, figures: SalmonPlanSubmit.Figures) -> ExecutorPlanBatchJob {
        var job = SalmonPlanSubmit.job(made, figures: figures)
        job.stagedReferencePaths = made.stagedReferencePaths
        return job
    }

    /// Writes the batch folder of the samples' plans through ``ExecutorPlanBatchWriter``, which returns each `home` output
    /// into `<batch>/<sample>/result/`.
    @discardableResult
    package static func write(
        _ jobs: [(made: STARPlanOutcome, figures: SalmonPlanSubmit.Figures)], image: ExecutorPlanImageRecord,
        layout: ExecutorPlanStagingLayout, requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        try ExecutorPlanBatchWriter.write(
            jobs.map { job($0.made, figures: $0.figures) }, image: image, layout: layout, requirements: requirements, into: folder)
    }
}
