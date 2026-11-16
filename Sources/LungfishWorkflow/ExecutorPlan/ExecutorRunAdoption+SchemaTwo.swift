// ExecutorRunAdoption+SchemaTwo.swift - The adopt's checks of a run of a schema 2 plan that makes counts, and the refusal
// of a plan that the other adopt reads (Phase 5.3 lane EX-ADOPT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The adopt a returned plan folder was given to, by the command that runs it.
enum ExecutorAdoptCommand: Sendable, Equatable {
    /// `lungfish-cli import fastq <folder> --adopt`, which adopts the reads of a schema 1 plan.
    case importFASTQ
    /// `lungfish-cli import rnaseq <folder> --adopt`, which adopts the counts of a schema 2 plan.
    case importRNASeq
}

/// One `home` output of a schema 2 step, as the run record states it and the resolver checked it in the folder.
struct ExecutorAdoptedOutput: Sendable, Equatable {
    let stepIndex: Int
    let stepID: String
    /// The output's plan path, relative to the folder.
    let path: String
    let sha256: String
    let size: Int64
    /// The file's real path inside the folder, as the resolver checked it.
    let url: URL
}

/// A returned folder of a schema 2 plan that makes counts, whose plan and run record passed every check of the adopt
/// before any result file exists (lane EX-ADOPT M1). The result is written from it.
struct ExecutorAdoptedCountsRun: Sendable {
    let folder: URL
    let plan: ExecutionPlan
    let pipeline: PlanPipeline
    /// The plan's `pipeline.route`, which a plan that makes counts always holds.
    let route: PlanPipelineRoute
    let record: ExecutorRunRecord
    /// Every `home` output of the plan, in the order of its steps and of each step's outputs.
    let homeOutputs: [ExecutorAdoptedOutput]
    /// The image `staging.json` names, or nil for a folder that holds none.
    let stagingImage: ExecutorAdoptStagingImage?
}

extension ExecutorRunAdoption {
    /// The checks of a run of a schema 2 plan that makes counts, with every refusal. It writes nothing.
    static func checkCounts(
        _ folder: URL, policy: ExecutorAdoptPolicy
    ) throws(ExecutorAdoptRefusal) -> ExecutorAdoptedCountsRun {
        let checked = try checkShared(folder, policy: policy)
        let (plan, record) = (checked.plan, checked.record)
        guard let pipeline = plan.pipeline, let route = pipeline.route else {
            throw refusal("pipeline", "This build does not adopt this plan.")
        }
        return ExecutorAdoptedCountsRun(
            folder: URL(fileURLWithPath: checked.resolver.workRoot, isDirectory: true), plan: plan, pipeline: pipeline,
            route: route, record: record, homeOutputs: [], stagingImage: checked.stagingImage
        )
    }
}
