// ExecutorRunAdoption+UMICounts.swift - The payload of the UMI branch in the counts adopt: umi_tools' count per gene in
// umi/counts.tsv as one gene table in UMIs, the record's lines of the check and the extraction, and the refusal of a
// sample whose UMI layout check failed (Phase 5.3 lane EX-ADOPT M6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable

/// One sample of a UMI chain's adopt: umi_tools' count by gene, the file it was read from, and the record's lines.
struct ExecutorUMICountsSample: Sendable {
    /// `umi/counts.tsv`, which the result keeps under `source/<sample>/` at its plan path.
    let kept: ExecutorAdoptedOutput
    /// The UMIs umi_tools counted, by gene id. A gene of the set that the table does not list counted none.
    let counts: [String: Int]
    /// The counting step's lines in the record: the check's words, the extraction share and each `home` file left out.
    let lines: [String: ParameterValue]
}

extension ExecutorRunAdoption {
    static let umiToolsID = "umi_tools"
    /// The header `umi_tools count --per-gene` writes above its table.
    static let umiCountsHeader = ["gene", "count"]

    /// The UMI branch's route (`UMIPlan.pipeline`): umi_tools counts, under the branch's route id.
    static func isUMIRoute(_ route: PlanPipelineRoute) -> Bool {
        route.tool == umiToolsID && route.id == UMIPlan.pipelineID
    }

    /// The sample form of a UMI chain's `duplicates` (`UMIPlan.duplicatesEntry`): the UMI step's words, then what the
    /// import did before it.
    static func isUMIWords(_ words: String, route: PlanPipelineRoute) -> Bool {
        words.hasPrefix("Duplicates: removed with UMIs by umi_tools \(route.toolVersion) count --per-gene ")
            && (words.hasSuffix(" The import removed none.")
                || words.hasSuffix(" Whether the reads lost duplicates before this step is Not recorded (the bundle holds no "
                    + "import record that names its steps)."))
    }

    /// The plan's `countingGTF` names the set's `derived/genes.gtf` by SHA-256, or the run is refused in words that name
    /// the step that gave each read its gene, before any table is read (as `checkCountingGTF` for a STAR chain).
    static func checkUMICountingGTF(_ run: ExecutorAdoptedCountsRun, set: ReferenceSetOutcome) throws {
        let gtf = try set.manifest.requireCountingGTF()
        let stated = run.route.settings["countingGTF"] ?? ""
        let planned = stated.range(of: "SHA-256 ").map { String(stated[$0.upperBound...]) }
        guard planned != gtf.sha256 else { return }
        let named = planned.map { "a \(gtf.path) of SHA-256 \($0)" } ?? "no \(gtf.path) by SHA-256"
        throw refusal(
            "pipeline.route.settings",
            "The step \(UMIPlan.featureCountsStepID) of the sample \(run.plan.sample.sampleName) gave each read its gene on \(named), "
                + "and the set \(set.manifest.id) on this Mac holds \(gtf.path) of SHA-256 \(gtf.sha256), so its genes are not the "
                + "ones counted. Adopt the folder with the set the plan was made on, or make the plan again on this set."
        )
    }

