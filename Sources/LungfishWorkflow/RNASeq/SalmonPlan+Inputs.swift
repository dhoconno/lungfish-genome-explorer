// SalmonPlan+Inputs.swift - The reads frame of a plan on one sample's reads, its inputs and trim steps, which each
// chain of Phase 5.3 builds on (lane EX-PLAN-SALMON, FIX-SALMON-1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// One sample's reads as a chain's plan names them: each read an input entry, its Mac file when it has one, the trim
/// steps (none with no trimming), and the paths the chain's counting step reads. EX-PLAN-STAR, EX-UMI and SOLO-PLAN add
/// their steps after these, so every chain of one shape names the same `inputs/` and `home` paths, which the samples of
/// one `sample.sub` share (`ExecutorPlanBatchWriter`) and the adopt reads.
package struct SalmonPlanReadsFrame: Sendable, Equatable {
    package var inputs: [PlanEntry]
    /// Each input's `relativePath` to the Mac file the batch copies there. A staged read has none.
    package var sources: [String: URL]
    package var trimSteps: [PlanStep]
    /// Read 1 and read 2 of each pair, trimmed when the frame trims, in pair order.
    package var r1s: [String]
    package var r2s: [String]
    /// The single reads, trimmed when the frame trims.
    package var singles: [String]

    package init(inputs: [PlanEntry], sources: [String: URL], trimSteps: [PlanStep], r1s: [String], r2s: [String], singles: [String]) {
        self.inputs = inputs
        self.sources = sources
        self.trimSteps = trimSteps
        self.r1s = r1s
        self.r2s = r2s
        self.singles = singles
    }
}

extension SalmonPlan {
    /// The frame of one sample: each pair at `inputs/pair<n>_R1<suffix>` and `inputs/pair<n>_R2<suffix>`, each single
    /// read at `inputs/single<n><suffix>`, and with Trim Galore one ``trimStep(_:files:paired:polyG:tool:deadline:)`` a
    /// pair, `trim-pair<n>`, and one for the single reads, `trim-singles`.
    package static func readsFrame(
        sample: SalmonPlanSample, trim: SalmonQuantTrim, trimTool: PlanToolPin, deadline: Double
    ) -> SalmonPlanReadsFrame {
        var sources: [String: URL] = [:]
        var inputs: [PlanEntry] = []
        func input(_ read: SalmonPlanRead, _ path: String) -> String {
            inputs.append(PlanEntry(role: .input, relativePath: path, sha256: read.sha256, size: read.size))
            if let source = read.source { sources[path] = source }
            return path
        }
        func suffix(_ read: SalmonPlanRead) -> String { PlanTemplate.fastqSuffix(of: read.name) }
        var calls: [(id: String, files: [String], paired: Bool)] = []
        for (n, pair) in sample.pairs.enumerated() {
            let r1 = input(pair.r1, "inputs/pair\(n + 1)_R1\(suffix(pair.r1))")
            let r2 = input(pair.r2, "inputs/pair\(n + 1)_R2\(suffix(pair.r2))")
            calls.append(("trim-pair\(n + 1)", [r1, r2], true))
        }
        let singles = sample.singles.enumerated().map { n, read in input(read, "inputs/single\(n + 1)\(suffix(read))") }
        if !singles.isEmpty { calls.append(("trim-singles", singles, false)) }

        var steps: [PlanStep] = []
        var r1s = calls.filter { $0.paired }.map { $0.files[0] }, r2s = calls.filter { $0.paired }.map { $0.files[1] }
        var counted = singles
        if case .trimGalore(let polyG) = trim {
            steps = calls.map { trimStep($0.id, files: $0.files, paired: $0.paired, polyG: polyG, tool: trimTool, deadline: deadline) }
            func trimmed(_ step: PlanStep) -> [String] { step.outputs.filter { step.outputPolicy?[$0] == .stays } }
            r1s = steps.filter { $0.id != "trim-singles" }.map { trimmed($0)[0] }
            r2s = steps.filter { $0.id != "trim-singles" }.map { trimmed($0)[1] }
            counted = steps.first { $0.id == "trim-singles" }.map(trimmed) ?? []
        }
        return SalmonPlanReadsFrame(inputs: inputs, sources: sources, trimSteps: steps, r1s: r1s, r2s: r2s, singles: counted)
    }

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
