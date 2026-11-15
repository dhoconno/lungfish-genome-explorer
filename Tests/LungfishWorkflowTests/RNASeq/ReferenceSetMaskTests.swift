// ReferenceSetMaskTests.swift - A bacterium extra's rRNA mask from a GTF the person gives (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-NOTHOST-BARCODE items 1 to 6. The mask is the `gene` lines of `gene_biotype "rRNA"` in a GTF the person gives
// for the extra, each by its gene-line span, as `scripts/repro/rnaseq/gse296788/mtb.py:71-79` reads them. The set keeps
// the GTF as `extras/<name>.mask.gtf`, names it in the content list as `extra mask`, and holds a `masks[]` entry of
// intervals, since the rRNA genes are not features of the set.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReferenceSetMaskTests: XCTestCase {
    private var root: URL!
    private var inputs: URL!

    static let genome = ">chr1\n" + String(repeating: "ACGTACGTAC", count: 6) + "\n"
    static let annotation = "chr1\tt\tgene\t1\t30\t.\t+\t.\tgene_id \"G1\"; gene_biotype \"protein_coding\";\n"
        + "chr1\tt\texon\t1\t30\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\";\n"
    static let bacterium = ">KK1 scaffold one\n" + String(repeating: "ACGT", count: 10) + "\n>KK2\n" + String(repeating: "GC", count: 10) + "\n"
    /// Two rRNA genes, an exon line that carries no biotype (as Erdman's exon lines), and a protein-coding gene.
    static let maskGTF = """
        #gtf-version 2.2
        KK1\tGenbank\tgene\t5\t14\t.\t+\t.\tgene_id "Q1"; gene_biotype "rRNA";
        KK1\tGenbank\texon\t5\t14\t.\t+\t.\tgene_id "Q1"; transcript_id "t1";
        KK1\tGenbank\tgene\t20\t30\t.\t+\t.\tgene_id "Q2"; gene_biotype "protein_coding";
        KK2\tGenbank\tgene\t1\t8\t.\t-\t.\tgene_id "Q3"; gene_biotype "rRNA";

        """
    /// The deposit's own features of the bacterium, one a whole record, as `gse296788/run.sh:212` writes them.
    static let depositFeatures = "KK1\tref\texon\t1\t40\t.\t+\t.\tgene_id \"tb001\"; transcript_id \"tb001\";\n"
        + "KK2\tref\texon\t1\t20\t.\t+\t.\tgene_id \"tb002\"; transcript_id \"tb002\";\n"

    override func setUpWithError() throws {
        let base = try TestTempDirectory.make(prefix: "refset-mask")
        root = base.appendingPathComponent("root", isDirectory: true)
        inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        for (name, text) in [("genome.fa", Self.genome), ("genes.gtf", Self.annotation), ("mtb.fa", Self.bacterium),
                             ("erdman.gtf", Self.maskGTF), ("tb.gtf", Self.depositFeatures)] {
            try write(text, name)
        }
    }

    override func tearDownWithError() throws { TestTempDirectory.cleanup(root.deletingLastPathComponent()) }

    func write(_ text: String, _ name: String) throws {
        try Data(text.utf8).write(to: inputs.appendingPathComponent(name))
    }

    func sha(_ name: String) throws -> String {
        ReferenceSetID.sha256Hex(try Data(contentsOf: inputs.appendingPathComponent(name)))
    }

    func request(mask: String? = "erdman.gtf", layout: ReferenceSetLayout = .lge, features: Bool = false) -> ReferenceSetRequest {
        let extra = ReferenceSetExtraInput(
            name: "mtb", kind: .bacterium, fasta: inputs.appendingPathComponent("mtb.fa"),
            annotation: features ? inputs.appendingPathComponent("tb.gtf") : nil,
            mask: mask.map { inputs.appendingPathComponent($0) })
        return ReferenceSetRequest(
            name: "Mask set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB",
            annotationRelease: "7", genome: inputs.appendingPathComponent("genome.fa"),
            annotation: inputs.appendingPathComponent("genes.gtf"), extras: [extra], layout: layout)
    }

    func build(_ request: ReferenceSetRequest, root: URL? = nil) async throws -> ReferenceSetOutcome {
        try await ReferenceSetOwner(
            storageRoot: root ?? self.root, deriver: StandInTranscriptDeriver(),
            provenanceWriter: ProvenanceWriter(signingProvider: nil)
        ).build(request)
    }

    func otherRoot() throws -> URL {
        let url = root.deletingLastPathComponent().appendingPathComponent("root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let intervals: [ReferenceSetManifest.Mask.Interval] = [
        .init(record: "KK1", start: 5, end: 14, geneID: "Q1"), .init(record: "KK2", start: 1, end: 8, geneID: "Q3"),
    ]

    func testABacteriumsMaskIsItsGTFsRRNAGeneLinesKeptBesideItsOneFeatureARecord() async throws {
        let outcome = try await build(request())
        let mask = try XCTUnwrap(outcome.manifest.masks.first)
        XCTAssertEqual(outcome.manifest.masks.count, 1)
        XCTAssertEqual(mask.name, "mtb", "the mask carries its extra's name")
        XCTAssertEqual(mask.path, "extras/mtb.mask.gtf")
        XCTAssertEqual(mask.sha256, try sha("erdman.gtf"))
        XCTAssertEqual(mask.rule, ReferenceSetManifest.Mask.rRNARule)
        XCTAssertEqual(mask.intervals, Self.intervals, "the gene lines of gene_biotype rRNA, 1-based as given, and no exon line")
        let copy = outcome.url.appendingPathComponent(mask.path)
        XCTAssertEqual(ReferenceSetID.sha256Hex(try Data(contentsOf: copy)), mask.sha256, "the set keeps the GTF's bytes")
        XCTAssertTrue(outcome.manifest.namedFiles.contains { $0.path == mask.path && $0.sha256 == mask.sha256 })
        let genes = try String(contentsOf: outcome.url.appendingPathComponent("derived/genes.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        XCTAssertEqual(genes.filter { $0[5] == "true" }.map { String($0[0]) }, ["KK1", "KK2"],
                       "in LGE's layout the bacterium still counts as one feature a record")
        XCTAssertTrue(genes.allSatisfy { $0.count < 7 || $0[6].isEmpty }, "the rRNA genes are no feature, so no row is marked")

        let reused = try await build(request())
        XCTAssertTrue(reused.reused, "a set with its mask settles and is reused")
    }

    func testTheMaskHasItsOwnContentLineAfterItsExtraAndAnotherMaskMakesAnotherID() async throws {
        let masked = try await build(request())
        let contents = [
            ReferenceSetID.Content(role: "genome", fileName: "genome.fa", sha256: try sha("genome.fa")),
            ReferenceSetID.Content(role: "annotation", fileName: "genes.gtf", sha256: try sha("genes.gtf")),
            ReferenceSetID.Content(role: "extra", fileName: "mtb", sha256: try sha("mtb.fa")),
        ]
        let maskLine = ReferenceSetID.Content(role: "extra mask", fileName: "erdman.gtf", sha256: try sha("erdman.gtf"))
        let id = { (contents: [ReferenceSetID.Content], layout: ReferenceSetLayout) in
            ReferenceSetID.make(species: "Testus examplus", assembly: "T1", annotationSource: "TestDB", annotationRelease: "7",
                                layout: layout, contents: contents, deriveVersion: "0.12.9")
        }
        XCTAssertEqual(masked.manifest.id, id(contents + [maskLine], .lge))
        let plain = try await build(request(mask: nil), root: try otherRoot())
        XCTAssertEqual(plain.manifest.id, id(contents, .lge))
        XCTAssertEqual(plain.manifest.masks, [], "a bacterium with no mask GTF still builds")
        try write(Self.maskGTF.replacingOccurrences(of: "gene_id \"Q3\"; gene_biotype \"rRNA\"", with: "gene_id \"Q3\"; gene_biotype \"tRNA\""), "other.gtf")
        let other = try await build(request(mask: "other.gtf"), root: try otherRoot())
        XCTAssertNotEqual(other.manifest.id, masked.manifest.id, "another mask makes another id")
        XCTAssertEqual(other.manifest.masks.first?.intervals, [Self.intervals[0]])

        let deposit = try await build(request(layout: .deposit(study: "GSE296788"), features: true), root: try otherRoot())
        let annotationLine = ReferenceSetID.Content(role: "extra annotation", fileName: "tb.gtf", sha256: try sha("tb.gtf"))
        XCTAssertEqual(deposit.manifest.id, id(contents + [annotationLine, maskLine], .deposit(study: "GSE296788")),
                       "the mask's line follows the extra's annotation line")
        XCTAssertEqual(deposit.manifest.extras.first?.annotationPath, "extras/mtb.gtf")
        XCTAssertEqual(deposit.manifest.masks.first?.intervals, Self.intervals, "the deposit's features and the mask are kept apart")
    }

    func testAMaskOfNoRRNAGeneOrOfARecordTheExtraLacksIsRefusedInWords() async throws {
        try write(Self.maskGTF.replacingOccurrences(of: "\"rRNA\"", with: "\"tRNA\""), "none.gtf")
        do {
            _ = try await build(request(mask: "none.gtf"))
            XCTFail("a mask GTF with no rRNA gene is refused")
        } catch let error as ReferenceSetError {
            XCTAssertEqual(error.localizedDescription, "The annotation none.gtf holds no rRNA gene, so it gives mtb no mask.")
        }
        try write(Self.maskGTF + "KK9\tGenbank\tgene\t1\t4\t.\t+\t.\tgene_id \"Q9\"; gene_biotype \"rRNA\";\n", "stray.gtf")
        do {
            _ = try await build(request(mask: "stray.gtf"))
            XCTFail("a mask GTF that names a record the extra lacks is refused")
        } catch let error as ReferenceSetError {
            XCTAssertEqual(error.localizedDescription,
                           "The annotation stray.gtf names sequences the extra mtb lacks: KK9. It gives mtb no mask, and nothing was built.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rnaseq-reference-sets").path), [],
                       "a refused build leaves no set and no stage")
    }

    func testTheImportReadsTheSetsMaskAndABacteriumWithoutOneIsNotMaskedInWords() async throws {
        let masked = try SingleCellNotHostPass.readSet(try await build(request()).url)
        let mask = try XCTUnwrap(masked.extras.first?.mask)
        XCTAssertEqual(mask.intervals, Self.intervals.map {
            SingleCellNotHostExtra.Mask.Interval(record: $0.record, start: $0.start, end: $0.end, geneID: $0.geneID)
        })
        XCTAssertEqual(mask.file, "extras/mtb.mask.gtf")
        XCTAssertEqual(mask.sha256, try sha("erdman.gtf"))
        XCTAssertEqual(masked.extras.first?.maskWords, "on mtb rRNA genes, source not resolved")
        XCTAssertEqual(masked.records, [.init(name: "KK1", length: 40), .init(name: "KK2", length: 20)])

        let plain = try SingleCellNotHostPass.readSet(try await build(request(mask: nil), root: try otherRoot()).url)
        XCTAssertNil(plain.extras.first?.mask)
        XCTAssertEqual(plain.extras.first?.maskWords, "rRNA not masked: no annotation given for mtb")
    }
}
