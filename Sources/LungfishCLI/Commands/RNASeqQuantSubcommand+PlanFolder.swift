// RNASeqQuantSubcommand+PlanFolder.swift - The samples, the jobs and the folder of `rnaseq quant --write-plan` (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import LungfishWorkflow

extension RNASeqCommand.QuantSubcommand {
    /// One sample a row of the sample sheet, from the staged-reads list, with the UMI kit its `kit` column names. The sheet's
    /// `model` column names the instrument, and no read is opened.
    func stagedSamples(layout: ExecutorPlanStagingLayout) throws -> [(sample: SalmonPlanSample, kit: String?)] {
        guard let list = planOptions.stagedReads, let sheetPath = planOptions.samplesheet else { return [] }
        let staged = try ImportFastqStagedReads.read(list)
        let pairs: [SamplePair]
        do {
            pairs = try FASTQSampleSheet.samplePairsAllowingSingleEnd(url: URL(fileURLWithPath: sheetPath))
        } catch FASTQSampleSheetError.missingRequiredColumns {
            throw SalmonPlanError("The sample sheet \(sheetPath) needs the columns sample, r1 and r2, written comma-separated. "
                + "Leave r2 empty for a sample of single-end reads.")
        } catch FASTQSampleSheetError.emptyValue(column: "r1", line: let line) {
            throw SalmonPlanError("Sample sheet line \(line) has an empty r1 value. Name a sample's read file in r1, and leave r2 empty "
                + "for single-end reads.")
        }
        return try pairs.map { pair in
            let reads = try staged.inputs(of: pair, files: [pair.r1] + [pair.r2].compactMap { $0 }, layout: layout).map {
                SalmonPlanStagedRead(path: $0.url.path, size: $0.size, sha256: $0.sha256)
            }
            // A sheet cell with no words gives no instrument, since an empty model names nothing.
            let model = pair.metadata.first { $0.key.lowercased() == "model" }?.value.trimmingCharacters(in: .whitespaces)
            let kit = pair.metadata.first { $0.key.lowercased() == "kit" }?.value.trimmingCharacters(in: .whitespaces)
            let instrument = model?.isEmpty == false ? model : nil
            // A row with an empty r2 cell is one sample with one read file, which the plan takes as a single read.
            let sample = pair.r2 == nil
                ? SalmonPlan.stagedSample(name: pair.sampleName, pairs: [], singles: [reads[0]], model: instrument)
                : SalmonPlan.stagedSample(name: pair.sampleName, pairs: [(r1: reads[0], r2: reads[1])], model: instrument)
            return (sample, kit?.isEmpty == false ? kit : nil)
        }
    }

    /// Refuses a staged sheet whose rows mix one read file and a read pair, before any plan, on every chain and with or without
    /// `--trim`. The batch writer refuses such a mix only when the trim steps differ, and then in its generic words, and an
    /// untrimmed mix would write a batch whose samples no adopt can take together (SE-M1-BIO R2). It is the plan route's rule
    /// for a batch, and it names the first sample of each layout, as the kit rule below names the first of each kind.
    static func checkOneLayout(_ samples: [SalmonPlanSample]) throws {
        guard let single = samples.first(where: { $0.pairs.isEmpty }), let pair = samples.first(where: { !$0.pairs.isEmpty }) else { return }
        throw SalmonPlanError("The sample sheet gives \(single.name) one read file and \(pair.name) a read pair. A plan folder holds "
            + "samples of one layout, so write the single-end samples and the pairs in two plan folders.")
    }

