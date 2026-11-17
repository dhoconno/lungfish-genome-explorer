// ExecutorRunAdoption+RNASeq.swift - The RNA-seq payload of the adopt: each sample's salmon folder of a returned run or
// batch, read into one result as rnaseq quant writes it (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// One sample of a counts adopt: its checked run, the counts its counting step returned, read where they lie, the
/// duplicates state its plan states, and the adapter of each trim call by step index.
struct ExecutorCountsAdoptedSample: Sendable {
    /// salmon's folder, the table of a STAR chain (lane EX-ADOPT M5), a STARsolo folder (lane SOLO-PLAN M3), or the UMI
    /// branch's table (lane EX-ADOPT M6).
    enum Counts: Sendable {
        case salmon(SalmonQuantFolder)
        case star(ExecutorSTARCountsSample)
        case singleCell(ExecutorSoloSample)
        case umi(ExecutorUMICountsSample)
    }

    let run: ExecutorAdoptedCountsRun
    let counts: Counts
    let duplicates: SalmonQuantRecordLines.DuplicatesState
    let adapters: [Int: TrimGaloreAdapterReport]
    /// The record's lines of a salmon folder of LGE's default route: each other `home` file, STAR's among them, as left
    /// out (lane EX-ADOPT M6). None for salmon on the reads.
    var salmonLines: [String: ParameterValue] = [:]

    /// The plan's sample name, which labels the counts, the kept files and the record.
    var name: String { run.plan.sample.sampleName }
    var salmonFolder: SalmonQuantFolder? {
        if case .salmon(let folder) = counts { return folder }
        return nil
    }
    var starCounts: ExecutorSTARCountsSample? {
        if case .star(let star) = counts { return star }
        return nil
    }
    var soloSample: ExecutorSoloSample? {
        if case .singleCell(let solo) = counts { return solo }
        return nil
    }
    var umiCounts: ExecutorUMICountsSample? {
        if case .umi(let umi) = counts { return umi }
        return nil
    }
    /// The counting step's lines the payload adds to the record beside the Mac route's: none for salmon on the reads.
    var payloadLines: [String: ParameterValue] { starCounts?.lines ?? soloSample?.lines ?? umiCounts?.lines ?? salmonLines }
}

/// A returned folder or batch whose every sample passed every check, read into the writer's request before any result
/// file exists. A batch gives one result that holds all its samples.
struct ExecutorCountsAdoption: Sendable {
    let samples: [ExecutorCountsAdoptedSample]
    /// The set folder under the storage root that `pipeline.referenceSet.id` names.
    let setURL: URL
    let request: RNASeqResultWriter.Request

    /// What the import prints and the record keeps beside the result, such as reads that do not look unstranded.
    var warnings: [String] { samples.compactMap { $0.starCounts?.warning } }
}

extension ExecutorRunAdoption {
    /// Every check and every read of the counts adopt, with nothing written: each sample's run (`checkCounts`), one
    /// pipeline for all, the set under `storageRoot`, each salmon folder or STAR chain's table and each trim call's
    /// adapter, then the request `RNASeqResultWriter` takes.
    static func prepareCounts(
        _ folder: URL, storageRoot: URL, name: String, policy: ExecutorAdoptPolicy
    ) throws -> ExecutorCountsAdoption {
        let runs = try checkCountsRuns(folder, policy: policy)
        // A single-cell plan's counts are STARsolo's matrix, which its own payload reads (lane SOLO-PLAN M3).
        if runs[0].pipeline.modality == .singleCell { return try prepareSingleCell(runs, storageRoot: storageRoot, name: name) }
        let first = runs[0]
        let duplicates = try runs.map { try duplicatesState($0) }
        try checkOnePipeline(runs, duplicates: duplicates)
        let (setURL, set) = try countsReferenceSet(first.pipeline.referenceSet, storageRoot: storageRoot)
        // A STAR chain's two checks come before any table is read: `multimapNmax` in the argv (`checkCounts`), then each
        // plan's GTF against the set's (lane EX-ADOPT M5). The UMI branch's GTF check comes first too (lane EX-ADOPT M6).
        let (star, umi) = (isSTARRoute(first.route), isUMIRoute(first.route))
        if star { for run in runs { try checkCountingGTF(run, set: set) } }
        if umi { for run in runs { try checkUMICountingGTF(run, set: set) } }
        let setGenes = star || umi ? try starSetGenes(set) : []
        var samples: [ExecutorCountsAdoptedSample] = []
        for (run, state) in zip(runs, duplicates) {
            try Task.checkCancellation()
            let counts: ExecutorCountsAdoptedSample.Counts
            if star {
                counts = .star(try starSample(run, setID: set.manifest.id, setGenes: setGenes))
            } else if umi {
                counts = .umi(try umiSample(run, setID: set.manifest.id, setGenes: setGenes))
            } else {
                counts = .salmon(try salmonFolder(run))
            }
            var sample = ExecutorCountsAdoptedSample(run: run, counts: counts, duplicates: state, adapters: try trimAdapters(run))
            sample.salmonLines = defaultRouteLines(run)
            samples.append(sample)
        }
        let request = try countsRequest(name: name, samples: samples, set: set)
        return ExecutorCountsAdoption(samples: samples, setURL: setURL, request: request)
    }

