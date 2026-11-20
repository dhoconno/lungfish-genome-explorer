// RNASeqResultWriter+CellMap.swift - The one writer's cell map (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A cell map is a result of the RNA-seq kind, modality `cell-map`, at manifest schema 2 (`docs/formats/rnaseq-cell-map.md`).
// `rnaseq cell-map import` (CM-IMPORT) and `rnaseq cell-map compute` (CM-COMPUTE) check their inputs and hand the
// coordinates and labels here, and write nothing of their own. This extension creates, settles and discards the folder as
// `write(_:to:envelope:)` does (`docs/formats/rnaseq-bundle.md`, The one writer). When it settles it writes all of 5.5 L3:
// each label's count in total and for each sample, every bound, `gene_values` through the gene pass, and `labels/<set>.tsv`.
// It checks the parent's sha256 values before the gene pass reads the parent's matrices, and the free space of the volume
// before it writes anything. The caller makes the record's envelope from the summary, so the writer invents no run fact.

import Foundation
import LungfishCore
import LungfishIO

/// A refusal of the cell-map writer, or of a command given a cell map where it needs counts.
public enum RNASeqCellMapError: Error, Equatable, LocalizedError, Sendable {
    public enum Use: Equatable, Sendable { case export, pseudobulk }

    case parentNotSingleCell(name: String, isCellMap: Bool)
    case notEnoughSpace(folder: String, temporary: Int64, output: Int64, available: Int64)
    case cellMapGiven(name: String, parent: String, use: Use)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .parentNotSingleCell(let name, let isCellMap):
            return "\(name) is \(isCellMap ? "a cell map" : "a bulk result"). "
                + "rnaseq cell-map import reads a single-cell result, such as one that import rnaseq made from Cell Ranger or STARsolo folders."
        case .notEnoughSpace(let folder, let temporary, let output, let available):
            return "The cell map needs about \(Self.bytes(temporary + output)) of free space on the volume of \(folder), "
                + "\(Self.bytes(temporary)) for the temporary files of its gene values and \(Self.bytes(output)) for the cell map, "
                + "and the volume has \(Self.bytes(available)) free. Free some space on that volume, or write the cell map to another one."
        case .cellMapGiven(let name, let parent, let use):
            let start = "\(name) is a cell map, which holds coordinates and labels and no counts."
            switch use {
            case .export: return "\(start) Export its single-cell result, \(parent)."
            case .pseudobulk: return "\(start) Give its single-cell result, \(parent), and name the cell map with --cell-map."
            }
        case .invalidRequest(let words):
            return words
        }
    }

    /// A byte count with its thousands marked, such as `8,194,178,000 bytes`.
    static func bytes(_ count: Int64) -> String {
        let digits = String(max(0, count))
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped += "," }
            grouped.append(digit)
        }
        return grouped + (count == 1 ? " byte" : " bytes")
    }
}

extension RNASeqResultWriter {
    public struct CellMapRequest: Sendable {
        public enum Source: String, Sendable { case imported, computed }

        /// A file the person gave an import, kept as `source/<n>/<file name>` with `<n>` its place from 1.
        public struct GivenFile: Sendable {
            public var url: URL
            public var sample: String
            public var tool: String
            public init(url: URL, sample: String, tool: String) {
                (self.url, self.sample, self.tool) = (url, sample, tool)
            }
        }

        /// One embedding: the parent's cell ids it draws, rising, and `dimensions` values a cell, cell after cell.
        public struct Embedding: Sendable {
            public var name: String
            public var method: String?
            public var source: Source
            public var sourceFile: String
            public var otherCounts: Bool
            public var dimensions: Int
            public var cells: [Int32]
            public var values: [Double]
            public init(name: String, method: String?, source: Source, sourceFile: String, otherCounts: Bool, dimensions: Int, cells: [Int32], values: [Double]) {
                (self.name, self.method, self.source, self.sourceFile, self.otherCounts) = (name, method, source, sourceFile, otherCounts)
                (self.dimensions, self.cells, self.values) = (dimensions, cells, values)
            }
        }

