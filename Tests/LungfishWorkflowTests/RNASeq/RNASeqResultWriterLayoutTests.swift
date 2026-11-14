// RNASeqResultWriterLayoutTests.swift - The layout rules SF1 of the P5-LAYOUT review sets (lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension RNASeqResultWriterTests {
    private func umiRequest(sourceFiles: [RNASeqResultWriter.SourceFile]? = nil) throws -> (RNASeqResultWriter.Request, RNASeqCountTable) {
        let text = try String(contentsOf: RNASeqFixtures.umiCounts, encoding: .utf8)
        let lines = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let rows = lines.dropFirst().map { RNASeqCountTable.Row(id: $0[0], counts: $0.dropFirst().map { Double($0)! }) }
        let table = RNASeqCountTable(sampleIDs: Array(lines[0].dropFirst()), rows: Array(rows))
        let files = sourceFiles ?? [.init(url: RNASeqFixtures.umiCounts, relativePath: "counts.tsv", sample: nil, tool: "umi_tools")]
        return (RNASeqResultWriter.Request(
            name: "C9 UMI counts", modality: .bulk,
            origin: .init(kind: .imported, tool: "umi_tools", toolVersion: nil),
            route: .init(id: "umi-tools-per-gene", tool: "umi_tools", toolVersion: "unknown", settings: [:]),
            referenceSet: nil, samples: table.sampleIDs.map { RNASeqSampleRecord(id: $0) },
            genes: .ids(rows.map(\.id)),
            counts: [.init(rows: .gene, column: .default, unit: .umis, table: table)],
            sourceFiles: files, notHost: []), table)
    }

    func testAPlainTableWithNoReferenceSetStaysUnderTablesAndItsGenesReadAsNotRecorded() throws {
        let (request, table) = try umiRequest()
        _ = try RNASeqResultWriter(provenanceWriter: unsigned).write(request, to: resultURL, envelope: envelope())
        let result = try RNASeqResultBundle.load(from: resultURL)
        XCTAssertEqual(try Data(contentsOf: resultURL.appendingPathComponent("source/tables/counts.tsv")),
                       try Data(contentsOf: RNASeqFixtures.umiCounts))
        XCTAssertEqual(result.manifest.sourceFiles.map(\.sample), [""])
        XCTAssertNil(result.manifest.referenceSet)
        XCTAssertEqual(result.counts.map(\.table), [table])
        XCTAssertEqual(result.genes.map(\.id), table.rows.map(\.id))
        XCTAssertTrue(result.genes.allSatisfy {
            $0.name == nil && $0.biotype == nil && $0.contig == nil && $0.length == nil
                && $0.notHost == nil && $0.mask == nil && $0.unreliable == nil
        }, "every column but the id is Not recorded")
        XCTAssertEqual(RNASeqResultBundle.notRecordedText, "Not recorded")
    }

    func testASampleNamedTablesTakesTheNextFreeSuffix() throws {
        let quant = RNASeqFixtures.salmonRun("SRR896663").appendingPathComponent("quant.sf")
        let (request, _) = try umiRequest(sourceFiles: [
            .init(url: RNASeqFixtures.umiCounts, relativePath: "counts.tsv", sample: nil, tool: "umi_tools"),
            .init(url: quant, relativePath: "quant.sf", sample: "tables", tool: "salmon"),
        ])
        var named = request
        named.samples = [RNASeqSampleRecord(id: "tables")]
        _ = try RNASeqResultWriter(provenanceWriter: unsigned).write(named, to: resultURL, envelope: envelope())
        let result = try RNASeqResultBundle.load(from: resultURL)
        XCTAssertEqual(result.manifest.sourceFiles.map(\.path), ["source/tables/counts.tsv", "source/tables-2/quant.sf"])
        XCTAssertEqual(result.samples.map(\.sourceFolder), ["tables-2"])
    }

    func testGenesFollowTheReferenceSetTable() throws {
        let header = "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n"
        let rowsText = ["G1\tA\tprotein_coding\t1\t1000\tfalse\t\t\n", "G2\tB\tlncRNA\t1\t2000\tfalse\t\t\n", "G3\tC\tprotein_coding\t2\t3000\ttrue\t\t\n"]
        let setTable = tempRoot.appendingPathComponent("derived-genes.tsv")
        try Data((header + rowsText.joined()).utf8).write(to: setTable)
        let (base, _) = try umiRequest()
        func request(keeping ids: [String]) -> RNASeqResultWriter.Request {
            var request = base
            request.referenceSet = .init(id: "test-set", layout: .lge)
            request.genes = .referenceSetTable(url: setTable, keeping: ids)
            return request
        }
        let writer = RNASeqResultWriter(provenanceWriter: unsigned)
        let all = analyses.appendingPathComponent("all.lungfishrnaseq")
        _ = try writer.write(request(keeping: ["G3", "G1", "G2"]), to: all, envelope: envelope())
        XCTAssertEqual(try Data(contentsOf: all.appendingPathComponent("genes.tsv")), try Data(contentsOf: setTable))
        let loaded = try RNASeqResultBundle.load(from: all)
        XCTAssertEqual(loaded.manifest.genes.sha256, sha256(try Data(contentsOf: setTable)))
        XCTAssertEqual(loaded.genes.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(loaded.genes.map(\.notHost), [false, false, true])
        XCTAssertEqual(loaded.genes.first?.length, 1000)

        let some = analyses.appendingPathComponent("some.lungfishrnaseq")
        _ = try writer.write(request(keeping: ["G1", "G3"]), to: some, envelope: envelope())
        let own = try Data(contentsOf: some.appendingPathComponent("genes.tsv"))
        XCTAssertEqual(String(decoding: own, as: UTF8.self), header + rowsText[0] + rowsText[2])
        XCTAssertEqual(try RNASeqResultBundle.load(from: some).manifest.genes.sha256, sha256(own))

        XCTAssertThrowsError(try writer.write(request(keeping: ["G9"]), to: analyses.appendingPathComponent("bad.lungfishrnaseq"), envelope: envelope())) {
            XCTAssertTrue($0.localizedDescription.contains("G9"), $0.localizedDescription)
        }
        XCTAssertEqual(try names(in: analyses), ["all.lungfishrnaseq", "some.lungfishrnaseq"])
    }

    func testPublishesWhenTheVolumeRejectsExclusiveRename() throws {
        let table = try quantTable()
        let writer = RNASeqResultWriter(provenanceWriter: unsigned)
        let request = salmonRequest(table)
        try PortableRename.simulatingUnsupportedFlags {
            _ = try writer.write(request, to: resultURL, envelope: envelope())
        }
        XCTAssertEqual(try RNASeqResultBundle.load(from: resultURL).counts.map(\.table), [table])
        XCTAssertEqual(try names(in: analyses), ["seqc-c1.lungfishrnaseq"])
    }
}
