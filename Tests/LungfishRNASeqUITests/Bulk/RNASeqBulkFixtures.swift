// RNASeqBulkFixtures.swift - Bulk results for the tests of the bulk view, each written by the one writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

enum RNASeqBulkFixtures {
    static let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")

    static func write(_ request: RNASeqResultWriter.Request, to url: URL) throws -> URL {
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    /// `import rnaseq` of the two salmon-c1 folders with a `--tx2gene`, built as `ImportRNASeqSubcommand` builds it
    /// (`Plan.request()`). The map puts each ERCC transcript in a gene of its own and every 4 other transcripts in
    /// one gene, in `quant.sf` order, so a gene's count is a sum of salmon's 3-decimal values.
    static func importSalmonC1(into folder: URL) throws -> URL {
        let folders = try RNASeqFixtures.salmonRunIDs.map {
            try SalmonQuantFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("salmon-c1/\($0)", isDirectory: true))
        }
        let transcripts = try SalmonQuantFolderReader.transcriptCounts(folders)
        var map: [String: String] = [:]
        for (index, row) in transcripts.rows.enumerated() {
            map[row.id] = row.id.hasPrefix("ERCC-") ? row.id : "ENSG-test-\(index / 4)"
        }
        let genes = try SalmonQuantFolderReader.geneCounts(folders, tx2gene: SalmonTx2Gene(geneByTranscript: map))
        let route = try SalmonQuantFolderReader.route(folders, tx2geneName: "tx2gene.tsv")
        let request = RNASeqResultWriter.Request(
            name: "salmon-c1", modality: .bulk,
            origin: .init(kind: .imported, tool: SalmonQuantFolderReader.tool, toolVersion: route.toolVersion),
            route: route, referenceSet: nil, samples: folders.map { RNASeqSampleRecord(id: $0.sample, runs: [$0.sample]) },
            genes: .ids(genes.rows.map(\.id)),
            counts: [.init(rows: .gene, column: .default, unit: .estimated, table: genes),
                     .init(rows: .transcript, column: .default, unit: .estimated, table: transcripts)],
            sourceFiles: SalmonQuantFolderReader.sourceFiles(folders), notHost: [],
            quality: SalmonQuantFolderReader.qualityTable(folders))
        return try write(request, to: folder.appendingPathComponent("salmon-c1.lungfishrnaseq", isDirectory: true))
    }

    /// The gene rows of the named result, as a set's `derived/genes.tsv` lists them. The last gene has no name,
    /// biotype or flag, which the view shows as Not recorded.
    static let namedGenes: [RNASeqGeneRecord] = [
        RNASeqGeneRecord(id: "ENSG00000141510", name: "TP53", biotype: "protein_coding", contig: "17", length: 25768, notHost: false),
        RNASeqGeneRecord(id: "ENSG00000111640", name: "GAPDH", biotype: "protein_coding", contig: "12", length: 4408, notHost: false),
        RNASeqGeneRecord(id: "ENSG00000275215", name: "RNA5-8SN4", biotype: "rRNA", contig: "21", length: 151, notHost: false),
        RNASeqGeneRecord(id: "NC_045512.2", name: "sars-cov-2", biotype: "virus", contig: "NC_045512.2", length: 29903, notHost: true),
        RNASeqGeneRecord(id: "ENSG00000999999"),
    ]

    /// A result on a reference set, with names, biotypes and a not-host feature in `genes.tsv` and a masked table beside
    /// the default one.
    static func writeNamed(into folder: URL) throws -> URL {
        let set = folder.appendingPathComponent("genes-of-set.tsv")
        try RNASeqGeneRecord.tsvData(namedGenes).write(to: set)
        let ids = namedGenes.map(\.id)
        let samples = ["S1", "S2", "S3"]
        let counts = RNASeqCountTable(sampleIDs: samples, rows: [
            .init(id: ids[0], counts: [120, 98.5, 0.25]), .init(id: ids[1], counts: [5000, 4210, 3999.75]),
            .init(id: ids[2], counts: [40, 0, 12]), .init(id: ids[3], counts: [7, 0, 1e-05]), .init(id: ids[4], counts: [0, 0, 0]),
        ])
        let masked = RNASeqCountTable(sampleIDs: samples, rows: ids.map { .init(id: $0, counts: $0 == ids[3] ? [3, 0, 0] : [0, 0, 0]) })
        let request = RNASeqResultWriter.Request(
            name: "Named genes", modality: .bulk, origin: .init(kind: .quantified, tool: "salmon", toolVersion: "1.10.3"),
            route: .init(id: "salmon-selective-alignment-reads", tool: "salmon", toolVersion: "1.10.3", settings: ["counts": "NumReads"]),
            referenceSet: .init(id: "test-set", layout: .lge),
            samples: samples.map { RNASeqSampleRecord(id: $0, runs: [$0]) },
            genes: .referenceSetTable(url: set, keeping: ids),
            counts: [.init(rows: .gene, column: .default, unit: .reads, table: counts),
                     .init(rows: .gene, column: .masked, unit: .reads, table: masked)],
            sourceFiles: [], notHost: [ids[3]])
        return try write(request, to: folder.appendingPathComponent("named.lungfishrnaseq", isDirectory: true))
    }

    /// A bulk view that showed the result at `url` as the surface shows it, with its quality numbers read.
    @MainActor
    static func show(_ url: URL) async throws -> RNASeqBulkViewController {
        guard case .loaded(let result) = RNASeqResultSurface.read(url) else {
            throw NSError(domain: "RNASeqBulkFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(RNASeqResultSurface.read(url))"])
        }
        let controller = RNASeqBulkViewController(model: RNASeqBulkModel())
        controller.configure(result: result, bundleURL: url)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        await controller.model.qualityRead()
        controller.reloadFromModel()
        return controller
    }

    /// The table as the file prints it, rebuilt from the cells the model gives, header first.
    @MainActor
    static func printed(_ model: RNASeqBulkModel, table: Int) -> String {
        let lines = [(["feature_id"] + model.tables[table].sampleIDs).joined(separator: "\t")]
            + model.tables[table].visibleRows.map { model.countCells(table: table, row: $0).joined(separator: "\t") }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// Path, size, modification time and sha256 of every item under the folder.
    static func snapshot(_ folder: URL) throws -> [String: String] {
        var items: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(folder.path.count))
            items[relative] = values.isDirectory == true ? "directory"
                : "\(try RNASeqResultBundle.sha256Hex(fileAt: url)) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return items
    }
}
