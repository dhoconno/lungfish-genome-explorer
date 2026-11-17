// STARPlan+Salmon.swift - The default route on Linux, STAR 2.7.11b TranscriptomeSAM GeneCounts then salmon on STAR's
// transcriptome alignments (Phase 5.3 lane EX-PLAN-STAR milestone 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The program plan's default route (`docs/plans/2026-10-02-architecture-program.md:248`, ADJ-ROUTE item 4): STAR with the
/// argv of `scripts/repro/rnaseq/gse225770/star.sh:42-46` and `--quantMode TranscriptomeSAM GeneCounts` (BIO-LINUX-HOST
/// item 1), then salmon `quant -a` on `Aligned.toTranscriptome.out.bam` against the set's `derived/transcripts.fa`.
extension STARPlan {
    package static let salmonStepID = "salmon-quant"
    package static let transcriptomeBAM = "star/Aligned.toTranscriptome.out.bam"
    package static let quantFolder = "quant"
    /// The STAR version gate GT measured, the one this route maps with.
    package static let defaultRouteSTAR = STARIndexVersion.v2_7_11b.rawValue
    /// nf-core/rnaseq's `--outFilterMultimapNmax` for its STAR then salmon route, which `star.sh` passes.
    package static let defaultRouteMultimapNmax = 20

    /// The salmon pin, after the refusals of this route: single-end reads, another STAR, no salmon in the image, and another
    /// number of loci. The single-end refusal comes first, since no index or image makes the route take them. Gate GT measured
    /// the route on read pairs only (`BIO-GT.md` item 9), and no run has read its argv on single reads, so the plan is refused
    /// for the sample of a bundle and for the sample of a staged sheet alike (SE-M1-BIO R1).
    static func checkDefaultRoute(_ request: STARPlanRequest, setID: String) throws -> PlanToolPin {
        guard request.sample.singles.isEmpty else {
            throw STARPlanError("The STAR then salmon route, --chain star-salmon and star-salmon-errormodel, was measured on read pairs "
                + "only (its gate GT), so Lungfish does not plan it for single-end reads, and the sample \(request.sample.name) holds "
                + "single-end reads. For single-end reads choose salmon, star-2.7.3a-genecounts, star-2.7.11b-genecounts or "
                + "star-2.7.11b-featurecounts.")
        }
        let record = request.index.record
        guard record.tool.version == defaultRouteSTAR else {
            throw STARPlanError("The STAR then salmon route maps with STAR \(defaultRouteSTAR), the version its gate GT measured, "
                + "and the index \(record.key.folderName) was built by STAR \(record.tool.version). Build a \(defaultRouteSTAR) index "
                + "with lungfish-cli rnaseq index-plan --set \(setID) --star \(defaultRouteSTAR), adopt it with lungfish-cli rnaseq "
                + "index-adopt, then write the plan again.")
        }
        guard let salmon = request.pins.salmon else {
            throw STARPlanError("The image's tool manifest lists no single salmon, and the STAR then salmon route counts with it, "
                + "so name an image that holds salmon with --image-tool-manifest.")
        }
        guard request.multimapNmax == nil else { throw STARPlanError(defaultRouteMultimapRefusal) }
        return salmon
    }

    /// The refusal of a number of loci on this route, which maps with nf-core/rnaseq's fixed number. The words name the
    /// option of `lungfish-cli rnaseq quant` that sets the number on the other STAR chains. The command refuses the option
    /// with the two `star-salmon` chains in these words before it plans a sample, and a caller of the API reads them here.
    package static var defaultRouteMultimapRefusal: String {
        "The STAR then salmon route, --chain star-salmon and star-salmon-errormodel, maps with --outFilterMultimapNmax "
            + "\(defaultRouteMultimapNmax), as nf-core/rnaseq's route does, so --star-multimap-nmax does not apply to it. "
            + "Choose star-2.7.11b-genecounts, star-2.7.3a-genecounts or star-2.7.11b-featurecounts to set the number of loci, "
            + "or leave the option out."
    }

    /// The argv of `star.sh align` in its order, with every path relative to the work root, the plan's threads, the
    /// decompressor of gzip reads in place of `gunzip -c`, and STAR 2.7.11b's name for `--quantTranscriptomeBan Singleend`.
    static func defaultRouteArguments(
        _ request: STARPlanRequest, genomeDir: String, mates: [[String]], gzip: Bool, gtfPath: String
    ) -> [String] {
        let name = request.sample.name
        var arguments = ["--genomeDir", genomeDir, "--readFilesIn"] + mates.map { $0.joined(separator: ",") }
        arguments += ["--runThreadN", String(request.threads), "--outFileNamePrefix", "\(starFolder)/", "--outSAMtype", "BAM",
                      "Unsorted", "--sjdbGTFfile", gtfPath, "--outSAMattrRGline", "ID:\(name)", "SM:\(name)",
                      "--quantMode", "TranscriptomeSAM", "GeneCounts", "--twopassMode", "Basic"]
        if gzip { arguments += ["--readFilesCommand", request.pins.decompressor.id, "-d", "-c"] }
        return arguments + ["--runRNGseed", "0", "--outFilterMultimapNmax", String(defaultRouteMultimapNmax),
                            "--alignSJDBoverhangMin", "1", "--outSAMattributes", "NH", "HI", "AS", "NM", "MD",
                            "--quantTranscriptomeSAMoutput", "BanSingleEnd"]
    }

