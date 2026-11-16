// ExecutorRunAdoption+RNASeq.swift - The RNA-seq payload of the adopt: each sample's salmon folder of a returned run or
// batch, read into one result as rnaseq quant writes it (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// One sample of a counts adopt: its checked run and the salmon folder its counting step returned, read where it lies.
struct ExecutorCountsAdoptedSample: Sendable {
    let run: ExecutorAdoptedCountsRun
    let folder: SalmonQuantFolder
}

/// A returned folder or batch whose every sample passed every check, read into the writer's request before any result
/// file exists. A batch gives one result that holds all its samples.
struct ExecutorCountsAdoption: Sendable {
    let samples: [ExecutorCountsAdoptedSample]
    /// The set folder under the storage root that `pipeline.referenceSet.id` names.
    let setURL: URL
    let request: RNASeqResultWriter.Request
}

extension ExecutorRunAdoption {
    /// Every check and every read of the counts adopt, with nothing written: each sample's run (`checkCounts`), one
    /// pipeline for all, the set under `storageRoot`, each salmon folder, then the request `RNASeqResultWriter` takes.
    static func prepareCounts(
        _ folder: URL, storageRoot: URL, name: String, policy: ExecutorAdoptPolicy
    ) throws -> ExecutorCountsAdoption {
        let runs = try checkCountsRuns(folder, policy: policy)
        let first = runs[0]
        try checkOnePipeline(runs)
        let (setURL, set) = try countsReferenceSet(first.pipeline.referenceSet, storageRoot: storageRoot)
        var samples: [ExecutorCountsAdoptedSample] = []
        for run in runs {
            try Task.checkCancellation()
            samples.append(ExecutorCountsAdoptedSample(run: run, folder: try salmonFolder(run)))
        }
        let request = try countsRequest(name: name, samples: samples, set: set)
        return ExecutorCountsAdoption(samples: samples, setURL: setURL, request: request)
    }

    /// One returned folder's run, or each sample's run of a returned batch in the batch's order. A batch is refused
    /// whole, with every sample's refusal, as the FASTQ batch adopt refuses it.
    static func checkCountsRuns(_ folder: URL, policy: ExecutorAdoptPolicy) throws -> [ExecutorAdoptedCountsRun] {
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

    /// One result holds one route and one set, so every sample's plan states the same pipeline, and the adopt reads
    /// salmon's bulk counts.
    static func checkOnePipeline(_ runs: [ExecutorAdoptedCountsRun]) throws(ExecutorAdoptRefusal) {
        let first = runs[0]
        guard first.route.tool == salmonToolID, first.pipeline.modality == .bulk else {
            throw refusal(
                "pipeline.route",
                "This plan counts \(first.pipeline.modality?.rawValue ?? "no") reads with \(first.route.tool) \(first.route.toolVersion), "
                    + "and import rnaseq --adopt reads the bulk counts of salmon only."
            )
        }
        for run in runs.dropFirst() {
            let (one, other) = (first.plan.sample.sampleName, run.plan.sample.sampleName)
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
        return Set(one.settings.keys).union(other.settings.keys).sorted().first { one.settings[$0] != other.settings[$0] }
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
        folder.sample = SampleFolderNaming.sanitizedDirectoryName(for: sampleName)
        folder.keptFiles = SalmonQuantFolderReader.readFiles
        folder.leftOut = []
        return folder
    }
}
