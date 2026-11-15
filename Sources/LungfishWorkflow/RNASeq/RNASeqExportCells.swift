// RNASeqExportCells.swift - The export folder of a single-cell result (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A single-cell result exports by itself. Each sample's matrix, features and barcodes are copied as given into a folder of the
// sample's own, beside `genes.tsv`, `samples.tsv`, `seurat.R`, `scanpy.py` and one record that names every file. No table of
// counts is joined and no test is written, so a flag of a comparison is refused in words that point to `rnaseq pseudobulk`.
// The files inside a sample folder go in the record's resolved options (`matrixFiles`), since a record lists flat names only.

import Foundation
import LungfishCore
import LungfishIO

enum RNASeqExportCells {
    /// One file of a sample's matrix as it goes into the export, with the hash the result's manifest holds for it.
    struct MatrixFile {
        let folder: String
        let name: String
        let source: URL
        let sourcePath: String
        let sha256: String
        let size: Int64
        var path: String { "\(folder)/\(name)" }
    }

    static func run(
        _ item: RNASeqExportResult, sheet sheetURL: URL?, settings: RNASeqExportSettings, sourceURLs: [URL], output folder: URL,
        argv: [String], runClock: ProvenanceRunClock, checkpoint: (() throws -> Void)?
    ) throws -> URL {
        try refuseFlags(settings)
        let sheet = try sheetURL.map(RNASeqExportSheet.read)
        let files = try matrixFiles(item)
        let samples = try sampleTable(item, files: files, sheet: sheet)
        let top: [(name: String, data: Data)] = [
            ("genes.tsv", try RNASeqGeneRecord.tsvData(item.result.genes)),
            ("samples.tsv", Data(([samples.columns] + samples.rows).map { $0.map(RNASeqExport.cell).joined(separator: "\t") }.joined(separator: "\n").appending("\n").utf8)),
            ("seurat.R", Data(RNASeqExportTemplates.seurat().utf8)),
            ("scanpy.py", Data(RNASeqExportTemplates.scanpy().utf8)),
        ]
        let route = ParameterValue.string(RNASeqExportWords.route(item.manifest.route))
        let set = ParameterValue.string(RNASeqExportWords.referenceSet(item.manifest.referenceSet))
        let resolved: [String: ParameterValue] = [
            "modality": .string("single-cell"), "route": route, "referenceSet": set,
            "results": .array([.dictionary(["name": .string(item.manifest.name), "folder": .string(item.label), "route": route, "referenceSet": set,
                                            "samples": .integer(item.result.samples.count)])]),
            "matrixFiles": .array(files.map {
                .dictionary(["path": .string($0.path), "sha256": .string($0.sha256), "size": .integer(Int($0.size)), "source": .string($0.sourcePath)])
            }),
        ]
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeFolderAtomically(.cliLeaf(
            workflowName: "RNA-seq export", sourceURLs: sourceURLs + (sheetURL.map { [$0] } ?? []), outputURL: folder, outputFormat: .text, argv: argv,
            explicitOptions: ["output": .file(folder)], resolved: resolved, runClock: runClock
        )) { staged in
            for file in top { try file.data.write(to: staged.appendingPathComponent(file.name)) }
            try copy(files, into: staged)
            try checkpoint?()
            try Task.checkCancellation()
            return top.map(\.name)
        }
        return folder
    }

    /// The flags of a comparison do nothing here, so each one given is named and the way to a comparison is told.
    static func refuseFlags(_ s: RNASeqExportSettings) throws {
        var given: [String] = []
        if !s.design.isEmpty { given.append("--design") }
        if !s.contrasts.isEmpty { given.append("--contrast") }
        if s.batch != nil { given.append("--batch") }
        if s.batchCorrection != .none { given.append("--batch-correction") }
        if s.lfcBar != nil { given.append("--lfc-bar") }
        if s.padjCutoff != 0.05 { given.append("--padj-cutoff") }
        guard !given.isEmpty else { return }
        let many = given.count > 1
        throw RNASeqExportRefusal(
            "The \(many ? "flags" : "flag") \(RNASeqExportWords.list(given)) \(many ? "do" : "does") nothing on a single-cell export, "
                + "which copies the matrices and writes the Seurat and Scanpy templates and tests no difference between groups. "
                + "Leave \(many ? "them" : "it") out, or sum the cells with rnaseq pseudobulk and export that bulk result with \(many ? "them" : "it").")
    }

    /// The three files of each sample's matrix, in the order the manifest lists the samples. The folder is the second component
    /// of the path (`source/<folder>/...`) and the name is the last, so a `.gz` and an older `genes.tsv` stay as given.
    static func matrixFiles(_ item: RNASeqExportResult) throws -> [MatrixFile] {
        try (item.manifest.matrices ?? []).flatMap { matrix in
            try [matrix.matrix, matrix.features, matrix.barcodes].map { entry in
                let parts = entry.path.split(separator: "/").map(String.init)
                guard parts.count >= 3, parts[0] == "source", let name = parts.last else {
                    throw RNASeqExportRefusal("The RNA-seq result \(item.label) lists the matrix file \(entry.path) outside source/<sample>/, so its sample folder cannot be told. Import the sample again.")
                }
                let source = try RNASeqResultBundle.resolve(entry.path, in: item.url)
                let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
                return MatrixFile(folder: parts[1], name: name, source: source, sourcePath: entry.path, sha256: entry.sha256, size: size)
            }
        }
    }

    /// One row a sample: the result's fields, the sheet's columns, then the sample's folder, route and reference set. A sheet's
    /// own column of those three names decides nothing.
    static func sampleTable(_ item: RNASeqExportResult, files: [MatrixFile], sheet: RNASeqExportSheet?) throws -> RNASeqExportSampleTable {
        let ids = item.result.samples.map(\.id)
        if let sheet {
            let onlyInResults = ids.filter { sheet.rows[$0] == nil }
            let onlyInSheet = sheet.rows.keys.filter { !ids.contains($0) }.sorted()
            guard onlyInResults.isEmpty, onlyInSheet.isEmpty else {
                func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
                throw RNASeqExportRefusal(
                    "The sample ids of the results and the sample sheet differ. Only in the results: \(list(onlyInResults)). Only in the sheet: \(list(onlyInSheet)). "
                        + "Make the sheet's sample column name the same samples as the results, or leave out --sample-sheet.")
            }
        }
        let fixed = RNASeqExport.baseColumns + ["sample", "folder", "route", "reference_set"]
        let extra = (sheet?.columns ?? []).filter { !fixed.contains($0) }
        let folders = Dictionary((item.manifest.matrices ?? []).map { ($0.sample, $0.matrix.path.split(separator: "/").dropFirst().first.map(String.init) ?? "") },
                                 uniquingKeysWith: { first, _ in first })
        let rows = item.result.samples.map { record -> [String] in
            let own = sheet?.rows[record.id] ?? [:]
            func pick(_ column: String, _ value: String?) -> String { (own[column].flatMap { $0.isEmpty ? nil : $0 }) ?? value ?? "" }
            return [record.id, pick("animal", record.animal), pick("species", record.species), pick("origin", record.origin), pick("group", record.group),
                    pick("runs", record.runs.joined(separator: ","))] + extra.map { own[$0] ?? "" }
                + [folders[record.id] ?? "", RNASeqExportWords.route(item.manifest.route), RNASeqExportWords.referenceSet(item.manifest.referenceSet)]
        }
        return RNASeqExportSampleTable(columns: RNASeqExport.baseColumns + extra + ["folder", "route", "reference_set"], rows: rows)
    }
}
