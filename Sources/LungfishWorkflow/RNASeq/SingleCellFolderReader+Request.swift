// SingleCellFolderReader+Request.swift - The writer's request, the record's facts and the summary numbers (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension SingleCellFolderReader {
    /// The writer's request for folders of one tool and one feature list. Each sample's matrix is read in the
    /// writer's stage, and genomes, when named, split each cell's UMIs by the id prefix of the gene.
    public static func request(
        _ folders: [SingleCellFolder], name: String, samples: [RNASeqSampleRecord], genomes: [String]
    ) throws -> RNASeqResultWriter.Request {
        guard let first = folders.first else { throw SingleCellImportError.notSingleCellFolder(name) }
        guard folders.allSatisfy({ $0.tool == first.tool }) else { throw SingleCellImportError.toolsDiffer }
        if let other = folders.first(where: { $0.featureIDs != first.featureIDs }) {
            throw SingleCellImportError.featuresDiffer(first: first.sample, other: other.sample)
        }
        if !genomes.isEmpty {
            for (id, type) in zip(first.featureIDs, first.featureTypeOfRow) where type == geneExpression {
                guard genomes.contains(where: { id.hasPrefix($0 + "_") }) else {
                    throw SingleCellImportError.featureOfNoGenome(feature: id, sample: first.sample, genomes: genomes)
                }
            }
        }
        let sourceFiles = folders.flatMap { folder in
            folder.keptFiles.map {
                RNASeqResultWriter.SourceFile(url: folder.url.appendingPathComponent($0), relativePath: $0, sample: folder.sample, tool: folder.tool.rawValue)
            }
        }
        let matrices = folders.map {
            RNASeqResultWriter.MatrixInput(sample: $0.sample, matrix: $0.matrix, features: $0.features, barcodes: $0.barcodes)
        }
        var columns: [String] = []
        for folder in folders { for column in folder.qualityColumns where !columns.contains(column) { columns.append(column) } }
        let quality = columns.isEmpty ? nil : RNASeqQualityTable(columns: columns, rows: folders.map { folder in
            RNASeqQualityTable.Row(sample: folder.sample, values: columns.map { column in
                folder.qualityColumns.firstIndex(of: column).map { folder.qualityValues[$0] }
            })
        })
        // The same tool at two versions is two routes (`docs/formats/rnaseq-bundle.md`, What the export reads and
        // refuses), so only a version every folder states is recorded.
        let version = first.toolVersion.flatMap { stated in folders.allSatisfy { $0.toolVersion == stated } ? stated : nil }
            ?? RNASeqImportFacts.notRecorded
        return RNASeqResultWriter.Request(
            name: name, modality: .singleCell,
            origin: .init(kind: .imported, tool: first.tool.rawValue, toolVersion: version),
            route: route(first.tool, version: version), referenceSet: nil, samples: samples, genes: .ids(first.featureIDs), counts: [],
            sourceFiles: sourceFiles, notHost: [], matrices: matrices, genomes: genomes, quality: quality)
    }

    /// The route of a tool's filtered matrix at `version`. Cell Ranger's matrix states its version and STARsolo's
    /// folder keeps none, so a STARsolo route reads Not recorded.
    public static func route(_ tool: SingleCellTool, version: String = RNASeqImportFacts.notRecorded) -> RNASeqResultManifest.Route {
        switch tool {
        case .cellRanger:
            return .init(id: "cellranger-filtered-matrix", tool: tool.rawValue, toolVersion: version,
                         settings: ["matrix": "filtered_feature_bc_matrix", "counts": "UMIs"])
        case .starsolo:
            return .init(id: "starsolo-gene-filtered-matrix", tool: tool.rawValue, toolVersion: version,
                         settings: ["features": "Gene", "matrix": "Solo.out/Gene/filtered", "counts": "UMIs"])
        }
    }

    /// The record's facts: what the files do not state, the files left out, the feature types and the genomes.
    public static func facts(_ folders: [SingleCellFolder], genomes: [String]) -> [String: ParameterValue] {
        var facts = RNASeqImportFacts.unstated
        let leftOut = folders.flatMap { folder in
            folder.leftOut.map { path -> ParameterValue in
                guard let file = folder.leftOutHDF5.first(where: { $0.path == path }) else { return .string("\(folder.sample)/\(path)") }
                return .string("\(folder.sample)/\(path) (sha256 \(file.sha256), \(file.size) bytes)")
            }
        }
        if !leftOut.isEmpty { facts[RNASeqImportFacts.filesLeftOutKey] = .array(leftOut) }
        facts["featureTypes"] = .array(folders.map { folder in
            .string("\(folder.sample): " + folder.featureTypes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        })
        facts["genomes"] = .string(genomes.isEmpty ? "Not named" : "\(genomes.joined(separator: ", ")), named by the person by the prefix of each gene id")
        return facts
    }

    /// The names and values of `metrics_summary.csv` (a header row and a value row) or STARsolo's `Summary.csv` (a
    /// name and a value a line), as the tool printed them.
    static func summary(_ base: URL, tool: SingleCellTool, present: [String]) throws -> [(String, String)] {
        let file = tool == .cellRanger ? "metrics_summary.csv" : "Solo.out/Gene/Summary.csv"
        guard present.contains(file) else { return [] }
        let text = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
        let rows = text.split(whereSeparator: \.isNewline).map { csvFields(String($0)) }
        switch tool {
        case .cellRanger:
            guard rows.count >= 2 else { return [] }
            return zip(rows[0], rows[1]).map { ($0, $1) }
        case .starsolo:
            return rows.compactMap { $0.count >= 2 ? ($0.dropLast().joined(separator: ","), $0[$0.count - 1]) : nil }
        }
    }

    /// The fields of one CSV line, with double quotes around a field that holds a comma.
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var previous: Character?
        for character in line {
            if character == "\"" {
                if quoted, previous == "\"" { field.append("\"") }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            previous = character
        }
        fields.append(field)
        return fields
    }
}
