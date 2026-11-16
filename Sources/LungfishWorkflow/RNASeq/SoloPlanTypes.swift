// SoloPlanTypes.swift - What the STARsolo count plan on Linux takes and gives, and its presets (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The presets of `scripts/repro/rnaseq/tenx-controls/run.sh:159-169` (`solo_args`), each with its chemistry's barcode
/// list. One run counts `Gene`, `GeneFull` and `GeneFull_Ex50pAS`, and the preset names the matrix its route counts.
package enum SoloPlanPreset: String, CaseIterable, Sendable {
    /// 10x 3' v3 with STARsolo's options for Cell Ranger 3.0.0 (pbmc_1k_v3, hgmm_1k_v3).
    case threePrimeV3 = "tenx-3p-v3"
    /// 10x 5' v2, read 2 only, with the options for Cell Ranger 5.0.0 (sc5p_v2_hs_PBMC_1k).
    case fivePrimeV2 = "tenx-5p-v2"
    /// 10x 3' v3 with the options for Cell Ranger 4 and later, counting introns (SC3pv3_GEX_Human_PBMC).
    case threePrimeV3Introns = "tenx-3p-v3-introns"

    package var name: String {
        switch self {
        case .threePrimeV3: "Exons only, 10x 3' v3 (STARsolo Gene)"
        case .fivePrimeV2: "Exons only, 10x 5' v2 (STARsolo Gene)"
        case .threePrimeV3Introns: "Exons and introns (STARsolo GeneFull_Ex50pAS)"
        }
    }

    package var barcodeList: SoloBarcodeList {
        self == .fivePrimeV2 ? SoloPlanBarcodes.fivePrimeV2 : SoloPlanBarcodes.threePrimeV3
    }

    /// The arguments of `solo_args` after `--soloCBwhitelist <list>`.
    package var arguments: [String] {
        let clip = ["--clipAdapterType", "CellRanger4", "--outFilterScoreMin", "30"]
        switch self {
        case .threePrimeV3: return ["--soloUMIlen", "12", "--soloStrand", "Forward"]
        case .fivePrimeV2: return ["--soloUMIlen", "10", "--soloStrand", "Reverse"] + clip
        case .threePrimeV3Introns: return ["--soloUMIlen", "12", "--soloStrand", "Forward"] + clip
        }
    }

    /// The `Solo.out` matrix the result's route counts, which the adopt reads.
    package var feature: String { self == .threePrimeV3Introns ? "GeneFull_Ex50pAS" : "Gene" }

    package var routeID: String { self == .threePrimeV3Introns ? "starsolo-genefull-ex50pas" : "starsolo-gene" }

    /// The record line of `chemistry`, which states the read layout and every option the preset adds.
    package var chemistry: String {
        let layout = "barcode of 16 nt at 1 and UMI of \(self == .fivePrimeV2 ? 10 : 12) nt at 17 of read 1, cDNA in read 2"
        switch self {
        case .threePrimeV3: return "10x 3' v3: \(layout) on the gene's strand (--soloStrand Forward)"
        case .fivePrimeV2: return "10x 5' v2, read 2 only: \(layout) on the other strand (--soloStrand Reverse), "
            + "--clipAdapterType CellRanger4 --outFilterScoreMin 30"
        case .threePrimeV3Introns: return "10x 3' v3: \(layout) on the gene's strand (--soloStrand Forward), "
            + "--clipAdapterType CellRanger4 --outFilterScoreMin 30"
        }
    }

    /// The record line of `counts`. The introns preset approximates Cell Ranger 7's include-introns counting and is never
    /// called more than that (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:86`).
    package var counts: String {
        self == .threePrimeV3Introns
            ? "UMIs a cell and gene of Solo.out/GeneFull_Ex50pAS, reads on a gene's exons and introns, which approximates "
                + "Cell Ranger 7's include-introns counting"
            : "UMIs a cell and gene of Solo.out/Gene, reads on a gene's exons"
    }
}