    /// One returned folder's run, or each sample's run of a returned batch in the batch's order. A batch is refused
    /// whole, with every sample's refusal, as the FASTQ batch adopt refuses it.
    static func checkCountsRuns(_ folder: URL, policy: ExecutorAdoptPolicy) throws -> [ExecutorAdoptedCountsRun] {
        // A UMI sample whose layout check failed is refused in words that name the check's verdict (lane EX-ADOPT M6).
        func checkCounts(_ folder: URL, policy: ExecutorAdoptPolicy) throws(ExecutorAdoptRefusal) -> ExecutorAdoptedCountsRun {
            do throws(ExecutorAdoptRefusal) {
                return try ExecutorRunAdoption.checkCounts(folder, policy: policy)
            } catch {
                throw umiCheckRefusal(folder, refused: error) ?? error
            }
        }
        guard isReturnedBatchFolder(folder) else { return [try checkCounts(folder, policy: policy)] }
        let samples = try sampleFolders(in: folder)
        var runs: [ExecutorAdoptedCountsRun] = []
        var refusals: [ExecutorBatchAdoptRefusal] = []
        for sample in samples {
            if holdsUncopiedResult(sample.folder) {
                refusals.append(uncopiedResultRefusal(sample))
                continue
            }
            do throws(ExecutorAdoptRefusal) {
                runs.append(try checkCounts(sample.folder, policy: policy))
            } catch {
                refusals.append(ExecutorBatchAdoptRefusal(sample: sample.name, field: error.field, cause: error.cause, gap: error.gap))
            }
        }
        guard refusals.isEmpty else { throw ExecutorBatchAdoptError.refused(refusals, sampleCount: samples.count) }
        return runs
    }

    /// The duplicates state of one sample's plan entry `duplicates` (ruling ARCH-ADOPT-ROUTE item 2): the removed words
    /// with source `recipe` are removed, the kept words with source `default` kept, the Not recorded words with source
    /// `default` Not recorded, and a UMI chain's words with source `preset` removed with UMIs. Any other value is refused
    /// in words that name it and the sample, never read as kept.
    static func duplicatesState(_ run: ExecutorAdoptedCountsRun) throws(ExecutorAdoptRefusal) -> SalmonQuantRecordLines.DuplicatesState {
        let sample = run.plan.sample.sampleName
        let entry = run.pipeline.settings.first { $0.id == "duplicates" }
        switch entry?.source {
        case .default? where entry?.value == SalmonQuantRecordLines.duplicates: return .kept
        case .default? where entry?.value == SalmonQuantRecordLines.duplicatesNotRecorded: return .notRecorded
        case .recipe? where entry.map(\.value).map(isRemovedWords) == true: return .removed
        case .preset? where isUMIRoute(run.route) && entry.map({ isUMIWords($0.value, route: run.route) }) == true: return .umi
        default:
            let stated = entry.map { "states duplicates as \"\($0.value)\" with source \($0.source.rawValue)" } ?? "states no duplicates"
            throw refusal(
                "pipeline.settings",
                "The plan of the sample \(sample) \(stated). The adopt reads only the removed words with source recipe, "
                    + "the kept or the Not recorded words with source default, or a UMI chain's words with source preset, so it "
                    + "cannot say what the counted reads lost to duplicate removal."
            )
        }
    }

