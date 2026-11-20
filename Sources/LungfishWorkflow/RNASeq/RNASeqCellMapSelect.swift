// RNASeqCellMapSelect.swift - The checks, the selection and the table of rnaseq cell-map select (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq cell-map select` reads one embedding of a cell map and a polygon or a label set, runs the one
// membership function of LungfishIO, and returns the label table of the selection, `selected` and `rest`, in the bytes
// of the one serializer (`docs/formats/rnaseq-cell-map.md`, cell-map select). Every refusal comes before anything is
// written, and this file writes nothing. The leaf writes the table and its record.

import Foundation
import LungfishCore
import LungfishIO

/// The words of each refusal of `rnaseq cell-map select`, and of `rnaseq pseudobulk --cell-map` given a result that is
/// not a cell map.
public enum RNASeqCellMapSelectRefusal: Error, Equatable, LocalizedError, Sendable {
    case bothOrNeither
    case tooManyVertices(Int)
    case tooFewVertices(Int)
    case unreadableVertex(index: Int, text: String)
    case outputExists(path: String)
    case outputInsideResult(result: String)
    case noOutputFolder(path: String)
    case notACellMap(name: String)
    case noEmbedding(cellMap: String, name: String, known: [String])
    case noLabelSet(cellMap: String, set: String, known: [String])
    case noLabel(set: String, label: String, known: [String])
    case nothingSelected(embedding: String)

    public var errorDescription: String? {
        switch self {
        case .bothOrNeither:
            return "Give --polygon, or --label-set with --label, and not both."
        case .tooManyVertices(let count):
            return "The polygon has \(Self.vertices(count)), and cell-map select takes at most "
                + "\(RNASeqCellMapImportRefusal.number(RNASeqCellMapSelection.maximumVertices)). Draw it again with fewer turns, or pass fewer vertices."
        case .tooFewVertices(let count):
            return "The polygon has \(Self.vertices(count)). Give at least \(RNASeqCellMapSelection.minimumVertices), such as '0,0 10,0 10,10'."
        case .unreadableVertex(let index, let text):
            return "Vertex \(index) of --polygon reads \(text), which is not x,y with two finite decimal numbers."
        case .outputExists(let path):
            return "\(path) already exists. Choose a new name for the table."
        case .outputInsideResult(let result):
            return "--output names a file inside the result \(result). LGE never writes inside a result, so choose a place outside it."
        case .noOutputFolder(let path):
            return "No folder at \(path) to write the table in. Create it or choose another output."
        case .notACellMap(let name):
            return "\(name) is not a cell map. rnaseq cell-map select reads a result that rnaseq cell-map import or compute made."
        case .noEmbedding(let cellMap, let name, let known):
            return "\(cellMap) holds no embedding \(name). Its embeddings are \(RNASeqPseudobulkRefusal.list(known))."
        case .noLabelSet(let cellMap, let set, let known):
            return known.isEmpty ? "\(cellMap) holds no label set \(set). It holds no label sets, so select by --polygon."
                : "\(cellMap) holds no label set \(set). Its label sets are \(RNASeqPseudobulkRefusal.list(known))."
        case .noLabel(let set, let label, let known):
            return "The label set \(set) holds no label \(label). Its labels are \(RNASeqPseudobulkRefusal.list(known))."
        case .nothingSelected(let embedding):
            return "The selection holds no cell drawn in \(embedding). Draw the polygon around drawn cells, or choose a label that holds some."
        }
    }

    static func vertices(_ count: Int) -> String {
        count == 1 ? "1 vertex" : "\(RNASeqCellMapImportRefusal.number(count)) vertices"
    }
}

public enum RNASeqCellMapSelect {
    /// The two labels of the table. `rest` sorts before `selected` by code point, so it is the first column of a pseudobulk.
    public static let selectedLabel = "selected"
    public static let restLabel = "rest"

    /// How the cells are chosen, as the command line gives it.
    public enum Form: Equatable, Sendable {
        case polygon([RNASeqCellMapSelection.Vertex])
        case labels(set: String, labels: [String])
    }

    /// One sample's cells in the embedding: selected, in the rest, and left out of the embedding, which have no line.
    public struct SampleCells: Equatable, Sendable {
        public var sample: String
        public var selected: Int
        public var rest: Int
        public var leftOut: Int
    }