    /// The UMI branch's plan of each sample, on the set's adopted STAR 2.7.11b index, with the request rule of a UMI job.
    /// The kit's preset fixes the chain, so a sheet that names a kit for some samples only, and --chain, --trim, --k or
    /// --decoys beside a kit, are refused.
    func umiPlanJobs(
        setFolder: URL, root: URL, manifest: ReferenceSetManifest, layout: ExecutorPlanStagingLayout, image: RNASeqQuantImageFiles,
        samples: [(sample: SalmonPlanSample, kit: String?)]
    ) throws -> RNASeqQuantPlanJobs {
        let options = planOptions
        if let none = samples.first(where: { $0.kit == nil }), let named = samples.first(where: { $0.kit != nil }) {
            throw SalmonPlanError("The sample sheet names a UMI kit for \(named.sample.name) and none for \(none.sample.name). A "
                + "plan folder counts its samples one way, so write the samples with a kit and those without in two plan folders.")
        }
        let fixed = "The sample sheet's kit column picks the UMI branch, whose steps the kit's preset fixes"
        guard options.chain == nil else { throw SalmonPlanError("\(fixed), so leave out --chain.") }
        guard !trim else { throw SalmonPlanError("\(fixed) with the reads untrimmed, so leave out --trim.") }
        guard k == 31, decoys == "genome" else {
            throw SalmonPlanError("\(fixed) on a STAR index, and --k and --decoys pick a salmon index, so leave out --k and --decoys.")
        }
        let pins = try UMIPlanPins(
            executor: image.executor, executorBuild: image.executorBuild, imageManifest: image.pin, toolManifest: image.tools,
            star: .v2_7_11b)
        // The index is pinned once for every sample, so a missing one is refused before any plan is made.
        let index = try Self.adoptedIndex(setID: manifest.id, version: .v2_7_11b, storageRoot: root, star: pins.star, layout: layout)
        var result = RNASeqQuantPlanJobs(key: index.record.key.folderName, jobs: [], samples: [])
        for (sample, kit) in samples {
            try Task.checkCancellation()
            let made = try UMIPlan.make(UMIPlanRequest(
                setFolder: setFolder, sample: sample, kit: kit ?? "", pins: pins, index: index,
                threads: options.requestCPUs ?? STARPlan.defaultThreads))
            let figures = try UMIPlanSubmit.figures(
                for: manifest, made: made, memoryMiB: options.requestMemoryMiB, cpus: options.requestCPUs, diskGiB: options.requestDiskGiB)
            result.jobs.append(UMIPlan.job(made, figures: figures))
            result.samples.append((sample.name, figures))
        }
        return result
    }

