// RNASeqPseudobulkSelectionTests.swift - `rnaseq cell-map select` and the pseudobulk of a selection (Phase 5.5 lane CM-SELECT-CLI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Check X3 and BIO's P6 on the 200-cell cuts, with CM-TRUTH's numbers (`selection/p1-cut200`, `p2-cut200` and
// `p2-cut200-leave30` of `scripts/repro/rnaseq/sc-embed/truth/claims.tsv`). Selecting every cell of graph cluster 1 gives
// the same pseudobulk bytes as a table that labels that cluster by hand. Selected, rest and unlabelled UMIs add up to the
// sample's Gene Expression UMIs, also where the embedding leaves 30 cells out. The record names the cell map by manifest
// sha256 and verifies, a cell map of another parent is refused in words, each recorded command replays to equal bytes,
// and each refusal of the format page speaks its words and writes nothing.

import ArgumentParser
import CryptoKit
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqPseudobulkSelectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-pseudobulk-selection") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// The UMIs of each cut, all Gene Expression (`Tests/Fixtures/rnaseq/README.md`, How the cut chose rows).
    static let starsoloUMIs = 212_629
    static let cellRangerUMIs = 212_733
    static let clusterOne = ["--embedding", "TSNE", "--label-set", "graphclust", "--label", "1"]

    private var analyses: URL { root.appendingPathComponent("Analyses", isDirectory: true) }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A cell map of 10x's t-SNE and graph clusters on `result`. The STARsolo cut needs the suffix flag and other counts.
    private func tenxMap(_ result: URL, name: String = "tsne", starsolo: Bool) async throws -> URL {
        let map = analyses.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        try await RNASeqCellMapImportSubcommand.parse([
            result.path, "--coordinates", CellMapImportFixture.projection.path, "--clusters", CellMapImportFixture.clusters.path,
        ] + (starsolo ? ["--barcode-suffix", "drop", "--other-counts"] : []) + ["--output", map.path, "--quiet"]).run()
        return map
    }

    /// A cell map of the STARsolo cut whose LGE table lists only the first 170 columns, so its embedding leaves out the
    /// last 30 cells, the 30 that the pseudobulk fixture leaves with no label (CM-TRUTH `p2-cut200-leave30`).
    private func leave30Map(_ result: URL) async throws -> URL {
        let manifest = try RNASeqResultBundle.loadManifest(from: result)
        let summary = try XCTUnwrap(manifest.cellsSummary)
        let cells = try RNASeqCellsDatabase(url: try RNASeqResultBundle.resolve(summary.path, in: result)).cells(offset: 0, limit: 200)
            .sorted { $0.column < $1.column }
        let projection = Dictionary(try CellMapImportFixture.rows(CellMapImportFixture.projection).map { ($0[0], $0) }, uniquingKeysWith: { a, _ in a })
        let clusters = Dictionary(try CellMapImportFixture.rows(CellMapImportFixture.clusters).map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        var text = "sample\tbarcode\tTSNE_1\tTSNE_2\tgraphclust\n"
        for cell in cells.prefix(170) {
            let row = try XCTUnwrap(projection[cell.barcode + "-1"], cell.barcode)
            text += "\(CellMapImportFixture.starsolo)\t\(cell.barcode)\t\(row[1])\t\(row[2])\t\(try XCTUnwrap(clusters[cell.barcode + "-1"]))\n"
        }
        let table = root.appendingPathComponent("lge-cell-map.tsv")
        try text.write(to: table, atomically: true, encoding: .utf8)
        let map = analyses.appendingPathComponent("leave30.lungfishrnaseq", isDirectory: true)
        try await RNASeqCellMapImportSubcommand.parse([result.path, "--coordinates", table.path, "--label-column", "graphclust",
                                                       "--output", map.path, "--quiet"]).run()
        return map
    }

    /// The table of a selection where the app writes it, in a new hidden folder under Analyses.
    private func newTableURL() throws -> URL {
        let folder = analyses.appendingPathComponent(".lungfish-cell-map-inputs/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("selection.tsv")
    }

    private func select(_ map: URL, _ form: [String], to table: URL? = nil) async throws -> URL {
        let output = try table ?? newTableURL()
        try await RNASeqCellMapSelectSubcommand.parse([map.path] + form + ["--output", output.path, "--quiet"]).run()
        return output
    }

    private func pseudobulk(_ result: URL, labels: URL, cellMap: URL?, name: String) async throws -> URL {
        let output = analyses.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        try await RNASeqPseudobulkSubcommand.parse([result.path, "--labels", labels.path] + (cellMap.map { ["--cell-map", $0.path] } ?? [])
            + ["--output", output.path, "--quiet"]).run()
        return output
    }

    private func facts(_ folder: URL) throws -> [String: ParameterValue] {
        try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: folder)).options.resolvedDefaults
    }

    /// Each group of a pseudobulk record's list as label, cells and UMIs.
    private func groups(_ facts: [String: ParameterValue], _ key: String) -> [String] {
        guard case .array(let list)? = facts[key] else { return [] }
        return list.compactMap { item -> String? in
            guard case .dictionary(let fields) = item, case .integer(let cells)? = fields["cells"], case .integer(let umis)? = fields["umis"] else { return nil }
            if case .string(let label)? = fields["label"] { return "\(label) \(cells) \(umis)" }
            return "\(cells) \(umis)"
        }
    }

    private func labelsOfTable(_ table: URL) throws -> [String] {
        try String(contentsOf: table, encoding: .utf8).split(separator: "\n").dropFirst().map { String($0.split(separator: "\t")[2]) }
    }

    // MARK: - P6 on the cuts

    /// P1, `selection/p1-cut200`. Graph cluster 1 of the Cell Ranger cut is 32 cells with 62,422 UMIs and the rest 168 with
    /// 150,311. The pseudobulk of the selection equals, byte for byte, the pseudobulk of a hand-written table that labels
    /// cluster 1 `selected` and every other cell `rest`, and its selected column equals CM-TRUTH's sums of cluster 1.
    func testSelectingEveryCellOfOneClusterGivesTheSameBytesAsThatClustersTable() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, in: root)
        let map = try await tenxMap(result, starsolo: false)
        let table = try await select(map, Self.clusterOne)
        let labels = try labelsOfTable(table)
        XCTAssertEqual([labels.filter { $0 == "selected" }.count, labels.filter { $0 == "rest" }.count], [32, 168])
        let fromSelection = try await pseudobulk(result, labels: table, cellMap: map, name: "cluster-1")

        var hand = "barcode\tlabel\n"
        for row in try CellMapImportFixture.rows(CellMapImportFixture.clusters).reversed() { hand += "\(row[0])\t\(row[1] == "1" ? "selected" : "rest")\n" }
        let handTable = root.appendingPathComponent("cluster-1-by-hand.tsv")
        try hand.write(to: handTable, atomically: true, encoding: .utf8)
        let fromHand = try await pseudobulk(result, labels: handTable, cellMap: nil, name: "cluster-1-by-hand")
        for file in ["samples.tsv", "genes.tsv", "counts/genes.counts.tsv"] {
            XCTAssertEqual(try sha256(fromSelection.appendingPathComponent(file)), try sha256(fromHand.appendingPathComponent(file)), file)
        }
        let facts = try facts(fromSelection)
        XCTAssertEqual(groups(facts, "groupsKept"), ["rest 168 150311", "selected 32 62422"])
        XCTAssertEqual(groups(facts, "cellsWithNoLabel"), [])

        let counts = try RNASeqCountTable(tsv: Data(contentsOf: fromSelection.appendingPathComponent("counts/genes.counts.tsv")), path: "genes.counts.tsv")
        let selected = try XCTUnwrap(counts.sampleIDs.firstIndex { $0.hasSuffix("_selected") })
        let truth = try String(contentsOf: RNASeqFixtures.root.appendingPathComponent("cell-map-pbmc_1k_v3/expected-labels-cellranger.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let ofCluster = Dictionary(truth.map { ($0[0], Double($0[1]) ?? -1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(counts.rows.count, truth.count)
        XCTAssertEqual(counts.rows.filter { ofCluster[$0.id] != $0.counts[selected] }.map(\.id), [], "the selected column equals CM-TRUTH's cluster 1")
    }

    /// P2 and `p2-cut200-leave30`. On the STARsolo cut the selection of cluster 1 is 32 cells with 62,390 UMIs and the rest
    /// 168 with 150,239. With the embedding leaving out the last 30 cells it is 28 with 56,223, the rest 142 with 124,986,
    /// and the 30 cells with no line hold 31,420 UMIs. Each way the three add up to the cut's 212,629.
    func testSelectedRestAndUnlabelledUMIsAddUpAlsoWhereTheEmbeddingLeavesCellsOut() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let cases: [(URL, [String], [String], [Int])] = [
            (try await tenxMap(result, starsolo: true), ["rest 168 150239", "selected 32 62390"], [], [32, 168, 0]),
            (try await leave30Map(result), ["rest 142 124986", "selected 28 56223"], ["30 31420"], [28, 142, 30]),
        ]
        for (map, kept, unlabelled, cells) in cases {
            let what = map.lastPathComponent
            let table = try await select(map, Self.clusterOne)
            let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: table)), what)
            XCTAssertEqual(record.options.resolvedDefaults["samples"], .array([.dictionary([
                "sample": .string(CellMapImportFixture.starsolo), "selected": .integer(cells[0]), "rest": .integer(cells[1]), "leftOut": .integer(cells[2]),
            ])]), what)
            XCTAssertEqual(try labelsOfTable(table).count, cells[0] + cells[1], "a cell left out of the embedding has no line in \(what)")
            let summed = try await pseudobulk(result, labels: table, cellMap: map, name: "sum-\(map.deletingPathExtension().lastPathComponent)")
            let facts = try facts(summed)
            XCTAssertEqual(groups(facts, "groupsKept"), kept, what)
            XCTAssertEqual(groups(facts, "cellsWithNoLabel"), unlabelled, what)
            let total = (groups(facts, "groupsKept") + groups(facts, "groupsLeftOut") + groups(facts, "cellsWithNoLabel"))
                .compactMap { Int($0.split(separator: " ").last ?? "") }.reduce(0, +)
            XCTAssertEqual(total, Self.starsoloUMIs, "selected, rest and unlabelled UMIs add up to the sample's Gene Expression UMIs in \(what)")
        }
    }

    // MARK: - The record and the replay

    /// The record names the result and the table by sha256, as before, and the cell map by its manifest's path and sha256.
    /// Its command puts `--cell-map` between `--labels` and `--output`. The result stays at schema 1 with origin
    /// pseudobulk. `provenance verify` passes on the record and fails on a copy with one digit edited.
    func testTheRecordNamesTheCellMapByManifestSha256AndVerifies() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = try await tenxMap(result, starsolo: true)
        let table = try await select(map, Self.clusterOne)
        let out = analyses.appendingPathComponent("cluster-1.lungfishrnaseq", isDirectory: true)
        try await withThrowawayKey {
            try await RNASeqPseudobulkSubcommand.parse([result.path, "--labels", table.path, "--cell-map", map.path, "--output", out.path, "--quiet"]).run()
        }
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        XCTAssertEqual(record.argv, ["lungfish-cli", "rnaseq", "pseudobulk", result.path, "--labels", table.path, "--cell-map", map.path, "--output", out.path])
        let mapManifest = RNASeqResultBundle.manifestURL(in: map)
        XCTAssertEqual(record.files.first { $0.path == mapManifest.path }?.checksumSHA256, try sha256(mapManifest))
        XCTAssertEqual(record.files.first { $0.path == table.path }?.checksumSHA256, try sha256(table))
        XCTAssertEqual(record.options.resolvedDefaults["cellMapManifestSHA256"], .string(try sha256(mapManifest)))
        XCTAssertEqual(record.options.explicit["cellMap"], .file(map))
        let manifest = try RNASeqResultBundle.loadManifest(from: out)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.origin.kind, .pseudobulk)
        XCTAssertNil(manifest.parent)

        let tableRecord = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: table)))
        XCTAssertEqual(tableRecord.options.resolvedDefaults["cellMapManifestSHA256"], .string(try sha256(mapManifest)))
        XCTAssertEqual(tableRecord.options.resolvedDefaults["labelSet"], .string("graphclust"))
        XCTAssertEqual(tableRecord.files.first { $0.path == mapManifest.path }?.checksumSHA256, try sha256(mapManifest))
        XCTAssertEqual(tableRecord.output?.checksumSHA256, try sha256(table))

        let file = out.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let signature = ProvenanceSigningConfiguration.signatureURL(for: file)
        let publicKey = ProvenanceSigningConfiguration.publicKeyURL(for: file)
        try await ProvenanceCommand.VerifySubcommand.parse([out.path]).run()
        let text = try String(contentsOf: file, encoding: .utf8)
        let digit = try XCTUnwrap(text.firstIndex { $0.isASCII && $0.isNumber })
        var edited = text
        edited.replaceSubrange(digit...digit, with: String(((text[digit].wholeNumberValue ?? 0) + 1) % 10))
        let tampered = root.appendingPathComponent("tampered", isDirectory: true).appendingPathComponent(file.lastPathComponent)
        try FileManager.default.createDirectory(at: tampered.deletingLastPathComponent(), withIntermediateDirectories: true)
        try edited.write(to: tampered, atomically: true, encoding: .utf8)
        do {
            try await ProvenanceCommand.VerifySubcommand.parse([tampered.path, "--signature", signature.path, "--public-key", publicKey.path]).run()
            XCTFail("a copy of the record with one digit edited still verifies")
        } catch {
            // The verifier refuses the edited copy, as it must.
        }
    }

    /// The recorded select command parses to the same vertices, printed in Float32 shortest round-trip form, and a replay
    /// writes a table of equal sha256. The recorded pseudobulk command, with `--cell-map`, replays to equal tables.
    func testTheRecordedCommandsReplayToEqualBytes() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = try await tenxMap(result, starsolo: true)
        let first = try await select(map, ["--embedding", "TSNE", "--polygon", "-100.0,-100.00 0.10,-100 0.1,100 -100,100"])
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: first)))
        let polygon = try XCTUnwrap(record.argv.firstIndex(of: "--polygon"))
        XCTAssertEqual(record.argv[polygon + 1], "-100.0,-100.0 0.1,-100.0 0.1,100.0 -100.0,100.0")
        XCTAssertEqual(record.options.resolvedDefaults["vertices"], .integer(4))
        var argv = Array(record.argv.dropFirst(4))
        let second = try newTableURL()
        argv[try XCTUnwrap(argv.firstIndex(of: "--output")) + 1] = second.path
        let reparsed = try RNASeqCellMapSelectSubcommand.parse(argv + ["--quiet"])
        XCTAssertEqual(try RNASeqCellMapSelect.parsePolygon(record.argv[polygon + 1]),
                       try RNASeqCellMapSelect.parsePolygon("-100.0,-100.00 0.10,-100 0.1,100 -100,100"), "the recorded text parses to the run's vertices")
        try await reparsed.run()
        XCTAssertEqual(try sha256(second), try sha256(first))

        let one = try await pseudobulk(result, labels: first, cellMap: map, name: "half-1")
        var pseudobulkArgv = Array(try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: one)).argv.dropFirst(3))
        let two = analyses.appendingPathComponent("half-2.lungfishrnaseq", isDirectory: true)
        pseudobulkArgv[try XCTUnwrap(pseudobulkArgv.firstIndex(of: "--output")) + 1] = two.path
        try await RNASeqPseudobulkSubcommand.parse(pseudobulkArgv + ["--quiet"]).run()
        for file in ["samples.tsv", "genes.tsv", "counts/genes.counts.tsv"] {
            XCTAssertEqual(try sha256(two.appendingPathComponent(file)), try sha256(one.appendingPathComponent(file)), file)
        }
    }

    // MARK: - Words

    /// A cell map of another single-cell result is refused in words that name both sha256 values and the parent, and a
    /// result that is not a cell map gets select's words. Nothing is written.
    func testACellMapOfAnotherParentIsRefusedInWords() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let other = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "other", in: root)
        let map = try await tenxMap(parent, starsolo: true)
        let table = try await select(map, Self.clusterOne)
        let out = analyses.appendingPathComponent("refused.lungfishrnaseq", isDirectory: true)
        let parentSHA = try sha256(RNASeqResultBundle.manifestURL(in: parent))
        let otherSHA = try sha256(RNASeqResultBundle.manifestURL(in: other))
        let cases: [(URL, String)] = [
            (map, "tsne.lungfishrnaseq was made from the single-cell result whose manifest has sha256 \(parentSHA), and other.lungfishrnaseq has \(otherSHA). "
                + "Give the result the cell map was made from, \(parent.path)."),
            (parent, "cells is not a cell map. rnaseq cell-map select reads a result that rnaseq cell-map import or compute made."),
        ]
        for (cellMap, words) in cases {
            XCTAssertThrowsError(try RNASeqPseudobulkSubcommand.parse([other.path, "--labels", table.path, "--cell-map", cellMap.path, "--output", out.path])
                .write { _ in }) { error in
                XCTAssertEqual((error as? LocalizedError)?.errorDescription, words)
            }
            do {
                try await RNASeqPseudobulkSubcommand.parse([other.path, "--labels", table.path, "--cell-map", cellMap.path, "--output", out.path, "--quiet"]).run()
                XCTFail("pseudobulk summed with \(cellMap.lastPathComponent)")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    /// With `--cell-map` the CLI says W7 after the notes and before its summary line, and without it the words stay out.
    func testThePseudobulkOfASelectionSaysW7() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = try await tenxMap(result, starsolo: true)
        let table = try await select(map, Self.clusterOne)
        var notes: [String] = []
        _ = try RNASeqPseudobulkSubcommand.parse([result.path, "--labels", table.path, "--cell-map", map.path,
                                                  "--output", analyses.appendingPathComponent("w7.lungfishrnaseq").path]).write { notes.append($0) }
        XCTAssertEqual(notes.last, "Cells picked from this picture differ in the genes that drew it, so testing a selection against the rest "
                       + "finds those genes by construction. Compare samples or animals within one selection.")
        notes = []
        _ = try RNASeqPseudobulkSubcommand.parse([result.path, "--labels", table.path,
                                                  "--output", analyses.appendingPathComponent("no-w7.lungfishrnaseq").path]).write { notes.append($0) }
        XCTAssertFalse(notes.contains(RNASeqPseudobulk.selectionWords))
    }

    /// Each refusal of `cell-map select` on the format page, in its words, with the input exit code and no table, no
    /// record and no staged file.
    func testEachRefusalOfSelectSpeaksTheFormatPagesWordsAndWritesNothing() async throws {
        let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = try await tenxMap(result, starsolo: true)
        let existing = try await select(map, Self.clusterOne)
        let output = try newTableURL()
        let many = (0..<1_001).map { "\($0),0" }.joined(separator: " ")
        let cases: [([String], URL, String)] = [
            (["--embedding", "TSNE", "--polygon", "0,0 1,0 1,1", "--label-set", "graphclust", "--label", "1"], output,
             "Give --polygon, or --label-set with --label, and not both."),
            (["--embedding", "TSNE", "--label-set", "graphclust"], output, "Give --polygon, or --label-set with --label, and not both."),
            (["--embedding", "TSNE", "--polygon", many], output,
             "The polygon has 1,001 vertices, and cell-map select takes at most 1,000. Draw it again with fewer turns, or pass fewer vertices."),
            (["--embedding", "TSNE", "--polygon", "0,0 10,10"], output, "The polygon has 2 vertices. Give at least 3, such as '0,0 10,0 10,10'."),
            (["--embedding", "TSNE", "--polygon", "0,0 1,nan 1,1"], output, "Vertex 2 of --polygon reads 1,nan, which is not x,y with two finite decimal numbers."),
            (["--embedding", "UMAP", "--label-set", "graphclust", "--label", "1"], output, "tsne.lungfishrnaseq holds no embedding UMAP. Its embeddings are TSNE."),
            (["--embedding", "TSNE", "--label-set", "kmeans", "--label", "1"], output,
             "tsne.lungfishrnaseq holds no label set kmeans. Its label sets are graphclust."),
            (["--embedding", "TSNE", "--label-set", "graphclust", "--label", "9"], output,
             "The label set graphclust holds no label 9. Its labels are 1, 2, 3, 4, 5, 6 and 7."),
            (["--embedding", "TSNE", "--polygon", "1000,1000 1001,1000 1001,1001"], output,
             "The selection holds no cell drawn in TSNE. Draw the polygon around drawn cells, or choose a label that holds some."),
            (Self.clusterOne, existing, "\(existing.path) already exists. Choose a new name for the table."),
            (Self.clusterOne, map.appendingPathComponent("selection.tsv"),
             "--output names a file inside the result tsne.lungfishrnaseq. LGE never writes inside a result, so choose a place outside it."),
        ]
        for (form, table, words) in cases {
            XCTAssertThrowsError(try RNASeqCellMapSelectSubcommand.parse([map.path] + form + ["--output", table.path]).write(), words) { error in
                XCTAssertEqual((error as? LocalizedError)?.errorDescription, words)
            }
        }
        XCTAssertThrowsError(try RNASeqCellMapSelectSubcommand.parse([result.path] + Self.clusterOne + ["--output", output.path]).write()) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "cells is not a cell map. rnaseq cell-map select reads a result that rnaseq cell-map import or compute made.")
        }
        let database = map.appendingPathComponent("cellmap.sqlite")
        let handle = try FileHandle(forWritingTo: database)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try RNASeqCellMapSelectSubcommand.parse([map.path] + Self.clusterOne + ["--output", output.path]).write()) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "The file cellmap.sqlite of tsne differs from the sha256 that its manifest lists, "
                           + "so the result changed after LGE wrote it. Import the tool's folders again into a new result.")
        }
        do {
            try await RNASeqCellMapSelectSubcommand.parse([map.path] + Self.clusterOne + ["--output", output.path, "--quiet"]).run()
            XCTFail("a changed cell map was selected from")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), [],
                       "a refusal leaves no table, no record and no staged file")
    }

    // MARK: - The record signs when a key is set

    /// Runs `body` with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under `root`, and puts the two signing
    /// variables back afterwards, as `RNASeqPseudobulkCommandTests` does.
    private func withThrowawayKey<T>(_ body: () async throws -> T) async throws -> T {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "selection-pin-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
        let fileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
        let saved = [keyName, fileName].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        unsetenv(keyName)
        setenv(fileName, keyFile.path, 1)
        defer {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        return try await body()
    }
}
