// RNASeqExportFolder.swift - The export folder of `rnaseq export` (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `counts.tsv` (genes by samples, the default column), `counts.masked.tsv` beside it when a result holds one, `genes.tsv` with
// `not_host`, `samples.tsv` (the results' sample rows, the columns of an optional sheet, and `route` and `reference_set` read
// from each result), the two R templates and one record that names every file. The folder is staged and renamed into place by
// `ScientificFileExportProvenance.writeFolderAtomically`, never over an existing folder, and every refusal comes before a write.

import Foundation
import LungfishCore
import LungfishIO

/// A sample sheet of any columns, keyed by its `sample` or `sample_id` column.
public struct RNASeqExportSheet: Equatable, Sendable {
    public var columns: [String]
    public var rows: [String: [String: String]]

    public static func read(_ url: URL) throws -> RNASeqExportSheet {
        let name = url.lastPathComponent
        let lines = try SalmonQuantFolderReader.tsvRows(Data(contentsOf: url), path: name).map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let header = lines.first, let key = header.firstIndex(of: "sample") ?? header.firstIndex(of: "sample_id") else {
            throw RNASeqExportRefusal("\(name) could not be read, because its first line names no sample column. A sample sheet is tab-separated, and its first line names a sample column.")
        }
        // A column of empty name, such as the trailing tabs a spreadsheet saves, is left out, and a name given twice is refused.
        let named = header.enumerated().filter { !$0.element.isEmpty }
        if let twice = Dictionary(grouping: named.map(\.element), by: { $0 }).filter({ $0.value.count > 1 }).keys.sorted().first {
            throw RNASeqExportRefusal("\(name) names the column \(twice) more than once. Each column of a sample sheet is named once, so remove or rename the repeat.")
        }
        var rows: [String: [String: String]] = [:]
        for (index, line) in lines.dropFirst().enumerated() {
            guard key < line.count, !line[key].isEmpty else { throw RNASeqExportRefusal("\(name) could not be read, because line \(index + 2) names no sample.") }
            guard rows[line[key]] == nil else { throw RNASeqExportRefusal("The sample \(line[key]) appears twice in \(name). Each sample is one row.") }
            rows[line[key]] = Dictionary(named.map { ($0.element, $0.offset < line.count ? line[$0.offset] : "") }, uniquingKeysWith: { first, _ in first })
        }
        return RNASeqExportSheet(columns: named.filter { $0.offset != key }.map(\.element), rows: rows)
    }
}

public enum RNASeqExport {
    static let baseColumns = ["sample_id", "animal", "species", "origin", "group", "runs"]