    /// One sample's table from the `home` output `umi/counts.tsv` of its count step, read where the run returned it, and
    /// the record's lines from the check's file and each extraction log. umi_tools lists only the genes it counted a UMI
    /// on, so a gene of the set the table does not list counted none, and the table is refused in words when its shape is
    /// not umi_tools' or an id is not a gene of the set (BIO-COUNTING-GTF item 5).
    static func umiSample(_ run: ExecutorAdoptedCountsRun, setID: String, setGenes: [String]) throws -> ExecutorUMICountsSample {
        let sample = run.plan.sample.sampleName
        guard !sample.isEmpty else {
            throw refusal("sample.sampleName", "The plan of the step \(UMIPlan.countStepID) names no sample, so the result could not label its counts.")
        }
        guard let table = run.homeOutputs.first(where: { $0.path == UMIPlan.countTable && $0.stepID == UMIPlan.countStepID }) else {
            throw refusal(
                "steps", "The plan of the sample \(sample) returns no \(UMIPlan.countTable) from a step \(UMIPlan.countStepID), so the result would hold no counts."
            )
        }
        let field = "steps[\(table.stepIndex)].outputs"
        let label = "\(table.path) of the sample \(sample)"
        let rows = try readUMICounts(table.url, label: label, field: field)
        guard !rows.isEmpty else {
            throw refusal(
                field,
                "\(label) lists no gene, so umi_tools counted no UMI on a gene of the set and every count would read 0. "
                    + "\(UMIPlan.readCountsSummary) of the sample says how many reads featureCounts gave a gene."
            )
        }
        // The set's genes the table does not list counted none, so only an id the set lacks shows another GTF.
        let listed = Set(rows.map(\.id))
        do {
            try STARCountTableReader.checkGenes(
                rows.map(\.id) + setGenes.filter { !listed.contains($0) }, label: label, setID: setID, setGenes: setGenes)
        } catch let error as STARCountTableError {
            throw refusal(field, error.message)
        }
        var lines: [String: ParameterValue] = [
            "umiCheck": .string(try umiCheckWords(run, sample: sample)),
            "umiExtraction": .string(try umiExtractionWords(run, sample: sample)),
        ]
        let leftOut = run.homeOutputs.map(\.path).filter { $0 != table.path }
        if !leftOut.isEmpty { lines[RNASeqImportFacts.filesLeftOutKey] = .array(leftOut.map { .string($0) }) }
        return ExecutorUMICountsSample(kept: table, counts: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.count) }), lines: lines)
    }

    /// The rows of `umi_tools count --per-gene`'s table: the header `gene` and `count`, then one gene a line with a whole
    /// count, each gene once.
    static func readUMICounts(_ url: URL, label: String, field: String) throws -> [(id: String, count: Int)] {
        func refuse(_ what: String) -> ExecutorAdoptRefusal {
            refusal(field, "\(label) is not the table umi_tools count --per-gene writes: \(what). It writes the header gene and "
                + "count, then one gene a line with its count of UMIs.")
        }
        var lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first?.components(separatedBy: "\t") == umiCountsHeader else { throw refuse("line 1 is not the header gene and count") }
        var seen = Set<String>()
        return try lines.enumerated().dropFirst().map { index, line in
            let cells = line.components(separatedBy: "\t")
            guard cells.count == 2, !cells[0].isEmpty, let count = Int(cells[1]), count >= 0 else {
                throw refuse("line \(index + 1) is not a gene and its count")
            }
            guard seen.insert(cells[0]).inserted else { throw refuse("line \(index + 1) names the gene \(cells[0]) a second time") }
            return (cells[0], count)
        }
    }

    /// The `home` outputs of each pair's step, in pair order, or a refusal that names the first pair's missing file.
    private static func pairOutputs(
        _ run: ExecutorAdoptedCountsRun, sample: String, path: (Int) -> String, what: String
    ) throws -> [ExecutorAdoptedOutput] {
        let pairs = run.plan.steps.filter { $0.tool?.id == umiToolsID && $0.id.hasPrefix("umi-extract-pair") }.count
        return try (1...max(pairs, 1)).map { pair in
            guard let output = run.homeOutputs.first(where: { $0.path == path(pair) }) else {
                throw refusal(
                    "steps", "The plan of the sample \(sample) returns no \(path(pair)), so the record could not state \(what). "
                        + "Make the plan again with this version of Lungfish, run it, and adopt the folder it returns."
                )
            }
            return output
        }
    }

    /// The words of each pair's UMI layout check, read from the file the check returned, which hold its verdict and
    /// shares. Several pairs join their words in pair order.
    static func umiCheckWords(_ run: ExecutorAdoptedCountsRun, sample: String) throws -> String {
        let files = try pairOutputs(run, sample: sample, path: UMIPlan.checkOutput(pair:), what: "the UMI layout check's verdict")
        let words = try files.map { file in
            do {
                return try JSONDecoder().decode(UMILayoutCheck.Report.self, from: Data(contentsOf: file.url)).words
            } catch {
                throw refusal("steps[\(file.stepIndex)].outputs", "\(file.path) of the sample \(sample) is not the file the UMI layout check writes.")
            }
        }
        guard words.count > 1 else { return words[0] }
        return words.enumerated().map { "Pair \($0.offset + 1): \($0.element)" }.joined(separator: " ")
    }

    /// The share of read pairs that `umi_tools extract` kept, its `Reads output` over its `Input Reads` summed over the
    /// pairs' logs and cut down to one decimal (`UMIPlanReport`). The UMI branch is paired, so each count is a pair.
    static func umiExtractionWords(_ run: ExecutorAdoptedCountsRun, sample: String) throws -> String {
        let logs = try pairOutputs(run, sample: sample, path: UMIPlan.extractLog(pair:), what: "the share of reads extraction kept")
        let read = try logs.map { log in
            do {
                return try UMIPlanReport.extractCounts(String(decoding: try Data(contentsOf: log.url), as: UTF8.self))
            } catch {
                throw refusal("steps[\(log.stepIndex)].outputs", "\(log.path) of the sample \(sample) holds no Input Reads or Reads output line.")
            }
        }
        let (output, input) = (read.map(\.output).reduce(0, +), read.map(\.input).reduce(0, +))
        return "umi_tools extract kept \(output) of \(input) read pairs (\(UMIPlanReport.percent(output, of: input))%), the pairs "
            + "whose UMI read starts with the motif, in \(logs.map(\.path).joined(separator: ", "))"
    }

    /// The writer's request of a UMI chain: one gene table of umi_tools' counts in the set's gene order, in UMIs, the
    /// set's genes and not-host ids, `umi/counts.tsv` of each sample at its plan path, and the plan's route with
    /// `duplicates` in the result's form.
    static func umiCountsRequest(
        name: String, samples: [ExecutorCountsAdoptedSample], set: ReferenceSetOutcome
    ) throws -> RNASeqResultWriter.Request {
        let route = samples[0].run.route
        let umis = samples.compactMap(\.umiCounts)
        let genesURL = set.url.appendingPathComponent(set.manifest.derived.genes.path)
        let genes = try starSetGenes(set)
        let names = samples.map(\.name)
        let table = RNASeqCountTable(sampleIDs: names, rows: genes.map { id in
            .init(id: id, counts: umis.map { Double($0.counts[id] ?? 0) })
        })
        var settings = route.settings
        settings["duplicates"] = SalmonQuantRecordLines.duplicatesSetting(samples.map(\.duplicates))
        let referenceSet = samples[0].run.pipeline.referenceSet
        let sources = zip(names, umis).map { sample, umi in
            RNASeqResultWriter.SourceFile(url: umi.kept.url, relativePath: umi.kept.path, sample: sample, tool: route.tool)
        }
        return RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: .quantified, tool: route.tool, toolVersion: route.toolVersion),
            route: .init(id: route.id, tool: route.tool, toolVersion: route.toolVersion, settings: settings),
            referenceSet: .init(id: referenceSet.id, layout: referenceSet.layout == .deposit ? .deposit : .lge),
            samples: try RNASeqSampleSheet.match(nil, fileIDs: names, byRun: true).records,
            genes: .referenceSetTable(url: genesURL, keeping: genes),
            counts: [.init(rows: .gene, column: .default, unit: .umis, table: table)],
            sourceFiles: sources, notHost: try SalmonQuantRoute.notHostIDs(genesURL))
    }

    /// The refusal of a UMI sample whose layout check failed, in place of the record's outcome words: the run stopped at
    /// the check, so the sample has no counts. It names the check's verdict and gives the check's words from the step's
    /// standard error in the run record. Any other refusal is nil.
    static func umiCheckRefusal(_ folder: URL, refused: ExecutorAdoptRefusal) -> ExecutorAdoptRefusal? {
        guard refused.field == "outcome",
              let resolver = try? PlanResourceResolver(workRoot: folder),
              let plan = try? ExecutionPlan.decode(read(planFileName, in: resolver, limit: largestPlanBytes)),
              let route = plan.pipeline?.route, isUMIRoute(route),
              let record = try? ExecutorRunRecord.decode(read(ExecutorRunRecord.fileName, in: resolver, limit: largestRecordBytes)),
              let failed = record.failedStepID, failed.hasPrefix("umi-layout-check-pair"),
              let step = record.steps.first(where: { $0.id == failed }), step.outcome == .failed
        else { return nil }
        let lines = step.stderrTail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let said = lines.filter { !$0.isEmpty }.joined(separator: " ")
        return refusal(
            "failedStepID",
            "The UMI layout check of the sample \(plan.sample.sampleName) failed in the step \(failed), so the run stopped there "
                + "and the sample has no UMI counts to adopt. A failed check never falls back to counting without UMIs."
                + (said.isEmpty ? "" : " The check said: \(said)")
        )
    }
}
