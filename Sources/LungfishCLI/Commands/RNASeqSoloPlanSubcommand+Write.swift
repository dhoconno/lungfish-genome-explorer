// RNASeqSoloPlanSubcommand+Write.swift - The run of `rnaseq solo-plan`: the libraries, the index, the list and the folder
// (Phase 5.3 lane SOLO-PLAN M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import LungfishWorkflow

extension RNASeqSoloPlanSubcommand {
    /// Refuses, plans and writes the batch. With `--dry-run` it makes the same refusals and writes nothing. A cancel before
    /// the write leaves nothing, and one after it removes the folder.
    func writePlan() async throws -> RNASeqIndexPlanSubcommand.PlanSummary {
        guard globalOptions.threads == nil else {
            throw SoloPlanError("A plan runs STAR with the threads of --request-cpus, 8 when you name none, so --threads does not apply. Leave it out.")
        }
        guard let preset = SoloPlanPreset(rawValue: preset) else {
            throw SoloPlanError("--preset is \(SoloPlanPreset.allCases.map(\.rawValue).joined(separator: ", ")), not \(self.preset).")
        }
        let list = try RNASeqIndexPlanSubcommand.tenxList(tenxFilter)
        guard stagingFolder.hasPrefix("/") else { throw SoloPlanError("--staging-folder must be an absolute path.") }
        let output = outputURL
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw SoloPlanError("The plan folder \(output.lastPathComponent) already exists, so name a new folder or remove this one.")
        }
        let layout = ExecutorPlanStagingLayout(folder: stagingFolder, batch: output.lastPathComponent)
        try ExecutorPlanBatchWriter.checkLayout(layout)
        try ExecutorPlanBatchWriter.checkRequirements(jobRequirements)
        let setFolder = try RNASeqIndexPlanSubcommand.setFolder(for: setReference, storageRoot: storageRoot)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let image = try imageFiles()
        let pins = try SoloPlanPins(
            executor: image.executor, executorBuild: image.executorBuild, imageManifest: image.pin, toolManifest: image.tools)
        // The index and the list are pinned once for every library, so either is refused before a read is listed.
        let index = try Self.adoptedIndex(
            setID: manifest.id, list: list, storageRoot: RNASeqIndexPlanSubcommand.storageRootURL(storageRoot), star: pins.star,
            layout: layout)
        let supplied = try barcodeList.map(Self.measured)
        var jobs: [ExecutorPlanBatchJob] = []
        var samples: [(name: String, figures: SalmonPlanSubmit.Figures)] = []
        for sample in try stagedSamples(layout: layout) {
            try Task.checkCancellation()
            let made = try SoloPlan.make(SoloPlanRequest(
                setFolder: setFolder, sample: sample, pins: pins, preset: preset, index: index, suppliedList: supplied,
                threads: requestCPUs ?? SoloPlan.defaultThreads, expectedCells: expectedCells))
            let figures = try SoloPlanSubmit.figures(
                for: manifest, made: made, memoryMiB: requestMemoryMiB, cpus: requestCPUs ?? made.threads, diskGiB: requestDiskGiB)
            jobs.append(SoloPlanSubmit.job(made, figures: figures))
            samples.append((sample.name, figures))
        }
        let key = index.record.key.folderName
        var lines: [String]
        if dryRun {
            lines = try ExecutorPlanBatchWriter.dryRun(jobs, image: image.record, layout: layout, requirements: jobRequirements)
            lines.insert("Planned \(jobs.count) library(ies) of the set \(manifest.id) on the index \(key).", at: 0)
        } else {
            try ViewerExportLeaf.checkpointAfterStaging()
            let batch = try ExecutorPlanBatchWriter.write(jobs, image: image.record, layout: layout, requirements: jobRequirements, into: output)
            do { try Task.checkCancellation() } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            lines = ["Wrote the plan folder \(batch.folder.path) for \(batch.samples.count) library(ies) of the set \(manifest.id) on the index \(key)."]
            for file in batch.files { lines.append("  \(file.size) bytes  \(file.stagingPath)" + (file.source.map { "  from \($0)" } ?? "")) }
            for job in samples {
                lines.append("The job of \(job.name) asks for \(job.figures.memoryMiB) MiB of memory, \(job.figures.cpus) CPUs and \(job.figures.diskGiB) GiB of disk.")
            }
        }
        let facts: [String: Any] = [
            "setID": manifest.id, "index": key, "preset": preset.rawValue, "output": output.path, "dryRun": dryRun,
            "expectedCells": expectedCells ?? SoloPlan.defaultExpectedCells, "samples": samples.map(\.name),
            "jobs": samples.map { ["sample": $0.name, "memoryMiB": $0.figures.memoryMiB, "cpus": $0.figures.cpus, "diskGiB": $0.figures.diskGiB] as [String: Any] },
        ]
        let json = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .withoutEscapingSlashes])
        return RNASeqIndexPlanSubcommand.PlanSummary(lines: lines, json: String(decoding: json, as: UTF8.self))
    }

    /// The one adopted STAR 2.7.11b index of the set whose 10x filter list is `list`, or with no filter rule when `list` is
    /// nil, read from the records `rnaseq index-adopt` wrote. A set with none, or with more than one, is refused in words.
    static func adoptedIndex(
        setID: String, list: TenxGTFFilter.List?, storageRoot: URL, star: PlanToolPin, layout: ExecutorPlanStagingLayout
    ) throws -> ExecutorPlanStagedIndex {
        let store = STARIndexRecordStore(storageRoot: storageRoot)
        let folder = storageRoot.appendingPathComponent(STARIndexRecordStore.folderName, isDirectory: true)
            .appendingPathComponent(setID, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var keys: [String] = [], others: [String] = []
        for name in names {
            guard let record = try store.find(setID: setID, key: name), record.tool.version == SoloPlan.starVersion else { continue }
            if record.key.gtfFilter?.list == list?.rawValue {
                keys.append(name)
            } else {
                others.append("\(name) (" + (record.key.gtfFilter.map { "--tenx-filter \($0.list)" } ?? "no --tenx-filter") + ")")
            }
        }
        let wanted = list.map { "the 10x filter list \($0.rawValue)" } ?? "no 10x filter rule"
        guard let key = keys.first, keys.count == 1 else {
            if keys.isEmpty {
                let option = list.map { " --tenx-filter \($0.rawValue)" } ?? ""
                let other = others.isEmpty ? "" : " Its adopted STAR \(SoloPlan.starVersion) indexes are \(others.joined(separator: " and ")), "
                    + "so to map on one of them give its option as written."
                throw SoloPlanError("The set \(setID) has no adopted STAR \(SoloPlan.starVersion) index with \(wanted) in this storage "
                    + "root, and a plan never builds one. Plan it with lungfish-cli rnaseq index-plan --set \(setID) --star "
                    + "\(SoloPlan.starVersion)\(option), run that plan on the Linux machine, record the run with lungfish-cli rnaseq "
                    + "index-adopt\(option), then write the plan again.\(other)")
            }
            throw SoloPlanError("The set \(setID) has adopted STAR \(SoloPlan.starVersion) indexes with \(wanted), "
                + "\(keys.joined(separator: " and ")), under \(folder.path), and a plan pins one. Keep the record of the index to map "
                + "on there, then write the plan again.")
        }
        return try ExecutorPlanStagedIndex.pin(setID: setID, key: key, store: store, star: star, layout: layout)
    }

    /// The list file the person gave, by its SHA-256 and size. The plan pins it, and the batch never copies it.
    static func measured(_ path: String) throws -> ExecutorPlanSourceFile {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
            throw SoloPlanError("No barcode list is at \(url.path), so name the file of the preset's whole 10x list.")
        }
        return ExecutorPlanSourceFile(url: url, sha256: try PortableDigest.sha256Hex(ofFileAt: url), size: size)
    }

    /// One library a sample of the sheet, its rows its lanes in the sheet's order, from the staged-reads list. No read is
    /// opened. A row with no r2 is refused, since STARsolo counts 10x pairs.
    func stagedSamples(layout: ExecutorPlanStagingLayout) throws -> [SalmonPlanSample] {
        let staged = try ImportFastqStagedReads.read(stagedReads)
        let pairs: [SamplePair]
        do {
            pairs = try FASTQSampleSheet.parse(url: URL(fileURLWithPath: samplesheet)).samplePairs()
        } catch FASTQSampleSheetError.missingRequiredColumns {
            throw SoloPlanError("The sample sheet \(samplesheet) needs the columns sample, r1 and r2, written comma-separated.")
        }
        var order: [String] = []
        var lanes: [String: [(r1: SalmonPlanStagedRead, r2: SalmonPlanStagedRead)]] = [:]
        for pair in pairs {
            guard let r2 = pair.r2 else {
                throw SoloPlanError("The sample sheet gives \(pair.sampleName) no r2. STARsolo counts 10x pairs, read 1 the barcode and "
                    + "UMI and read 2 the cDNA, so give each lane's r1 and r2.")
            }
            let reads = try staged.inputs(of: pair, files: [pair.r1, r2], layout: layout).map {
                SalmonPlanStagedRead(path: $0.url.path, size: $0.size, sha256: $0.sha256)
            }
            if lanes[pair.sampleName] == nil { order.append(pair.sampleName) }
            lanes[pair.sampleName, default: []].append((r1: reads[0], r2: reads[1]))
        }
        return order.map { SalmonPlan.stagedSample(name: $0, pairs: lanes[$0] ?? []) }
    }

    /// The executor, the tool manifest and the image record of the files the options name, else the app's, as
    /// `rnaseq quant --write-plan` reads them. A tool manifest that is not the one `image.json` pins is refused.
    func imageFiles() throws -> RNASeqQuantImageFiles {
        let defaults = ImportFastqPlanDefaults.bundled()
        guard let manifestPath = executorManifest ?? defaults.executorManifest?.path else {
            throw SoloPlanError(ImportFastqPlanDefaults.noExecutorSentence)
        }
        guard let imagePath = image ?? defaults.image?.path, let toolsPath = imageToolManifest ?? defaults.imageToolManifest?.path else {
            throw SoloPlanError(ImportFastqPlanDefaults.noImageSentence)
        }
        func read<Value>(_ path: String, _ option: String, _ expected: String, _ decode: (Data) throws -> Value) throws -> Value {
            do {
                return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw SoloPlanError("The file \(path) given to \(option) is not \(expected).")
            }
        }
        let executor = try read(manifestPath, "--executor-manifest", "a manifest.json, so name the manifest.json beside the executor you built") {
            try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: $0)
        }
        let (bytes, tools) = try read(toolsPath, "--image-tool-manifest", "a tool manifest, so name the tool manifest that image.json pins") {
            ($0, try ImageToolManifest.decode($0))
        }
        let record = try read(imagePath, "--image", "an image.json, so name the image.json written when the image was built") {
            try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: $0)
        }
        let pin = PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: bytes), size: Int64(bytes.count))
        guard record.imageManifest == pin else {
            throw SoloPlanError("The tool manifest \(toolsPath) is not the one \(imagePath) pins, so name the manifest of that image.")
        }
        return RNASeqQuantImageFiles(
            executor: try executor.sourceFile(besideManifestAt: URL(fileURLWithPath: manifestPath)), executorBuild: executor.build,
            pin: pin, tools: tools, record: record)
    }
}