    /// Reads, joins, checks and writes. Nothing is written when a step refuses, and a cancel in `checkpoint` removes the stage.
    @discardableResult
    public static func run(
        results urls: [URL], sheet sheetURL: URL?, settings: RNASeqExportSettings, output: URL, argv: [String],
        checkpoint: (() throws -> Void)? = nil
    ) throws -> URL {
        let runClock = ProvenanceRunClock()
        let folder = output.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw RNASeqExportRefusal("\(folder.path) already exists. The export writes a new folder, so choose a path that does not exist.")
        }
        guard FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RNASeqExportRefusal("No folder at \(folder.deletingLastPathComponent().path) to write the export in. Create it or choose another --output.")
        }
        let join = try RNASeqExportJoin.make(try RNASeqExportReader.read(urls))
        let sheet = try sheetURL.map(RNASeqExportSheet.read)
        let samples = try sampleTable(join, sheet: sheet)
        try RNASeqExportDesignCheck.check(settings, samples: samples)
        // A pseudobulk result counts animals and not cells, so each level of its tested factor needs columns of 3 animals.
        let minimumAnimals = join.results.contains { $0.manifest.origin.kind == .pseudobulk } ? RNASeqExportDesignCheck.minimumAnimals : nil
        if minimumAnimals != nil { try RNASeqExportDesignCheck.checkAnimals(settings, samples: samples) }
        var files: [(name: String, data: Data)] = [("counts.tsv", Data(countsText(join.counts).utf8))]
        if let masked = join.masked { files.append(("counts.masked.tsv", Data(countsText(masked).utf8))) }
        files += [
            ("genes.tsv", try RNASeqGeneRecord.tsvData(join.genes)),
            ("samples.tsv", Data(([samples.columns] + samples.rows).map { $0.map(cell).joined(separator: "\t") }.joined(separator: "\n").appending("\n").utf8)),
            ("deseq2.R", Data(RNASeqExportTemplates.deseq2(settings, minimumAnimals: minimumAnimals).utf8)),
            ("edger-limma-dream.R", Data(RNASeqExportTemplates.edgerLimmaDream(settings, minimumAnimals: minimumAnimals).utf8)),
        ]
        let bar = settings.lfcBar.map { "\($0)" } ?? "none"
        var resolved: [String: ParameterValue] = [
            "padjCutoff": .string("\(settings.padjCutoff)"), "alpha": .string("\(settings.padjCutoff)"), "lfcBar": .string(bar),
            "design": .array(settings.design.map(ParameterValue.string)),
            "contrasts": .array(settings.contrasts.map { .string("\($0.factor):\($0.numerator):\($0.denominator)") }),
            "batch": .string(settings.batch ?? "none"), "batchCorrection": .string(settings.batchCorrection.rawValue),
            "route": .string(RNASeqExportWords.route(join.route)), "referenceSet": .string(RNASeqExportWords.referenceSet(join.referenceSet)),
            "results": .array(join.results.map { item in
                .dictionary(["name": .string(item.manifest.name), "folder": .string(item.label), "route": .string(RNASeqExportWords.route(item.manifest.route)),
                             "referenceSet": .string(RNASeqExportWords.referenceSet(item.manifest.referenceSet)), "samples": .integer(item.result.samples.count)])
            }),
        ]
        // Only a pseudobulk record names the minimum, so the record of a bulk export is as it was.
        if let minimumAnimals { resolved["minimumAnimals"] = .integer(minimumAnimals) }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeFolderAtomically(.cliLeaf(
            workflowName: "RNA-seq export", sourceURLs: urls + (sheetURL.map { [$0] } ?? []), outputURL: folder, outputFormat: .text, argv: argv,
            explicitOptions: ["output": .file(folder)], resolved: resolved, runClock: runClock
        )) { staged in
            for file in files { try file.data.write(to: staged.appendingPathComponent(file.name)) }
            try checkpoint?()
            try Task.checkCancellation()
            return files.map(\.name)
        }
        return folder
    }

    static func cell(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }

    static func countsText(_ table: RNASeqCountTable) -> String {
        func number(_ value: Double) -> String { value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)" }
        let lines = [(["gene_id"] + table.sampleIDs).map(cell).joined(separator: "\t")]
            + table.rows.map { ([cell($0.id)] + $0.counts.map(number)).joined(separator: "\t") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row a sample, with the results' fields, the sheet's columns, and the route and set read from each result.
    static func sampleTable(_ join: RNASeqExportJoin, sheet: RNASeqExportSheet?) throws -> RNASeqExportSampleTable {
        if let sheet {
            let ids = join.counts.sampleIDs
            let onlyInResults = ids.filter { sheet.rows[$0] == nil }
            let onlyInSheet = sheet.rows.keys.filter { !ids.contains($0) }.sorted()
            guard onlyInResults.isEmpty, onlyInSheet.isEmpty else {
                func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
                throw RNASeqExportRefusal(
                    "The sample ids of the results and the sample sheet differ. Only in the results: \(list(onlyInResults)). Only in the sheet: \(list(onlyInSheet)). "
                        + "Make the sheet's sample column name the same samples as the results, or leave out --sample-sheet.")
            }
        }
        // The record holds route and set, so a sheet's own columns of those names never decide anything.
        let extra = (sheet?.columns ?? []).filter { !baseColumns.contains($0) && !["sample", "route", "reference_set"].contains($0) }
        let rows = join.samples.map { record -> [String] in
            let own = sheet?.rows[record.id] ?? [:]
            func pick(_ column: String, _ value: String?) -> String { (own[column].flatMap { $0.isEmpty ? nil : $0 }) ?? value ?? "" }
            let item = join.results[join.sampleResult[record.id] ?? 0].manifest
            return [record.id, pick("animal", record.animal), pick("species", record.species), pick("origin", record.origin), pick("group", record.group),
                    pick("runs", record.runs.joined(separator: ","))] + extra.map { own[$0] ?? "" }
                + [RNASeqExportWords.route(item.route), RNASeqExportWords.referenceSet(item.referenceSet)]
        }
        return RNASeqExportSampleTable(columns: baseColumns + extra + ["route", "reference_set"], rows: rows)
    }
}
