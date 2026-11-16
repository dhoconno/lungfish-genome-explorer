// SoloPlan.swift - The schema 2 plan of one 10x library's STARsolo counts on Linux (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The plan of one library on the reads frame of ``SalmonPlan/readsFrame(sample:trim:trimTool:deadline:)`` with no trim
/// step, since a trimmer would cut read 1's barcode and UMI: one STAR 2.7.11b call with the argv of
/// `scripts/repro/rnaseq/tenx-controls/run.sh:188-196`, the preset's `solo_args` and `--readFilesIn R2 R1`, on an index an
/// earlier run staged. STARsolo reads its genes only through the index, so the step names no GTF, and the plan takes BIO
/// item 4's facts from the index's adopted record (ARCH-SOLO-GTF item 5, BIO-SOLO-GTF items 4 and 6).
package enum SoloPlan {
    package static let pipelineID = "starsolo"
    package static let pipelineVersion = 1
    /// GeneFull_Ex50pAS, EmptyDrops_CR, MultiGeneUMI_CR and `--clipAdapterType CellRanger4` need a STAR of 2.7.9a or later,
    /// and the image holds 2.7.11b, the STAR of the 5.0 runs.
    package static let starVersion = "2.7.11b"
    /// `--runThreadN` when the person names no CPUs, as EX-PLAN-STAR's chains run.
    package static let defaultThreads = 8
    /// STAR's default expected cells for `EmptyDrops_CR`, which 5.0 took where Cell Ranger's metrics name none.
    package static let defaultExpectedCells = 3000
    /// The values of `ed_args` after the expected cells (`run.sh:172-176`).
    package static let emptyDropsArguments = ["0.99", "10", "45000", "90000", "500", "0.01", "20000", "0.01", "10000"]
    package static let stepID = "starsolo"
    package static let folder = "solo"
    /// The matrices whose files come home: `Gene` for the exon presets and GX, `GeneFull_Ex50pAS` for the introns preset.
    package static let homeFeatures = ["Gene", "GeneFull_Ex50pAS"]

    /// `Log.final.out` and, for each feature of ``homeFeatures``, the raw and filtered matrix files and `Summary.csv`, so
    /// `SingleCellFolderReader.read` and GX read the returned `solo/` folder.
    package static var reports: [String] {
        ["\(folder)/Log.final.out"] + homeFeatures.flatMap { feature in
            ["raw", "filtered"].flatMap { matrix in
                ["barcodes.tsv", "features.tsv", "matrix.mtx"].map { "\(folder)/Solo.out/\(feature)/\(matrix)/\($0)" }
            } + ["\(folder)/Solo.out/\(feature)/Summary.csv"]
        }
    }

    package static func make(_ request: SoloPlanRequest) throws -> SoloPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let gtf = try manifest.requireCountingGTF()
        let (id, pins, sample, index) = (manifest.id, request.pins, request.sample, request.index)
        guard request.threads > 0 else { throw SoloPlanError("Threads is a number from 1 up.") }
        let cells = request.expectedCells ?? defaultExpectedCells
        guard cells > 0 else { throw SoloPlanError("Expected cells is a number from 1 up, and \(cells) is not.") }
        guard !sample.pairs.isEmpty, sample.singles.isEmpty else {
            throw SoloPlanError("The sample \(sample.name) holds \(sample.pairs.isEmpty ? "no read pairs" : "single reads beside its pairs"). "
                + "STARsolo counts 10x pairs, read 1 the barcode and UMI and read 2 the cDNA, so give each lane's read 1 and read 2.")
        }
        if let staged = sample.stagedPaths, staged.count != sample.reads.count {
            throw SoloPlanError("The sample \(sample.name) names \(staged.count) reads in the staging folder for its \(sample.reads.count) read files.")
        }
        guard sample.duplicatesSource != .recipe else {
            throw SoloPlanError("The reads of \(sample.name) lost duplicates at import, without UMIs, so molecules that STARsolo "
                + "counts by UMI are gone. Import the reads again with no deduplicating step, then write the plan again.")
        }
        try check(index, set: manifest, gtfSHA256: gtf.sha256, star: pins.star)
        let list = try SoloPlanBarcodes.choose(preset: request.preset, supplied: request.suppliedList, imageFiles: pins.imageFiles)
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        let frame = SalmonPlan.readsFrame(sample: sample, trim: .none, trimTool: pins.star, deadline: deadline)
        var sources = frame.sources
        sources[ExecutorPlanEmitter.executorPath] = pins.executor.url
        let reads = frame.r2s + frame.r1s
        let gzip = reads.filter { $0.hasSuffix(".gz") }.count
        guard gzip == 0 || gzip == reads.count else {
            throw SoloPlanError("The sample \(sample.name) holds gzip reads and plain reads, and STAR reads every file of a run "
                + "through one --readFilesCommand. Give the sample's reads in one form, then write the plan again.")
        }
        let key = index.record.key.folderName
        var arguments = ["--runThreadN", String(request.threads), "--genomeDir", "references/\(id)/indexes/\(key)",
                         "--readFilesIn", frame.r2s.joined(separator: ","), frame.r1s.joined(separator: ",")]
        if gzip > 0 { arguments += ["--readFilesCommand", pins.decompressor.id, "-d", "-c"] }
        arguments += ["--soloType", "CB_UMI_Simple", "--soloCBstart", "1", "--soloCBlen", "16", "--soloUMIstart", "17",
                      "--soloCBwhitelist", list.list.relativePath] + request.preset.arguments
        arguments += ["--soloCBmatchWLtype", "1MM_multi_Nbase_pseudocounts", "--soloUMIfiltering", "MultiGeneUMI_CR",
                      "--soloUMIdedup", "1MM_CR", "--soloCellFilter", "EmptyDrops_CR", String(cells)] + emptyDropsArguments
        arguments += ["--soloFeatures", "Gene", "GeneFull", "GeneFull_Ex50pAS", "--outSAMtype", "None",
                      "--outFileNamePrefix", "\(folder)/"]
        let step = PlanStep(
            id: stepID, title: "Count the cells' UMIs with STARsolo \(pins.star.version) on the index \(key)", kind: .tool,
            tool: pins.star, arguments: arguments, deadlineSeconds: deadline,
            inputs: reads + [list.list.relativePath] + index.entries.map(\.relativePath), outputs: reports,
            outputPolicy: Dictionary(uniqueKeysWithValues: reports.map { ($0, PlanOutputPolicy.home) }))

        let used = [pins.star] + (gzip > 0 ? [pins.decompressor] : [])
        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + frame.inputs + index.entries + [list.entry],
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: pipeline(manifest: manifest, request: request, gtfSHA256: gtf.sha256, list: list, cells: cells),
            sample: PlanSampleValues(
                sampleName: sample.name, originalFilenames: sample.reads.map(\.name),
                originalSizeBytes: sample.reads.reduce(Int64(0)) { $0 + $1.size }, instrument: sample.instrument),
            storage: nil, clumping: nil, graceSeconds: 60, steps: [step])
        _ = try ExecutionPlan.decode(try plan.encoded())
        return SoloPlanOutcome(plan: plan, sample: sample, index: index.record.key, barcodeList: list, threads: request.threads,
                               sources: sources, stagedReferencePaths: index.stagingPaths)
    }

    /// The index must be of this set and its `derived/genes.gtf`, built by the STAR that maps. A bulk index, with no
    /// `gtfFilter`, is taken too, and the plan says no 10x filter rule ran (SOLO-PLAN-M1-BIO R4).
    static func check(_ index: ExecutorPlanStagedIndex, set manifest: ReferenceSetManifest, gtfSHA256: String, star: PlanToolPin) throws {
        let (record, key) = (index.record, index.record.key.folderName)
        guard record.setID == manifest.id, record.key.setID == manifest.id else {
            throw SoloPlanError("The index \(key) is an index of the set \(record.setID), and this plan counts on the set "
                + "\(manifest.id). Pin the index of the set \(manifest.id).")
        }
        guard record.key.countingGTFSHA256 == gtfSHA256 else {
            throw SoloPlanError("The index \(key) was built from a derived/genes.gtf with SHA-256 \(record.key.countingGTFSHA256), "
                + "and the set \(manifest.id)'s derived/genes.gtf has SHA-256 \(gtfSHA256), so the index's genes are not the "
                + "set's. Build it again with lungfish-cli rnaseq index-plan --set \(manifest.id) --star \(starVersion), run "
                + "that plan and adopt it.")
        }
        guard star.id == "STAR", star.version == starVersion, record.tool.version == starVersion else {
            throw SoloPlanError("STARsolo's options in this plan (GeneFull_Ex50pAS, EmptyDrops_CR, MultiGeneUMI_CR and "
                + "--clipAdapterType CellRanger4) need STAR \(starVersion), and the plan maps with STAR \(star.version) on an "
                + "index built by STAR \(record.tool.version). Pin an index built with lungfish-cli rnaseq index-plan --star "
                + "\(starVersion) and map with STAR \(starVersion).")
        }
    }
}