    /// The words of a sample whose import removed duplicates without UMIs (`SalmonQuantRecordLines.duplicatesLine`).
    private static func isRemovedWords(_ words: String) -> Bool {
        words.hasPrefix("Duplicates: removed at import by ") && words.hasSuffix(", without UMIs. This count removes none.")
    }

    /// One result holds one route and one set, so every sample's plan states the same pipeline, and the adopt reads
    /// the bulk counts of salmon, STAR GeneCounts, featureCounts or umi_tools. Route keys other than `duplicates` must be
    /// equal, and a batch of two salmon scorings is refused in words that name both. `duplicates` holds each sample's own
    /// step names, so the samples must share its state instead, as a result adopted from plans holds samples of one
    /// state (`docs/formats/executor-plan.md`, the `duplicates` paragraph).
    static func checkOnePipeline(
        _ runs: [ExecutorAdoptedCountsRun], duplicates: [SalmonQuantRecordLines.DuplicatesState]
    ) throws(ExecutorAdoptRefusal) {
        let first = runs[0]
        let read = first.route.tool == salmonToolID || isSTARRoute(first.route) || isUMIRoute(first.route)
        guard read, first.pipeline.modality == .bulk else {
            throw refusal(
                "pipeline.route",
                "This plan counts \(first.pipeline.modality?.rawValue ?? "no") reads with \(first.route.tool) \(first.route.toolVersion), "
                    + "and import rnaseq --adopt reads the bulk counts of salmon, STAR GeneCounts, featureCounts and umi_tools only."
            )
        }
        let scoring = "alignmentScoring"
        if let one = first.route.settings[scoring],
           let other = runs.dropFirst().first(where: { $0.route.settings[scoring].map { $0 != one } == true }),
           let two = other.route.settings[scoring] {
            let (withModel, without) = one == "errorModel" ? (first, other) : (other, first)
            throw refusal(
                "pipeline.route",
                "The samples \(first.plan.sample.sampleName) and \(other.plan.sample.sampleName) were planned with two alignment "
                    + "scorings, \(one) and \(two), so salmon weighed the alignments of \(withModel.plan.sample.sampleName) with its "
                    + "error model and those of \(without.plan.sample.sampleName) without it. One result holds one route, so adopt "
                    + "them as two batches."
            )
        }
        for (run, state) in zip(runs, duplicates).dropFirst() {
            let (one, other) = (first.plan.sample.sampleName, run.plan.sample.sampleName)
            if state != duplicates[0] {
                throw refusal(
                    "pipeline.route",
                    "The samples \(one) and \(other) differ in duplicates: \(first.route.settings["duplicates"] ?? "none") and "
                        + "\(run.route.settings["duplicates"] ?? "none"). One result holds samples of one duplicates state, so adopt them as two batches."
                )
            }
            if run.pipeline.referenceSet != first.pipeline.referenceSet {
                throw refusal(
                    "pipeline.referenceSet",
                    "The samples \(one) and \(other) name two reference sets, \(first.pipeline.referenceSet.id) and "
                        + "\(run.pipeline.referenceSet.id). One result holds one set, so adopt them as two batches."
                )
            }
            if let key = differingKey(first.route, run.route) {
                throw refusal(
                    "pipeline.route",
                    "The samples \(one) and \(other) were planned with two routes, which differ in \(key). One result "
                        + "holds one route, so adopt them as two batches."
                )
            }
        }
    }

    /// The first key in which two routes differ, or nil for one route.
    private static func differingKey(_ one: PlanPipelineRoute, _ other: PlanPipelineRoute) -> String? {
        if one.id != other.id { return "id" }
        if one.tool != other.tool { return "tool" }
        if one.toolVersion != other.toolVersion { return "toolVersion" }
        return Set(one.settings.keys).union(other.settings.keys).subtracting(["duplicates"]).sorted()
            .first { one.settings[$0] != other.settings[$0] }
    }

