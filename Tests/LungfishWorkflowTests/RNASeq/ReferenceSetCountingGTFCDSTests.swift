// ReferenceSetCountingGTFCDSTests.swift - A transcript of CDS lines and no exon line in `derived/genes.gtf`
// (Phase 5.3 lane RS-COUNTING-GTF, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// RefSeq Macaca_fascicularis_5.0 release 101 gives 232 genes (220 V_segment, 12 C_region) their exons under one transcript id
/// and their CDS under `unknown_transcript_1`, which LGE renames to `<gene>:unknown_transcript_1`. gffread 0.12.9
/// writes a record of that CDS with its stop codon and no exon line, so the real build was refused until the counting
/// GTF gave the record its exons (RS-COUNTING-GTF milestone 2). The lengths are gffread 0.12.9's on this GTF.
enum ReferenceSetCDSOnlyFixture {
    static let annotation = """
        c1\tGnomon\tgene\t100\t400\t.\t+\t.\tgene_id "G1"; gbkey "Gene"; gene_biotype "V_segment";
        c1\tGnomon\texon\t100\t200\t.\t+\t.\tgene_id "G1"; transcript_id "G1"; gbkey "V_segment";
        c1\tGnomon\texon\t250\t400\t.\t+\t.\tgene_id "G1"; transcript_id "G1"; gbkey "V_segment";
        c1\tGnomon\tCDS\t150\t200\t.\t+\t0\tgene_id "G1"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tCDS\t250\t300\t.\t+\t2\tgene_id "G1"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tstart_codon\t150\t152\t.\t+\t0\tgene_id "G1"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tstop_codon\t301\t303\t.\t+\t0\tgene_id "G1"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tgene\t500\t900\t.\t-\t.\tgene_id "G2"; gbkey "Gene"; gene_biotype "C_region";
        c1\tGnomon\texon\t500\t900\t.\t-\t.\tgene_id "G2"; transcript_id "G2"; gbkey "C_region";
        c1\tGnomon\tCDS\t604\t700\t.\t-\t0\tgene_id "G2"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tCDS\t750\t800\t.\t-\t2\tgene_id "G2"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tstop_codon\t601\t603\t.\t-\t0\tgene_id "G2"; transcript_id "unknown_transcript_1"; gbkey "CDS";
        c1\tGnomon\tgene\t950\t990\t.\t+\t.\tgene_id "G3"; gbkey "Gene"; gene_biotype "V_segment";
        c1\tGnomon\texon\t950\t990\t.\t+\t.\tgene_id "G3"; transcript_id "G3"; gbkey "V_segment";
        c1\tGnomon\tCDS\t955\t980\t.\t+\t0\tgene_id "G3"; transcript_id "unknown_transcript_1"; gbkey "CDS";

        """

    /// The GTF gffread reads for `annotation`, the shared id renamed on the lines that carry it.
    static var gffreadGTF: String {
        annotation.split(separator: "\n").map { line -> String in
            guard let gene = ["G1", "G2", "G3"].first(where: { line.contains("gene_id \"\($0)\"") }) else { return String(line) }
            return line.replacingOccurrences(of: "transcript_id \"unknown_transcript_1\"",
                                             with: "transcript_id \"\(gene):unknown_transcript_1\"")
        }.joined(separator: "\n") + "\n"
    }

    /// Each record gffread 0.12.9 writes from `gffreadGTF`, in its order, with its length in bases.
    static let records: [(name: String, gene: String, length: Int)] = [
        ("G1", "G1", 252), ("G1:unknown_transcript_1", "G1", 105), ("G2", "G2", 401),
        ("G2:unknown_transcript_1", "G2", 151), ("G3", "G3", 41), ("G3:unknown_transcript_1", "G3", 26),
    ]

    /// The exon lines the counting GTF adds after the host part: each CDS-only transcript's CDS and stop codon,
    /// merged where they touch, as gffread reads them.
    static let addedLines = [
        "c1\tLGE\texon\t150\t200\t.\t+\t.\tgene_id \"G1\"; transcript_id \"G1:unknown_transcript_1\";",
        "c1\tLGE\texon\t250\t303\t.\t+\t.\tgene_id \"G1\"; transcript_id \"G1:unknown_transcript_1\";",
        "c1\tLGE\texon\t601\t700\t.\t-\t.\tgene_id \"G2\"; transcript_id \"G2:unknown_transcript_1\";",
        "c1\tLGE\texon\t750\t800\t.\t-\t.\tgene_id \"G2\"; transcript_id \"G2:unknown_transcript_1\";",
        "c1\tLGE\texon\t955\t980\t.\t+\t.\tgene_id \"G3\"; transcript_id \"G3:unknown_transcript_1\";",
    ]

