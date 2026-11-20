// RNASeqCellMapImport.swift - The checker of rnaseq cell-map import (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq cell-map import` reads coordinates and labels that the person's own tool made, checks every one
// before anything is written, and hands them to the one writer's cell map (`RNASeqResultWriter+CellMap`), which writes
// all of 5.5 L3 and keeps the given files under `source/`. The checks run in the fixed order of
// `docs/formats/rnaseq-cell-map.md`, Matching cells, so one input meets one refusal, and each refusal names the file and
// what to do. The parent's sha256 values are checked once, by the writer, before it reads a matrix (review CM-KIND SWIFT R3).

import Foundation
import LungfishCore
import LungfishIO

public enum RNASeqCellMapImport {
    /// `--barcode-suffix`: drop `-1` from each given barcode that ends in it, or add `-1` to each (5.5 I2).
    public enum BarcodeSuffix: String, Sendable, CaseIterable {
        case drop, add

        var changed: String { self == .drop ? "once -1 is dropped" : "once -1 is added" }
        func apply(_ barcode: String) -> String {
            switch self {
            case .drop: return barcode.hasSuffix("-1") ? String(barcode.dropLast(2)) : barcode
            case .add: return barcode + "-1"
            }
        }
    }

    public struct Options: Sendable {
        public var parent: URL
        public var coordinates: [URL]
        public var clusters: [URL]
        public var labelColumns: [String]
        /// Each `--method` as given, `<embedding>=<name>`.
        public var methods: [String]
        public var barcodeSuffix: BarcodeSuffix?
        public var skipBarcodesNotHeld: Bool
        public var otherCounts: Bool
        public var tool: String?
        public var toolVersion: String?

        public init(parent: URL, coordinates: [URL], clusters: [URL] = [], labelColumns: [String] = [], methods: [String] = [],
                    barcodeSuffix: BarcodeSuffix? = nil, skipBarcodesNotHeld: Bool = false, otherCounts: Bool = false,
                    tool: String? = nil, toolVersion: String? = nil) {
            (self.parent, self.coordinates, self.clusters, self.labelColumns, self.methods) = (parent, coordinates, clusters, labelColumns, methods)
            (self.barcodeSuffix, self.skipBarcodesNotHeld, self.otherCounts) = (barcodeSuffix, skipBarcodesNotHeld, otherCounts)
            (self.tool, self.toolVersion) = (tool, toolVersion)
        }

        /// The given files in their places from 1, each `--coordinates` and then each `--clusters`, as the record's command
        /// names them, so a replay keeps each file at its `source/<n>`.
        public var files: [URL] { coordinates + clusters }
    }

    /// What the record says of one given file, and its barcodes matched and not held for each sample.
    public struct FileFacts: Sendable {
        public var path: String
        public var kept: String
        public var form: Form
        public var sha256: String
        public var size: Int64
        public var rows: Int
        public var readPast: [String]
        public var matched: [Int]
        public var notHeld: [Int]
        public var firstNotHeld: [[String]]
    }

    /// The three choices of the record (`docs/formats/rnaseq-cell-map.md`, The record).
    public struct Choices: Equatable, Sendable {
        public var barcodeSuffix: String
        public var barcodesNotHeld: String
        public var counts: String
    }

    /// Every input checked, ready for the writer.
    public struct Checked: Sendable {
        public var request: RNASeqResultWriter.CellMapRequest
        public var files: [FileFacts]
        public var parentName: String
        public var samples: [String]
        public var choices: Choices
        public var tool: String?
        public var toolVersion: String?
    }

    public static let notRecorded = "Not recorded"
    static let tenXMethods = ["TSNE": "t-SNE", "UMAP": "UMAP", "PC": "PCA"]

    /// Checks `options` for a cell map at `output` and writes nothing.
    public static func check(_ options: Options, output: URL, createdAt: Date = Date()) throws -> Checked {
        let methods = try parseMethods(options.methods)
        try RNASeqPseudobulk.checkOutput(output)
        var ancestor = output.deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if RNASeqResultBundle.isBundleURL(ancestor) { throw RNASeqCellMapImportRefusal.outputInsideResult(result: ancestor.lastPathComponent) }
            ancestor = ancestor.deletingLastPathComponent()
        }