/// What a STARsolo plan takes from outside the set and the reads: the executor, the image's tool manifest pin, STAR
/// 2.7.11b, the decompressor STAR's `--readFilesCommand` starts for gzip reads, and the data files of the manifest, whose
/// barcode lists decide a list's source (BIO-SOLO-GTF item 9).
package struct SoloPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var star: PlanToolPin
    package var decompressor: PlanToolPin
    package var imageFiles: [ImageDataFile]

    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        star: PlanToolPin, decompressor: PlanToolPin, imageFiles: [ImageDataFile]
    ) {
        (self.executor, self.executorBuild, self.imageManifest) = (executor, executorBuild, imageManifest)
        (self.star, self.decompressor, self.imageFiles) = (star, decompressor, imageFiles)
    }

    /// STAR 2.7.11b and pigz, each listed once in the image's tool manifest, and the manifest's data files.
    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        toolManifest: ImageToolManifest
    ) throws {
        let stars = toolManifest.tools.filter { $0.id == "STAR" && $0.version == SoloPlan.starVersion }
        guard stars.count == 1, let star = stars.first, let pigz = try? toolManifest.pin(forToolID: "pigz") else {
            throw SoloPlanError("The image's tool manifest lists no single STAR \(SoloPlan.starVersion) and pigz, so name an "
                + "image that holds them with --image-tool-manifest.")
        }
        self.init(executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, star: star.pin,
                  decompressor: pigz, imageFiles: toolManifest.files ?? [])
    }
}

package struct SoloPlanRequest: Sendable {
    /// The set's folder in the storage root's reference sets.
    package var setFolder: URL
    /// One library: its read pairs, read 1 the barcode and UMI and read 2 the cDNA, every lane a pair.
    package var sample: SalmonPlanSample
    package var pins: SoloPlanPins
    package var preset: SoloPlanPreset
    /// The STAR index an earlier run staged, pinned from its adopted record by the variant's key (ARCH-SOLO-GTF item 5).
    package var index: ExecutorPlanStagedIndex
    /// The barcode list the person gave, measured, or nil for the image's list of the preset.
    package var suppliedList: ExecutorPlanSourceFile?
    /// STAR's `--runThreadN`, a fixed number in the argv and the job's CPUs.
    package var threads: Int
    /// The first value of `--soloCellFilter EmptyDrops_CR`, or nil for STAR's default of 3,000.
    package var expectedCells: Int?
    /// The limit the person named for each step in seconds, or nil for the longest a plan allows.
    package var deadlineSeconds: Double?

    package init(
        setFolder: URL, sample: SalmonPlanSample, pins: SoloPlanPins, preset: SoloPlanPreset, index: ExecutorPlanStagedIndex,
        suppliedList: ExecutorPlanSourceFile? = nil, threads: Int = SoloPlan.defaultThreads, expectedCells: Int? = nil,
        deadlineSeconds: Double? = nil
    ) {
        (self.setFolder, self.sample, self.pins, self.preset, self.index) = (setFolder, sample, pins, preset, index)
        (self.suppliedList, self.threads, self.expectedCells, self.deadlineSeconds) = (suppliedList, threads, expectedCells, deadlineSeconds)
    }
}

package struct SoloPlanOutcome: ReadsPlanOutcome {
    package var plan: ExecutionPlan
    package var sample: SalmonPlanSample
    package var index: STARIndexKey
    package var barcodeList: SoloBarcodeChoice
    /// STAR's `--runThreadN` in the argv, which the job's CPUs equal.
    package var threads: Int
    /// Each entry's `relativePath` to the Mac file the batch copies there.
    package var sources: [String: URL]
    /// Each index file's `relativePath` to where the index run left it in the staging folder.
    package var stagedReferencePaths: [String: String]
}

/// A refusal of the STARsolo plan, in words that say what to do.
package struct SoloPlanError: Error, LocalizedError, Equatable, Sendable {
    package var message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}
