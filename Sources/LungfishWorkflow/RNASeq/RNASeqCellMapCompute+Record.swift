// RNASeqCellMapCompute+Record.swift - The facts and files of a compute run's record (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The rows of `docs/formats/rnaseq-cell-map.md`, The record, A compute run. The route's own `record.json` holds every
// fact that scopes the bytes (5.5 C2), so the record carries it whole beside LGE's facts: the parent's matrices, the
// script, the seed and threads, the memory prediction, the packages and what the run wrote.

import Foundation
import LungfishIO

extension RNASeqCellMapCompute {
    /// The facts of the record, keyed as the page's rows.
    public static func facts(_ run: Run, summary: RNASeqResultWriter.CellMapSummary) -> [String: ParameterValue] {
        let record = (try? JSONSerialization.jsonObject(with: run.record)) ?? [String: Any]()
        let samples = run.checked.samples
        func perSample(_ values: [Int]) -> ParameterValue {
            .array(zip(samples, values).map { .dictionary(["sample": .string($0), "cells": .integer($1)]) })
        }
        let matrices: [ParameterValue] = run.prepared.inputs.map { input in
            .dictionary([
                "sample": .string(input.sample), "matrix": .string(input.matrix.path), "features": .string(input.features.path),
                "barcodes": .string(input.barcodes.path), "gzip": .boolean(input.isGzip), "cells": .integer(input.cells),
                "storedEntries": .integer(input.entries), "matrixSHA256": .string(input.matrixSHA256),
            ])
        }
        let packages = String(decoding: run.packages, as: UTF8.self).split(whereSeparator: \.isNewline).map { ParameterValue.string(String($0)) }
        let embeddings: [ParameterValue] = zip(run.checked.request.embeddings, summary.embeddings).map { embedding, counts in
            .dictionary([
                "name": .string(embedding.name), "method": .string(embedding.method ?? RNASeqCellMapImport.notRecorded),
                "dimensions": .integer(embedding.dimensions), "sourceFile": .string(embedding.sourceFile),
                "drawn": perSample(counts.drawn), "leftOut": perSample(counts.leftOut),
            ])
        }
        let labelSets: [ParameterValue] = summary.labelSets.map { set in
            .dictionary([
                "name": .string(set.name), "table": .string(set.table), "labelled": perSample(set.labelled), "unlabelled": perSample(set.unlabelled),
                "labels": .array(zip(set.labels, set.cells).map { .dictionary(["label": .string($0), "cells": .integer($1)]) }),
            ])
        }
        return [
            "singleCellResult": .string(run.prepared.parentName),
            "parentManifestSHA256": .string(summary.parentManifestSHA256),
            "parentCellsSummarySHA256": .string(summary.parentCellsSHA256),
            "parentMatrices": .array(matrices),
            "script": .dictionary(["name": .string(scriptName), "sha256": .string(scriptSHA256)]),
            "pythonCall": .string((["python"] + pythonFlags + [scriptName]).joined(separator: " ") + " with its inputs as argv"),
            "seed": .integer(run.prepared.seed),
            "threads": .integer(run.prepared.threads),
            "memory": .dictionary(run.prepared.memory.facts),
            "cells": .string("Every cell kept"),
            "samples": .string("Samples were not integrated or batch-corrected."),
            "packages": .array(packages),
            "routeRecord": parameterValue(record),
            "routeRecordSHA256": .string(RNASeqResultBundle.sha256Hex(run.record)),
            "routeExitCode": .integer(Int(run.exitCode)),
            "wrote": .dictionary([
                "table": .string(keptTable), "tableSHA256": .string(run.tableSHA256),
                "embedding": .string(embeddingName), "method": .string(embeddingMethod), "labelSet": .string(labelSetName),
            ]),
            "embeddings": .array(embeddings),
            "labelSets": .array(labelSets),
        ]
    }

    /// The record's files: the parent's manifest, `cells.sqlite` and each matrix the route and the gene pass read, as
    /// inputs, and every file of the cell map as an output.
    public static func files(_ run: Run, summary: RNASeqResultWriter.CellMapSummary, output: URL) -> [ProvenanceFileDescriptor] {
        let parent = run.prepared.parent
        var files = [ProvenanceFileDescriptor(path: RNASeqResultBundle.manifestURL(in: parent).path, checksumSHA256: summary.parentManifestSHA256, role: .input)]
        if let manifest = try? RNASeqResultBundle.loadManifest(from: parent), let cells = manifest.cellsSummary {
            files.append(.init(path: parent.appendingPathComponent(cells.path).path, checksumSHA256: summary.parentCellsSHA256, role: .input))
        }
        files += summary.parentInputs.map { .init(path: parent.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256, role: .input) }
        files += summary.outputs.map { .init(path: output.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256, role: .output) }
        return files
    }

    /// A JSON value of the route's record as a parameter value, numbers kept as integers where JSON wrote them so.
    static func parameterValue(_ json: Any) -> ParameterValue {
        switch json {
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return CFNumberIsFloatType(number) ? .number(number.doubleValue) : .integer(number.intValue)
        case let array as [Any]:
            return .array(array.map(parameterValue))
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.mapValues(parameterValue))
        default:
            return .string("null")
        }
    }
}
