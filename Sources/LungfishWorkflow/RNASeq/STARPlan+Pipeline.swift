// STARPlan+Pipeline.swift - The index check and the identity of a STAR plan (Phase 5.3 lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension STARPlan {
    /// The index must be this set's, built from the set's `derived/genes.gtf` by SHA-256 (its key pins it), and mapped by
    /// the STAR that built it. Each mismatch is refused in words that say what to do.
    static func check(_ index: ExecutorPlanStagedIndex, set manifest: ReferenceSetManifest, gtfSHA256: String, star: PlanToolPin) throws {
        let (record, key) = (index.record, index.record.key.folderName)
        guard record.setID == manifest.id else {
            throw STARPlanError("The pinned index \(key) is of the set \(record.setID), not \(manifest.id), so pin the index of this set.")
        }
        guard record.key.countingGTFSHA256 == gtfSHA256 else {
            throw STARPlanError("The index \(key) of the set \(manifest.id) was built from a derived/genes.gtf of SHA-256 "
                + "\(record.key.countingGTFSHA256), and the set's derived/genes.gtf has SHA-256 \(gtfSHA256), so its genes "
                + "are not the set's. Build it again with lungfish-cli rnaseq index-plan --set \(manifest.id) --star "
                + "\(record.tool.version), adopt it with lungfish-cli rnaseq index-adopt, then write the plan again.")
        }
        guard star.id == record.tool.id, star.version == record.tool.version else {
            throw STARPlanError("The plan maps with STAR \(star.version), and the index \(key) was built by STAR "
                + "\(record.tool.version). STAR maps only on an index of its own version, so map with STAR \(record.tool.version).")
        }
    }

    /// The words of `counts`, which say what a count is.
    static func countsWords(_ chain: STARPlanChain, paired: Bool) -> String {
        switch chain {
        case .starSalmon:
            // The default route counts with salmon, whose plan states its counts as the Mac route does (defaultRoutePipeline).
            return "NumReads"
        case .geneCounts:
            // Columns 3 and 4 count by strand, in the words the adopt writes for the same columns
            // (`ExecutorRunAdoption.geneCountsColumnWords`): the two mates of a pair, or the one read of a single read file.
            let strands = paired ? "read 1 on the gene's strand and read 2 on the gene's strand"
                : "the read on the gene's strand and the read on the other strand"
            return "STAR GeneCounts in ReadsPerGene.out.tab: a uniquely mapped \(paired ? "pair" : "read") counted for the one gene "
                + "whose exons it overlaps, in three columns, unstranded, \(strands)"
        case .featureCounts:
            // -M counts each reported alignment of a multimapping read, so a read that maps to two genes counts once in each
            // (the GF rule). No -O means overlap never counts a pair twice, and STAR's GeneCounts differs by design
            // (EX-PLAN-STAR-M2-BIO SF1).
            let unit = paired ? "a pair counted once, for one gene only (-p --countReadPairs)"
                : "each read counted once, for one gene only (single reads take no -p --countReadPairs)"
            return "featureCounts exon counts summed by gene_id, in featurecounts/counts.txt: \(unit), a \(paired ? "pair" : "read") "
                + "that cannot be given to one gene left uncounted as ambiguous (no -O), each reported alignment of a multimapping "
                + "read counted (-M), so a read that maps to two genes counts once in each, whole counts (no --fraction), unstranded "
                + "(-s 0, the default). STAR's own star/ReadsPerGene.out.tab of the same run counts by STAR's rule (unique pairs "
                + "only, a pair whose reads touch two genes ambiguous) and differs from these counts by design"
        }
    }

    /// The words of `multimapNmax`. 1000 is the value C6 needs, an undocumented step of its authors (reproduction plan
    /// row GE), so the record line names it.
    static func multimapWords(_ nmax: Int?) -> String {
        guard let nmax else { return "10 loci, STAR's default (no --outFilterMultimapNmax)" }
        let c6 = nmax == 1000 ? ", the undocumented step of GSE304256 (C6) that its deposited ReadsPerGene files need" : ""
        return "\(nmax) loci, chosen with --outFilterMultimapNmax \(nmax)\(c6)"
    }

    /// The chain's identity. `route.settings` holds every setting that changes counts, the GTF by path and SHA-256 beside
    /// the set id (BIO-COUNTING-GTF item 4), and the trim, adapter and duplicates lines of the salmon chain's frame.
    static func pipeline(
        manifest: ReferenceSetManifest, request: STARPlanRequest, gtf: ReferenceSetManifest.DerivedFile, paired: Bool
    ) -> PlanPipeline {
        let (pins, chain) = (request.pins, request.chain)
        let trimVersion = pins.trimGalore.version
        var polyGChosen = false
        if case .trimGalore(let polyG) = request.trim { polyGChosen = polyG }
        var settings = [
            PlanPipelineSetting(id: "mapping", label: "Mapping",
                                value: "STAR \(pins.star.version) on the genome, --outSAMtype BAM Unsorted --quantMode GeneCounts",
                                source: .default),
            PlanPipelineSetting(id: "index", label: "Index", value: request.index.record.key.folderName, source: .default),
            PlanPipelineSetting(id: "multimapNmax", label: "Loci a read may map to", value: multimapWords(request.multimapNmax),
                                source: request.multimapNmax == nil ? .default : .option),
            PlanPipelineSetting(id: "countingGTF", label: "Genes",
                                value: "\(gtf.path) of the set \(manifest.id), SHA-256 \(gtf.sha256)", source: .default),
            PlanPipelineSetting(id: "counts", label: "Counts", value: countsWords(chain, paired: paired), source: .default),
            PlanPipelineSetting(id: "trimming", label: "Trimming",
                                value: SalmonQuantRecordLines.trimming(request.trim, version: trimVersion),
                                source: polyGChosen ? .option : .default),
            PlanPipelineSetting(id: "duplicates", label: "Duplicates", value: request.sample.duplicates,
                                source: request.sample.duplicatesSource),
        ]
        if let adapter = SalmonQuantRecordLines.adapter(request.trim, version: trimVersion) {
            settings.append(PlanPipelineSetting(id: "adapter", label: "Adapter", value: adapter, source: .default))
        }
        settings.sort { $0.id < $1.id }
        let tool = chain == .featureCounts ? pins.featureCounts : pins.star
        return PlanPipeline(
            id: chain.rawValue, version: pipelineVersion, preset: PlanPipelinePreset(id: chain.rawValue, name: chain.presetName),
            modality: .bulk,
            route: PlanPipelineRoute(id: chain.rawValue, tool: tool.id, toolVersion: tool.version,
                                     settings: Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0.value) })),
            referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
            settings: settings)
    }
}