        let manifest = try RNASeqResultBundle.loadManifest(from: options.parent)
        guard manifest.modality == .singleCell else {
            throw RNASeqCellMapError.parentNotSingleCell(name: manifest.name, isCellMap: manifest.modality == .cellMap)
        }
        guard let matrices = manifest.matrices, !matrices.isEmpty, let summary = manifest.cellsSummary else {
            throw RNASeqPseudobulkRefusal.noCells(name: manifest.name)
        }
        // cells.sqlite is read here for the matcher. The writer matches every file of the parent to its sha256 before it
        // reads a matrix, so a changed parent is refused there, before the stage exists.
        let database = try RNASeqCellsDatabase(url: try RNASeqResultBundle.resolve(summary.path, in: options.parent))
        let parentSamples = try database.samples()
        var samples = parentSamples.map { RNASeqPseudobulk.SampleCells(name: $0.name, count: $0.cells, columnOfBarcode: [:]) }
        var firstCell = [Int](repeating: 1, count: samples.count)
        let placeOf = Dictionary(parentSamples.enumerated().map { ($1.sample, $0) }, uniquingKeysWith: { first, _ in first })
        for cell in try database.cells(offset: 0, limit: try database.cellCount()) {
            guard let place = placeOf[cell.sample] else { continue }
            samples[place].columnOfBarcode[cell.barcode] = cell.column
            firstCell[place] = cell.cell - cell.column + 1
        }
        let names = samples.map(\.name)

        let files = options.files.map(\.standardizedFileURL)
        let tables = try files.enumerated().map { try table(place: $0.offset + 1, url: $0.element, labelColumns: options.labelColumns, samples: samples.count) }
        let lgeTables = tables.filter { $0.form == .lgeTable }
        for column in options.labelColumns where !lgeTables.contains(where: { $0.header.contains(column) }) {
            throw RNASeqCellMapImportRefusal.noLabelColumn(file: (lgeTables.first ?? tables.first)?.file ?? "", column: column)
        }
        guard tables.contains(where: { !$0.embeddings.isEmpty }) else { throw RNASeqCellMapImportRefusal.noEmbedding }

        let parsed = try tables.map { try parse($0, samples: samples, firstCell: firstCell, suffix: options.barcodeSuffix) }
        try checkNames(tables, methods: methods)
        if options.barcodeSuffix == nil {
            for sample in samples.indices {
                for (table, counts) in zip(tables, parsed) where counts.given[sample] > 0 && counts.matched[sample] == 0 {
                    let (drop, add) = (counts.wouldDrop[sample], counts.wouldAdd[sample])
                    guard drop > 0 || add > 0 else { continue }
                    throw RNASeqCellMapImportRefusal.suffix(file: table.file, sample: names[sample], wouldMatch: max(drop, add),
                                                            of: counts.given[sample], suffix: drop >= add ? .drop : .add)
                }
            }
        }
        if !options.skipBarcodesNotHeld {
            for (table, counts) in zip(tables, parsed) where counts.notHeld.reduce(0, +) > 0 {
                throw RNASeqCellMapImportRefusal.notHeld(file: table.file, count: counts.notHeld.reduce(0, +), first: counts.firstNotHeldAll)
            }
        }
        let tenX = tables.filter(\.form.isTenX)
        if !options.otherCounts, let first = tenX.first, manifest.route.tool != SingleCellTool.cellRanger.rawValue {
            throw RNASeqCellMapImportRefusal.otherCounts(file: first.file, name: manifest.name, tool: manifest.route.tool)
        }