        /// One label set: the parent's cell ids that hold a label, rising, and each one's label as written.
        public struct LabelSet: Sendable {
            public var name: String
            public var source: Source
            public var sourceFile: String
            public var cells: [Int32]
            public var labels: [String]
            public init(name: String, source: Source, sourceFile: String, cells: [Int32], labels: [String]) {
                (self.name, self.source, self.sourceFile, self.cells, self.labels) = (name, source, sourceFile, cells, labels)
            }
        }

        public var name: String
        public var parent: URL
        public var origin: Manifest.Origin
        public var givenFiles: [GivenFile]
        /// A compute run's table, kept as `source/compute/embedding.tsv`.
        public var computedTable: URL?
        public var embeddings: [Embedding]
        public var labelSets: [LabelSet]
        public var createdAt: Date

        public init(name: String, parent: URL, origin: Manifest.Origin, givenFiles: [GivenFile] = [], computedTable: URL? = nil,
                    embeddings: [Embedding], labelSets: [LabelSet], createdAt: Date = Date()) {
            (self.name, self.parent, self.origin, self.givenFiles, self.computedTable) = (name, parent, origin, givenFiles, computedTable)
            (self.embeddings, self.labelSets, self.createdAt) = (embeddings, labelSets, createdAt)
        }
    }

    /// The counts and facts of a written cell map, which the caller's record names.
    public struct CellMapSummary: Sendable {
        public struct Sample: Equatable, Sendable { public var sample: Int, name: String, cells: Int }
        public struct EmbeddingCount: Equatable, Sendable { public var name: String, drawn: [Int], leftOut: [Int] }
        public struct LabelSetCount: Equatable, Sendable {
            public var name: String, table: String, labels: [String], cells: [Int], labelled: [Int], unlabelled: [Int]
        }

        public var parentManifestSHA256: String
        public var parentCellsSHA256: String
        /// Each matrix, features and barcodes file of the parent the gene pass read, by its path in the parent.
        public var parentInputs: [Manifest.FileEntry]
        public var samples: [Sample]
        /// For each embedding, the cells drawn and left out of each sample, in sample order.
        public var embeddings: [EmbeddingCount]
        public var labelSets: [LabelSetCount]
        public var genes: RNASeqCellMapGenes.Summary
        public var cellMapBytes: Int64
        /// Every file of the cell map but the record, with its sha256.
        public var outputs: [Manifest.FileEntry]
    }

    /// The bytes free for important use on the volume that holds `folder`.
    public static func availableBytes(_ folder: URL) throws -> Int64 {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
    }

