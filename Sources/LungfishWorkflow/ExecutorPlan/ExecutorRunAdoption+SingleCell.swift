// ExecutorRunAdoption+SingleCell.swift - The single-cell payload of the counts adopt: each sample's STARsolo folder of a
// returned run or batch, read with `SingleCellFolderReader` into one result (Phase 5.3 lane SOLO-PLAN M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// One sample of a STARsolo adopt: the folder the reader read, with the plan's sample name, and the counting step's
/// lines in the record.
struct ExecutorSoloSample: Sendable {
    let folder: SingleCellFolder
    let lines: [String: ParameterValue]
}

extension ExecutorRunAdoption {
    /// The record line on multi-mappers that every STARsolo result states
    /// (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:146`).
    static let soloMultimapperLine = "STARsolo counts an intronic read that maps to several loci when only one locus lies in a "
        + "gene, and Cell Ranger keeps a multi-mapper only for a single exonic locus"
    /// The route keys of the plan that the counting step's record lines repeat: BIO-SOLO-GTF item 4's facts, the list by
    /// name and SHA-256, the cell filter, the chemistry and what is counted.
    static let soloRouteLines = ["barcodeList", "cellFilter", "chemistry", "counts", "countingGTF", "index"]

    /// Every check and read of a STARsolo adopt, with nothing written: one route and one set for all samples, each plan's
    /// GTF against the set's under the storage root, then each sample's returned `solo/` folder read with
    /// `SingleCellFolderReader.read` and the writer's request.
    static func prepareSingleCell(
        _ runs: [ExecutorAdoptedCountsRun], storageRoot: URL, name: String
    ) throws -> ExecutorCountsAdoption {
        let first = runs[0]
        try checkOneSoloPipeline(runs)
        let (setURL, set) = try countsReferenceSet(first.pipeline.referenceSet, storageRoot: storageRoot)
        for run in runs { try checkSoloGTF(run, set: set) }
        var samples: [ExecutorCountsAdoptedSample] = []
        for run in runs {
            try Task.checkCancellation()
            samples.append(ExecutorCountsAdoptedSample(run: run, counts: .singleCell(try soloSample(run)), duplicates: .umi, adapters: [:]))
        }
        return ExecutorCountsAdoption(samples: samples, setURL: setURL, request: try soloRequest(name: name, samples: samples, set: set))
    }

