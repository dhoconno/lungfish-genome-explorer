// UMIPlanSubmit.swift - The request rule of a UMI job (Phase 5.3 lane EX-UMI, milestone 3, EX-UMI-M2-BIO ruling 1 (c))
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The memory, CPUs and disk a UMI job asks for, values of the submit side that never reach a plan byte. STAR's rule fits
/// jobs that sort nothing (``STARPlanSubmit``). A UMI job's STAR sorts its BAM in a buffer of `--limitBAMsortRAM` bytes,
/// and samtools sorts the tagged BAM again with `-m 768M` a thread, so the memory holds STAR's peak and both buffers.
/// samtools runs after STAR ends, so the sum also leaves room for umi_tools count, which is not measured yet. GU's first
/// run reads `peakResidentBytes` of `star-align` against it (BIO-5-1-C-2 item 8).
package enum UMIPlanSubmit {
    /// STAR's sort buffer, the argv's `--limitBAMsortRAM`.
    package static let starSortBytes = Double(UMIPlan.bamSortRAM) ?? 8_000_000_000
    /// samtools sort's `-m 768M`, a thread's buffer.
    package static let samtoolsSortBytesPerThread = 768.0 * 1_048_576

    /// The person's value for each figure, else the rule's. CPUs are the argv's threads. Memory is 1.25 times the sum of
    /// STAR's measured peak at the job's pairs, STAR's sort buffer and samtools sort's buffer a thread, rounded up to a
    /// whole GiB, and disk is a STAR job's, so a 50 M pair cynomolgus sample at 8 threads asks for 47,104 MiB and 60 GiB. A
    /// genome with no measured peak takes all three from the person or is refused.
    package static func figures(
        for manifest: ReferenceSetManifest, made: UMIPlanOutcome, millionPairs: Double? = nil, memoryMiB: Int64? = nil,
        cpus: Int? = nil, diskGiB: Int? = nil
    ) throws -> SalmonPlanSubmit.Figures {
        guard cpus == nil || cpus == made.threads else {
            throw STARPlanError("The job asks for \(cpus ?? 0) CPUs and its plan runs STAR with --runThreadN \(made.threads). "
                + "Write the plan with the CPUs the job asks for.")
        }
        let fit = STARPlanSubmit.measured[manifest.assembly.name]
        guard fit != nil || (memoryMiB != nil && cpus != nil && diskGiB != nil) else {
            let missing = [("--request-memory-mib", memoryMiB == nil), ("--request-cpus", cpus == nil), ("--request-disk-gib", diskGiB == nil)]
                .filter(\.1).map(\.0)
            throw STARPlanError("LGE has no measured figures for STAR on \(manifest.assembly.name), which is the genome of the set "
                + "\(manifest.id), so it cannot size a UMI job. A UMI job's memory must hold STAR's peak on the index, "
                + bufferWords(threads: made.threads) + ". Give \(missing.joined(separator: ", ")).")
        }
        let pairs = millionPairs ?? STARPlanSubmit.estimatedMillionPairs(made.plan)
        let memory = fit.map { fit -> Int64 in
            let bytes = STARPlanSubmit.memoryFactor * (fit.peakBytes + fit.peakBytesPerMillionPairs * pairs + starSortBytes
                + samtoolsSortBytesPerThread * Double(made.threads))
            return Int64((bytes / 1_073_741_824).rounded(.up)) * 1024
        }
        let disk = fit.map { fit -> Int in
            Int((STARPlanSubmit.diskFactor * (fit.diskGiB + fit.diskGiBPerMillionPairs * pairs) / 10).rounded(.up)) * 10
        }
        return SalmonPlanSubmit.Figures(memoryMiB: memoryMiB ?? memory ?? 0, cpus: made.threads, diskGiB: diskGiB ?? disk ?? 0)
    }

    static func bufferWords(threads: Int) -> String {
        "STAR's sort buffer of 8,000,000,000 bytes (--limitBAMsortRAM) and samtools sort's 768 MiB for each of \(threads) "
            + "thread\(threads == 1 ? "" : "s") (-m 768M)"
    }

    /// The rule in the words of the plan folder's summary, once for the folder.
    package static func words(for manifest: ReferenceSetManifest, threads: Int) -> String {
        guard let fit = STARPlanSubmit.measured[manifest.assembly.name] else {
            return "LGE has no measured peak for STAR on \(manifest.assembly.name), so each UMI job asks for the memory given, "
                + "which must hold STAR's peak on the index, \(bufferWords(threads: threads))."
        }
        let peak = String(format: "%.1f GB and %.3f GB a million pairs", fit.peakBytes / 1e9, fit.peakBytesPerMillionPairs / 1e9)
        return "Each UMI job's memory, unless --request-memory-mib names it, is 1.25 times the sum of STAR's measured peak on "
            + "\(manifest.assembly.name) (\(peak)), \(bufferWords(threads: threads)), rounded up to a whole GiB, and its disk "
            + "is a STAR job's."
    }
}
