// ExecutorRunAdoption+STARCounts.swift - The payload of the STAR chains in the counts adopt: STAR GeneCounts'
// ReadsPerGene.out.tab or featureCounts' table, read into one result (Phase 5.3 lane EX-ADOPT M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// One sample of a STAR chain's adopt: the count kept, by gene, the files its reader read, and the record's lines.
struct ExecutorSTARCountsSample: Sendable {
    /// The `home` outputs the reader read, which the result keeps under `source/<sample>/` at their plan paths.
    let kept: [ExecutorAdoptedOutput]
    /// The count kept by gene id: column 2 of `ReadsPerGene.out.tab`, or featureCounts' count column.
    let counts: [String: Int]
    /// Whether the plan maps read pairs, which makes the unit `pairs`, or single reads, which makes it `reads`.
    let paired: Bool
    /// The counting step's lines in the record: the totals, the strand share and each `home` file left out.
    let lines: [String: ParameterValue]
    /// The warning the import prints and the record keeps when the reads do not look unstranded.
    let warning: String?
}

extension ExecutorRunAdoption {
    static let starToolID = "STAR"
    static let featureCountsToolID = "featureCounts"
    static let starMultimapFlag = "--outFilterMultimapNmax"
    /// The band of strand share an unstranded library reads in, GT's band for salmon's strand bias (ruling
    /// BIO-ADOPT-M5-Q1 item 6).
    static let unstrandedBand = 0.4...0.6

    /// The counting step of each STAR chain by the route's tool: STAR GeneCounts or featureCounts.
    static let starCountingStepIDs = [starToolID: STARPlan.starStepID, featureCountsToolID: STARPlan.featureCountsStepID]

    static func isSTARRoute(_ route: PlanPipelineRoute) -> Bool { starCountingStepIDs[route.tool] != nil }

    /// The words of `geneCountsColumn`: the column kept and the two left out (ruling BIO-ADOPT-M5-Q1 item 3).
    static func geneCountsColumnWords(paired: Bool, sample: String = "<sample>") -> String {
        let unit = paired ? "a pair" : "a read"
        let (third, fourth) = paired ? ("read 1 on the gene's strand", "read 2 on the gene's strand")
            : ("the read on the gene's strand", "the read on the other strand")
        return "Column 2 of STAR's ReadsPerGene.out.tab, unstranded: \(unit) counted for the gene whose exons it overlaps, "
            + "on either strand. Columns 3 (\(third)) and 4 (\(fourth)) are not counts of this result and stay in "
            + "source/\(sample)/\(STARPlan.starReports[1])."
    }

    /// The plan's `countingGTF` names the set's `derived/genes.gtf` by the SHA-256 of the set under the storage root, or
    /// the run is refused in words that name its counting step, before any table is read.
    static func checkCountingGTF(_ run: ExecutorAdoptedCountsRun, set: ReferenceSetOutcome) throws {
        let gtf = try set.manifest.requireCountingGTF()
        let stated = run.route.settings["countingGTF"] ?? ""
        let step = run.countingSteps.first.map { run.plan.steps[$0].id } ?? run.route.tool
        let planned = stated.range(of: "SHA-256 ").map { String(stated[$0.upperBound...]) }
        guard planned != gtf.sha256 else { return }
        let named = planned.map { "a \(gtf.path) of SHA-256 \($0)" } ?? "no \(gtf.path) by SHA-256"
        throw refusal(
            "pipeline.route.settings",
            "The step \(step) of the sample \(run.plan.sample.sampleName) counted on \(named), and the set \(set.manifest.id) "
                + "on this Mac holds \(gtf.path) of SHA-256 \(gtf.sha256), so its genes are not the ones counted. Adopt the "
                + "folder with the set the plan was made on, or make the plan again on this set."
        )
    }