    /// 1,000 bases of `c1`, the same on every run.
    static var genome: String {
        var state: UInt32 = 1
        let bases = (0..<1000).map { _ -> Character in
            state = state &* 1_103_515_245 &+ 12_345
            return Array("ACGT")[Int((state >> 16) & 3)]
        }
        return ">c1\n" + String(bases) + "\n"
    }
}

final class ReferenceSetCountingGTFCDSTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("refset-cds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The transcript table and FASTA gffread 0.12.9 gives for `ReferenceSetCDSOnlyFixture.gffreadGTF`.
    func tables() throws -> (table: URL, fasta: URL) {
        let records = ReferenceSetCDSOnlyFixture.records
        let table = try file("transcripts.tsv", "transcript_id\tgene_id\n" + records.map { "\($0.name)\t\($0.gene)\n" }.joined())
        let fasta = try file("transcripts.fa", records.map { ">\($0.name)\n\(String(repeating: "A", count: $0.length))\n" }.joined())
        return (table, fasta)
    }

    func testATranscriptOfCDSLinesAndNoExonGetsItsCDSAndStopCodonAsExonsAfterTheHostPart() throws {
        let host = try file("lge-annotation.gtf", ReferenceSetCDSOnlyFixture.gffreadGTF)
        let (table, fasta) = try tables()
        let output = folder.appendingPathComponent("genes.gtf")
        try ReferenceSetCountingGTF.write(host: host, extras: [], to: output)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(ReferenceSetCDSOnlyFixture.gffreadGTF), "the host part stays the bytes gffread read")
        XCTAssertEqual(text.dropFirst(ReferenceSetCDSOnlyFixture.gffreadGTF.count).split(separator: "\n").map(String.init),
                       ReferenceSetCDSOnlyFixture.addedLines)
        XCTAssertNoThrow(try ReferenceSetCountingGTF.check(output, transcriptTable: table, transcripts: fasta))
    }

    func testAnExtrasGTFInTheDepositLayoutGetsTheSameLinesAfterItsBytes() throws {
        let hostText = "h1\tLGE\texon\t1\t10\t.\t+\t.\tgene_id \"H\"; transcript_id \"H\";\n"
        let host = try file("lge-annotation.gtf", hostText)
        let extra = try file("extra-0.lge-annotation.gtf", ReferenceSetCDSOnlyFixture.gffreadGTF)
        let output = folder.appendingPathComponent("genes.gtf")
        try ReferenceSetCountingGTF.write(host: host, extras: [.gtf(extra)], to: output)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), hostText + ReferenceSetCDSOnlyFixture.gffreadGTF
            + ReferenceSetCDSOnlyFixture.addedLines.map { $0 + "\n" }.joined())
    }
}

/// The same GTF through real gffread and the owner, from the conda root (`LUNGFISH_CONDA_ROOT` when it is set, else
/// the configured root). It skips when no gffread is installed there, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.
final class ReferenceSetCountingGTFCDSConformanceTests: XCTestCase {
    func testGffreadWritesACDSOnlyTranscriptAtTheLengthOfTheExonsTheCountingGTFGivesIt() async throws {
        let gffread = try await ToolAvailability.require("gffread", environment: "gffread")
        print("ReferenceSetCountingGTFCDSConformanceTests: gffread at \(gffread.path)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refset-cds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let genome = inputs.appendingPathComponent("segments.fa")
        let annotation = inputs.appendingPathComponent("segments.gtf")
        try Data(ReferenceSetCDSOnlyFixture.genome.utf8).write(to: genome)
        try Data(ReferenceSetCDSOnlyFixture.annotation.utf8).write(to: annotation)
        let owner = ReferenceSetOwner(storageRoot: root.appendingPathComponent("storage", isDirectory: true),
                                      deriver: GffreadTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let outcome = try await owner.build(ReferenceSetRequest(
            name: "Segments", species: "Macaca fascicularis", assemblyName: "Macaca_fascicularis_5.0",
            annotationSource: "RefSeq", annotationRelease: "101", genome: genome, annotation: annotation))
        let derived = outcome.url.appendingPathComponent("derived", isDirectory: true)
        let records = try ReferenceSetAnnotationReader.fastaRecords(derived.appendingPathComponent("transcripts.fa"))
        XCTAssertEqual(records.map { "\($0.name) \($0.length)" }.sorted(),
                       ReferenceSetCDSOnlyFixture.records.map { "\($0.name) \($0.length)" }.sorted())
        let gtf = try String(contentsOf: derived.appendingPathComponent("genes.gtf"), encoding: .utf8)
        XCTAssertEqual(gtf.split(separator: "\n").suffix(5).map(String.init), ReferenceSetCDSOnlyFixture.addedLines)
        XCTAssertEqual(try outcome.manifest.requireCountingGTF().sha256,
                       try ProvenanceFileHasher.sha256(of: derived.appendingPathComponent("genes.gtf")))
    }
}
