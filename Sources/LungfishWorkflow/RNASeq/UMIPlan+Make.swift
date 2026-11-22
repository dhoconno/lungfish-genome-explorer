// UMIPlan+Make.swift - One sample's plan of the UMI branch: the reads frame and each pair's layout check (Phase 5.3
// lane EX-UMI, milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// What a UMI plan takes beside the set and the reads: the executor, the image's tool manifest pin, the decompressor the
/// check and STAR's `--readFilesCommand` read gzip through, and each tool the chain runs, with the python3 that runs
/// umi_tools, since `tools` holds every program a step runs or starts (`docs/formats/executor-plan.md`, The `tool` step).
package struct UMIPlanPins: Sendable {
    package var executor: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var pigz: PlanToolPin
    package var star: PlanToolPin
    package var featureCounts: PlanToolPin
    package var samtools: PlanToolPin
    package var umiTools: PlanToolPin
    package var python: PlanToolPin

    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin, pigz: PlanToolPin,
        star: PlanToolPin, featureCounts: PlanToolPin, samtools: PlanToolPin, umiTools: PlanToolPin, python: PlanToolPin
    ) {
        self.executor = executor
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.pigz = pigz
        self.star = star
        self.featureCounts = featureCounts
        self.samtools = samtools
        self.umiTools = umiTools
        self.python = python
    }

    /// The pins of STAR `version` and pigz (``STARIndexPlanPins``), of featureCounts, samtools and umi_tools, each listed
    /// once in the image's manifest, and of the python3 in umi_tools' own folder, the interpreter that runs it.
    package init(
        executor: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild, imageManifest: PlanImageManifestPin,
        toolManifest: ImageToolManifest, star version: STARIndexVersion
    ) throws {
        let index = try STARIndexPlanPins(
            executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, toolManifest: toolManifest,
            star: version)
        func pin(_ id: String) throws -> PlanToolPin {
            guard let pin = try? toolManifest.pin(forToolID: id) else {
                throw SalmonPlanError("The image's tool manifest lists no single \(id), so name an image that holds it with "
                    + "--image-tool-manifest.")
            }
            return pin
        }
        let umiTools = try pin("umi_tools")
        guard let path = toolManifest.tool(matching: umiTools)?.path, let slash = path.lastIndex(of: "/"),
              let python = toolManifest.tools.first(where: { $0.id == "python3" && $0.path == path[..<slash] + "/python3" })
        else {
            throw SalmonPlanError("The image's tool manifest lists no python3 beside umi_tools, the interpreter that runs it, so "
                + "name an image that holds it with --image-tool-manifest.")
        }
        self.init(
            executor: executor, executorBuild: executorBuild, imageManifest: imageManifest, pigz: index.decompressor,
            star: index.star, featureCounts: try pin("featureCounts"), samtools: try pin("samtools"), umiTools: umiTools,
            python: python.pin)
    }
}

package struct UMIPlanRequest: Sendable {
    package var setFolder: URL
    package var sample: SalmonPlanSample
    /// The sample sheet's kit column.
    package var kit: String
    package var pins: UMIPlanPins
    /// STAR's index an earlier run staged, pinned once a command from its adopted record. A plan never builds one.
    package var index: ExecutorPlanStagedIndex
    /// STAR's `--runThreadN`, featureCounts' `-T` and samtools sort's `-@`, a fixed number in the argv and the job's CPUs.
    package var threads: Int
    package var deadlineSeconds: Double?

    package init(
        setFolder: URL, sample: SalmonPlanSample, kit: String, pins: UMIPlanPins, index: ExecutorPlanStagedIndex,
        threads: Int = STARPlan.defaultThreads, deadlineSeconds: Double? = nil
    ) {
        self.setFolder = setFolder
        self.sample = sample
        self.kit = kit
        self.pins = pins
        self.index = index
        self.threads = threads
        self.deadlineSeconds = deadlineSeconds
    }
}

package struct UMIPlanOutcome: ReadsPlanOutcome {
    package var plan: ExecutionPlan
    package var sample: SalmonPlanSample
    package var preset: UMIKitPreset
    package var index: STARIndexKey
    /// The threads of the argv, which the job's CPUs equal.
    package var threads: Int
    package var sources: [String: URL]
    /// Each index entry's `relativePath` to its absolute path in the staging folder, a submit value.
    package var stagedReferencePaths: [String: String]
}

