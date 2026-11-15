// RNASeqPseudobulk+Request.swift - The bulk result's request and the record's facts (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The result keeps the single-cell result's route and reference set and adds the route setting `pseudobulk`. Each column's
// `samples.tsv` row carries its sample's animal, species, origin and runs, with the label as the group, so the export can
// count the animals of a group (`docs/formats/rnaseq-bundle.md`, Pseudobulk).

import Foundation
import LungfishCore
import LungfishIO

extension RNASeqPseudobulk {
    struct Summed {
        var kept: [Group]
        var dropped: [Group]
        var unlabelled: [Unlabelled]
        var geneIDs: [String]
        var otherTypes: [String: Int]
        var table: RNASeqCountTable
    }

    static func outcome(
        _ summed: Summed, manifest: RNASeqResultManifest, loaded: RNASeqResult, result: URL, labels: URL, name: String, createdAt: Date
    ) throws -> Outcome {
        let records = summed.kept.map { group -> RNASeqSampleRecord in
            let source = loaded.samples.first { $0.id == group.sample }
            return RNASeqSampleRecord(
                id: group.column, animal: source?.animal, species: source?.species, origin: source?.origin, group: group.label,
                runs: source?.runs ?? [])
        }
        var route = manifest.route
        route.settings[routeSetting] = routeSettingValue
        let kept = Set(summed.geneIDs)
        let genes: RNASeqResultWriter.GeneTable = manifest.referenceSet == nil ? .ids(summed.geneIDs)
            : .referenceSetTable(url: try RNASeqResultBundle.resolve(manifest.genes.path, in: result), keeping: summed.geneIDs)
        let request = RNASeqResultWriter.Request(
            name: name, modality: .bulk,
            origin: .init(kind: .pseudobulk, tool: manifest.origin.tool, toolVersion: manifest.origin.toolVersion),
            route: route, referenceSet: manifest.referenceSet, samples: records, genes: genes,
            counts: [.init(rows: .gene, column: .default, unit: .umis, table: summed.table)],
            sourceFiles: [], notHost: manifest.notHost.filter(kept.contains), createdAt: createdAt)

        let manifestSHA = try RNASeqResultBundle.sha256Hex(fileAt: RNASeqResultBundle.manifestURL(in: result))
        let labelSHA = try RNASeqResultBundle.sha256Hex(fileAt: labels)
        func fact(_ group: Group, words: String? = nil) -> ParameterValue {
            var fields: [String: ParameterValue] = [
                "column": .string(group.column), "sample": .string(group.sample), "label": .string(group.label),
                "cells": .integer(group.cells), "umis": .integer(Int(group.umis)),
            ]
            if let words { fields["words"] = .string(words) }
            return .dictionary(fields)
        }
        let facts: [String: ParameterValue] = [
            "singleCellResult": .string(manifest.name),
            "singleCellManifestSHA256": .string(manifestSHA),
            "labelTable": .string(labels.lastPathComponent),
            "labelTableSHA256": .string(labelSHA),
            "minimumCells": .integer(minimumCells),
            "groupsKept": .array(summed.kept.map { fact($0) }),
            "groupsLeftOut": .array(summed.dropped.map { fact($0, words: droppedWords($0)) }),
            "cellsWithNoLabel": .array(summed.unlabelled.map {
                .dictionary(["sample": .string($0.sample), "cells": .integer($0.cells), "umis": .integer(Int($0.umis)), "words": .string(unlabelledWords($0))])
            }),
            "geneExpressionFeatures": .integer(summed.geneIDs.count),
            "featureTypesLeftOut": .dictionary(summed.otherTypes.mapValues { .integer($0) }),
        ]
        return Outcome(
            request: request, kept: summed.kept, dropped: summed.dropped, unlabelled: summed.unlabelled,
            notes: summed.dropped.map(droppedWords) + summed.unlabelled.map(unlabelledWords), facts: facts,
            resultManifestSHA256: manifestSHA, labelTableSHA256: labelSHA)
    }
}