        let tool = options.tool ?? (tables.allSatisfy(\.form.isTenX) ? SingleCellTool.cellRanger.rawValue : nil)
        var request = RNASeqResultWriter.CellMapRequest(
            name: output.deletingPathExtension().lastPathComponent, parent: options.parent.standardizedFileURL,
            origin: .init(kind: .imported, tool: tool, toolVersion: options.toolVersion),
            givenFiles: tables.map { .init(url: $0.url, sample: $0.form.isTenX ? names[0] : "",
                                           tool: options.tool ?? ($0.form.isTenX ? SingleCellTool.cellRanger.rawValue : "")) },
            embeddings: [], labelSets: [], createdAt: createdAt)
        for (table, counts) in zip(tables, parsed) {
            let order = counts.cells.indices.sorted { counts.cells[$0] < counts.cells[$1] }
            let kept = "source/\(table.place)/\(table.file)"
            for (index, embedding) in table.embeddings.enumerated() {
                let dimensions = embedding.columns.count
                let method = methods.first { $0.embedding.lowercased() == embedding.name.lowercased() }?.name
                    ?? (table.form == .projection ? tenXMethods[embedding.name] : nil)
                request.embeddings.append(.init(
                    name: embedding.name, method: method, source: .imported, sourceFile: kept, otherCounts: options.otherCounts,
                    dimensions: dimensions, cells: order.map { counts.cells[$0] },
                    values: order.flatMap { counts.values[index][($0 * dimensions)..<(($0 + 1) * dimensions)] }))
            }
            for (index, set) in table.labelSets.enumerated() {
                let labelled = order.filter { !counts.labels[index][$0].isEmpty }
                request.labelSets.append(.init(name: set.name, source: .imported, sourceFile: kept, cells: labelled.map { counts.cells[$0] },
                                               labels: labelled.map { counts.labels[index][$0] }))
            }
        }
        let counts: String
        if options.otherCounts {
            counts = "computed on other counts"
        } else if tenX.isEmpty {
            counts = "not checked"
        } else {
            counts = lgeTables.isEmpty ? "the parent's" : "the parent's for 10x's files, not checked for LGE's table"
        }
        let choices = Choices(barcodeSuffix: options.barcodeSuffix.map { $0 == .drop ? "-1 dropped" : "-1 added" } ?? "as given",
                              barcodesNotHeld: options.skipBarcodesNotHeld ? "left out" : "refused", counts: counts)
        let facts = zip(tables, parsed).map { table, counts in
            FileFacts(path: table.url.path, kept: "source/\(table.place)/\(table.file)", form: table.form, sha256: table.sha256, size: table.size,
                      rows: table.lines.count, readPast: table.readPast, matched: counts.matched, notHeld: counts.notHeld,
                      firstNotHeld: counts.firstNotHeld)
        }
        return Checked(request: request, files: facts, parentName: manifest.name, samples: names, choices: choices,
                       tool: tool, toolVersion: options.toolVersion)
    }

    /// Writes `checked` as the cell map `output` through the one writer. The writer copies each given file under
    /// `source/` and hashes the copy, and a copy whose sha256 is not the one the check read is refused before the
    /// record is written, so the stage is discarded.
    @discardableResult
    public static func write(
        _ checked: Checked, to output: URL, writer: RNASeqResultWriter,
        availableBytes: (URL) throws -> Int64 = RNASeqResultWriter.availableBytes,
        makeEnvelope: (RNASeqResultWriter.CellMapSummary) throws -> ProvenanceEnvelope
    ) throws -> RNASeqResultWriter.CellMapSummary {
        try writer.writeCellMap(checked.request, to: output, availableBytes: availableBytes) { summary in
            for file in checked.files where !summary.outputs.contains(where: { $0.path == file.kept && $0.sha256 == file.sha256 }) {
                throw RNASeqCellMapImportRefusal.changedWhileRead(file: URL(fileURLWithPath: file.path).lastPathComponent)
            }
            return try makeEnvelope(summary)
        }
    }

    static func parseMethods(_ given: [String]) throws -> [(embedding: String, name: String)] {
        var methods: [(embedding: String, name: String)] = []
        for text in given {
            guard let cut = text.firstIndex(of: "="), cut > text.startIndex, text.index(after: cut) < text.endIndex,
                  !text.contains(where: { $0 == "\t" || $0.isNewline }) else {
                throw RNASeqCellMapImportRefusal.methodForm(text: text)
            }
            let embedding = String(text[..<cut])
            guard !methods.contains(where: { $0.embedding.lowercased() == embedding.lowercased() }) else {
                throw RNASeqCellMapImportRefusal.methodTwice(embedding: embedding)
            }
            methods.append((embedding, String(text[text.index(after: cut)...])))
        }
        return methods
    }

    /// Embedding names and label-set names are each unique ignoring case, two sets never share a label table, and each
    /// `--method` names an embedding a file holds.
    static func checkNames(_ tables: [Table], methods: [(embedding: String, name: String)]) throws {
        func shown(_ a: Table, _ b: Table) -> (String, String) { a.file == b.file && a.place != b.place ? (a.url.path, b.url.path) : (a.file, b.file) }
        var embeddingFrom: [String: Table] = [:]
        var setFrom: [String: Table] = [:]
        var setOfTable: [String: String] = [:]
        for table in tables {
            for embedding in table.embeddings {
                if let other = embeddingFrom.updateValue(table, forKey: embedding.name.lowercased()) {
                    let (a, b) = shown(other, table)
                    throw RNASeqCellMapImportRefusal.nameTwice(what: "embedding", name: embedding.name, first: a, second: b)
                }
            }
            for set in table.labelSets {
                if let other = setFrom.updateValue(table, forKey: set.name.lowercased()) {
                    let (a, b) = shown(other, table)
                    throw RNASeqCellMapImportRefusal.nameTwice(what: "label set", name: set.name, first: a, second: b)
                }
                let fileName = RNASeqCellMap.labelTableFileName(set.name)
                if let other = setOfTable.updateValue(set.name, forKey: fileName.lowercased()) {
                    throw RNASeqCellMapImportRefusal.tableNameTwice(first: other, second: set.name, fileName: fileName)
                }
            }
        }
        let embeddings = tables.flatMap { $0.embeddings.map(\.name) }
        for method in methods where embeddingFrom[method.embedding.lowercased()] == nil {
            throw RNASeqCellMapImportRefusal.methodNoEmbedding(name: method.embedding, embeddings: embeddings)
        }
    }
}
