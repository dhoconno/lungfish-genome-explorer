// SalmonPlan+Inputs.swift - The reads frame of a plan on one sample's reads, its inputs and trim steps, which each
// chain of Phase 5.3 builds on (lane EX-PLAN-SALMON, FIX-SALMON-1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension SalmonPlan {
    /// One Trim Galore call with the Mac's argv, `<poly-G flag> [--paired] -o <folder> <files>`, and no adapter flag, so
    /// Trim Galore chooses from read 1 (BIO-PLAN-ADAPTER item 1). Its JSON reports and its standard error, which holds
    /// the line "Using <name> adapter for trimming (count: N). Second best hit was <name> (count: M).", come home
    /// (item 2), and the trimmed reads stay.
    static func trimStep(
        _ id: String, files: [String], paired: Bool, polyG: Bool, tool: PlanToolPin, deadline: Double
    ) -> PlanStep {
        let trimmed = files.enumerated().map { m, file in
            "\(id)/" + SalmonQuantRoute.trimmedName(URL(fileURLWithPath: file), mate: paired ? m + 1 : nil)
        }
        let reports = files.map { "\(id)/\(($0 as NSString).lastPathComponent)_trimming_report.json" }
        let console = consolePath(of: id)
        var policy = Dictionary(uniqueKeysWithValues: trimmed.map { ($0, PlanOutputPolicy.stays) })
        for path in reports + [console] { policy[path] = .home }
        return PlanStep(
            id: id, title: "Trim \(paired ? "the pair" : "the single reads") with Trim Galore \(tool.version)", kind: .tool,
            tool: tool, arguments: [polyG ? "--poly_g" : "--no_poly_g"] + (paired ? ["--paired"] : []) + ["-o", id] + files,
            deadlineSeconds: deadline, inputs: files, outputs: trimmed + reports + [console], outputPolicy: policy)
    }

    /// The file the executor writes a step's standard error to (`PlanRunner.runStep`). Trim Galore 2.3.0 writes its
    /// adapter detection line there and nothing to standard output (one run of the image's trim_galore, EX-PLAN-SALMON).
    static func consolePath(of stepID: String) -> String { "logs/\(stepID).stderr" }
}
