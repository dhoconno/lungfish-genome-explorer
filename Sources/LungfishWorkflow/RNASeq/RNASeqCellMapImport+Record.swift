// RNASeqCellMapImport+Record.swift - The facts and files of an import's record (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The rows of `docs/formats/rnaseq-cell-map.md`, The record, An import: the parent, the given files, the tool, the three
// choices, the counts, the gene values and the outputs. Every number comes from the check or the writer's summary, so the
// record invents no run fact.

import Foundation
import LungfishIO

extension RNASeqCellMapImport {
    /// The facts of the record, keyed as the page's rows.
    public static func facts(_ checked: Checked, summary: RNASeqResultWriter.CellMapSummary) -> [String: ParameterValue] {
        func perSample(_ values: [Int]) -> ParameterValue {
            .array(zip(checked.samples, values).map { .dictionary(["sample": .string($0), "cells": .integer($1)]) })
        }
        let files: [ParameterValue] = checked.files.map { file in
            .dictionary([
                "path": .string(file.path), "kept": .string(file.kept), "sha256": .string(file.sha256), "size": .integer(Int(file.size)),
                "form": .string(file.form.rawValue), "rows": .integer(file.rows), "columnsReadPast": .array(file.readPast.map { .string($0) }),
            ])
        }
        let barcodes: [ParameterValue] = checked.files.flatMap { file in
            checked.samples.indices.map { sample in
                var fields: [String: ParameterValue] = [
                    "file": .string(file.kept), "sample": .string(checked.samples[sample]),
                    "matched": .integer(file.matched[sample]), "notHeld": .integer(file.notHeld[sample]),
                ]
                if file.notHeld[sample] > 0 { fields["firstNotHeld"] = .array(file.firstNotHeld[sample].map { .string($0) }) }
                return .dictionary(fields)
            }
        }
        let embeddings: [ParameterValue] = zip(checked.request.embeddings, summary.embeddings).map { embedding, counts in
            .dictionary([
                "name": .string(embedding.name), "method": .string(embedding.method ?? notRecorded), "dimensions": .integer(embedding.dimensions),
                "sourceFile": .string(embedding.sourceFile), "otherCounts": .boolean(embedding.otherCounts),
                "drawn": perSample(counts.drawn), "leftOut": perSample(counts.leftOut),
            ])
        }
        let labelSets: [ParameterValue] = summary.labelSets.map { set in
            .dictionary([
                "name": .string(set.name), "table": .string(set.table), "labelled": perSample(set.labelled), "unlabelled": perSample(set.unlabelled),
                "labels": .array(zip(set.labels, set.cells).map { .dictionary(["label": .string($0), "cells": .integer($1)]) }),
            ])
        }
        let genes = summary.genes
        return [
            "singleCellResult": .string(checked.parentName),
            "parentManifestSHA256": .string(summary.parentManifestSHA256),
            "parentCellsSummarySHA256": .string(summary.parentCellsSHA256),
            "givenFiles": .array(files),
            "tool": .string(checked.tool ?? notRecorded),
            "toolVersion": .string(checked.toolVersion ?? notRecorded),
            "choices": .dictionary([
                "barcodeSuffix": .string(checked.choices.barcodeSuffix),
                "barcodesNotHeld": .string(checked.choices.barcodesNotHeld),
                "counts": .string(checked.choices.counts),
            ]),
            "barcodes": .array(barcodes),
            "embeddings": .array(embeddings),
            "labelSets": .array(labelSets),
            "geneValues": .dictionary([
                "geneExpressionFeatures": .integer(genes.geneExpressionFeatures),
                "notHostFeatures": .integer(genes.notHostFeatures),
                "featureTypesLeftOut": .dictionary(genes.otherTypes.mapValues { .integer($0) }),
                "normalisation": .string(RNASeqCellMap.normalisationFormula),
                "bounds": .string("nearest-rank p99 over all \(genes.cells) cells of the map, zeros included"),
                "bytesWithNormalised": .integer(Int(genes.blobBytesWithNormalised)),
                "bytesWithoutNormalised": .integer(Int(genes.blobBytesWithoutNormalised)),
            ]),
        ]
    }

    /// The record's files: the parent's manifest, `cells.sqlite` and each matrix the gene pass read, then each given file,
    /// as inputs, and every file of the cell map as an output.
    public static func files(_ checked: Checked, summary: RNASeqResultWriter.CellMapSummary, output: URL) -> [ProvenanceFileDescriptor] {
        let parent = checked.request.parent
        var files = [ProvenanceFileDescriptor(path: RNASeqResultBundle.manifestURL(in: parent).path, checksumSHA256: summary.parentManifestSHA256, role: .input)]
        if let manifest = try? RNASeqResultBundle.loadManifest(from: parent), let cells = manifest.cellsSummary {
            files.append(.init(path: parent.appendingPathComponent(cells.path).path, checksumSHA256: summary.parentCellsSHA256, role: .input))
        }
        files += summary.parentInputs.map { .init(path: parent.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256, role: .input) }
        files += checked.files.map { .init(path: $0.path, checksumSHA256: $0.sha256, fileSize: UInt64($0.size), role: .input) }
        files += summary.outputs.map { .init(path: output.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256, role: .output) }
        return files
    }
}
