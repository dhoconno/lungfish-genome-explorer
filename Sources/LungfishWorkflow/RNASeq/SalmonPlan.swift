// SalmonPlan.swift - The schema 2 plan of one sample's salmon counts on Linux (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The plan of one sample: with trimming, one Trim Galore 2.3.0 call a pair and one for the single reads, then one
/// `salmon quant` on the index `SalmonIndexCache` has published for the set, k and decoys. The argv is the Mac route's
/// (`SalmonQuantRoute+Reads.swift`) with every path relative to the work root, so a Mac result and an adopted Linux
/// result of the same reads name one route. The plan pins each file of the index and never builds one (WAVES-5.1-C Q1).
package enum SalmonPlan {
    package static let pipelineID = "salmon-quant"
    package static let pipelineVersion = 1
    package static let presetName = "Bulk counts by salmon selective alignment on the reads"
    /// salmon's `-p` when the person names no CPUs, the thread count of SPIKE-SALMON's measured quants.
    package static let defaultThreads = 8
    package static let quantFolder = "quant"
    package static let salmonStepID = "salmon-quant"
    /// The words of `duplicates` for reads whose bundle holds no import record, and for staged reads, which LGE never reads
    /// (`docs/formats/executor-plan.md`, the paragraph on `duplicates`).
    package static let duplicatesNotRecorded = "Duplicates: Not recorded (the bundle holds no import record that names its steps)"

    package static func make(_ request: SalmonPlanRequest) throws -> SalmonPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let (id, pins, sample) = (manifest.id, request.pins, request.sample)
        guard request.threads > 0 else { throw SalmonPlanError("Threads is a number from 1 up.") }
        guard sample.pairs.isEmpty != sample.singles.isEmpty else {
            let what = sample.pairs.isEmpty ? "holds no reads" : "holds read pairs and single reads, which one salmon run cannot count as one sample"
            throw SalmonPlanError("The sample \(sample.name) \(what), so no plan was written.")
        }
        if let staged = sample.stagedPaths, staged.count != sample.reads.count {
            throw SalmonPlanError("The sample \(sample.name) names \(staged.count) reads in the staging folder for its \(sample.reads.count) read files.")
        }
        let key = SalmonIndexKey(setID: id, salmonVersion: pins.salmon.version, k: request.k, decoys: request.decoys)
        let index = try indexEntries(key: key, storageRoot: request.storageRoot)
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        var sources = [ExecutorPlanEmitter.executorPath: pins.executor.url]
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
        if case .trimGalore(let polyG) = request.trim {
            steps = calls.map { trimStep($0.id, files: $0.files, paired: $0.paired, polyG: polyG, tool: pins.trimGalore, deadline: deadline) }
            func trimmed(_ step: PlanStep) -> [String] { step.outputs.filter { step.outputPolicy?[$0] == .stays } }
            r1s = steps.filter { $0.id != "trim-singles" }.map { trimmed($0)[0] }
            r2s = steps.filter { $0.id != "trim-singles" }.map { trimmed($0)[1] }
            counted = steps.first { $0.id == "trim-singles" }.map(trimmed) ?? []
        }
        let indexPath = "references/\(id)/indexes/\(key.folderName)"
        var arguments = ["quant", "-i", indexPath, "-l", "A"]
        arguments += r1s.isEmpty ? ["-r"] + counted : ["-1"] + r1s + ["-2"] + r2s
        arguments += ["-p", String(request.threads), "-o", quantFolder]
        let reports = SalmonQuantFolderReader.readFiles.map { "\(quantFolder)/\($0)" }
        steps.append(PlanStep(
            id: salmonStepID, title: "Count the reads with salmon \(pins.salmon.version) on the index \(key.folderName)",
            kind: .tool, tool: pins.salmon, arguments: arguments, deadlineSeconds: deadline,
            inputs: (r1s.isEmpty ? counted : r1s + r2s) + index.entries.map(\.relativePath), outputs: reports,
            outputPolicy: Dictionary(uniqueKeysWithValues: reports.map { ($0, PlanOutputPolicy.home) })))
        for entry in index.entries { sources[entry.relativePath] = index.sources[entry.relativePath] }

        let used = [pins.salmon] + (request.trim == .none ? [] : [pins.trimGalore])
        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + inputs + index.entries,
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: pipeline(manifest: manifest, request: request, key: key),
            sample: PlanSampleValues(
                sampleName: sample.name, originalFilenames: sample.reads.map(\.name),
                originalSizeBytes: sample.reads.reduce(Int64(0)) { $0 + $1.size }, instrument: sample.instrument),
            storage: nil, clumping: nil, graceSeconds: 60, steps: steps)
        _ = try ExecutionPlan.decode(try plan.encoded())
        return SalmonPlanOutcome(plan: plan, sample: sample, index: key, threads: request.threads, sources: sources)
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
