// ExecutorPlanFill.swift - The plan request cut into a recipe template request and a sample row (CHTC C4 lane F)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishPortable

/// The half of a plan request that every sample of one recipe and input shape shares (V5): the input shape, the
/// platform, the recipe, the storage settings, the executor, the image and the databases. It holds no sample value, so
/// `ExecutorPlanEmitter.template(_:host:)` plans it once for every sample.
package struct ExecutorPlanTemplateRequest: Sendable {
    package var inputFormat: RecipeFileFormat
    /// Each input's FASTQ suffix by `PlanTemplate.fastqSuffix(of:)`, R1 then R2, or the one file. The template names one
    /// slot per suffix, and the fill refuses a sample whose file names take another.
    package var inputSuffixes: [String]
    /// The platform the import names for every sample, a setting option.
    package var platform: String?
    /// The resolved recipe, or nil for an import with no recipe, given with `recipeFile` or not at all.
    package var recipe: Recipe?
    package var recipeFile: ExecutorPlanSourceFile?
    package var storage: ExecutorPlanStorageRequest
    package var executorFile: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var imageTools: [PlanToolPin]
    package var deadlines: ExecutorPlanDeadlines
    /// Each database a recipe step reads, by the step's database id.
    package var databases: [String: ExecutorPlanDatabaseFile]

    package init(
        inputFormat: RecipeFileFormat, inputSuffixes: [String], platform: String?, recipe: Recipe?,
        recipeFile: ExecutorPlanSourceFile?, storage: ExecutorPlanStorageRequest, executorFile: ExecutorPlanSourceFile,
        executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin, imageTools: [PlanToolPin],
        deadlines: ExecutorPlanDeadlines, databases: [String: ExecutorPlanDatabaseFile] = [:]
    ) {
        self.inputFormat = inputFormat
        self.inputSuffixes = inputSuffixes
        self.platform = platform
        self.recipe = recipe
        self.recipeFile = recipeFile
        self.storage = storage
        self.executorFile = executorFile
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.imageTools = imageTools
        self.deadlines = deadlines
        self.databases = databases
    }
}

/// A template and the Mac file each of its executor, recipe and database entries is staged from.
package struct ExecutorPlanTemplate: Sendable {
    package let template: PlanTemplate
    /// Entry `relativePath` to the Mac file, for each entry the template pins.
    package let sources: [String: URL]

    package init(template: PlanTemplate, sources: [String: URL]) {
        self.template = template
        self.sources = sources
    }

    /// One sample's plan and the Mac file of each of its entries: the row's split, then the template's fill. A fill
    /// refusal becomes an `ExecutorPlanError` with the same field and words, as the folder writer maps the resolver's,
    /// and the decoder's own `PlanDecodeError` passes on as it is.
    package func emission(for row: ExecutorPlanSampleRow) throws -> ExecutorPlanEmission {
        let split = row.split()
        let plan: ExecutionPlan
        do {
            plan = try template.fill(split.fill)
        } catch let refusal as PlanFillRefusal {
            throw ExecutorPlanError(field: refusal.field, reason: refusal.reason)
        }
        var all = sources
        for (slot, source) in zip(template.inputs, split.inputSources) {
            all[slot.relativePath] = source
        }
        return ExecutorPlanEmission(plan: plan, sources: all)
    }
}

/// The values of a sample row that the submit file and the DAG read and no plan holds (OQ-9 A).
package struct ExecutorPlanSubmitValues: Sendable, Equatable {
    package var sampleName: String
    /// The job's `request_disk` in whole GiB, or nil when the row gives none.
    package var requestDiskGiB: Int?

    package init(sampleName: String, requestDiskGiB: Int?) {
        self.sampleName = sampleName
        self.requestDiskGiB = requestDiskGiB
    }
}

/// A row cut in three: what the plan takes, where its inputs are on this machine, and what only the submit side reads.
package struct ExecutorPlanSampleSplit: Sendable, Equatable {
    package let fill: PlanSampleFill
    /// R1 then R2, or the one file. The folder writer copies them or the submit file names them; no plan holds them.
    package let inputSources: [URL]
    package let submit: ExecutorPlanSubmitValues
}

/// One sample as a sample sheet row gives it (V5): its name, each input's file with its SHA-256 and size, each file's
/// original name, its labels, and the values only the submit side reads. `split()` is the one route from a row to a
/// plan, and `PlanSampleFill` has no field for a submit value, so `request_disk` never reaches `plan.json`, an argv or a
/// child's environment (OQ-9 A, ARCH-fill F2).
package struct ExecutorPlanSampleRow: Sendable, Equatable {
    package var sampleName: String
    /// R1 then R2, or the one file, with the SHA-256 and size each entry pins.
    package var inputs: [ExecutorPlanSourceFile]
    package var originalFilenames: [String]
    package var sampleSheet: [PlanKeyValue]
    /// The job's `request_disk` in whole GiB, a submit value.
    package var requestDiskGiB: Int?

    /// With `originalFilenames` nil, each input is named by its file's last path component.
    package init(
        sampleName: String, inputs: [ExecutorPlanSourceFile], originalFilenames: [String]? = nil,
        sampleSheet: [PlanKeyValue] = [], requestDiskGiB: Int? = nil
    ) {
        self.sampleName = sampleName
        self.inputs = inputs
        self.originalFilenames = originalFilenames ?? inputs.map(\.url.lastPathComponent)
        self.sampleSheet = sampleSheet
        self.requestDiskGiB = requestDiskGiB
    }

    package func split() -> ExecutorPlanSampleSplit {
        ExecutorPlanSampleSplit(
            fill: PlanSampleFill(
                sampleName: sampleName, originalFilenames: originalFilenames, sampleSheet: sampleSheet,
                inputs: inputs.map { PlanInputFile(sha256: $0.sha256, size: $0.size) }
            ),
            inputSources: inputs.map(\.url),
            submit: ExecutorPlanSubmitValues(sampleName: sampleName, requestDiskGiB: requestDiskGiB)
        )
    }
}

extension ExecutorPlanRequest {
    /// The request's per-recipe half: its input shape, its platform and every value but the sample's.
    package var templateRequest: ExecutorPlanTemplateRequest {
        ExecutorPlanTemplateRequest(
            inputFormat: inputFormat, inputSuffixes: inputs.map { PlanTemplate.fastqSuffix(of: $0.url.lastPathComponent) },
            platform: sample.platform, recipe: recipe, recipeFile: recipeFile, storage: storage, executorFile: executorFile,
            executorBuild: executorBuild, imageManifest: imageManifest, imageTools: imageTools, deadlines: deadlines,
            databases: databases
        )
    }

    /// The request's sample as a row. A plan states the sum of its input sizes as the sample's original size, so a
    /// request that states another size is refused rather than written with a size it did not give.
    package func sampleRow() throws -> ExecutorPlanSampleRow {
        let total = inputs.reduce(Int64(0)) { $0 &+ $1.size }
        guard sample.originalSizeBytes == total else {
            throw ExecutorPlanError(
                field: "sample.originalSizeBytes",
                reason: "The request's sample states \(sample.originalSizeBytes) bytes, and its input files hold \(total). A plan states the sum of its input sizes as the sample's original size."
            )
        }
        return ExecutorPlanSampleRow(
            sampleName: sample.sampleName, inputs: inputs, originalFilenames: sample.originalFilenames,
            sampleSheet: sample.sampleSheet
        )
    }
}
