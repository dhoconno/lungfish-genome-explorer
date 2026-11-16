// STARPlan.swift - The schema 2 plans of one sample's STAR GeneCounts and featureCounts on Linux (Phase 5.3 lane
// EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The plan of one sample: the reads frame's trim steps (``SalmonPlan/readsFrame(sample:trim:trimTool:deadline:)``),
/// one STAR `--quantMode GeneCounts` call on an index an earlier run staged, and for the featureCounts chain one subread
/// featureCounts call on STAR's BAM and the exons of the set's `derived/genes.gtf`. The argv is the 5.0 scripts'
/// (`scripts/repro/rnaseq/gse304256/star.sh`, `gse290671/run.sh` and `gf_truth.sh`) with every path relative to the work
/// root. STAR and featureCounts read the set's `derived/genes.gtf` by its SHA-256, STAR through the index whose key pins
/// it, and never the annotation as given (BIO-COUNTING-GTF item 4).
package enum STARPlan {
    package static let pipelineVersion = 1
    /// STAR's `--runThreadN` and featureCounts' `-T` when the person names no CPUs, as the 5.0 chains ran.
    package static let defaultThreads = 8
    package static let starStepID = "star-align"
    package static let featureCountsStepID = "featurecounts"
    package static let starFolder = "star"
    /// STAR's two reports the adopt reads, which come home, and its BAM, which stays.
    package static let starReports = ["star/Log.final.out", "star/ReadsPerGene.out.tab"]
    package static let starBAM = "star/Aligned.out.bam"
    /// featureCounts' table and its `.summary`, which come home.
    package static let countTable = "featurecounts/counts.txt"
    package static var featureCountsReports: [String] { [countTable, countTable + ".summary"] }

    package static func make(_ request: STARPlanRequest) throws -> STARPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let gtf = try manifest.requireCountingGTF()
        let (id, pins, sample, index) = (manifest.id, request.pins, request.sample, request.index)
        guard request.threads > 0 else { throw STARPlanError("Threads is a number from 1 up.") }
        guard sample.pairs.isEmpty != sample.singles.isEmpty else {
            let what = sample.pairs.isEmpty ? "holds no reads" : "holds read pairs and single reads, which one STAR run cannot map as one sample"
            throw STARPlanError("The sample \(sample.name) \(what), so no plan was written.")
        }
        if let staged = sample.stagedPaths, staged.count != sample.reads.count {
            throw STARPlanError("The sample \(sample.name) names \(staged.count) reads in the staging folder for its \(sample.reads.count) read files.")
        }
        if let nmax = request.multimapNmax, nmax < 1 {
            throw STARPlanError("--outFilterMultimapNmax is a number of loci from 1 up, and \(nmax) is not.")
        }
        try check(index, set: manifest, gtfSHA256: gtf.sha256, star: pins.star)
        guard request.alignmentScoring == .none || request.chain == .starSalmon else {
            throw STARPlanError("Alignment scoring \(request.alignmentScoring.rawValue) is a setting of the STAR then salmon route, "
                + "and the chain \(request.chain.rawValue) has no salmon step.")
        }
        let salmon = request.chain == .starSalmon ? try checkDefaultRoute(request, setID: id) : nil
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        let frame = SalmonPlan.readsFrame(sample: sample, trim: request.trim, trimTool: pins.trimGalore, deadline: deadline)
        var sources = frame.sources
        sources[ExecutorPlanEmitter.executorPath] = pins.executor.url
        let paired = !frame.r1s.isEmpty
        let mates = paired ? [frame.r1s, frame.r2s] : [frame.singles]
        let reads = mates.flatMap { $0 }
        let gzip = reads.filter { $0.hasSuffix(".gz") }.count
        guard gzip == 0 || gzip == reads.count else {
            throw STARPlanError("The sample \(sample.name) holds gzip reads and plain reads, and STAR reads every file of a run "
                + "through one --readFilesCommand. Give the sample's reads in one form, then write the plan again.")
        }
        let genomeDir = "references/\(id)/indexes/\(index.record.key.folderName)"
        let gtfPath = "references/\(id)/\(gtf.path)"
        var arguments: [String]
        if salmon != nil {
            arguments = defaultRouteArguments(request, genomeDir: genomeDir, mates: mates, gzip: gzip > 0, gtfPath: gtfPath)
        } else {
            arguments = ["--runThreadN", String(request.threads), "--genomeDir", genomeDir, "--readFilesIn"]
                + mates.map { $0.joined(separator: ",") }
            if gzip > 0 { arguments += ["--readFilesCommand", pins.decompressor.id, "-d", "-c"] }
            arguments += ["--outSAMtype", "BAM", "Unsorted", "--quantMode", "GeneCounts", "--outFileNamePrefix", "\(starFolder)/"]
            if let nmax = request.multimapNmax { arguments += ["--outFilterMultimapNmax", String(nmax)] }
        }
        // The default route's transcriptome BAM stays beside the genome BAM, and salmon reads it in the same work root.
        let bams = [starBAM] + (salmon == nil ? [] : [transcriptomeBAM])
        var policy = Dictionary(uniqueKeysWithValues: starReports.map { ($0, PlanOutputPolicy.home) })
        for bam in bams { policy[bam] = .stays }
        var steps = frame.trimSteps
        steps.append(PlanStep(
            id: starStepID, title: "Map the reads with STAR \(pins.star.version) on the index \(index.record.key.folderName)",
            kind: .tool, tool: pins.star, arguments: arguments, deadlineSeconds: deadline,
            inputs: reads + index.entries.map(\.relativePath) + (salmon == nil ? [] : [gtfPath]), outputs: starReports + bams,
            outputPolicy: policy))

        var references = index.entries
        var used = [pins.star] + (request.trim == .none ? [] : [pins.trimGalore]) + (gzip > 0 ? [pins.decompressor] : [])
        if request.chain != .geneCounts {
            references.append(PlanEntry(role: .reference, relativePath: gtfPath, sha256: gtf.sha256, size: gtf.size,
                                        reference: PlanReferenceIdentity(setID: id, path: gtf.path)))
            sources[gtfPath] = request.setFolder.appendingPathComponent(gtf.path)
        }
        if let salmon {
            let transcripts = manifest.derived.transcripts
            let path = "references/\(id)/\(transcripts.path)"
            references.append(PlanEntry(role: .reference, relativePath: path, sha256: transcripts.sha256, size: transcripts.size,
                                        reference: PlanReferenceIdentity(setID: id, path: transcripts.path)))
            sources[path] = request.setFolder.appendingPathComponent(transcripts.path)
            steps.append(salmonStep(salmon, transcripts: path, threads: request.threads, scoring: request.alignmentScoring,
                                    deadline: deadline))
            used.append(salmon)
        }
        if request.chain == .featureCounts {
            steps.append(PlanStep(
                id: featureCountsStepID, title: "Count the exons of \(gtf.path) with featureCounts \(pins.featureCounts.version)",
                kind: .tool, tool: pins.featureCounts,
                arguments: (paired ? ["-p", "--countReadPairs"] : []) + ["-M", "-T", String(request.threads), "-a", gtfPath,
                                                                         "-o", countTable, starBAM],
                deadlineSeconds: deadline, inputs: [starBAM, gtfPath], outputs: featureCountsReports,
                outputPolicy: Dictionary(uniqueKeysWithValues: featureCountsReports.map { ($0, PlanOutputPolicy.home) })))
            used.append(pins.featureCounts)
        }

        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + frame.inputs + references.sorted { $0.relativePath < $1.relativePath },
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: salmon.map { defaultRoutePipeline(manifest: manifest, request: request, gtf: gtf, salmon: $0) }
                ?? pipeline(manifest: manifest, request: request, gtf: gtf, paired: paired),
            sample: PlanSampleValues(
                sampleName: sample.name, originalFilenames: sample.reads.map(\.name),
                originalSizeBytes: sample.reads.reduce(Int64(0)) { $0 + $1.size }, instrument: sample.instrument),
            storage: nil, clumping: nil, graceSeconds: 60, steps: steps)
        _ = try ExecutionPlan.decode(try plan.encoded())
        return STARPlanOutcome(plan: plan, sample: sample, index: index.record.key, threads: request.threads, sources: sources,
                               stagedReferencePaths: index.stagingPaths)
    }
}
