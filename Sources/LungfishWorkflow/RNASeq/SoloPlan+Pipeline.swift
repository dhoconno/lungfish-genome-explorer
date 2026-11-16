// SoloPlan+Pipeline.swift - The identity of the STARsolo chain in a plan's pipeline (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

extension SoloPlan {
    /// The chain's identity. `route.settings` holds each setting that changes counts: the chemistry, the barcode list by
    /// name and SHA-256, the cell filter, the matrix counted, the GTF the index read with BIO-SOLO-GTF item 4's facts, the
    /// UMI deduplication, the index and that no trimmer ran. `barcodeListSource` keeps whether the person gave the list
    /// (BIO-SOLO-GTF item 9) and is no route key, since a supplied list equal to the image's changes no count.
    static func pipeline(
        manifest: ReferenceSetManifest, request: SoloPlanRequest, gtfSHA256: String, list: SoloBarcodeChoice, cells: Int
    ) -> PlanPipeline {
        let (preset, record, star) = (request.preset, request.index.record, request.pins.star.version)
        let listSource: ImportSettingSource = request.suppliedList == nil ? .default : .option
        let route = [
            PlanPipelineSetting(id: "barcodeList", label: "Barcode list", value: "\(list.list.name), SHA-256 \(list.list.sha256)",
                                source: listSource),
            PlanPipelineSetting(id: "cellFilter", label: "Cell filter",
                                value: "EmptyDrops_CR with \(cells) expected cells, then " + emptyDropsArguments.joined(separator: " "),
                                source: request.expectedCells == nil ? .default : .option),
            PlanPipelineSetting(id: "chemistry", label: "Chemistry", value: preset.chemistry, source: .option),
            PlanPipelineSetting(id: "counts", label: "Counts", value: preset.counts, source: .option),
            PlanPipelineSetting(id: "countingGTF", label: "Counting GTF",
                                value: countingGTF(record: record, setID: manifest.id, gtfSHA256: gtfSHA256), source: .default),
            PlanPipelineSetting(id: "duplicates", label: "Duplicates",
                                value: "Duplicates: removed with UMIs by STARsolo \(star) (--soloUMIdedup 1MM_CR, "
                                    + "--soloUMIfiltering MultiGeneUMI_CR), one count for each UMI of a cell and gene.",
                                source: .default),
            PlanPipelineSetting(id: "index", label: "Index", value: record.key.folderName, source: .default),
            PlanPipelineSetting(id: "trimming", label: "Trimming", value: "Reads not trimmed", source: .default),
        ]
        let settings = (route + [PlanPipelineSetting(id: "barcodeListSource", label: "Barcode list source", value: list.words,
                                                     source: listSource)]).sorted { $0.id < $1.id }
        return PlanPipeline(
            id: pipelineID, version: pipelineVersion, preset: PlanPipelinePreset(id: preset.rawValue, name: preset.name),
            modality: .singleCell,
            route: PlanPipelineRoute(id: preset.routeID, tool: request.pins.star.id, toolVersion: star,
                                     settings: Dictionary(uniqueKeysWithValues: route.map { ($0.id, $0.value) })),
            referenceSet: PlanPipelineReferenceSet(id: manifest.id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
            settings: settings)
    }

    /// BIO-SOLO-GTF item 4 from the index record: the rule, its version and list, the made file's SHA-256 and size and the
    /// genes it left out, beside the SHA-256 of `derived/genes.gtf` and the set id. A bulk index names no rule.
    static func countingGTF(record: STARIndexRecord, setID: String, gtfSHA256: String) -> String {
        let key = record.key.folderName
        guard let filter = record.key.gtfFilter else {
            return "derived/genes.gtf (SHA-256 \(gtfSHA256)) of the set \(setID), with no 10x filter rule. STARsolo reads its "
                + "genes through the index \(key)."
        }
        let made = "made/\(filter.rule)\(filter.ruleVersion)-\(filter.list)/genes.gtf"
        return "\(made), which the 10x filter rule \(filter.rule) version \(filter.ruleVersion) made with the list \(filter.list) "
            + "from derived/genes.gtf (SHA-256 \(gtfSHA256)) of the set \(setID): SHA-256 \(filter.sha256), \(filter.size) bytes, "
            + "\(filter.genesLeftOut) genes left out. STARsolo reads its genes through the index \(key)."
    }
}