    /// `--outFilterMultimapNmax <n>` in each STAR step's recorded argv for a plan that chose `n`, and no such flag for
    /// STAR's default (`docs/formats/executor-plan.md`, The pipeline). Each refusal names the step.
    static func checkMultimapNmax(
        _ record: ExecutorRunRecord, plan: ExecutionPlan, route: PlanPipelineRoute
    ) throws(ExecutorAdoptRefusal) {
        let stated = route.settings["multimapNmax"] ?? ""
        let wanted: Int?
        if stated == STARPlan.multimapWords(nil) {
            wanted = nil
        } else if let loci = Int(stated.prefix { $0.isNumber }), stated == STARPlan.multimapWords(loci) {
            wanted = loci
        } else {
            throw refusal(
                "pipeline.route.settings",
                "The plan states multimapNmax as \(stated.isEmpty ? "nothing" : stated), which is none of the values the adopt "
                    + "reads. A STAR plan states \(STARPlan.multimapWords(nil)) or the loci it chose with \(starMultimapFlag)."
            )
        }
        let steps = plan.steps.indices.filter { plan.steps[$0].tool?.id == starToolID }
        guard !steps.isEmpty else {
            throw refusal("steps", "The plan counts with \(route.tool) \(route.toolVersion), and no step runs STAR.")
        }
        for index in steps {
            let argv = record.steps[index].argv
            let given = argv.firstIndex(of: starMultimapFlag).map { $0 + 1 < argv.count ? argv[$0 + 1] : "" }
            guard given != wanted.map(String.init) else { continue }
            let ran = given.map { "with \(starMultimapFlag) \($0)" } ?? "without \(starMultimapFlag)"
            throw refusal(
                "steps[\(index)].argv",
                "The step \(plan.steps[index].id) ran STAR \(ran), and the plan states multimapNmax as \(stated)."
            )
        }
    }

    /// The genes the set counts, the genes of `derived/genes.tsv` with a length above 0.
    static func starSetGenes(_ set: ReferenceSetOutcome) throws -> [String] {
        do {
            return try STARCountTableReader.countedGenes(genesTSV: set.url.appendingPathComponent(set.manifest.derived.genes.path))
        } catch let error as STARCountTableError {
            throw refusal("pipeline.referenceSet", error.message)
        }
    }

    /// Whether the plan's STAR step maps read pairs: two lists after `--readFilesIn`.
    static func mapsPairs(_ plan: ExecutionPlan) -> Bool {
        guard let arguments = plan.steps.first(where: { $0.tool?.id == starToolID })?.arguments,
              let flag = arguments.firstIndex(of: "--readFilesIn") else { return false }
        return arguments[(flag + 1)...].prefix { !$0.hasPrefix("--") }.count == 2
    }

    /// One sample's table from its counting step's `home` outputs, read where the run returned them: `star-align`'s
    /// `ReadsPerGene.out.tab` for GeneCounts, or `featurecounts`' table and `.summary`. Each is refused in words when its
    /// shape is not the tool's or its genes are not the set's (BIO-COUNTING-GTF item 5).
    static func starSample(_ run: ExecutorAdoptedCountsRun, setID: String, setGenes: [String]) throws -> ExecutorSTARCountsSample {
        let sample = run.plan.sample.sampleName
        let stepID = starCountingStepIDs[run.route.tool] ?? run.route.tool
        guard !sample.isEmpty else {
            throw refusal("sample.sampleName", "The plan of the step \(stepID) names no sample, so the result could not label its counts.")
        }
        guard run.countingSteps.count == 1, let step = run.countingSteps.first, run.plan.steps[step].id == stepID else {
            let ids = run.countingSteps.map { run.plan.steps[$0].id }
            throw refusal(
                "steps",
                "The plan of the sample \(sample) counts with \(run.route.tool) in the steps \(ids.isEmpty ? "none" : ids.joined(separator: ", ")), "
                    + "and the adopt reads the one step \(stepID) a sample."
            )
        }
        let isGeneCounts = run.route.tool == starToolID
        let outputs = run.homeOutputs.filter { $0.stepIndex == step }
        let kept = try (isGeneCounts ? [STARPlan.starReports[1]] : STARPlan.featureCountsReports).map { path in
            guard let output = outputs.first(where: { $0.path == path }) else {
                throw refusal("steps[\(step)].outputPolicy", "The step \(stepID) of the sample \(sample) returns no \(path), so the result would hold no counts.")
            }
            return output
        }
        let label = { (output: ExecutorAdoptedOutput) in "\(output.path) of the sample \(sample)" }
        let paired = mapsPairs(run.plan)
        let counts: [String: Int]
        var lines: [String: ParameterValue]
        var warning: String?
        do {
            if isGeneCounts {
                let table = try STARCountTableReader.readGeneCounts(kept[0].url, label: label(kept[0]))
                try STARCountTableReader.checkGenes(table.genes.map(\.id), label: label(kept[0]), setID: setID, setGenes: setGenes)
                counts = Dictionary(uniqueKeysWithValues: table.genes.map { ($0.id, $0.counts[0]) })
                (lines, warning) = geneCountsLines(table, sample: sample, paired: paired)
            } else {
                let table = try STARCountTableReader.readFeatureCounts(
                    table: kept[0].url, summary: kept[1].url, label: label(kept[0]), summaryLabel: label(kept[1]))
                try STARCountTableReader.checkGenes(table.genes.map(\.id), label: label(kept[0]), setID: setID, setGenes: setGenes)
                counts = Dictionary(uniqueKeysWithValues: table.genes.map { ($0.id, $0.count) })
                let rows = table.summary.filter { $0.id == "Assigned" || ($0.id.hasPrefix("Unassigned") && $0.count > 0) }
                lines = ["countsSummary": .string("featureCounts' summary: " + rows.map { "\($0.id) \($0.count)" }.joined(separator: ", "))]
            }
        } catch let error as STARCountTableError {
            throw refusal("steps[\(step)].outputs", error.message)
        }
        let keptPaths = Set(kept.map(\.path))
        let leftOut = run.homeOutputs.map(\.path).filter { !keptPaths.contains($0) }
        if !leftOut.isEmpty { lines[RNASeqImportFacts.filesLeftOutKey] = .array(leftOut.map { .string($0) }) }
        if let warning { lines["strandWarning"] = .string(warning) }
        return ExecutorSTARCountsSample(kept: kept, counts: counts, paired: paired, lines: lines, warning: warning)
    }