    /// salmon on STAR's transcriptome BAM. `-l A` lets salmon find the library type, as the Mac route does, and its
    /// `lib_format_counts.json` comes home with the other three files ``SalmonQuantFolderReader`` reads. `--errorModel` is
    /// passed only for ``STARPlanAlignmentScoring/errorModel``.
    static func salmonStep(
        _ salmon: PlanToolPin, transcripts: String, threads: Int, scoring: STARPlanAlignmentScoring, deadline: Double
    ) -> PlanStep {
        let reports = SalmonQuantFolderReader.readFiles.map { "\(quantFolder)/\($0)" }
        return PlanStep(
            id: salmonStepID, title: "Count STAR's transcriptome alignments with salmon \(salmon.version)", kind: .tool,
            tool: salmon,
            arguments: ["quant", "-l", "A", "-t", transcripts, "-a", transcriptomeBAM, "-p", String(threads), "-o", quantFolder]
                + (scoring == .errorModel ? ["--errorModel"] : []),
            deadlineSeconds: deadline, inputs: [transcriptomeBAM, transcripts], outputs: reports,
            outputPolicy: Dictionary(uniqueKeysWithValues: reports.map { ($0, PlanOutputPolicy.home) }))
    }

    /// The route's identity. `route.tool` is salmon, the counting tool, and the route id differs from the Mac's salmon on the
    /// reads, so the two never join in one table (ADJ-ROUTE item 11). `alignmentScoring` is `none` or `errorModel`, the
    /// value the adopt checks against the argv, and `alignmentScores` is its record line (ADJ-ROUTE item 5).
    static func defaultRoutePipeline(
        manifest: ReferenceSetManifest, request: STARPlanRequest, gtf: ReferenceSetManifest.DerivedFile, salmon: PlanToolPin
    ) -> PlanPipeline {
        let (pins, scoring, chain) = (request.pins, request.alignmentScoring, request.chain)
        let transcripts = manifest.derived.transcripts
        let chosen: ImportSettingSource = scoring == .none ? .default : .option
        var settings = frameSettings(request) + [
            PlanPipelineSetting(id: "mapping", label: "Mapping",
                                value: "STAR \(pins.star.version) on the genome, --quantMode TranscriptomeSAM GeneCounts --twopassMode "
                                    + "Basic, then salmon \(salmon.version) on STAR's transcriptome alignments (-a)", source: .default),
            PlanPipelineSetting(id: "index", label: "Index", value: request.index.record.key.folderName, source: .default),
            PlanPipelineSetting(id: "multimapNmax", label: "Loci a read may map to",
                                value: "\(defaultRouteMultimapNmax) loci, the --outFilterMultimapNmax \(defaultRouteMultimapNmax) of "
                                    + "nf-core/rnaseq's STAR then salmon route", source: .default),
            PlanPipelineSetting(id: "countingGTF", label: "Genes",
                                value: "\(gtf.path) of the set \(manifest.id), SHA-256 \(gtf.sha256)", source: .default),
            PlanPipelineSetting(id: "transcripts", label: "Transcripts",
                                value: "\(transcripts.path) of the set \(manifest.id), SHA-256 \(transcripts.sha256)", source: .default),
            PlanPipelineSetting(id: "libraryType", label: "Library type", value: "A", source: .default),
            PlanPipelineSetting(id: "alignmentScoring", label: "Alignment scoring", value: scoring.rawValue, source: chosen),
            PlanPipelineSetting(id: "alignmentScores", label: "Alignment scores", value: scoring.recordLine, source: chosen),
            PlanPipelineSetting(id: "counts", label: "Counts", value: "NumReads", source: .default),
            PlanPipelineSetting(id: "geneSums", label: "Gene sums",
                                value: "NumReads summed by gene through the reference set's \(manifest.derived.transcriptGenes.path)",
                                source: .default),
        ]
        settings.sort { $0.id < $1.id }
        return PlanPipeline(
            id: chain.rawValue, version: pipelineVersion, preset: PlanPipelinePreset(id: chain.rawValue, name: chain.presetName),
            modality: .bulk,
            route: PlanPipelineRoute(id: chain.rawValue, tool: salmon.id, toolVersion: salmon.version,
                                     settings: Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0.value) })),
            referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
            settings: settings)
    }

    /// The trim, adapter and duplicates lines of the reads frame, in the words of the salmon chain.
    static func frameSettings(_ request: STARPlanRequest) -> [PlanPipelineSetting] {
        let version = request.pins.trimGalore.version
        var polyGChosen = false
        if case .trimGalore(let polyG) = request.trim { polyGChosen = polyG }
        var settings = [
            PlanPipelineSetting(id: "trimming", label: "Trimming", value: SalmonQuantRecordLines.trimming(request.trim, version: version),
                                source: polyGChosen ? .option : .default),
            PlanPipelineSetting(id: "duplicates", label: "Duplicates", value: request.sample.duplicates,
                                source: request.sample.duplicatesSource),
        ]
        if let adapter = SalmonQuantRecordLines.adapter(request.trim, version: version) {
            settings.append(PlanPipelineSetting(id: "adapter", label: "Adapter", value: adapter, source: .default))
        }
        return settings
    }
}