    /// Publishes `request` as the cell map `resultURL`, which ends in `.lungfishrnaseq` and does not exist yet.
    @discardableResult
    public func writeCellMap(
        _ request: CellMapRequest, to resultURL: URL,
        availableBytes: (URL) throws -> Int64 = RNASeqResultWriter.availableBytes,
        observe: ((RNASeqCellMapGenes.Step) throws -> Void)? = nil,
        makeEnvelope: (CellMapSummary) throws -> ProvenanceEnvelope
    ) throws -> CellMapSummary {
        guard RNASeqResultBundle.isBundleURL(resultURL) else { throw RNASeqResultWriterError.notAResultFolder(resultURL.lastPathComponent) }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: resultURL.path) else { throw RNASeqResultWriterError.alreadyExists(resultURL.lastPathComponent) }
        let parent = try CellMapParent(request.parent)
        try checkCellMap(request, cellCount: parent.cells.count)
        let folder = resultURL.deletingLastPathComponent()
        let estimate = RNASeqCellMapGenes.estimate(
            entries: parent.manifest.matrices?.reduce(0) { $0 + $1.entryCount } ?? 0,
            coordinateValues: request.embeddings.reduce(0) { $0 + $1.values.count }, cells: parent.cells.count)
        let given = try request.givenFiles.map(\.url).reduce(Int64(0)) { sum, url in
            sum + Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let available = try availableBytes(folder)
        guard available >= estimate.temporary + estimate.output + given else {
            throw RNASeqCellMapError.notEnoughSpace(folder: folder.path, temporary: estimate.temporary, output: estimate.output + given, available: available)
        }
        let stage = folder.appendingPathComponent(".\(resultURL.lastPathComponent).creating-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            try note(.staged, stage)
            let summary = try DurableReplace.transaction {
                try fillCellMap(stage, request: request, parent: parent, resultURL: resultURL, observe: observe, makeEnvelope: makeEnvelope)
            }
            try PortableRename.exclusive(stage, to: resultURL)
            return summary
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    /// Refuses a request whose cells, values or names break the page's rules. The import's checker gives each case its
    /// own words first, so these words are a guard for any caller that skipped it.
    func checkCellMap(_ request: CellMapRequest, cellCount: Int) throws {
        func rising(_ cells: [Int32], _ what: String) throws {
            for (index, cell) in cells.enumerated() {
                guard cell >= 1, Int(cell) <= cellCount, index == 0 || cell > cells[index - 1] else {
                    throw RNASeqCellMapError.invalidRequest("The \(what) lists the cell \(cell) out of order or outside the result's \(cellCount) cells.")
                }
            }
        }
        guard !request.embeddings.isEmpty else {
            throw RNASeqCellMapError.invalidRequest("No given file holds an embedding. Give LGE's table with columns such as umap_1 and umap_2, or one of 10x's projection.csv files.")
        }
        for (names, what) in [(request.embeddings.map(\.name), "embedding"), (request.labelSets.map(\.name), "label set"),
                              (request.labelSets.map { RNASeqCellMap.labelTableFileName($0.name) }, "label table")] {
            var seen = Set<String>()
            for name in names where !seen.insert(name.lowercased()).inserted {
                throw RNASeqCellMapError.invalidRequest("The \(what) \(name) is named twice, ignoring case. Give each its own name.")
            }
        }
        for embedding in request.embeddings {
            try rising(embedding.cells, "embedding \(embedding.name)")
            guard embedding.dimensions >= 2, embedding.values.count == embedding.cells.count * embedding.dimensions,
                  embedding.values.allSatisfy(\.isFinite) else {
                throw RNASeqCellMapError.invalidRequest("The embedding \(embedding.name) needs 2 or more dimensions and one finite value a dimension for each cell it draws.")
            }
        }
        for set in request.labelSets {
            try rising(set.cells, "label set \(set.name)")
            guard set.labels.count == set.cells.count, !set.labels.contains(where: \.isEmpty) else {
                throw RNASeqCellMapError.invalidRequest("The label set \(set.name) needs one label that is not empty for each cell it lists.")
            }
        }
    }

    private func fillCellMap(
        _ stage: URL, request: CellMapRequest, parent: CellMapParent, resultURL: URL,
        observe: ((RNASeqCellMapGenes.Step) throws -> Void)?, makeEnvelope: (CellMapSummary) throws -> ProvenanceEnvelope
    ) throws -> CellMapSummary {
        var sourceFiles: [Manifest.SourceFileEntry] = []
        for (index, file) in request.givenFiles.enumerated() {
            let relative = "source/\(index + 1)/\(file.url.lastPathComponent)"
            let destination = stage.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (sha256, size) = try copyHashing(file.url, to: destination)
            sourceFiles.append(.init(path: relative, sha256: sha256, size: size, sample: file.sample, tool: file.tool))
        }
        if let table = request.computedTable {
            let relative = "source/compute/embedding.tsv"
            let destination = stage.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (sha256, size) = try copyHashing(table, to: destination)
            sourceFiles.append(.init(path: relative, sha256: sha256, size: size, sample: "", tool: request.origin.tool ?? ""))
        }
        try note(.sourcesCopied, stage)

        // samples.tsv and genes.tsv are the parent's bytes, which verifyChecksums has just matched to its manifest.
        let samplesData = try Data(contentsOf: try RNASeqResultBundle.resolve(parent.manifest.samples.path, in: parent.url))
        let genesData = try Data(contentsOf: try RNASeqResultBundle.resolve(parent.manifest.genes.path, in: parent.url))
        try DurableReplace.replace(samplesData, named: "samples.tsv", in: stage)
        try DurableReplace.replace(genesData, named: "genes.tsv", in: stage)

        let databaseURL = stage.appendingPathComponent(RNASeqCellMap.filename)
        let writer = try RNASeqCellMapDatabaseWriter(url: databaseURL)
        var summary = try writeTables(request, parent: parent, writer: writer, spill: stage.appendingPathComponent(".gene-pass", isDirectory: true),
                                      observe: observe)
        try writer.finish()
        summary.cellMapBytes = Int64((try databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        var labelTables: [Manifest.FileEntry] = []
        if !request.labelSets.isEmpty {
            let labels = stage.appendingPathComponent("labels", isDirectory: true)
            try FileManager.default.createDirectory(at: labels, withIntermediateDirectories: false)
            for set in request.labelSets {
                let name = RNASeqCellMap.labelTableFileName(set.name)
                let data = RNASeqCellMap.labelTableData(set.cells.indices.map { index in
                    let cell = Int(set.cells[index]) - 1
                    return (parent.sampleNames[Int(parent.cells.sample[cell])] ?? "", parent.cells.barcode[cell], set.labels[index])
                })
                try DurableReplace.replace(data, named: name, in: labels)
                labelTables.append(.init(path: "labels/\(name)", sha256: RNASeqResultBundle.sha256Hex(data)))
            }
        }
        try note(.tablesWritten, stage)

        let manifest = Manifest(
            schemaVersion: Manifest.schemaVersion(for: .cellMap), modality: .cellMap, name: request.name,
            createdAt: ISO8601DateFormatter().string(from: request.createdAt), origin: request.origin,
            route: parent.manifest.route, referenceSet: parent.manifest.referenceSet,
            samples: .init(path: "samples.tsv", sha256: RNASeqResultBundle.sha256Hex(samplesData)),
            genes: .init(path: "genes.tsv", sha256: RNASeqResultBundle.sha256Hex(genesData)),
            counts: [], sourceFiles: sourceFiles, notHost: parent.manifest.notHost,
            parent: .init(path: Self.parentPointer(from: resultURL.deletingLastPathComponent(), to: parent.url),
                          manifestSHA256: summary.parentManifestSHA256, cellsSummarySHA256: summary.parentCellsSHA256),
            cellMap: .init(path: RNASeqCellMap.filename, sha256: try RNASeqResultBundle.sha256Hex(fileAt: databaseURL),
                           schemaVersion: RNASeqCellMap.currentSchemaVersion),
            labelTables: labelTables)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try DurableReplace.replace(manifestData, named: Manifest.filename, in: stage)
        try note(.manifestPublished, stage)

        summary.outputs = [manifest.samples, manifest.genes]
            + [Manifest.FileEntry(path: RNASeqCellMap.filename, sha256: manifest.cellMap?.sha256 ?? "")]
            + labelTables + sourceFiles.map { .init(path: $0.path, sha256: $0.sha256) }
            + [Manifest.FileEntry(path: Manifest.filename, sha256: RNASeqResultBundle.sha256Hex(manifestData))]
        try provenanceWriter.write(try makeEnvelope(summary), to: stage, bundleLayoutRoot: resultURL)
        try note(.recordWritten, stage)
        return summary
    }

    /// `parent.path` of the format page: `parent`'s folder written from `folder`, with one `..` for each step up to the
    /// nearest folder that holds both, then down by `CanonicalFilePath.relativePath(of:within:)`, which compares physical
    /// paths. It is a pointer that the reader checks by `manifestSHA256`, and no recorded path takes this form.
    static func parentPointer(from folder: URL, to parent: URL) -> String {
        var base = CanonicalFilePath.url(for: folder.appendingPathComponent("", isDirectory: true))
        var climbs = 0
        while !CanonicalFilePath.isPath(parent, within: base), base.path != "/" {
            base = base.deletingLastPathComponent()
            climbs += 1
        }
        let down = CanonicalFilePath.relativePath(of: parent, within: base) ?? CanonicalFilePath.path(for: parent)
        return (Array(repeating: "..", count: climbs) + [down]).filter { !$0.isEmpty }.joined(separator: "/")
    }
}
