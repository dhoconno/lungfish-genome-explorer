// ExecutorRunAdoption+SchemaTwo.swift - The adopt's checks of a run of a schema 2 plan that makes counts, and the refusal
// of a plan that the other adopt reads (Phase 5.3 lane EX-ADOPT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

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
    /// The commands a refusal names for a plan that another command adopts.
    static let readsAdoptCommand = "lungfish-cli import fastq <folder> --adopt"
    static let countsAdoptCommand = "lungfish-cli import rnaseq <folder> --adopt"
    static let indexAdoptCommand = "lungfish-cli rnaseq index-adopt"

    /// The checks of a run of a schema 2 plan that makes counts, in order: the checks every run takes, the plan's kind,
    /// one succeeded step for each planned step in the plan's order, each output as the plan names it, and each setting
    /// in the argv of the step it changes. The step check is the FASTQ adopt's own, whose storage and Q20 rows name kinds
    /// that no schema 2 plan holds. It reads no `staged` or `stays` file and writes nothing.
    static func checkCounts(
        _ folder: URL, policy: ExecutorAdoptPolicy
    ) throws(ExecutorAdoptRefusal) -> ExecutorAdoptedCountsRun {
        let checked = try checkShared(folder, policy: policy)
        let (plan, record) = (checked.plan, checked.record)
        let (pipeline, route) = try countsIdentity(of: plan)
        try checkSteps(record, plan: plan)
        let homeOutputs = try checkOutputs(record, plan: plan, resolver: checked.resolver)
        try checkSettingsInArgv(record, plan: plan, route: route)
        return ExecutorAdoptedCountsRun(
            folder: URL(fileURLWithPath: checked.resolver.workRoot, isDirectory: true), plan: plan, pipeline: pipeline,
            route: route, record: record, homeOutputs: homeOutputs, stagingImage: checked.stagingImage
        )
    }

    /// The pipeline and route of a plan that makes counts. A schema 1 plan is refused in words that name the FASTQ adopt,
    /// and a schema 2 plan with no route, such as an index build, in words that name `rnaseq index-adopt`.
    static func countsIdentity(of plan: ExecutionPlan) throws(ExecutorAdoptRefusal) -> (PlanPipeline, PlanPipelineRoute) {
        guard let pipeline = plan.pipeline else {
            throw refusal(
                "schemaVersion",
                "This plan has schema version \(plan.schemaVersion) and imports reads. Adopt it with \(readsAdoptCommand), "
                    + "since import rnaseq --adopt adopts the counts of a schema 2 plan only."
            )
        }
        guard let route = pipeline.route else { throw makesNoCounts(pipeline) }
        return (pipeline, route)
    }

    /// The FASTQ adopt's plan holds no `pipeline`, so a schema 2 plan is refused in words that name the command that
    /// adopts it, before any check of steps or payload.
    static func checkReadsPlan(_ plan: ExecutionPlan) throws(ExecutorAdoptRefusal) {
        guard let pipeline = plan.pipeline else { return }
        guard let route = pipeline.route else { throw makesNoCounts(pipeline) }
        throw refusal(
            "schemaVersion",
            "This plan has schema version \(plan.schemaVersion) and makes counts with \(route.tool) \(route.toolVersion). "
                + "Adopt it with \(countsAdoptCommand), since import fastq --adopt adopts the reads of a schema 1 plan only."
        )
    }

    /// The decoder pairs `route` with `modality`, so a plan with no route makes no counts.
    private static func makesNoCounts(_ pipeline: PlanPipeline) -> ExecutorAdoptRefusal {
        refusal(
            "pipeline.route",
            "This plan's pipeline \(pipeline.id) makes no counts, as an index build does. Record what it built with \(indexAdoptCommand)."
        )
    }

    /// Each output of each step as the plan names it: the record names it with the plan's policy, and a `home` output is
    /// in the folder at its plan path with the record's size and SHA-256, by the resolver's path and link rules as the
    /// payload check reads the payload. A `staged` or `stays` output is never read. The record names no output the plan
    /// does not. `checkSteps` has matched the record's steps to the plan's, one for one.
    static func checkOutputs(
        _ record: ExecutorRunRecord, plan: ExecutionPlan, resolver: PlanResourceResolver
    ) throws(ExecutorAdoptRefusal) -> [ExecutorAdoptedOutput] {
        var home: [ExecutorAdoptedOutput] = []
        for (index, (planned, step)) in zip(plan.steps, record.steps).enumerated() {
            let policies = planned.outputPolicy ?? [:]
            for path in planned.outputs {
                guard let policy = policies[path] else { continue }
                guard let position = step.outputs.firstIndex(where: { $0.path == path }) else {
                    throw refusal(
                        "steps[\(index)].outputs",
                        "The run record names no output \(path) for the step \(planned.id), which the plan's step writes with policy \(policy.rawValue)."
                    )
                }
                let output = step.outputs[position]
                let field = "steps[\(index)].outputs[\(position)]"
                guard output.policy == policy else {
                    throw refusal(
                        field,
                        "The run record states the output \(path) of the step \(planned.id) with policy \(output.policy?.rawValue ?? "none"), "
                            + "and the plan gives \(policy.rawValue)."
                    )
                }
                guard policy == .home else { continue }
                guard let size = Int64(exactly: output.bytes) else {
                    throw refusal(field, "The run record states \(output.bytes) bytes for the output \(path) of the step \(planned.id).")
                }
                let url: URL
                do {
                    url = try resolver.verify(PlanEntry(role: .input, relativePath: path, sha256: output.sha256, size: size))
                } catch let error as PlanResourceRefusal {
                    throw refusal(field, outputSentence(error, path: path, step: planned.id))
                } catch {
                    throw refusal(field, "The output \(path) of the step \(planned.id) cannot be read. \(error.localizedDescription)")
                }
                home.append(ExecutorAdoptedOutput(
                    stepIndex: index, stepID: planned.id, path: path, sha256: output.sha256, size: size, url: url
                ))
            }
            let named = Set(planned.outputs)
            if let position = step.outputs.firstIndex(where: { !named.contains($0.path) }) {
                throw refusal(
                    "steps[\(index)].outputs[\(position)]",
                    "The run record names the output \(step.outputs[position].path) for the step \(planned.id), which the plan's step does not write."
                )
            }
        }
        return home
    }

    private static func outputSentence(_ error: PlanResourceRefusal, path: String, step: String) -> String {
        switch error {
        case .digestMismatch(_, let expected, let actual):
            return "The output \(path) of the step \(step) has SHA-256 \(actual), and the run record states \(expected). "
                + "The copy may be damaged, so copy the result folder again from the machine that ran the plan."
        case .sizeMismatch(_, let expected, let actual):
            return "The output \(path) of the step \(step) holds \(actual) bytes, and the run record states \(expected). "
                + "The copy may be incomplete, so copy the result folder again from the machine that ran the plan."
        case .missing:
            return "The output \(path) of the step \(step) is missing from the folder, and the plan returns it home. "
                + "Copy the result folder again from the machine that ran the plan, and check that the job finished."
        default:
            return "The output \(path) of the step \(step) cannot be adopted. \(error.reason)"
        }
    }
}
