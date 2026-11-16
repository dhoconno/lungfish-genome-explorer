// UMIPlan+Chain.swift - The UMI branch after the layout check: extraction, STAR on the kept read, featureCounts' gene tags,
// samtools and umi_tools count, with the chain's identity and its duplicates words (Phase 5.3 lane EX-UMI, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension UMIPlan {
    static let starStepID = "star-align"
    static let featureCountsStepID = "featurecounts"
    static let sortStepID = "samtools-sort"
    static let indexStepID = "samtools-index"
    static let countStepID = "umi-count"
    package static func extractStepID(pair: Int) -> String { "umi-extract-pair\(pair)" }
    /// The kept read of one pair with the UMI in its name, which stays.
    package static func extractedRead(pair: Int) -> String { "umi/pair\(pair)_R2.umi.fastq.gz" }
    /// `umi_tools extract`'s log of one pair, which comes home for the per-sample report.
    package static func extractLog(pair: Int) -> String { "umi/pair\(pair)-extract.log" }
    package static let starLog = "star/Log.final.out"
    package static let starBAM = "star/Aligned.sortedByCoord.out.bam"
    package static let readCounts = "featurecounts/counts.txt"
    package static let readCountsSummary = "featurecounts/counts.txt.summary"
    /// featureCounts' `-R BAM` copy of STAR's BAM with the XS and XT tags, which featureCounts names after its input.
    package static let taggedBAM = "featurecounts/Aligned.sortedByCoord.out.bam.featureCounts.bam"
    package static let assignedBAM = "umi/assigned.bam"
    package static let assignedIndex = "umi/assigned.bam.bai"
    package static let countTable = "umi/counts.tsv"
    package static let countLog = "umi/count.log"
    /// STAR's `--limitBAMsortRAM` as `gse163196/sample.sh:45` gives it, and samtools sort's `-m`, its default, each a
    /// fixed number in the argv.
    static let bamSortRAM = "8000000000"
    static let sortMemory = "768M"

    /// The steps after the checks: each pair's extraction, then STAR on the kept reads, featureCounts' tags, samtools sort
    /// and index, and umi_tools count per gene (`gse163196/sample.sh:31-68`, routes R and P). Reports come home, and
    /// reads and BAMs stay.
    static func chainSteps(
        _ preset: UMIKitPreset, r1s: [String], r2s: [String], genomeDir: String, gtfPath: String, indexPaths: [String],
        pins: UMIPlanPins, threads: Int, deadline: Double
    ) -> [PlanStep] {
        let cpus = String(threads)
        func step(
            _ id: String, _ title: String, _ tool: PlanToolPin, _ arguments: [String], inputs: [String],
            _ outputs: KeyValuePairs<String, PlanOutputPolicy>
        ) -> PlanStep {
            PlanStep(
                id: id, title: title, kind: .tool, tool: tool, arguments: arguments, deadlineSeconds: deadline, inputs: inputs,
                outputs: outputs.map(\.key), outputPolicy: Dictionary(uniqueKeysWithValues: outputs.map { ($0.key, $0.value) }))
        }
        var steps = zip(r1s, r2s).enumerated().map { n, files -> PlanStep in
            let (pair, read, log) = (n + 1, extractedRead(pair: n + 1), extractLog(pair: n + 1))
            let (umiFile, keptFile) = preset.umiRead == 1 ? (files.0, files.1) : (files.1, files.0)
            return step(
                extractStepID(pair: pair),
                "Move the UMI of pair \(pair) into the names of Read \(preset.keptRead) with umi_tools \(pins.umiTools.version)",
                pins.umiTools,
                preset.extractArguments + ["-I", umiFile, "--read2-in", keptFile, "--read2-stdout", "-S", read, "-L", log],
                inputs: [files.0, files.1], [read: .stays, log: .home])
        }
        let kept = steps.indices.map { extractedRead(pair: $0 + 1) }
        steps.append(step(
            starStepID, "Map Read \(preset.keptRead) alone with STAR \(pins.star.version), unique alignments only", pins.star,
            ["--runThreadN", cpus, "--genomeDir", genomeDir, "--readFilesIn", kept.joined(separator: ","),
             "--readFilesCommand", pins.pigz.id, "-d", "-c", "--outFilterMultimapNmax", "1", "--outSAMtype", "BAM",
             "SortedByCoordinate", "--limitBAMsortRAM", bamSortRAM, "--outFileNamePrefix", "star/"],
            inputs: kept + indexPaths, [starLog: .home, starBAM: .stays]))
        steps.append(step(
            featureCountsStepID, "Tag each read with its gene with featureCounts \(pins.featureCounts.version)", pins.featureCounts,
            ["-T", cpus, "-s", "0", "-a", gtfPath, "-o", readCounts, "-R", "BAM", "--Rpath", "featurecounts", starBAM],
            inputs: [starBAM, gtfPath], [readCounts: .stays, readCountsSummary: .home, taggedBAM: .stays]))
        steps.append(step(
            sortStepID, "Sort the tagged reads with samtools \(pins.samtools.version)", pins.samtools,
            ["sort", "-@", cpus, "-m", sortMemory, "-o", assignedBAM, taggedBAM], inputs: [taggedBAM], [assignedBAM: .stays]))
        steps.append(step(
            indexStepID, "Index the sorted tagged reads with samtools \(pins.samtools.version)", pins.samtools,
            ["index", assignedBAM], inputs: [assignedBAM], [assignedIndex: .stays]))
        steps.append(step(
            countStepID, "Count the UMIs of each gene with umi_tools \(pins.umiTools.version)", pins.umiTools,
            preset.countArguments + ["-I", assignedBAM, "-S", countTable, "-L", countLog],
            inputs: [assignedBAM, assignedIndex], [countTable: .home, countLog: .stays]))
        return steps
    }

    /// The chain's identity. `route.settings` holds every setting that changes counts: the preset's values, the mapping,
    /// the index, the genes by path and SHA-256, what a count is, trimming and duplicates. The check's pairs and bars
    /// decide whether a sample gets counts and change none, so they are in `settings` only.
    static func pipeline(
        _ preset: UMIKitPreset, manifest: ReferenceSetManifest, gtf: ReferenceSetManifest.DerivedFile, index: String,
        pins: UMIPlanPins, duplicates: (words: String, source: ImportSettingSource)
    ) -> PlanPipeline {
        func setting(_ id: String, _ label: String, _ value: String, _ source: ImportSettingSource = .default) -> PlanPipelineSetting {
            PlanPipelineSetting(id: id, label: label, value: value, source: source)
        }
        var settings = settings(preset) + [
            setting("mapping", "Mapping", "STAR \(pins.star.version) on the genome, Read \(preset.keptRead) alone, uniquely mapped "
                + "reads only (--outFilterMultimapNmax 1), --outSAMtype BAM SortedByCoordinate"),
            setting("index", "Index", index),
            setting("countingGTF", "Genes", "\(gtf.path) of the set \(manifest.id), SHA-256 \(gtf.sha256)"),
            setting("counts", "Counts", "umi_tools \(pins.umiTools.version) count per gene in \(countTable): the UMIs of each gene, "
                + "after featureCounts \(pins.featureCounts.version) gives each uniquely mapped Read \(preset.keptRead) to the one "
                + "gene whose exons it overlaps (-R BAM, unstranded -s 0, a read on two genes left uncounted as ambiguous, no -O), "
                + "so a count is molecules and not reads"),
            setting("trimming", "Trimming", SalmonQuantRecordLines.notTrimmed),
            setting("duplicates", "Duplicates", duplicates.words, duplicates.source),
        ]
        settings.sort { $0.id < $1.id }
        let checkOnly: Set = ["umiCheckBars", "umiCheckPairs"]
        let route = settings.filter { !checkOnly.contains($0.id) }.map { ($0.id, $0.value) }
        return PlanPipeline(
            id: pipelineID, version: pipelineVersion, preset: PlanPipelinePreset(id: preset.id, name: preset.label), modality: .bulk,
            route: PlanPipelineRoute(id: pipelineID, tool: pins.umiTools.id, toolVersion: pins.umiTools.version,
                                     settings: Dictionary(uniqueKeysWithValues: route)),
            referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
            settings: settings)
    }

    /// The UMI step in words set from the kit preset. umi_tools' directional method joins a UMI one base from another of
    /// the gene when that one has at least twice its reads less one (`--edit-distance-threshold` 1, its default).
    package static func duplicatesWords(_ preset: UMIKitPreset, umiTools: PlanToolPin) -> String {
        "Duplicates: removed with UMIs by umi_tools \(umiTools.version) count --per-gene --method=directional. The reads of one "
            + "gene that carry one UMI count as one molecule, and a UMI one base from a UMI of the gene with at least twice its "
            + "reads, less one, counts with that UMI. The UMI is the \(preset.umiLength) bases after \(preset.motif) on Read "
            + "\(preset.umiRead) (kit preset \(preset.id))."
    }

    /// The sample form of `duplicates` (`docs/formats/executor-plan.md`, the paragraph on `duplicates`): the UMI step with
    /// source `preset`, then what the import did before it. Reads that the import deduplicated without UMIs are refused,
    /// since the UMI step needs every read to count a molecule by its UMI (the lane's proposal, which BIO reads).
    static func duplicatesEntry(
        _ preset: UMIKitPreset, umiTools: PlanToolPin, sample: SalmonPlanSample
    ) throws -> (words: String, source: ImportSettingSource) {
        let words = duplicatesWords(preset, umiTools: umiTools)
        if sample.duplicatesSource == .recipe {
            throw SalmonPlanError("The sample \(sample.name) lost duplicates at import without UMIs (\(sample.duplicates)). The "
                + "UMI step counts each molecule by its UMI and needs every read the sequencer gave, so no plan was written. "
                + "Import the reads again with duplicates kept, then write the plan again.")
        }
        if sample.duplicatesSource == .default && sample.duplicates == SalmonQuantRecordLines.duplicates {
            return (words + " The import removed none.", .preset)
        }
        if sample.duplicatesSource == .default && sample.duplicates == SalmonPlan.duplicatesNotRecorded {
            return (words + " Whether the reads lost duplicates before this step is Not recorded (the bundle holds no import "
                + "record that names its steps).", .preset)
        }
        throw SalmonPlanError("The sample \(sample.name) states duplicates as \"\(sample.duplicates)\" with source "
            + "\(sample.duplicatesSource.rawValue), which the UMI branch does not read, so no plan was written.")
    }
}
