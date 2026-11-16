// UMIPlan+Make.swift - One sample's plan of the UMI branch: the reads frame and each pair's layout check (Phase 5.3
// lane EX-UMI, milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// What a UMI plan takes beside the set and the reads: the executor, the image's tool manifest pin and the decompressor
/// the check reads gzip through. Milestone 2 adds the pins of the chain's tools.
package struct UMIPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var pigz: PlanToolPin

    package init(executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin, pigz: PlanToolPin) {
        self.executor = executor
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.pigz = pigz
    }
}

package struct UMIPlanRequest: Sendable {
    package var setFolder: URL
    package var sample: SalmonPlanSample
    /// The sample sheet's kit column.
    package var kit: String
    package var pins: UMIPlanPins
    package var deadlineSeconds: Double?

    package init(setFolder: URL, sample: SalmonPlanSample, kit: String, pins: UMIPlanPins, deadlineSeconds: Double? = nil) {
        self.setFolder = setFolder
        self.sample = sample
        self.kit = kit
        self.pins = pins
        self.deadlineSeconds = deadlineSeconds
    }
}

package struct UMIPlanOutcome: ReadsPlanOutcome {
    package var plan: ExecutionPlan
    package var sample: SalmonPlanSample
    package var preset: UMIKitPreset
    package var sources: [String: URL]
}

extension UMIPlan {
    /// The plan of one sample whose sheet names a UMI kit: the reads frame untrimmed, then one layout check a pair, the
    /// first steps of the branch. The chain after the check, its route and its `duplicates` words come in milestone 2,
    /// so this plan states no route and makes no counts yet.
    package static func make(_ request: UMIPlanRequest) throws -> UMIPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let (sample, pins) = (request.sample, request.pins)
        let preset = try preset(kit: request.kit)
        guard !sample.pairs.isEmpty, sample.singles.isEmpty else {
            throw SalmonPlanError("The sample \(sample.name) needs read pairs, since the \(preset.id) kit holds its UMI on "
                + "Read \(preset.umiRead) and its transcript on Read \(preset.keptRead), so no plan was written.")
        }
        if let staged = sample.stagedPaths, staged.count != sample.reads.count {
            throw SalmonPlanError("The sample \(sample.name) names \(staged.count) reads in the staging folder for its \(sample.reads.count) read files.")
        }
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        let frame = SalmonPlan.readsFrame(sample: sample, trim: .none, trimTool: pins.pigz, deadline: deadline)
        var sources = frame.sources
        sources[ExecutorPlanEmitter.executorPath] = pins.executor.url
        let steps = zip(frame.r1s, frame.r2s).enumerated().map { n, files in
            checkStep(preset, pair: n + 1, r1: files.0, r2: files.1, decompressor: pins.pigz, executor: pins.executorBuild,
                      deadline: deadline)
        }
        var settings = settings(preset)
        settings.append(PlanPipelineSetting(id: "trimming", label: "Trimming", value: "Reads not trimmed", source: .default))
        settings.sort { $0.id < $1.id }
        let used = [executorPin(pins.executorBuild), pins.pigz]
        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + frame.inputs,
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: PlanPipeline(
                id: pipelineID, version: pipelineVersion, preset: PlanPipelinePreset(id: preset.id, name: preset.label),
                modality: nil, route: nil,
                referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
                settings: settings),
            sample: PlanSampleValues(
                sampleName: sample.name, originalFilenames: sample.reads.map(\.name),
                originalSizeBytes: sample.reads.reduce(Int64(0)) { $0 + $1.size }, instrument: sample.instrument),
            storage: nil, clumping: nil, graceSeconds: 60, steps: steps)
        _ = try ExecutionPlan.decode(try plan.encoded())
        return UMIPlanOutcome(plan: plan, sample: sample, preset: preset, sources: sources)
    }
}
