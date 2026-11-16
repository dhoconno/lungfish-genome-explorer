// TenxGTFFilterTests.swift - The 10x filter rule on a set's derived/genes.gtf (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// BIO-SOLO-GTF items 2 and 3 and ARCH-SOLO-GTF item 7 on the small set and on lines written here.
final class TenxGTFFilterTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tenx-gtf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The set of `STARIndexPlanTests.builtSet()`: the cynomolgus mitochondrion with the SARS-CoV-2 extra.
    func builtSet() async throws -> ReferenceSetOutcome {
        var request = ReferenceSetMitoFixture.request(.lge)
        request.extras = [ReferenceSetExtraInput(
            name: "sars-cov-2", kind: .virus,
            fasta: ReferenceSetMitoFixture.folder.appendingPathComponent("sars-cov-2.fa"), annotation: nil)]
        let owner = ReferenceSetOwner(
            storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        return ""
    }

    /// A gene line with its biotype, then an `exon` line of LGE's form, which carries no biotype (BIO-SOLO-GTF item 2).
    private func gene(_ id: String, _ biotype: String, contig: String = "chrM", start: Int = 1, end: Int = 30) -> String {
        "\(contig)\tRefSeq\tgene\t\(start)\t\(end)\t.\t+\t.\tgene_id \"\(id)\"; gene_biotype \"\(biotype)\";\n"
            + "\(contig)\tLGE\texon\t\(start)\t\(end)\t.\t+\t.\tgene_id \"\(id)\"; transcript_id \"\(id):1\";\n"
    }

    private func lge(_ data: Data) -> Int {
        String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.split(separator: "\t").dropFirst().first == "LGE" }.count
    }

    func testTheRuleReadsTheGeneLineOrElseTheTranscriptLineAndKeepsEveryLineOfAKeptGene() throws {
        let extra = "NC_045512.2\tLGE\texon\t1\t50\t.\t+\t.\tgene_id \"NC_045512.2\"; transcript_id \"NC_045512.2\";\n"
        let viaTranscript = "chrM\tGENCODE\ttranscript\t70\t90\t.\t-\t.\tgene_id \"LNC1\"; transcript_id \"LNC1.1\"; gene_type \"lncRNA\";\n"
            + "chrM\tGENCODE\texon\t70\t90\t.\t-\t.\tgene_id \"LNC1\"; transcript_id \"LNC1.1\";\n"
        let input = "#gtf-version 2.2\n" + gene("COX1", "protein_coding") + gene("TRNA1", "tRNA", start: 40, end: 60)
            + viaTranscript + extra
        let three = try TenxGTFFilter.filter(Data(input.utf8), list: .mkgtf300, extraRecords: ["NC_045512.2"], exonsAdded: ["COX1"])
        XCTAssertEqual(String(decoding: three.bytes, as: UTF8.self), "#gtf-version 2.2\n" + gene("COX1", "protein_coding") + extra)
        XCTAssertEqual(three.genesLeftOut, ["TRNA1", "LNC1"], "lncRNA is on gencode-2020-A only")
        XCTAssertEqual(three.size, Int64(three.bytes.count))
        XCTAssertEqual(three.sha256, PortableDigest.sha256Hex(of: three.bytes))
        let twenty = try TenxGTFFilter.filter(Data(input.utf8), list: .gencode2020A, extraRecords: ["NC_045512.2"], exonsAdded: [])
        XCTAssertEqual(twenty.genesLeftOut, ["TRNA1"])
        XCTAssertTrue(String(decoding: twenty.bytes, as: UTF8.self).contains(viaTranscript))
        XCTAssertEqual(TenxGTFFilter.List.mkgtf300.biotypes.count, 17)
        XCTAssertEqual(TenxGTFFilter.List.gencode2020A.biotypes.count, 16)
        XCTAssertEqual(TenxGTFFilter.List.mkgtf300.path, "made/tenx1-mkgtf-3.0.0/genes.gtf")
    }

    /// ARCH-SOLO-GTF item 7: the plain set keeps all its lines, so its made file is `derived/genes.gtf` byte for byte.
    func testThePlainSetsMadeFileEqualsDerivedGenesGTFByteForByteUnderBothLists() async throws {
        let set = try await builtSet()
        let derived = try Data(contentsOf: set.url.appendingPathComponent("derived/genes.gtf"))
        XCTAssertEqual(lge(derived), 14, "13 genes and the extra")
        for list in TenxGTFFilter.List.allCases {
            let made = try TenxGTFFilter.make(from: set.url, manifest: set.manifest, list: list)
            XCTAssertEqual(made.bytes, derived, list.rawValue)
            XCTAssertEqual(made.sha256, set.manifest.derived.countingGTF?.sha256, list.rawValue)
            XCTAssertEqual(made.genesLeftOut, [], list.rawValue)
        }
    }

    /// ARCH-SOLO-GTF item 7: a gene of a biotype on neither list is left out, and LGE's 14 lines stay.
    func testAnAddedTRNAGeneIsLeftOutWhileLGEsFourteenLinesStay() async throws {
        let set = try await builtSet()
        let derived = try Data(contentsOf: set.url.appendingPathComponent("derived/genes.gtf"))
        let firstFeature = String(decoding: derived, as: UTF8.self).split(separator: "\n").first { !$0.hasPrefix("#") }
        let contig = String(try XCTUnwrap(firstFeature).prefix { $0 != "\t" })
        let added = derived + Data(gene("TRNA-X", "tRNA", contig: contig, start: 100, end: 160).utf8)
        let made = try TenxGTFFilter.filter(
            added, list: .mkgtf300, extraRecords: set.manifest.extras.flatMap(\.records), exonsAdded: set.manifest.derivation.exonsAdded)
        XCTAssertEqual(made.genesLeftOut, ["TRNA-X"])
        XCTAssertEqual(lge(made.bytes), 14)
        XCTAssertNotEqual(made.sha256, PortableDigest.sha256Hex(of: added))
        XCTAssertEqual(made.bytes, derived, "only the added gene's two lines are left out")
    }

    /// BIO-SOLO-GTF item 3: a kept gene LGE gave an exon, or an extra's record, with no exon line is refused in words.
    func testAKeptGeneOfExonsAddedOrAnExtraRecordWithNoExonLineIsRefusedInWords() async throws {
        let set = try await builtSet()
        let derived = String(decoding: try Data(contentsOf: set.url.appendingPathComponent("derived/genes.gtf")), as: UTF8.self)
        let lines = derived.split(separator: "\n", omittingEmptySubsequences: false)
        let exonsAdded = set.manifest.derivation.exonsAdded
        let records = set.manifest.extras.flatMap(\.records)
        XCTAssertTrue(exonsAdded.contains("ND1") && records.count == 1, "\(exonsAdded) \(records)")
        func words(dropping: (Substring) -> Bool) -> String {
            let kept = lines.filter { !dropping($0) }.joined(separator: "\n")
            return refusal { _ = try TenxGTFFilter.filter(Data(kept.utf8), list: .mkgtf300, extraRecords: records, exonsAdded: exonsAdded) }
        }
        let gene = words { $0.contains("\tLGE\texon\t") && $0.contains("gene_id \"ND1\";") }
        XCTAssertEqual(gene, "The GTF that the 10x filter rule mkgtf-3.0.0 makes from derived/genes.gtf holds no exon line for the "
            + "gene ND1 that LGE gave an exon, so STAR would give it no row of features.tsv and count 0. LGE refused the file, and "
            + "no plan or record was written.")
        let both = words { $0.hasPrefix("\(records[0])\t") || ($0.contains("\tLGE\texon\t") && $0.contains("gene_id \"ND1\";")) }
        XCTAssertTrue(both.contains("holds no exon line for the extra record \(records[0]) and for the gene ND1 that LGE gave an "
            + "exon, so STAR would give them no row"), both)
    }
}