    /// A STARsolo plan of a preset whose matrix the reader reads, and one route and one set for every sample. The
    /// introns preset counts `Solo.out/GeneFull_Ex50pAS`, and the reader reads `Solo.out/Gene`, so it is refused.
    static func checkOneSoloPipeline(_ runs: [ExecutorAdoptedCountsRun]) throws(ExecutorAdoptRefusal) {
        let first = runs[0]
        let gene = SoloPlanPreset.threePrimeV3.routeID
        guard first.pipeline.id == SoloPlan.pipelineID, first.route.tool == starToolID else {
            throw refusal(
                "pipeline.route",
                "This plan counts single-cell reads with \(first.route.tool) \(first.route.toolVersion) in the pipeline "
                    + "\(first.pipeline.id), and import rnaseq --adopt reads the single-cell counts of STARsolo plans only. "
                    + "Import the tool's own folder with lungfish-cli import rnaseq <folder>."
            )
        }
        guard first.route.id == gene else {
            throw refusal(
                "pipeline.route",
                "This plan counts Solo.out/GeneFull_Ex50pAS (route \(first.route.id)), and the adopt reads the filtered "
                    + "matrix of Solo.out/Gene only, as import rnaseq reads a STARsolo folder, so its counts are not adopted "
                    + "and nothing was imported. The run also returned the exon matrix Solo.out/Gene, which "
                    + "lungfish-cli import rnaseq <the sample's result folder>/solo keeps. "
                    + "To adopt counts, plan the library with the preset \(SoloPlanPreset.threePrimeV3.rawValue) or "
                    + "\(SoloPlanPreset.fivePrimeV2.rawValue), which count Solo.out/Gene."
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
            let keys = Set(first.route.settings.keys).union(run.route.settings.keys).sorted()
            let differs = [("id", first.route.id != run.route.id), ("toolVersion", first.route.toolVersion != run.route.toolVersion)]
                .first(where: \.1)?.0 ?? keys.first { first.route.settings[$0] != run.route.settings[$0] }
            if let differs {
                throw refusal(
                    "pipeline.route",
                    "The samples \(one) and \(other) were planned with two routes, which differ in \(differs). One result "
                        + "holds one route, so adopt them as two batches."
                )
            }
        }
    }

    /// The plan's `countingGTF` names the set's `derived/genes.gtf` by the SHA-256 of the set under the storage root, the
    /// file the 10x filter rule made its GTF from, or the run is refused in words that name the step.
    static func checkSoloGTF(_ run: ExecutorAdoptedCountsRun, set: ReferenceSetOutcome) throws {
        let gtf = try set.manifest.requireCountingGTF()
        let stated = run.route.settings["countingGTF"] ?? ""
        let marker = "\(gtf.path) (SHA-256 "
        let planned = stated.range(of: marker).map { String(stated[$0.upperBound...].prefix(64)) }
        guard planned != gtf.sha256 else { return }
        let step = run.countingSteps.first.map { run.plan.steps[$0].id } ?? SoloPlan.stepID
        let named = planned.map { "an index built from a \(gtf.path) of SHA-256 \($0)" } ?? "an index that names no \(gtf.path) by SHA-256"
        throw refusal(
            "pipeline.route.settings",
            "The step \(step) of the sample \(run.plan.sample.sampleName) counted on \(named), and the set \(set.manifest.id) "
                + "on this Mac holds \(gtf.path) of SHA-256 \(gtf.sha256), so its genes are not the ones counted. Adopt the "
                + "folder with the set the plan was made on, or make the index and the plan again on this set."
        )
    }

    /// The counting step's `solo/` folder, read with the folder reader where the run returned it. Each file the reader
    /// keeps must be a `home` output of the step that the record states, so the result keeps only checked bytes.
    static func soloSample(_ run: ExecutorAdoptedCountsRun) throws -> ExecutorSoloSample {
        let sampleName = run.plan.sample.sampleName
        guard run.countingSteps.count == 1, let step = run.countingSteps.first else {
            throw refusal(
                "steps",
                "The plan of the sample \(sampleName) has \(run.countingSteps.count) steps that count with STAR, and the adopt "
                    + "reads one STARsolo folder a sample."
            )
        }
        let stepID = run.plan.steps[step].id
        let outputs = run.homeOutputs.filter { $0.stepIndex == step }
        let matrixFile = "Solo.out/Gene/filtered/matrix.mtx"
        guard let matrix = outputs.first(where: { $0.path == matrixFile || $0.path.hasSuffix("/" + matrixFile) }) else {
            throw refusal("steps[\(step)].outputPolicy", "The step \(stepID) returns no \(matrixFile), so the result would hold no counts.")
        }
        let prefix = String(matrix.path.dropLast(matrixFile.count))
        let base = URL(fileURLWithPath: String(matrix.url.standardizedFileURL.path.dropLast(matrixFile.count)), isDirectory: true)
        guard !sampleName.isEmpty else {
            throw refusal("sample.sampleName", "The plan of the step \(stepID) names no sample, so the result could not label its counts.")
        }
        var folder = try SingleCellFolderReader.read(folder: base)
        for kept in folder.keptFiles where !outputs.contains(where: { $0.path == prefix + kept }) {
            throw refusal(
                "steps[\(step)].outputPolicy",
                "The step \(stepID) returns no \(prefix + kept) as home, which the result keeps, so its bytes are not checked "
                    + "against the run record. Make the plan again with this version of Lungfish, run it, and adopt the folder it returns."
            )
        }
        folder.sample = sampleName
        var lines: [String: ParameterValue] = ["multimappers": .string(soloMultimapperLine)]
        for key in soloRouteLines { if let value = run.route.settings[key] { lines[key] = .string(value) } }
        if let source = run.pipeline.settings.first(where: { $0.id == "barcodeListSource" }) { lines["barcodeListSource"] = .string(source.value) }
        // The files left out and the feature types, and none of the import's Not recorded lines, since the plan states each.
        let facts = SingleCellFolderReader.facts([folder], genomes: []).filter { !RNASeqImportFacts.unstatedKeys.contains($0.key) }
        lines.merge(facts) { line, _ in line }
        return ExecutorSoloSample(folder: folder, lines: lines)
    }

    /// The writer's request as `import rnaseq` makes it for STARsolo folders, with the plan's route under STAR's name and
    /// version, `origin` `quantified`, and the genes and not-host ids of the set the plan names.
    static func soloRequest(
        name: String, samples: [ExecutorCountsAdoptedSample], set: ReferenceSetOutcome
    ) throws -> RNASeqResultWriter.Request {
        let folders = samples.compactMap(\.soloSample).map(\.folder)
        let records = try RNASeqSampleSheet.match(nil, fileIDs: folders.map(\.sample), byRun: true).records
        var request = try SingleCellFolderReader.request(folders, name: name, samples: records, genomes: [])
        let (route, referenceSet) = (samples[0].run.route, samples[0].run.pipeline.referenceSet)
        let genesURL = set.url.appendingPathComponent(set.manifest.derived.genes.path)
        let features = folders.first?.featureIDs ?? []
        request.origin = .init(kind: .quantified, tool: route.tool, toolVersion: route.toolVersion)
        request.route = .init(id: route.id, tool: route.tool, toolVersion: route.toolVersion, settings: route.settings)
        request.referenceSet = .init(id: referenceSet.id, layout: referenceSet.layout == .deposit ? .deposit : .lge)
        request.genes = .referenceSetTable(url: genesURL, keeping: features)
        request.notHost = try SalmonQuantRoute.notHostIDs(genesURL).filter(Set(features).contains)
        return request
    }
}
