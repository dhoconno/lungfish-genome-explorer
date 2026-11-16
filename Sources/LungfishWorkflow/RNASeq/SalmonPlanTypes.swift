// SalmonPlanTypes.swift - What the salmon plan on Linux takes and gives (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// What a salmon plan takes from outside the set and the reads: the executor, the image's tool manifest pin and the two
/// tools it runs. Trim Galore 2.3.0 trims, gzips and runs FastQC in its own process (its `--help` in the image), so a
/// plan launches no other program. A plan for a run whose record is adopted names a true executor manifest (ARCH-M-IMAGE
/// item 5).
package struct SalmonPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var salmon: PlanToolPin
    package var trimGalore: PlanToolPin

    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        salmon: PlanToolPin, trimGalore: PlanToolPin
    ) {
        self.executor = executor
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.salmon = salmon
        self.trimGalore = trimGalore
    }

    /// The pins of `salmon` and `trim_galore`, each listed once in the image's tool manifest.
    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        toolManifest: ImageToolManifest
    ) throws {
        func pin(_ id: String) throws -> PlanToolPin {
            guard let pin = try? toolManifest.pin(forToolID: id) else {
                throw SalmonPlanError("The image's tool manifest lists no single \(id), so name an image that holds it with "
                    + "--image-tool-manifest.")
            }
            return pin
        }
        self.init(executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, salmon: try pin("salmon"),
                  trimGalore: try pin("trim_galore"))
    }
}

/// One read file: the name it was given, its SHA-256 and size, and the Mac file the batch copies to the staging folder,
/// nil for a read that is in the staging folder already.
package struct SalmonPlanRead: Sendable, Equatable {
    package var name: String
    package var sha256: String
    package var size: Int64
    package var source: URL?

    package init(name: String, sha256: String, size: Int64, source: URL?) {
        self.name = name
        self.sha256 = sha256
        self.size = size
        self.source = source
    }
}

/// One sample's reads as salmon takes them, mate pairs or single reads and never both, as the Mac route takes a bundle.
package struct SalmonPlanSample: Sendable, Equatable {
    package struct Pair: Sendable, Equatable {
        package var r1: SalmonPlanRead
        package var r2: SalmonPlanRead

        package init(r1: SalmonPlanRead, r2: SalmonPlanRead) {
            self.r1 = r1
            self.r2 = r2
        }
    }

    package var name: String
    package var pairs: [Pair]
    package var singles: [SalmonPlanRead]
    /// Each read's absolute path in the staging folder, in the order of the plan's input entries, or nil for reads on
    /// this Mac (C6 ruling STAGED). A submit value, never a plan byte.
    package var stagedPaths: [String]?
    package var instrument: PlanSampleInstrument?
    /// The `duplicates` words and their source (executor-plan.md, the paragraph on `duplicates`).
    package var duplicates: String
    package var duplicatesSource: ImportSettingSource

    package init(
        name: String, pairs: [Pair], singles: [SalmonPlanRead], stagedPaths: [String]? = nil,
        instrument: PlanSampleInstrument? = nil, duplicates: String, duplicatesSource: ImportSettingSource
    ) {
        self.name = name
        self.pairs = pairs
        self.singles = singles
        self.stagedPaths = stagedPaths
        self.instrument = instrument
        self.duplicates = duplicates
        self.duplicatesSource = duplicatesSource
    }

    /// The reads in the order of the plan's input entries: each pair's R1 and R2, then the single reads.
    package var reads: [SalmonPlanRead] { pairs.flatMap { [$0.r1, $0.r2] } + singles }
}

package struct SalmonPlanRequest: Sendable {
    /// The set's folder in the storage root's reference sets.
    package var setFolder: URL
    /// The storage root whose `rnaseq-index-cache/` holds the published index. A plan never builds one.
    package var storageRoot: URL
    package var sample: SalmonPlanSample
    package var pins: SalmonPlanPins
    package var trim: SalmonQuantTrim
    package var k: Int
    package var decoys: SalmonIndexDecoys
    /// salmon's `-p`, a fixed number in the argv and the job's CPUs.
    package var threads: Int
    /// The limit the person named for each step in seconds, or nil for the longest a plan allows.
    package var deadlineSeconds: Double?

    package init(
        setFolder: URL, storageRoot: URL, sample: SalmonPlanSample, pins: SalmonPlanPins, trim: SalmonQuantTrim,
        k: Int = 31, decoys: SalmonIndexDecoys = .genome, threads: Int = SalmonPlan.defaultThreads,
        deadlineSeconds: Double? = nil
    ) {
        self.setFolder = setFolder
        self.storageRoot = storageRoot
        self.sample = sample
        self.pins = pins
        self.trim = trim
        self.k = k
        self.decoys = decoys
        self.threads = threads
        self.deadlineSeconds = deadlineSeconds
    }
}

/// One sample's plan from any chain on the reads frame, salmon's or a later lane's, as the batch takes it: the plan, the
/// sample whose name and staged reads the job carries, and the Mac file of each entry the batch copies.
package protocol ReadsPlanOutcome: Sendable {
    var plan: ExecutionPlan { get }
    var sample: SalmonPlanSample { get }
    /// Each entry's `relativePath` to the Mac file the batch copies there.
    var sources: [String: URL] { get }
}

package struct SalmonPlanOutcome: ReadsPlanOutcome {
    package var plan: ExecutionPlan
    package var sample: SalmonPlanSample
    package var index: SalmonIndexKey
    /// salmon's `-p` in the argv, which the job's CPUs equal.
    package var threads: Int
    /// Each entry's `relativePath` to the Mac file the batch copies there.
    package var sources: [String: URL]
}

/// A refusal of the salmon plan, in words that say what to do.
package struct SalmonPlanError: Error, LocalizedError, Equatable, Sendable {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}
