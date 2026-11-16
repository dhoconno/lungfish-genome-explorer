// STARIndexPlanTypes.swift - What the STAR index plan takes and gives (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// What a plan takes from outside the set: the executor, the image's tool manifest pin and the two tools it runs. A plan
/// for a run whose record is adopted names a true executor manifest, never `test` or zeros (ARCH-M-IMAGE item 5).
package struct STARIndexPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var star: PlanToolPin
    /// Decompresses a gzip genome. It writes plain text, so no step of the plan writes gzip (ARCH-M-IMAGE item 10).
    package var decompressor: PlanToolPin

    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        star: PlanToolPin, decompressor: PlanToolPin
    ) {
        self.executor = executor
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.star = star
        self.decompressor = decompressor
    }

    /// The pins of `version` and of `pigz` in the image's tool manifest, which lists STAR 2.7.11b and 2.7.3a each once.
    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        toolManifest: ImageToolManifest, star version: STARIndexVersion
    ) throws {
        let stars = Set(toolManifest.tools.filter { $0.id == "STAR" && $0.version == version.rawValue }.map(\.pin))
        guard stars.count == 1, let star = stars.first else {
            throw STARIndexError("The image's tool manifest lists \(stars.isEmpty ? "no" : "more than one") STAR \(version.rawValue), "
                + "so name an image that holds it with --image-tool-manifest.")
        }
        guard let pigz = try? toolManifest.pin(forToolID: "pigz") else {
            throw STARIndexError("The image's tool manifest lists no single pigz, which decompresses a gzip genome.")
        }
        self.init(executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, star: star, decompressor: pigz)
    }
}

package struct STARIndexPlanRequest: Sendable {
    package var setFolder: URL
    package var star: STARIndexVersion
    package var pins: STARIndexPlanPins
    /// The limit the person named for each step in seconds, or nil for the longest a plan allows.
    package var deadlineSeconds: Double?
    /// The list of the 10x filter rule for the STARsolo variant, or nil for the bulk index.
    package var tenxFilter: TenxGTFFilter.List?
    /// The plan folder the person names, which the variant's made GTF is written into and copied from, never the set.
    package var planFolder: URL?

    package init(
        setFolder: URL, star: STARIndexVersion, pins: STARIndexPlanPins, deadlineSeconds: Double? = nil,
        tenxFilter: TenxGTFFilter.List? = nil, planFolder: URL? = nil
    ) {
        self.setFolder = setFolder
        self.star = star
        self.pins = pins
        self.deadlineSeconds = deadlineSeconds
        self.tenxFilter = tenxFilter
        self.planFolder = planFolder
    }
}

package struct STARIndexPlanOutcome: Sendable {
    package var plan: ExecutionPlan
    package var key: STARIndexKey
    /// Each entry's `relativePath` to the Mac file the batch copies there.
    package var sources: [String: URL]
    /// The variant's made GTF, which the writer puts at `sources` of its entry. Nil for the bulk index.
    package var made: TenxGTFFilter.Made? = nil
}