    /// The set `referenceSet` names in the storage root's sets folder, whose transcript table sums the genes. A missing
    /// set is refused in words that name it, the folder and how to get it.
    static func countsReferenceSet(
        _ referenceSet: PlanPipelineReferenceSet, storageRoot: URL
    ) throws -> (URL, ReferenceSetOutcome) {
        let owner = ReferenceSetOwner(storageRoot: storageRoot)
        let url = owner.setsFolder.appendingPathComponent(
            "\(referenceSet.id).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw refusal(
                "pipeline.referenceSet",
                "The plan sums genes through the reference set \(referenceSet.id), and \(owner.setsFolder.path) holds no such set. "
                    + "Build the set on this Mac with lungfish-cli rnaseq reference-set, or copy it there, then adopt again."
            )
        }
        let set = try owner.settled(url, id: referenceSet.id)
        let layout: PlanPipelineReferenceSet.Layout = set.manifest.layout.kind == "deposit" ? .deposit : .lge
        guard layout == referenceSet.layout else {
            throw refusal(
                "pipeline.referenceSet.layout",
                "The plan names the set \(referenceSet.id) with layout \(referenceSet.layout.rawValue), and the set in "
                    + "\(owner.setsFolder.path) has layout \(layout.rawValue)."
            )
        }
        return (url, set)
    }

    /// The counting step's `home` outputs as one salmon folder of the reader's four files, read where the run returned
    /// them. The folder keeps only those four files, each checked against the record, and takes the plan's sample name.
    static func salmonFolder(_ run: ExecutorAdoptedCountsRun) throws -> SalmonQuantFolder {
        let sampleName = run.plan.sample.sampleName
        guard run.countingSteps.count == 1, let step = run.countingSteps.first else {
            throw refusal(
                "steps",
                "The plan of the sample \(sampleName) has \(run.countingSteps.count) steps that count with \(run.route.tool), "
                    + "and the adopt reads one salmon folder a sample."
            )
        }
        let stepID = run.plan.steps[step].id
        let outputs = run.homeOutputs.filter { $0.stepIndex == step }
        let quantFile = SalmonQuantFolderReader.readFiles[0]
        guard let quant = outputs.first(where: { $0.path == quantFile || $0.path.hasSuffix("/" + quantFile) }) else {
            throw refusal("steps[\(step)].outputPolicy", "The step \(stepID) returns no \(quantFile), so the result would hold no counts.")
        }
        let prefix = String(quant.path.dropLast(quantFile.count))
        let folderURL = quant.url.deletingLastPathComponent()
        for file in SalmonQuantFolderReader.readFiles {
            guard let output = outputs.first(where: { $0.path == prefix + file }) else {
                throw refusal(
                    "steps[\(step)].outputPolicy",
                    "The step \(stepID) returns no \(prefix + file), which salmon writes beside \(quant.path) and the result reads."
                )
            }
            guard output.url.standardizedFileURL.path == folderURL.appendingPathComponent(file).standardizedFileURL.path else {
                throw refusal("steps[\(step)].outputs", "The output \(output.path) of the step \(stepID) is not in the folder of \(quant.path).")
            }
        }
        var folder = try SalmonQuantFolderReader.read(folder: folderURL)
        // The plan's name, as the Mac route labels its result: the writer makes its own `source/<sample>` folder safe, and the
        // adopt's refusals and the plan say this name too (review EX-ADOPT-M2M3-BIO should-fix 1).
        guard !sampleName.isEmpty else {
            throw refusal("sample.sampleName", "The plan of the step \(stepID) names no sample, so the result could not label its counts.")
        }
        folder.sample = sampleName
        folder.keptFiles = SalmonQuantFolderReader.readFiles
        folder.leftOut = []
        return folder
    }

    /// The record's lines of LGE's default route, a salmon route whose plan maps with STAR first: each `home` file of a
    /// step other than salmon's, STAR's `Log.final.out` and `ReadsPerGene.out.tab` among them, as left out, since the
    /// result keeps salmon's four files only. None for salmon on the reads, whose record has always named none.
    static func defaultRouteLines(_ run: ExecutorAdoptedCountsRun) -> [String: ParameterValue] {
        guard run.route.tool == salmonToolID, run.plan.steps.contains(where: { $0.tool?.id == starToolID }) else { return [:] }
        let leftOut = run.homeOutputs.filter { !run.countingSteps.contains($0.stepIndex) }.map(\.path)
        return leftOut.isEmpty ? [:] : [RNASeqImportFacts.filesLeftOutKey: .array(leftOut.map { .string($0) })]
    }
}