    /// Refuses, plans and writes the batch. With `--dry-run` it makes the same refusals and writes nothing. A cancel before
    /// the write leaves nothing, and one after it removes the folder.
    func writePlanFolder() async throws -> RNASeqIndexPlanSubcommand.PlanSummary {
        let options = planOptions
        guard let target = options.writePlan, let staging = options.stagingFolder else { throw SalmonPlanError("--write-plan needs a folder.") }
        let output = URL(fileURLWithPath: target).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw SalmonPlanError("The plan folder \(output.lastPathComponent) already exists, so name a new folder or remove this one.")
        }
        let layout = ExecutorPlanStagingLayout(folder: staging, batch: output.lastPathComponent)
        try ExecutorPlanBatchWriter.checkLayout(layout)
        try ExecutorPlanBatchWriter.checkRequirements(options.jobRequirements)
        let (setFolder, root) = (try RNASeqIndexPlanSubcommand.setFolder(for: setID, storageRoot: storageRoot),
                                 RNASeqIndexPlanSubcommand.storageRootURL(storageRoot))
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let image = try imageFiles()
        let staged = try stagedSamples(layout: layout)
        // A sheet with a kit goes to the UMI branch, whose planner refuses a single-end sample in its own words.
        if staged.allSatisfy({ $0.kit == nil }) { try Self.checkOneLayout(staged.map(\.sample)) }
        let planned: RNASeqQuantPlanJobs
        var rule: String?
        if staged.contains(where: { $0.kit != nil }) {
            planned = try umiPlanJobs(setFolder: setFolder, root: root, manifest: manifest, layout: layout, image: image, samples: staged)
            rule = UMIPlanSubmit.words(for: manifest, threads: options.requestCPUs ?? STARPlan.defaultThreads)
        } else if let star = options.chain?.star {
            planned = try await starPlanJobs(
                star, setFolder: setFolder, root: root, manifest: manifest, layout: layout, image: image, samples: staged.map(\.sample))
        } else {
            planned = try await salmonPlanJobs(
                setFolder: setFolder, root: root, manifest: manifest, image: image, samples: staged.map(\.sample))
        }
        let (key, record) = (planned.key, image.record)
        var lines: [String]
        if options.dryRun {
            lines = try ExecutorPlanBatchWriter.dryRun(planned.jobs, image: record, layout: layout, requirements: options.jobRequirements)
            lines.insert("Planned \(planned.jobs.count) sample(s) of the set \(manifest.id) on the index \(key).", at: 0)
        } else {
            try ViewerExportLeaf.checkpointAfterStaging()
            let batch = try ExecutorPlanBatchWriter.write(
                planned.jobs, image: record, layout: layout, requirements: options.jobRequirements, into: output)
            do { try Task.checkCancellation() } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            lines = ["Wrote the plan folder \(batch.folder.path) for \(batch.samples.count) sample(s) of the set \(manifest.id) on the index \(key)."]
            for file in batch.files { lines.append("  \(file.size) bytes  \(file.stagingPath)" + (file.source.map { "  from \($0)" } ?? "")) }
            for job in planned.samples {
                lines.append("The job of \(job.name) asks for \(job.figures.memoryMiB) MiB of memory, \(job.figures.cpus) CPUs and \(job.figures.diskGiB) GiB of disk.")
            }
        }
        if let rule { lines.append(rule) }
        let facts: [String: Any] = [
            "setID": manifest.id, "index": key, "output": output.path, "dryRun": options.dryRun, "samples": planned.samples.map(\.name),
            "jobs": planned.samples.map { ["sample": $0.name, "memoryMiB": $0.figures.memoryMiB, "cpus": $0.figures.cpus, "diskGiB": $0.figures.diskGiB] as [String: Any] },
        ]
        let json = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .withoutEscapingSlashes])
        return RNASeqIndexPlanSubcommand.PlanSummary(lines: lines, json: String(decoding: json, as: UTF8.self))
    }

    /// salmon's plan of each sample on the index this Mac published for the set, k and decoys.
    func salmonPlanJobs(
        setFolder: URL, root: URL, manifest: ReferenceSetManifest, image: RNASeqQuantImageFiles, samples staged: [SalmonPlanSample]
    ) async throws -> RNASeqQuantPlanJobs {
        let options = planOptions
        let pins = try SalmonPlanPins(
            executor: image.executor, executorBuild: image.executorBuild, imageManifest: image.pin, toolManifest: image.tools)
        let trimChoice: SalmonQuantTrim = trim ? .trimGalore(polyG: polyGTrimming == "on") : .none
        let decoyChoice: SalmonIndexDecoys = decoys == "none" ? .none : .genome
        // The index is pinned once for every sample, so a missing one is refused before any read is hashed.
        let pin = try SalmonPlan.pinIndex(setID: manifest.id, storageRoot: root, pins: pins, k: k, decoys: decoyChoice)
        var result = RNASeqQuantPlanJobs(key: pin.key.folderName, jobs: [], samples: [])
        for sample in try await bundleSamples(or: staged) {
            try Task.checkCancellation()
            let made = try SalmonPlan.make(SalmonPlanRequest(
                setFolder: setFolder, storageRoot: root, sample: sample, pins: pins, trim: trimChoice, k: k, decoys: decoyChoice,
                threads: options.requestCPUs ?? SalmonPlan.defaultThreads, index: pin))
            let figures = try SalmonPlanSubmit.figures(
                for: manifest, made: made, memoryMiB: options.requestMemoryMiB, cpus: options.requestCPUs, diskGiB: options.requestDiskGiB)
            result.jobs.append(SalmonPlanSubmit.job(made, figures: figures))
            result.samples.append((sample.name, figures))
        }
        return result
    }
}
