// ExecutorRunAdoption+RNASeqRecord.swift - The record of a counts adopt: the command, each salmon file it read, the
// count tables, and each step the run record states with its tool, argv and the record lines (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ExecutorRunAdoption {
    /// The result's root record, handed to the writer. Each sample's steps come from its run record with their tool,
    /// version and argv as run, the trim steps carry the poly-G line of `pipeline.settings`, and the counting step
    /// carries the sample's lines: the poly-G line, the instrument of `sample.instrument`, the duplicates line and the
    /// adapter line when the plan states one.
    static func countsEnvelope(
        _ adoption: ExecutorCountsAdoption, argv: [String], resultFolder: URL, projectDirectory: URL, result: URL, started: Date
    ) throws -> ProvenanceEnvelope {
        let first = adoption.samples[0].run
        let explicit: [String: ParameterValue] = [
            "folder": .file(resultFolder.standardizedFileURL), "project": .file(projectDirectory.standardizedFileURL),
            "name": .string(adoption.request.name),
        ]
        let steps = adoption.samples.flatMap(countsSteps)
        var resolved: [String: ParameterValue] = [
            "set": .string(first.pipeline.referenceSet.id),
            "plans": .array(adoption.samples.compactMap { $0.run.record.plan.map { .string($0.sha256) } }),
        ]
        // One sentence when the samples got different adapters, as `rnaseq quant` writes it (BIO-PLAN-ADAPTER item 8).
        if let sentence = TrimGaloreAdapterReport.differentAdapters(in: steps) { resolved["adapters"] = .string(sentence) }
        var builder = ProvenanceRunBuilder(
            workflowName: "RNA-seq adopt", workflowVersion: WorkflowRun.currentAppVersion, toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion)
            .argv(argv)
            .reproducibleCommand(argv.map(SalmonQuantRoute.shellQuoted).joined(separator: " "))
            .options(explicit: explicit, defaults: [:], resolved: resolved)
            .runtime(runtimeIdentity(record: first.record, stagingImage: first.stagingImage))
        for sample in adoption.samples {
            for output in sample.run.homeOutputs where sample.run.countingSteps.contains(output.stepIndex) {
                builder = try builder.input(output.url)
            }
        }
        for count in adoption.request.counts {
            let data = try count.table.tsvData()
            let name = count.rows == .gene ? "genes.counts.tsv" : "transcripts.counts.tsv"
            builder = try builder.recordedOutputSnapshot(ProvenanceFileDescriptor(
                path: result.appendingPathComponent("counts/\(name)").path, checksumSHA256: RNASeqResultBundle.sha256Hex(data),
                fileSize: UInt64(data.count), role: .output))
        }
        for step in steps { builder = builder.step(step) }
        return try builder.complete(exitStatus: 0, status: .completed, startedAt: started, endedAt: Date())
    }

    /// One sample's steps as its run record states them. A trim step carries the poly-G line and its adapter lines.
    static func countsSteps(_ sample: ExecutorCountsAdoptedSample) -> [ProvenanceStep] {
        let run = sample.run
        let lines = countsRecordLines(run, sample: sample.folder.sample)
        return run.record.steps.enumerated().map { index, step in
            var options: [String: ParameterValue] = ["sample": .string(sample.folder.sample)]
            if run.countingSteps.contains(index) {
                options = lines
            } else if step.tool?.id == trimmerToolID {
                if let trimming = lines["trimming"] { options["polyG"] = trimming }
                if let adapter = sample.adapters[index] { options.merge(adapter.lines) { _, read in read } }
            }
            return ProvenanceStep(
                toolName: step.tool?.id ?? step.kind.rawValue, toolVersion: step.tool?.version ?? "unknown", argv: step.argv,
                resolvedOptions: options, exitStatus: Int(step.toolExitCode ?? 0), wallTimeSeconds: step.wallSeconds,
                startedAt: date(step.startedAt), completedAt: date(step.endedAt),
                managedToolID: step.tool.map { ManagedToolID(rawValue: $0.id) })
        }
    }

    /// Each trim call's adapter by step index, from the JSON reports and the console file the step returned, which the
    /// output check has read against the record (ruling BIO-PLAN-ADAPTER item 4). A trim step that returns no JSON
    /// report or no console file, or whose reports are not Trim Galore reports, is refused in words that name the step,
    /// since the record could not state the adapter it trimmed.
    static func trimAdapters(_ run: ExecutorAdoptedCountsRun) throws -> [Int: TrimGaloreAdapterReport] {
        var adapters: [Int: TrimGaloreAdapterReport] = [:]
        for (index, step) in run.plan.steps.enumerated() where step.tool?.id == trimmerToolID {
            let outputs = run.homeOutputs.filter { $0.stepIndex == index }
            let reports = outputs.filter { $0.path.hasSuffix("_trimming_report.json") }
            let consolePath = SalmonPlan.consolePath(of: step.id)
            guard let first = reports.first, let console = outputs.first(where: { $0.path == consolePath }) else {
                throw refusal(
                    "steps[\(index)].outputPolicy",
                    "The step \(step.id) returns no JSON trimming report or no \(consolePath) as home, so the record cannot "
                        + "state the adapter Trim Galore trimmed."
                )
            }
            let adapter = TrimGaloreAdapterReport.read(
                reports: try reports.map { try Data(contentsOf: $0.url) },
                console: String(decoding: try Data(contentsOf: console.url), as: UTF8.self))
            guard adapter.adapters != nil else {
                throw refusal(
                    "steps[\(index)].outputs",
                    "The report \(first.path) of the step \(step.id) is not a Trim Galore JSON report, so the record cannot "
                        + "state the adapter Trim Galore trimmed."
                )
            }
            adapters[index] = adapter
        }
        return adapters
    }

    /// What the adopted record says of the import's poly-G tails. A plan pins its reads by digest and names no import record,
    /// so the adopt cannot know, and it says so in the words of a plan, as the Mac's line says it for a bundle with no record
    /// (`SalmonQuantRecordLines.importNotRecorded`, review EX-ADOPT-M2M3-BIO should-fix 2).
    static let importPolyGNotInPlan = "Poly-G trimming at import: Not recorded (the plan names no import record that names its tools)"

    /// The counting step's lines, under the keys of the Mac route's `recordLines`.
    static func countsRecordLines(_ run: ExecutorAdoptedCountsRun, sample: String) -> [String: ParameterValue] {
        let settings = Dictionary(run.pipeline.settings.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        func value(_ id: String) -> String { settings[id] ?? run.route.settings[id] ?? RNASeqImportFacts.notRecorded }
        var lines: [String: ParameterValue] = [
            "sample": .string(sample), "trimming": .string(value("trimming")), "importPolyG": .string(importPolyGNotInPlan),
            "instrument": .string(instrumentLine(run.plan.sample.instrument)), "duplicates": .string(value("duplicates")),
        ]
        if let adapter = settings["adapter"] ?? run.route.settings["adapter"] { lines["adapter"] = .string(adapter) }
        return lines
    }

    /// The instrument line of the Mac record (`SalmonQuantRecordLines.instrument`) from the plan's `sample.instrument`.
    static func instrumentLine(_ instrument: PlanSampleInstrument?) -> String {
        guard let instrument else { return "Instrument: Not recorded" }
        return "Instrument: \(instrument.model)" + (instrument.inferred ? ", inferred from read names" : "")
    }
}