    public struct Outcome: Sendable {
        /// The table in the one serializer's bytes.
        public var table: Data
        public var samples: [SampleCells]
        public var cellMapName: String
        public var cellMapManifestSHA256: String
        /// The facts of the table's record.
        public var facts: [String: ParameterValue]
    }

    /// The form of the command line's flags, or the refusal of both forms or neither.
    public static func form(polygon: String?, labelSet: String?, labels: [String]) throws -> Form {
        switch (polygon, labelSet, labels.isEmpty) {
        case (let text?, nil, true): return .polygon(try parsePolygon(text))
        case (nil, let set?, false): return .labels(set: set, labels: labels)
        default: throw RNASeqCellMapSelectRefusal.bothOrNeither
        }
    }

    /// Vertices split by one space, x and y split by a comma, each number read by `Float(_:)` once and finite. The count is
    /// checked before any vertex is read.
    public static func parsePolygon(_ text: String) throws -> [RNASeqCellMapSelection.Vertex] {
        let pieces = text.isEmpty ? [] : text.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count <= RNASeqCellMapSelection.maximumVertices else { throw RNASeqCellMapSelectRefusal.tooManyVertices(pieces.count) }
        guard pieces.count >= RNASeqCellMapSelection.minimumVertices else { throw RNASeqCellMapSelectRefusal.tooFewVertices(pieces.count) }
        return try pieces.enumerated().map { index, piece in
            let numbers = piece.split(separator: ",", omittingEmptySubsequences: false)
            guard numbers.count == 2, let x = Float32(String(numbers[0])), let y = Float32(String(numbers[1])), x.isFinite, y.isFinite else {
                throw RNASeqCellMapSelectRefusal.unreadableVertex(index: index + 1, text: String(piece))
            }
            return RNASeqCellMapSelection.Vertex(x: x, y: y)
        }
    }

    /// The polygon in Float32 shortest round-trip form, `Float.description`, so the text parses to the same vertices.
    public static func polygonText(_ vertices: [RNASeqCellMapSelection.Vertex]) -> String {
        vertices.map { "\($0.x.description),\($0.y.description)" }.joined(separator: " ")
    }

