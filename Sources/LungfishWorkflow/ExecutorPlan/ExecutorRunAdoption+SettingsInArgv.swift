// ExecutorRunAdoption+SettingsInArgv.swift - The adopt's check that each setting of a schema 2 plan shows in the argv of
// the step it changes (Phase 5.3 lane EX-ADOPT, docs/formats/executor-plan.md, The pipeline)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ExecutorRunAdoption {
    /// The trimmer whose poly-G flag `trimming` names, by its id in the image's tool manifest.
    static let trimmerToolID = "trim_galore"
    static let polyGOnFlag = "--poly_g"
    static let polyGOffFlag = "--no_poly_g"
    static let polyGOffLine = "Poly-G trimming: off"
    static let polyGOnLine = "Poly-G trimming: on"
    static let errorModelFlag = "--errorModel"
    static let salmonToolID = "salmon"
    /// The salmon report that states the library type salmon detected, which the Mac route records as
    /// `detectedLibraryType`.
    static let libraryFormatReport = "lib_format_counts.json"

    /// Each setting of `route.settings` that a step's argv carries shows in the recorded argv of that step, so the argv
    /// and the identity never disagree, and a salmon result returns its library type report. Each refusal names the step.
    /// A counting step runs the pin the route names and returns a `home` output, as the decoder's own rule reads it.
    static func checkSettingsInArgv(
        _ record: ExecutorRunRecord, plan: ExecutionPlan, route: PlanPipelineRoute
    ) throws(ExecutorAdoptRefusal) {
        try checkTrimming(record, plan: plan, trimming: route.settings["trimming"] ?? "")
        let counting = plan.steps.indices.filter { index in
            let step = plan.steps[index]
            return step.tool?.id == route.tool && step.tool?.version == route.toolVersion
                && step.outputPolicy?.values.contains(.home) == true
        }
        try checkAlignmentScoring(record, plan: plan, counting: counting, route: route)
        if route.tool == salmonToolID {
            try checkLibraryFormatReport(plan, counting: counting)
        }
    }

    /// `--no_poly_g` in every trimmer step for poly-G trimming off, `--poly_g` for on, and no trimmer step for reads not
    /// trimmed. A trimmer step runs Trim Galore by the plan's pin or the record's tool.
    private static func checkTrimming(
        _ record: ExecutorRunRecord, plan: ExecutionPlan, trimming: String
    ) throws(ExecutorAdoptRefusal) {
        let trimmers = plan.steps.indices.filter {
            plan.steps[$0].tool?.id == trimmerToolID || record.steps[$0].tool?.id == trimmerToolID
        }
        let wanted: String
        if trimming == SalmonQuantRecordLines.notTrimmed {
            guard let index = trimmers.first else { return }
            throw refusal(
                "steps[\(index)].argv", "The step \(plan.steps[index].id) runs Trim Galore, and the plan states trimming as \(trimming)."
            )
        } else if trimming.hasPrefix(polyGOffLine) {
            wanted = polyGOffFlag
        } else if trimming.hasPrefix(polyGOnLine) {
            wanted = polyGOnFlag
        } else {
            throw refusal(
                "pipeline.route.settings",
                "The plan states trimming as \(trimming), which is none of the values the adopt reads. A plan states "
                    + "\(SalmonQuantRecordLines.notTrimmed) or a poly-G line that reads off or on."
            )
        }
        guard !trimmers.isEmpty else {
            throw refusal("pipeline.route.settings", "The plan states trimming as \(trimming), and no step runs Trim Galore.")
        }
        let other = wanted == polyGOnFlag ? polyGOffFlag : polyGOnFlag
        for index in trimmers {
            let argv = record.steps[index].argv
            let id = plan.steps[index].id
            if argv.contains(other) {
                throw refusal("steps[\(index)].argv", "The step \(id) ran Trim Galore with \(other), and the plan states trimming as \(trimming).")
            }
            if !argv.contains(wanted) {
                throw refusal(
                    "steps[\(index)].argv",
                    "The step \(id) ran Trim Galore without \(wanted), and the plan states trimming as \(trimming). "
                        + "Every trimmer call passes the poly-G setting."
                )
            }
        }
    }

    /// `--errorModel` in a counting step's argv only for `alignmentScoring` `errorModel`, and in each counting step then.
    private static func checkAlignmentScoring(
        _ record: ExecutorRunRecord, plan: ExecutionPlan, counting: [Int], route: PlanPipelineRoute
    ) throws(ExecutorAdoptRefusal) {
        let scoring = route.settings["alignmentScoring"]
        let wanted = scoring == "errorModel"
        let stated = scoring.map { "the plan states alignmentScoring as \($0)" } ?? "the plan states no alignmentScoring"
        for index in counting {
            let holds = record.steps[index].argv.contains(errorModelFlag)
            guard holds != wanted else { continue }
            throw refusal(
                "steps[\(index)].argv",
                "The step \(plan.steps[index].id) ran \(route.tool) \(holds ? "with" : "without") \(errorModelFlag), and \(stated)."
            )
        }
    }

    /// A salmon counting step returns `lib_format_counts.json` as a `home` output, so the result states the library type
    /// salmon detected, as the Mac route's `detectedLibraryType` does (FIX-EX-SCHEMA-BIO backlog 3).
    private static func checkLibraryFormatReport(_ plan: ExecutionPlan, counting: [Int]) throws(ExecutorAdoptRefusal) {
        for index in counting {
            let step = plan.steps[index]
            let returns = step.outputs.contains { path in
                step.outputPolicy?[path] == .home && path.split(separator: "/").last.map(String.init) == libraryFormatReport
            }
            guard !returns else { continue }
            throw refusal(
                "steps[\(index)].outputPolicy",
                "The step \(step.id) runs salmon and returns no \(libraryFormatReport), so the result could not state "
                    + "detectedLibraryType, the library type salmon detected."
            )
        }
    }
}