    /// The record's lines of one GeneCounts table: the four `N_` totals of column 2, the column kept, and the strand share
    /// with the warning when the reads do not look unstranded (ruling BIO-ADOPT-M5-Q1 items 5 and 6).
    static func geneCountsLines(
        _ table: STARGeneCounts, sample: String, paired: Bool
    ) -> (lines: [String: ParameterValue], warning: String?) {
        let totals = table.totals.map { "\($0.id) \($0.counts[0])" }.joined(separator: ", ")
        var lines: [String: ParameterValue] = ["countsSummary": .string("STAR's N_ lines in column 2, unstranded: \(totals)")]
        guard let share = table.strandShare else {
            lines["strandShare"] = .string("Strand share not measured (no \(paired ? "pair" : "read") on a gene in columns 3 and 4)")
            return (lines, nil)
        }
        let measured = String(format: "%.3f", share)
        let base = "Strand share \(measured) (column 3 over columns 3 and 4)"
        guard !unstrandedBand.contains(share) else {
            lines["strandShare"] = .string(base + ": reads unstranded")
            return (lines, nil)
        }
        let forward = share > unstrandedBand.upperBound
        let which = paired ? "read \(forward ? 1 : 2) mostly on the gene's strand"
            : "the read mostly on \(forward ? "the gene's" : "the other") strand"
        lines["strandShare"] = .string(base + ": \(which)")
        let warning = "\(sample)'s reads do not look unstranded (strand share \(measured), \(which)). The counts kept are "
            + "column 2, unstranded, as the plan's chain counts. LGE does not yet count STAR GeneCounts by strand."
        return (lines, warning)
    }

    /// The writer's request of a STAR chain: one gene table of the count kept in the set's gene order, in pairs or reads,
    /// the set's genes and not-host ids, the files each reader read in the run's layout, and the plan's route with
    /// `duplicates` in the result's form and, for GeneCounts, `geneCountsColumn`.
    static func starCountsRequest(
        name: String, samples: [ExecutorCountsAdoptedSample], set: ReferenceSetOutcome
    ) throws -> RNASeqResultWriter.Request {
        let route = samples[0].run.route
        let stars = samples.compactMap(\.starCounts)
        let genesURL = set.url.appendingPathComponent(set.manifest.derived.genes.path)
        let genes = try starSetGenes(set)
        let names = samples.map(\.name)
        let table = RNASeqCountTable(sampleIDs: names, rows: genes.map { id in
            .init(id: id, counts: stars.map { Double($0.counts[id] ?? 0) })
        })
        let paired = stars[0].paired
        var settings = route.settings
        settings["duplicates"] = SalmonQuantRecordLines.duplicatesSetting(samples.map(\.duplicates))
        if route.tool == starToolID { settings["geneCountsColumn"] = geneCountsColumnWords(paired: paired) }
        let referenceSet = samples[0].run.pipeline.referenceSet
        let sources = zip(names, stars).flatMap { sample, star in
            star.kept.map { RNASeqResultWriter.SourceFile(url: $0.url, relativePath: $0.path, sample: sample, tool: route.tool) }
        }
        return RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: .quantified, tool: route.tool, toolVersion: route.toolVersion),
            route: .init(id: route.id, tool: route.tool, toolVersion: route.toolVersion, settings: settings),
            referenceSet: .init(id: referenceSet.id, layout: referenceSet.layout == .deposit ? .deposit : .lge),
            samples: try RNASeqSampleSheet.match(nil, fileIDs: names, byRun: true).records,
            genes: .referenceSetTable(url: genesURL, keeping: genes),
            counts: [.init(rows: .gene, column: .default, unit: paired ? .pairs : .reads, table: table)],
            sourceFiles: sources, notHost: try SalmonQuantRoute.notHostIDs(genesURL))
    }
}
