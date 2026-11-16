// RNASeqQuantSubcommand+PlanFolder.swift - The samples, the jobs and the folder of `rnaseq quant --write-plan` (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import LungfishWorkflow

extension RNASeqCommand.QuantSubcommand {
    /// One sample a row of the sample sheet, from the staged-reads list. The sheet's `model` column names the instrument, and
    /// no read is opened.
    func stagedSamples(layout: ExecutorPlanStagingLayout) throws -> [SalmonPlanSample] {
        guard let list = planOptions.stagedReads, let sheetPath = planOptions.samplesheet else { return [] }
        let staged = try ImportFastqStagedReads.read(list)
        let pairs: [SamplePair]
        do {
            pairs = try FASTQSampleSheet.parse(url: URL(fileURLWithPath: sheetPath)).samplePairs()
        } catch FASTQSampleSheetError.missingRequiredColumns {
            throw SalmonPlanError("The sample sheet \(sheetPath) needs the columns sample, r1 and r2, written comma-separated.")
        }
        return try pairs.map { pair in
            let reads = try staged.inputs(of: pair, files: [pair.r1] + [pair.r2].compactMap { $0 }, layout: layout).map {
                SalmonPlanStagedRead(path: $0.url.path, size: $0.size, sha256: $0.sha256)
            }
            // A sheet cell with no words gives no instrument, since an empty model names nothing.
            let model = pair.metadata.first { $0.key.lowercased() == "model" }?.value.trimmingCharacters(in: .whitespaces)
            return SalmonPlan.stagedSample(
                name: pair.sampleName, pairs: [(r1: reads[0], r2: reads[1])], model: model?.isEmpty == false ? model : nil)
        }
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
        let (pins, record) = try imagePins()
        var samples = try stagedSamples(layout: layout)
        let trimChoice: SalmonQuantTrim = trim ? .trimGalore(polyG: polyGTrimming == "on") : .none
        let decoyChoice: SalmonIndexDecoys = decoys == "none" ? .none : .genome
        // The index is pinned once for every sample, so a missing one is refused before any read is hashed.
        let pin = try SalmonPlan.pinIndex(setID: manifest.id, storageRoot: root, pins: pins, k: k, decoys: decoyChoice)
        if samples.isEmpty {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-quant-plan-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            for bundle in bundles {
                try Task.checkCancellation()
                samples.append(try await SalmonPlan.sample(bundle: URL(fileURLWithPath: bundle, isDirectory: true), scratch: scratch))
            }
        }
        var jobs: [(made: SalmonPlanOutcome, figures: SalmonPlanSubmit.Figures)] = []
        for sample in samples {
            try Task.checkCancellation()
            let made = try SalmonPlan.make(SalmonPlanRequest(
                setFolder: setFolder, storageRoot: root, sample: sample, pins: pins, trim: trimChoice, k: k, decoys: decoyChoice,
                threads: options.requestCPUs ?? SalmonPlan.defaultThreads, index: pin))
            let figures = try SalmonPlanSubmit.figures(
                for: manifest, made: made, memoryMiB: options.requestMemoryMiB, cpus: options.requestCPUs, diskGiB: options.requestDiskGiB)
            jobs.append((made, figures))
        }
        let key = pin.key.folderName
        var lines: [String]
        if options.dryRun {
            lines = try ExecutorPlanBatchWriter.dryRun(
                jobs.map { SalmonPlanSubmit.job($0.made, figures: $0.figures) }, image: record, layout: layout, requirements: options.jobRequirements)
            lines.insert("Planned \(jobs.count) sample(s) of the set \(manifest.id) on the index \(key).", at: 0)
        } else {
            try ViewerExportLeaf.checkpointAfterStaging()
            let batch = try SalmonPlanSubmit.write(jobs, image: record, layout: layout, requirements: options.jobRequirements, into: output)
            do { try Task.checkCancellation() } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            lines = ["Wrote the plan folder \(batch.folder.path) for \(batch.samples.count) sample(s) of the set \(manifest.id) on the index \(key)."]
            for file in batch.files { lines.append("  \(file.size) bytes  \(file.stagingPath)" + (file.source.map { "  from \($0)" } ?? "")) }
            for job in jobs {
                lines.append("The job of \(job.made.sample.name) asks for \(job.figures.memoryMiB) MiB of memory, \(job.figures.cpus) CPUs and \(job.figures.diskGiB) GiB of disk.")
            }
        }
        let facts: [String: Any] = [
            "setID": manifest.id, "index": key, "output": output.path, "dryRun": options.dryRun, "samples": jobs.map { $0.made.sample.name },
            "jobs": jobs.map { ["sample": $0.made.sample.name, "memoryMiB": $0.figures.memoryMiB, "cpus": $0.figures.cpus, "diskGiB": $0.figures.diskGiB] as [String: Any] },
        ]
        let json = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .withoutEscapingSlashes])
        return RNASeqIndexPlanSubcommand.PlanSummary(lines: lines, json: String(decoding: json, as: UTF8.self))
    }
}
