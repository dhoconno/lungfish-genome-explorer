// RNASeqCellMapHandBackConformanceTests.swift - The hand-back blocks run in R with Seurat and in Python with Scanpy (Phase 5.5 lane CM-IMPORT, 5.5 I4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each test exports a single-cell result, adds an analysis where the template says it goes, runs the script in the Seurat
// environment (`LGE_RNASEQ_ENV_SEURAT`, else /Volumes/lge_scratch/lge/rnaseq/env-r-seurat) or the RNA-seq environment
// (`LGE_RNASEQ_ENV`, else /Volumes/lge_scratch/lge/rnaseq/env), and runs the import command the block printed on the table it
// wrote. Every cell has to match as given and be drawn in every embedding, with each stored Double equal to the table's text,
// and every cell has to hold its cluster. The result of two samples holds one barcode list twice, so a cell name read as a
// barcode, or a sample read from a name, matches no cell or the wrong one. A missing tool is a skip, and a failure with
// LUNGFISH_REQUIRE_TOOLS=1. `RNASeqCellMapHandBackTests` is the stand-in with no tool.

import Foundation
import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqCellMapHandBackConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-hand-back-tools") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func environment(_ variable: String, _ fallback: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment[variable] ?? fallback, isDirectory: true)
    }

    private var python: URL { environment("LGE_RNASEQ_ENV", "/Volumes/lge_scratch/lge/rnaseq/env").appendingPathComponent("bin/python") }
    private var rscript: URL { environment("LGE_RNASEQ_ENV_SEURAT", "/Volumes/lge_scratch/lge/rnaseq/env-r-seurat").appendingPathComponent("bin/Rscript") }

    /// The analysis each test adds before the hand-back block, as a person would.
    static let seuratAnalysis = """
    object <- Seurat::NormalizeData(object, verbose = FALSE)
    object <- Seurat::FindVariableFeatures(object, verbose = FALSE)
    object <- Seurat::ScaleData(object, verbose = FALSE)
    object <- Seurat::RunPCA(object, npcs = 10, verbose = FALSE)
    object <- Seurat::FindNeighbors(object, dims = 1:10, verbose = FALSE)
    object <- Seurat::FindClusters(object, verbose = FALSE)
    object <- Seurat::RunUMAP(object, dims = 1:10, verbose = FALSE)
    own <- SeuratObject::Embeddings(object, "umap"); own_meta <- object[[]]
    write.table(data.frame(sample = own_meta[["sample"]], barcode = own_meta[["barcode"]], x = sprintf("%a", own[rownames(own_meta), 1]), y = sprintf("%a", own[rownames(own_meta), 2])), "object-umap.tsv", sep = "\\t", quote = FALSE, row.names = FALSE)

    """
    /// The RNA-seq environment holds no igraph, so sc.tl.leiden cannot run there. The leiden column takes 10x's graph cluster of
    /// each cell by its barcode instead, with the first cell's label left out, so the test can check that each label reaches its cell.
    /// Both analyses also write the object's own UMAP of each cell as hex floats, `object-umap.tsv`, which the test compares with the map.
    static let scanpyAnalysis = """
    adata.X = adata.X.astype(np.float64)
    sc.pp.normalize_total(adata)
    sc.pp.log1p(adata)
    sc.pp.pca(adata, n_comps=10)
    sc.pp.neighbors(adata)
    sc.tl.umap(adata)
    tenx = pd.read_csv("\(CellMapImportFixture.clusters.path)", dtype=str).set_index("Barcode")["Cluster"]
    labels = [tenx.get(b if b.endswith("-1") else b + "-1") for b in adata.obs["barcode"]]
    labels[0] = None
    adata.obs["leiden"] = pd.Categorical(labels)
    pd.DataFrame({"sample": adata.obs["sample"].values, "barcode": adata.obs["barcode"].values, "x": [float(v).hex() for v in adata.obsm["X_umap"][:, 0]], "y": [float(v).hex() for v in adata.obsm["X_umap"][:, 1]]}).to_csv("object-umap.tsv", sep="\\t", index=False)

    """

    /// Runs `tool` in `folder` and returns the exit status and what it wrote. The wait ends at the lookup budget, and the exit
    /// status then fails the test. A signal on the termination handler replaces a sleep.
    private func run(_ tool: URL, _ arguments: [String], in folder: URL) throws -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { try ToolAvailability.skipOrFail("No \(tool.path) to run the template.") }
        let log = root.appendingPathComponent("run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = handle
        process.standardError = handle
        var variables = ProcessInfo.processInfo.environment
        variables["PATH"] = tool.deletingLastPathComponent().path + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        process.environment = variables
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + WaitBudget.lookup.seconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + WaitBudget.standard.seconds)
        }
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    /// A result of the STARsolo cut twice, as the samples cov_10 and cov_11, whose cells Seurat and Scanpy name `<sample>_<barcode>`.
    private func twoSamples() throws -> URL {
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let reads = try ["cov_10", "cov_11"].map { name in
            let copy = runs.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: RNASeqFixtures.root.appendingPathComponent(CellMapImportFixture.starsolo, isDirectory: true), to: copy)
            return try SingleCellFolderReader.read(folder: copy)
        }
        let samples = reads.enumerated().map { RNASeqSampleRecord(id: $1.sample, animal: "A\($0 + 1)", species: "Homo sapiens", runs: [$1.sample]) }
        let request = try SingleCellFolderReader.request(reads, name: "two", samples: samples, genomes: [])
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
            .write(request, to: analyses.appendingPathComponent("two.lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    /// Exports `result`, adds `analysis` before the hand-back block of `script` and runs it with `tool`. Returns the export folder
    /// and what the run printed.
    private func handBack(_ result: URL, script: String, analysis: String, tool: URL, arguments: [String]) throws -> (folder: URL, output: String) {
        let out = try RNASeqExport.run(
            results: [result], sheet: nil, settings: RNASeqExportSettings(), output: root.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"])
        let url = out.appendingPathComponent(script)
        var text = try String(contentsOf: url, encoding: .utf8)
        let block = try XCTUnwrap(text.range(of: "# ---- Hand back to LGE"), "\(script) holds the hand-back block")
        text.insert(contentsOf: analysis, at: block.lowerBound)
        try Data(text.utf8).write(to: url)
        let ran = try run(tool, arguments, in: out)
        XCTAssertEqual(ran.status, 0, ran.output)
        return (out, ran.output)
    }

    /// Each stored coordinate by embedding name, dimension, sample and barcode.
    private func stored(_ map: URL) throws -> [String: Double] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(map.appendingPathComponent("cellmap.sqlite").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT e.name, c.dimension, s.name, k.barcode, c.value FROM coordinates c JOIN embeddings e ON e.embedding = c.embedding "
            + "JOIN cells k ON k.cell = c.cell JOIN samples s ON s.sample = k.sample"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var values: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = (0..<4).map { $0 == 1 ? "\(sqlite3_column_int(statement, 1))" : String(cString: sqlite3_column_text(statement, Int32($0))) }
            values[text.joined(separator: "\t")] = sqlite3_column_double(statement, 4)
        }
        return values
    }

    /// Runs the import command the block printed, with RESULT and NEW filled in, and checks the cell map against the table.
    private func importPrinted(
        _ ran: (folder: URL, output: String), result: URL, label: String, unlabelled: Int = 0, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let printed = try XCTUnwrap(ran.output.split(separator: "\n").map(String.init).last { $0.hasPrefix("lungfish-cli rnaseq cell-map import ") },
                                    "the block prints the import command:\n\(ran.output)", file: file, line: line)
        let map = root.appendingPathComponent("Analyses/handed-\(UUID().uuidString).lungfishrnaseq", isDirectory: true)
        let words = printed.split(separator: " ").map { word -> String in
            let text = String(word)
            if text == "RESULT" { return result.path }
            if text == "NEW.lungfishrnaseq" { return map.path }
            return text.count >= 2 && text.hasPrefix("'") && text.hasSuffix("'") ? String(text.dropFirst().dropLast()) : text
        }
        let table = ran.folder.appendingPathComponent("lge-cell-map.tsv")
        let named = words[words.index(after: try XCTUnwrap(words.firstIndex(of: "--coordinates")))]
        XCTAssertEqual(URL(fileURLWithPath: named).resolvingSymlinksInPath().path, table.resolvingSymlinksInPath().path,
                       "the command names the table beside the script", file: file, line: line)
        XCTAssertTrue(printed.contains("--label-column \(label)"), printed, file: file, line: line)
        XCTAssertTrue(printed.contains("--method umap=UMAP") && printed.contains("--method pca=PCA"), printed, file: file, line: line)
        try await RNASeqCellMapImportSubcommand.parse(Array(words.dropFirst(4)) + ["--quiet"]).run()

        let rows = try String(contentsOf: table, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try XCTUnwrap(rows.first)
        XCTAssertEqual(Array(header.prefix(2)), ["sample", "barcode"], file: file, line: line)
        XCTAssertEqual(header.last, label, file: file, line: line)
        let cells = try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
        let samples = try cells.samples()
        let total = samples.map(\.cells).reduce(0, +)
        XCTAssertEqual(rows.count - 1, total, "the table lists every cell of the result", file: file, line: line)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite"))
        let embeddings = try database.embeddings()
        XCTAssertEqual(embeddings.map(\.name).sorted(), ["pca", "umap"], file: file, line: line)
        XCTAssertEqual(try database.embeddingCells().map(\.leftOut), Array(repeating: 0, count: 2 * samples.count), "no cell is left out", file: file, line: line)
        XCTAssertEqual(try database.embeddingCells().map(\.drawn).reduce(0, +), 2 * total, "every cell is drawn in both embeddings", file: file, line: line)
        let values = try stored(map)
        var wrong: [String] = []
        for row in rows.dropFirst() {
            for (column, name) in header.enumerated() where column >= 2 && name != label {
                let cut = try XCTUnwrap(name.lastIndex(of: "_"))
                let key = [String(name[..<cut]), String(name[name.index(after: cut)...]), row[0], row[1]].joined(separator: "\t")
                if values[key] != Double(row[column]) { wrong.append("\(key) is \(values[key].map { "\($0)" } ?? "missing") for \(row[column])") }
            }
        }
        XCTAssertEqual(wrong, [], "each stored Double equals the table's text", file: file, line: line)
        // The object's own UMAP of each cell, written by the analysis as hex floats so nothing is rounded: the map has to hold what
        // the tool holds for that (sample, barcode), so a coordinate paired with the wrong row fails here.
        let own = try String(contentsOf: ran.folder.appendingPathComponent("object-umap.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(own.count, total, "the object's UMAP is listed for every cell", file: file, line: line)
        for f in own {
            XCTAssertEqual(values["umap\t1\t\(f[0])\t\(f[1])"], Double(f[2]), "the map holds the object's own UMAP of each cell: \(f[0]) \(f[1])", file: file, line: line)
            XCTAssertEqual(values["umap\t2\t\(f[0])\t\(f[1])"], Double(f[3]), "the map holds the object's own UMAP of each cell: \(f[0]) \(f[1])", file: file, line: line)
        }
        let set = try XCTUnwrap(try database.labelSets().first { $0.name == label }, file: file, line: line)
        var labelled = samples.map(\.cells)
        labelled[0] -= unlabelled
        XCTAssertEqual(set.samples.map(\.labelled), labelled, "every cell holds its cluster but the \(unlabelled) left out", file: file, line: line)
        XCTAssertEqual(set.labels.map(\.cells).reduce(0, +), total - unlabelled, file: file, line: line)
    }

    func testTheSeuratBlockWritesATableThatImportsOnOneSampleAndOnTwo() async throws {
        for result in [try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root), try twoSamples()] {
            let ran = try handBack(result, script: "seurat.R", analysis: Self.seuratAnalysis, tool: rscript, arguments: ["--vanilla", "seurat.R"])
            try await importPrinted(ran, result: result, label: "seurat_clusters")
        }
    }

    func testTheScanpyBlockWritesATableThatImportsOnOneSampleAndOnTwo() async throws {
        for result in [try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root), try twoSamples()] {
            let ran = try handBack(result, script: "scanpy.py", analysis: Self.scanpyAnalysis, tool: python, arguments: ["-I", "scanpy.py"])
            try await importPrinted(ran, result: result, label: "leiden", unlabelled: 1)
            // Each line's label is 10x's cluster of its barcode, empty on the first line, written against the sample and barcode of obs.
            let cluster = Dictionary(try CellMapImportFixture.rows(CellMapImportFixture.clusters).map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            let lines = try String(contentsOf: ran.folder.appendingPathComponent("lge-cell-map.tsv"), encoding: .utf8).split(separator: "\n").dropFirst()
            let wrong = lines.enumerated().compactMap { index, line -> String? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let barcode = fields[1].hasSuffix("-1") ? fields[1] : fields[1] + "-1"
                return fields.last == (index == 0 ? "" : cluster[barcode]) ? nil : "\(fields[0]) \(fields[1]) \(fields.last ?? "")"
            }
            XCTAssertEqual(wrong, [], "each line holds the cluster of its barcode")
        }
    }
}