extension UMIPlan {
    /// The plan of one sample whose sheet names a UMI kit: the reads frame untrimmed, one layout check a pair, the first
    /// steps of the branch, then the chain (``chainSteps(_:r1s:r2s:genomeDir:gtfPath:indexPaths:pins:threads:deadline:)``)
    /// on STAR's staged index of the set and the set's `derived/genes.gtf` by SHA-256.
    package static func make(_ request: UMIPlanRequest) throws -> UMIPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let gtf = try manifest.requireCountingGTF()
        let (sample, pins, index) = (request.sample, request.pins, request.index)
        let preset = try preset(kit: request.kit)
        guard request.threads > 0 else { throw SalmonPlanError("Threads is a number from 1 up.") }
        guard !sample.pairs.isEmpty, sample.singles.isEmpty else {
            throw SalmonPlanError("The sample \(sample.name) needs read pairs, since the \(preset.id) kit holds its UMI on "
                + "Read \(preset.umiRead) and its transcript on Read \(preset.keptRead), so no plan was written.")
        }
        if let staged = sample.stagedPaths, staged.count != sample.reads.count {
            throw SalmonPlanError("The sample \(sample.name) names \(staged.count) reads in the staging folder for its \(sample.reads.count) read files.")
        }
        let duplicates = try duplicatesEntry(preset, umiTools: pins.umiTools, sample: sample)
        try STARPlan.check(index, set: manifest, gtfSHA256: gtf.sha256, star: pins.star)
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        let frame = try SalmonPlan.readsFrame(sample: sample, trim: .none, trimTool: pins.pigz, deadline: deadline)
        var sources = frame.sources
        sources[ExecutorPlanEmitter.executorPath] = pins.executor.url
        let gtfPath = "references/\(manifest.id)/\(gtf.path)"
        sources[gtfPath] = request.setFolder.appendingPathComponent(gtf.path)
        let references = index.entries + [PlanEntry(
            role: .reference, relativePath: gtfPath, sha256: gtf.sha256, size: gtf.size,
            reference: PlanReferenceIdentity(setID: manifest.id, path: gtf.path))]
        let checks = zip(frame.r1s, frame.r2s).enumerated().map { n, files in
            checkStep(preset, pair: n + 1, r1: files.0, r2: files.1, decompressor: pins.pigz, executor: pins.executorBuild,
                      deadline: deadline)
        }
        let key = index.record.key.folderName
        let chain = chainSteps(
            preset, r1s: frame.r1s, r2s: frame.r2s, genomeDir: "references/\(manifest.id)/indexes/\(key)", gtfPath: gtfPath,
            indexPaths: index.entries.map(\.relativePath), pins: pins, threads: request.threads, deadline: deadline)
        let used = [executorPin(pins.executorBuild), pins.pigz, pins.star, pins.featureCounts, pins.samtools, pins.umiTools, pins.python]
        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + frame.inputs + references.sorted { $0.relativePath < $1.relativePath },
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: pipeline(preset, manifest: manifest, gtf: gtf, index: key, pins: pins, duplicates: duplicates),
            sample: PlanSampleValues(
                sampleName: sample.name, originalFilenames: sample.reads.map(\.name),
                originalSizeBytes: sample.reads.reduce(Int64(0)) { $0 + $1.size }, instrument: sample.instrument),
            storage: nil, clumping: nil, graceSeconds: 60, steps: checks + chain)
        _ = try ExecutionPlan.decode(try plan.encoded())
        return UMIPlanOutcome(
            plan: plan, sample: sample, preset: preset, index: index.record.key, threads: request.threads, sources: sources,
            stagedReferencePaths: index.stagingPaths)
    }

    /// The job of `made` with `figures`: the frame's job, whose staged reads are read where they sit, with each index file
    /// read where the index batch left it, as a STAR job's (``STARPlanSubmit/job(_:figures:)``).
    package static func job(_ made: UMIPlanOutcome, figures: SalmonPlanSubmit.Figures) -> ExecutorPlanBatchJob {
        var job = SalmonPlanSubmit.job(made, figures: figures)
        job.stagedReferencePaths = made.stagedReferencePaths
        return job
    }

    /// Writes the batch folder of the samples' plans through ``ExecutorPlanBatchWriter``, which returns each `home` output
    /// into `<batch>/<sample>/result/`. The figures are the caller's, and the request rule of a UMI job is the CLI's.
    @discardableResult
    package static func write(
        _ jobs: [(made: UMIPlanOutcome, figures: SalmonPlanSubmit.Figures)], image: ExecutorPlanImageRecord,
        layout: ExecutorPlanStagingLayout, requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        try ExecutorPlanBatchWriter.write(
            jobs.map { job($0.made, figures: $0.figures) }, image: image, layout: layout, requirements: requirements, into: folder)
    }
}
