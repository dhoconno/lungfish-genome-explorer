// STARPlanTypes.swift - What the STAR plans on Linux take and give (Phase 5.3 lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The STAR chains of one sample's reads. Each maps with STAR `--quantMode GeneCounts` on an index an earlier run staged
/// on Linux, and the featureCounts chain then counts the exons of the set's `derived/genes.gtf` on STAR's BAM.
package enum STARPlanChain: String, CaseIterable, Sendable {
    /// STAR's `ReadsPerGene.out.tab` holds the counts (gate GE, at STAR 2.7.3a).
    case geneCounts = "star-genecounts"
    /// subread featureCounts on the exons, with STAR's `ReadsPerGene.out.tab` beside it (gate GF, at STAR 2.7.11b).
    case featureCounts = "star-featurecounts-exon"

    /// The name a person reads for the chain.
    package var presetName: String {
        switch self {
        case .geneCounts: return "Bulk counts by STAR GeneCounts on the genome"
        case .featureCounts: return "Bulk exon counts by featureCounts on STAR's alignments"
        }
    }
}

/// What a STAR plan takes from outside the set and the reads: the executor, the image's tool manifest pin and the tools
/// its steps run or start. pigz is the program STAR's `--readFilesCommand` starts for gzip reads, so it is pinned too
/// (`docs/formats/executor-plan.md`, The `tool` step).
package struct STARPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var star: PlanToolPin
    package var trimGalore: PlanToolPin
    package var decompressor: PlanToolPin
    package var featureCounts: PlanToolPin

    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        star: PlanToolPin, trimGalore: PlanToolPin, decompressor: PlanToolPin, featureCounts: PlanToolPin
    ) {
        self.executor = executor
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.star = star
        self.trimGalore = trimGalore
        self.decompressor = decompressor
        self.featureCounts = featureCounts
    }

    /// The pins of STAR `version`, `trim_galore`, `pigz` and `featureCounts`, each listed once in the image's manifest.
    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        toolManifest: ImageToolManifest, star version: STARIndexVersion
    ) throws {
        let index = try STARIndexPlanPins(
            executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, toolManifest: toolManifest,
            star: version)
        func pin(_ id: String) throws -> PlanToolPin {
            guard let pin = try? toolManifest.pin(forToolID: id) else {
                throw STARPlanError("The image's tool manifest lists no single \(id), so name an image that holds it with "
                    + "--image-tool-manifest.")
            }
            return pin
        }
        self.init(executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, star: index.star,
                  trimGalore: try pin("trim_galore"), decompressor: index.decompressor,
                  featureCounts: try pin("featureCounts"))
    }
}

package struct STARPlanRequest: Sendable {
    /// The set's folder in the storage root's reference sets.
    package var setFolder: URL
    package var sample: SalmonPlanSample
    package var pins: STARPlanPins
    package var chain: STARPlanChain
    /// The index an earlier run staged, pinned once a command from its adopted record. A plan never builds one.
    package var index: ExecutorPlanStagedIndex
    package var trim: SalmonQuantTrim
    /// STAR's `--runThreadN` and featureCounts' `-T`, a fixed number in the argv and the job's CPUs.
    package var threads: Int
    /// STAR's `--outFilterMultimapNmax` when the person names one, or nil for STAR's default of 10, which passes no flag.
    package var multimapNmax: Int?
    /// The limit the person named for each step in seconds, or nil for the longest a plan allows.
    package var deadlineSeconds: Double?

    package init(
        setFolder: URL, sample: SalmonPlanSample, pins: STARPlanPins, chain: STARPlanChain, index: ExecutorPlanStagedIndex,
        trim: SalmonQuantTrim, threads: Int = STARPlan.defaultThreads, multimapNmax: Int? = nil, deadlineSeconds: Double? = nil
    ) {
        self.setFolder = setFolder
        self.sample = sample
        self.pins = pins
        self.chain = chain
        self.index = index
        self.trim = trim
        self.threads = threads
        self.multimapNmax = multimapNmax
        self.deadlineSeconds = deadlineSeconds
    }
}

/// One sample's STAR plan as the batch takes it, with the staging path of each index file, which the job reads where the
/// earlier run left it (``ExecutorPlanBatchJob/stagedReferencePaths``).
package struct STARPlanOutcome: ReadsPlanOutcome {
    package var plan: ExecutionPlan
    package var sample: SalmonPlanSample
    package var index: STARIndexKey
    /// STAR's `--runThreadN` in the argv, which the job's CPUs equal.
    package var threads: Int
    /// Each entry's `relativePath` to the Mac file the batch copies there.
    package var sources: [String: URL]
    /// Each index entry's `relativePath` to its absolute path in the staging folder, a submit value.
    package var stagedReferencePaths: [String: String]
}

/// A refusal of a STAR plan or its request figures, in words that say what to do.
package struct STARPlanError: Error, LocalizedError, Equatable, Sendable {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}