    /// Refuses a table that exists, one inside a `.lungfishrnaseq` folder, and one whose folder is missing.
    public static func checkOutput(_ url: URL) throws {
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if RNASeqResultBundle.isBundleURL(ancestor) { throw RNASeqCellMapSelectRefusal.outputInsideResult(result: ancestor.lastPathComponent) }
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RNASeqCellMapSelectRefusal.outputExists(path: url.path) }
        var isDirectory: ObjCBool = false
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RNASeqCellMapSelectRefusal.noOutputFolder(path: folder.path)
        }
    }

    /// Refuses a result that is not a cell map, then one whose files differ from its manifest's sha256 values, and
    /// returns the manifest and its own sha256. The check hashes `cellmap.sqlite`, because the selection reads its bytes
    /// and the record names the map by a manifest that pins them.
    public static func checkCellMap(_ url: URL) throws -> (manifest: RNASeqResultManifest, manifestSHA256: String) {
        let manifest = try RNASeqResultBundle.loadManifest(from: url)
        guard manifest.modality == .cellMap, manifest.cellMap != nil else { throw RNASeqCellMapSelectRefusal.notACellMap(name: manifest.name) }
        var changed: [String] = []
        for mismatch in try RNASeqResultBundle.verifyChecksums(of: url) where !changed.contains(mismatch.path) { changed.append(mismatch.path) }
        guard changed.isEmpty else { throw RNASeqPseudobulkRefusal.checksumsDiffer(name: manifest.name, paths: changed) }
        return (manifest, try RNASeqResultBundle.sha256Hex(fileAt: RNASeqResultBundle.manifestURL(in: url)))
    }

    /// Checks the cell map, reads the embedding and the label set once, selects through the membership function and
    /// returns the table. Every cell drawn in the embedding has one line in cell order, `selected` or `rest`, and a cell
    /// left out of it has none.
    public static func select(cellMap: URL, embedding name: String, form: Form) throws -> Outcome {
        let (manifest, manifestSHA) = try checkCellMap(cellMap)
        let mapName = cellMap.lastPathComponent
        guard let entry = manifest.cellMap else { throw RNASeqCellMapSelectRefusal.notACellMap(name: manifest.name) }
        let database = try RNASeqCellMapDatabase(url: try RNASeqResultBundle.resolve(entry.path, in: cellMap))
        let embeddings = try database.embeddings()
        guard let embedding = embeddings.first(where: { $0.name == name }) else {
            throw RNASeqCellMapSelectRefusal.noEmbedding(cellMap: mapName, name: name, known: embeddings.map(\.name))
        }
        let rule: RNASeqCellMapSelection.Rule
        var facts: [String: ParameterValue] = [:]
        switch form {
        case .polygon(let vertices):
            rule = .polygon(vertices)
            facts["polygon"] = .string(polygonText(vertices))
            facts["vertices"] = .integer(vertices.count)
        case .labels(let setName, let labelNames):
            let sets = try database.labelSets()
            guard let set = sets.first(where: { $0.name == setName }) else {
                throw RNASeqCellMapSelectRefusal.noLabelSet(cellMap: mapName, set: setName, known: sets.map(\.name))
            }
            var chosen = Set<UInt32>()
            for label in labelNames {
                guard let found = set.labels.first(where: { $0.name == label }) else {
                    throw RNASeqCellMapSelectRefusal.noLabel(set: setName, label: label, known: set.labels.map(\.name))
                }
                chosen.insert(UInt32(found.label))
            }
            try Task.checkCancellation()
            rule = .labels(try database.cellLabels(labelSet: set.labelSet), chosen: chosen)
            facts["labelSet"] = .string(setName)
            facts["labels"] = .array(labelNames.map { .string($0) })
        }
        try Task.checkCancellation()
        let coordinates = try database.coordinates(embedding: embedding.embedding)
        let keys = try database.cellKeys()
        let samples = try database.samples()
        let placeOfNumber = Dictionary(samples.enumerated().map { ($1.sample, UInt32($0)) }, uniquingKeysWith: { first, _ in first })
        let sampleOfCell = ContiguousArray(keys.sample.map { placeOfNumber[Int($0)] ?? UInt32.max })
        try Task.checkCancellation()
        let chosenCells = RNASeqCellMapSelection.select(
            x: coordinates.x, y: coordinates.y, sampleOfCell: sampleOfCell, samples: samples.count, rule: rule)
        var isSelected = [Bool](repeating: false, count: keys.barcode.count)
        for cells in chosenCells { for cell in cells { isSelected[cell - 1] = true } }

        var counts = samples.map { SampleCells(sample: $0.name, selected: 0, rest: 0, leftOut: 0) }
        var rows: [(sample: String, barcode: String, label: String)] = []
        rows.reserveCapacity(keys.barcode.count)
        for cell in keys.barcode.indices {
            let place = Int(sampleOfCell[cell])
            guard place < counts.count else { continue }
            guard cell < coordinates.x.count, !coordinates.x[cell].isNaN, !coordinates.y[cell].isNaN else {
                counts[place].leftOut += 1
                continue
            }
            if isSelected[cell] { counts[place].selected += 1 } else { counts[place].rest += 1 }
            rows.append((counts[place].sample, keys.barcode[cell], isSelected[cell] ? selectedLabel : restLabel))
        }
        guard counts.contains(where: { $0.selected > 0 }) else { throw RNASeqCellMapSelectRefusal.nothingSelected(embedding: name) }

        facts["cellMap"] = .string(manifest.name)
        facts["cellMapManifestSHA256"] = .string(manifestSHA)
        facts["parentManifestSHA256"] = .string(manifest.parent?.manifestSHA256 ?? RNASeqResultBundle.notRecordedText)
        facts["embedding"] = .string(name)
        facts["form"] = .string(rule.isPolygon ? "polygon" : "labels")
        facts["tableLabels"] = .array([.string(restLabel), .string(selectedLabel)])
        facts["samples"] = .array(counts.map {
            .dictionary(["sample": .string($0.sample), "selected": .integer($0.selected), "rest": .integer($0.rest), "leftOut": .integer($0.leftOut)])
        })
        return Outcome(table: RNASeqCellMap.labelTableData(rows), samples: counts, cellMapName: manifest.name,
                       cellMapManifestSHA256: manifestSHA, facts: facts)
    }
}

extension RNASeqCellMapSelection.Rule {
    var isPolygon: Bool {
        if case .polygon = self { return true }
        return false
    }
}
