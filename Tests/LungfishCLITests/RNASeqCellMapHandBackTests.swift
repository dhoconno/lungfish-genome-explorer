// RNASeqCellMapHandBackTests.swift - The hand-back block of seurat.R and scanpy.py, read with no tool (Phase 5.5 lane CM-IMPORT, 5.5 I4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// LGE reads no HDF5 and no RDS, so both export templates end with a block that writes lge-cell-map.tsv, LGE's table, and prints the
// `rnaseq cell-map import` command that reads it (docs/formats/rnaseq-cell-map.md, The hand-back table). This class reads the text of
// the two blocks and imports a table of the form they write, with the flags they print. `RNASeqCellMapHandBackConformanceTests` runs
// both blocks in R with Seurat and in Python with Scanpy after an analysis, and imports what they wrote.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqCellMapHandBackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-hand-back") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func export(_ result: URL) throws -> URL {
        try RNASeqExport.run(
            results: [result], sheet: nil, settings: RNASeqExportSettings(), output: root.appendingPathComponent("export", isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"])
    }

    /// Each block comes after the object is made, defines write_lge_cell_map, calls it when the object holds a reduction, takes
    /// sample and barcode from the metadata and never from a cell name, writes each number so it reads back exactly, and prints
    /// the import command with its --label-column and --method flags.
    func testBothTemplatesEndWithTheHandBackBlockAfterTheObject() throws {
        let out = try export(try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root))
        let seurat = try String(contentsOf: out.appendingPathComponent("seurat.R"), encoding: .utf8)
        let scanpy = try String(contentsOf: out.appendingPathComponent("scanpy.py"), encoding: .utf8)
        let cases: [(name: String, text: String, object: String, block: String, words: [String], never: [String])] = [
            ("seurat.R", seurat, "CreateSeuratObject(", "write_lge_cell_map <- function(object",
             [#"meta[["sample"]]"#, #"meta[["barcode"]]"#, #"sprintf("%.17g""#, "SeuratObject::Reductions(object)", "seurat_clusters",
              "write_lge_cell_map(object)", "The object holds no reduction yet"],
             ["colnames(object)", "Cells(object)", "strsplit(", "sub("]),
            ("scanpy.py", scanpy, "sc.AnnData(", "def write_lge_cell_map(adata",
             [#"adata.obs["sample"]"#, #"adata.obs["barcode"]"#, "repr(float(", "adata.obsm", #""leiden""#, #""louvain""#,
              "write_lge_cell_map(adata)", "The AnnData holds no reduction yet"],
             ["obs_names", ".split(", "re.sub("]),
        ]
        for item in cases {
            let object = try XCTUnwrap(item.text.range(of: item.object), "\(item.name) makes its object")
            let block = try XCTUnwrap(item.text.range(of: item.block), "\(item.name) defines write_lge_cell_map")
            XCTAssertTrue(object.upperBound < block.lowerBound, "\(item.name) defines the hand-back block after the object is made")
            let tail = String(item.text[block.lowerBound...])
            for words in ["lge-cell-map.tsv", "lungfish-cli", "rnaseq", "cell-map", "import", "--coordinates", "--label-column", "--method",
                          "--output", "NEW names the new cell map, such as <project>/Analyses/<name>.lungfishrnaseq", #""umap""#, #""UMAP""#, #""tsne""#, #""t-SNE""#, #""pca""#, #""PCA""#] + item.words {
                XCTAssertTrue(tail.contains(words), "the hand-back block of \(item.name) holds \(words)")
            }
            for words in item.never {
                XCTAssertFalse(tail.contains(words), "the hand-back block of \(item.name) reads no cell name, so it never holds \(words)")
            }
            XCTAssertTrue(item.text.contains("# ---- Add your analysis here"), "\(item.name) says where the analysis goes")
        }
    }

    /// A table of the form the Seurat block writes, sample always, barcode, each reduction as `<name>_1` to `<name>_<k>` in
    /// `%.17g`, then seurat_clusters with a missing label written empty, imports with the flags the block prints. Every cell is
    /// drawn in both embeddings with the stored Double equal to the text, the empty label leaves one cell unlabelled, and the
    /// record says the counts were not checked.
    func testATableOfTheBlocksFormImportsWithThePrintedFlags() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let sample = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples()[0].name
        let projection = try CellMapImportFixture.rows(CellMapImportFixture.projection)
        let label = Dictionary(try CellMapImportFixture.rows(CellMapImportFixture.clusters).map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        func number(_ x: Double) -> String { String(format: "%.17g", x) }
        var lines = ["sample\tbarcode\tumap_1\tumap_2\tpca_1\tpca_2\tpca_3\tseurat_clusters"]
        for (index, row) in projection.enumerated() {
            let x = try XCTUnwrap(Double(row[1])), y = try XCTUnwrap(Double(row[2]))
            let fields = [sample, row[0], number(x / 3), number(y / 7), number(x * 1e-5), number(-y), number(x + y),
                          index == 0 ? "" : label[row[0]] ?? ""]
            lines.append(fields.joined(separator: "\t"))
        }
        let table = root.appendingPathComponent("lge-cell-map.tsv")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: table)
        let map = root.appendingPathComponent("Analyses/handed.lungfishrnaseq", isDirectory: true)
        try await RNASeqCellMapImportSubcommand.parse([
            result.path, "--coordinates", table.path, "--label-column", "seurat_clusters", "--method", "umap=UMAP", "--method", "pca=PCA",
            "--output", map.path, "--quiet",
        ]).run()
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try database.embeddings().map { [$0.name, $0.method ?? "Not recorded", "\($0.dimensions)"] },
                       [["umap", "UMAP", "2"], ["pca", "PCA", "3"]])
        XCTAssertEqual(try database.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0], [200, 0]])
        let stored = try CellMapImportFixture.coordinates(map)
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            XCTAssertEqual(stored[1]?[fields[1]], Double(fields[2]), fields[1])
            XCTAssertEqual(stored[2]?[fields[1]], Double(fields[3]), fields[1])
        }
        let set = try XCTUnwrap(try database.labelSets().first)
        XCTAssertEqual(set.name, "seurat_clusters")
        XCTAssertEqual(set.samples.map { [$0.labelled, $0.unlabelled] }, [[199, 1]])
        let facts = try CellMapImportFixture.facts(map)
        XCTAssertEqual(facts["choices"], .dictionary(["barcodeSuffix": .string("as given"), "barcodesNotHeld": .string("refused"),
                                                      "counts": .string("not checked")]))
    }
}
