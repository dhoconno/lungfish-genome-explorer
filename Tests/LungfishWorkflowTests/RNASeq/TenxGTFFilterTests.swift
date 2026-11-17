// TenxGTFFilterTests.swift - The 10x filter rule on a set's derived/genes.gtf (Phase 5.3 lane SOLO-PLAN)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import LungfishTestSupport
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
        // Version 1 with the 2020-A biotypes, which only a measurement names, since that list is read by version 2.
        let twenty = try TenxGTFFilter.filter(
            Data(input.utf8), list: .gencode2020A, ruleVersion: 1, extraRecords: ["NC_045512.2"], exonsAdded: [])
        XCTAssertEqual(twenty.genesLeftOut, ["TRNA1"])
        XCTAssertTrue(String(decoding: twenty.bytes, as: UTF8.self).contains(viaTranscript))
        XCTAssertEqual(TenxGTFFilter.List.mkgtf300.biotypes.count, 17)
        XCTAssertEqual(TenxGTFFilter.List.gencode2020A.biotypes.count, 16)
        XCTAssertEqual(TenxGTFFilter.List.mkgtf300.path, "made/tenx1-mkgtf-3.0.0/genes.gtf")
    }

    /// ARCH-SOLO-GTF item 7: the plain set keeps all its lines under mkgtf-3.0.0, so its made file is `derived/genes.gtf`
    /// byte for byte. Its RefSeq lines name gene_biotype and no gene_type or transcript_type, so version 2 of
    /// gencode-2020-A keeps none of its 13 genes and is refused in words, as 10x's rule_2020a would keep none.
    func testThePlainSetsMadeFileEqualsDerivedGenesGTFByteForByteUnderMkgtfAndGencodeIsRefused() async throws {
        let set = try await builtSet()
        let derived = try Data(contentsOf: set.url.appendingPathComponent("derived/genes.gtf"))
        XCTAssertEqual(lge(derived), 14, "13 genes and the extra")
        let made = try TenxGTFFilter.make(from: set.url, manifest: set.manifest, list: .mkgtf300)
        XCTAssertEqual(made.bytes, derived)
        XCTAssertEqual(made.sha256, set.manifest.derived.countingGTF?.sha256)
        XCTAssertEqual(made.genesLeftOut, [])
        let words = refusal { _ = try TenxGTFFilter.make(from: set.url, manifest: set.manifest, list: .gencode2020A) }
        XCTAssertTrue(words.hasPrefix("The 10x filter rule gencode-2020-A keeps none of the 13 genes of derived/genes.gtf"), words)
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

    /// BIO should-fix 1: a GTF that names no biotype on any host gene leaves out every host gene, so the rule is refused in
    /// words, since STAR would index no gene of the set. A GTF of an extra's lines only has no host gene to refuse.
    func testARuleThatKeepsNoGeneIsRefusedInWords() throws {
        let unnamed = "chrM\tUCSC\tgene\t1\t30\t.\t+\t.\tgene_id \"G1\";\n"
            + "chrM\tLGE\texon\t1\t30\t.\t+\t.\tgene_id \"G1\"; transcript_id \"G1:1\";\n" + gene("T1", "tRNA", start: 40, end: 60)
        let one = refusal { _ = try TenxGTFFilter.filter(Data(unnamed.utf8), list: .mkgtf300, extraRecords: [], exonsAdded: []) }
        XCTAssertEqual(one, "The 10x filter rule mkgtf-3.0.0 keeps none of the 2 genes of derived/genes.gtf, since no gene has a "
            + "gene_biotype or gene_type on its list, so STAR would index no gene of the set and its matrix would hold none. Index "
            + "the set without --tenx-filter, or build it from an annotation that names each gene's biotype. No plan or record "
            + "was written.")
        let two = refusal { _ = try TenxGTFFilter.filter(Data(unnamed.utf8), list: .gencode2020A, extraRecords: [], exonsAdded: []) }
        XCTAssertEqual(two, "The 10x filter rule gencode-2020-A keeps none of the 2 genes of derived/genes.gtf, since no transcript "
            + "line has a gene_type and a transcript_type on its list without the tag readthrough_transcript or PAR, as 10x's "
            + "GRCh38-2020-A rule asks, so STAR would index no gene of the set and its matrix would hold none. Index the set "
            + "without --tenx-filter, or build it from a GENCODE annotation, whose transcript lines name both. No plan or record "
            + "was written.")
        XCTAssertNoThrow(try TenxGTFFilter.filter(
            Data(gene("COX1", "protein_coding").utf8), list: .mkgtf300, extraRecords: [], exonsAdded: []))
        let extra = "NC_045512.2\tLGE\texon\t1\t50\t.\t+\t.\tgene_id \"NC_045512.2\"; transcript_id \"NC_045512.2\";\n"
        XCTAssertNoThrow(try TenxGTFFilter.filter(Data(extra.utf8), list: .mkgtf300, extraRecords: ["NC_045512.2"], exonsAdded: []))
    }

    // MARK: - Rule version 2 of gencode-2020-A (SOLO-PLAN-M1-BIO R1)

    /// The GENCODE v32 cut of `Tests/Fixtures/rnaseq/tenx-gtf-gencode/` and the file that 10x's `rule_2020a`
    /// (`scripts/repro/rnaseq/tenx-controls/tenx_gtf.py gencode-2020-A`) made from it.
    private func gencodeCut() throws -> (input: Data, expected: String) {
        let folder = RNASeqFixtures.root.appendingPathComponent("tenx-gtf-gencode", isDirectory: true)
        return (try Data(contentsOf: folder.appendingPathComponent("genes.gtf")),
                String(decoding: try Data(contentsOf: folder.appendingPathComponent("rule_2020a.gtf")), as: UTF8.self))
    }

    /// 10x's move of an Ensembl id's version into `<key>_version` (`tenx_gtf.py:66-71`). LGE's file keeps each id as
    /// `derived/genes.tsv` names it, so the test makes the move on LGE's lines before it compares them with 10x's.
    private func movingVersions(_ data: Data) throws -> String {
        let move = try NSRegularExpression(pattern: #"(gene|transcript|exon)_id "(ENS(?:MUS)?[GTE][0-9]+)\.([0-9]+)";"#)
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            guard !text.hasPrefix("#") else { return text }
            return move.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: #"$1_id "$2"; $1_version "$3";"#)
        }.joined(separator: "\n")
    }

    /// Version 2 keeps a gene whole when one of its `transcript` lines has a `gene_type` and a `transcript_type` on the list
    /// and neither `tag "readthrough_transcript"` nor `tag "PAR"`. On the cut it keeps the lines `rule_2020a` keeps, line
    /// for line, and it leaves out three genes that version 1 kept, one for each cause.
    func testRuleVersionTwoOfGencode2020AKeepsTheLinesOfTenxsRuleOnTheGencodeCut() throws {
        let (input, expected) = try gencodeCut()
        let made = try TenxGTFFilter.filter(input, list: .gencode2020A, extraRecords: [], exonsAdded: [])
        XCTAssertEqual(try movingVersions(made.bytes), expected, "rule_2020a's lines, once 10x's version move is made on LGE's")
        XCTAssertEqual(made.genesLeftOut, ["ENSG00000020219.9", "ENSG00000252690.3", "ENSG00000263126.1", "ENSG00000185203.12_PAR_Y"])
        let made2 = String(decoding: made.bytes, as: UTF8.self)
        XCTAssertFalse(made2.contains("_version"), "the ids stay those of derived/genes.gtf, with their versions")
        XCTAssertTrue(made2.contains("gene_id \"ENSG00000185203.12\";"), "the chrX copy of the PAR gene has no PAR tag and stays")
        XCTAssertTrue(made2.contains("transcript_type \"processed_pseudogene\""), "a kept gene keeps its transcript of another type")
        let lines = String(decoding: input, as: UTF8.self).split(separator: "\n")
        func transcriptLine(_ gene: String) throws -> String {
            String(try XCTUnwrap(lines.first { $0.contains("\ttranscript\t") && $0.contains("gene_id \"\(gene)\";") }, gene))
        }
        // Version 1 keeps a gene whose gene line names a gene_type on the list, and each of the three is lncRNA.
        let causes = [
            ("ENSG00000252690.3", "transcript_type \"retained_intron\"", "no transcript of a listed transcript_type"),
            ("ENSG00000263126.1", "tag \"basic\"; tag \"readthrough_transcript\";", "a readthrough transcript"),
            ("ENSG00000185203.12_PAR_Y", "tag \"basic\"; tag \"PAR\";", "a PAR transcript"),
        ]
        for (gene, words, cause) in causes {
            let gene1 = try XCTUnwrap(lines.first { $0.contains("\tgene\t") && $0.contains("gene_id \"\(gene)\";") }, gene)
            let type = try XCTUnwrap(ReferenceSetGTFFeature(String(gene1))?.attributes["gene_type"], gene)
            XCTAssertTrue(TenxGTFFilter.List.gencode2020A.biotypes.contains(type), "version 1 keeps \(gene) (\(type))")
            let transcript = try transcriptLine(gene)
            XCTAssertTrue(transcript.contains(words), "\(gene) is left out for \(cause)")
            // Each tag follows another tag, so the first value that parseAttributes keeps is never the tag the rule reads.
            XCTAssertNotEqual(ReferenceSetGTFFeature(transcript)?.attributes["tag"], words.contains("PAR") ? "PAR" : "readthrough_transcript")
        }
        XCTAssertEqual(TenxGTFFilter.List.gencode2020A.path, "made/tenx2-gencode-2020-A/genes.gtf")
        XCTAssertEqual(TenxGTFFilter.List.mkgtf300.path, "made/tenx1-mkgtf-3.0.0/genes.gtf", "mkgtf-3.0.0 stays at version 1")
        let one = try TenxGTFFilter.filter(input, list: .gencode2020A, ruleVersion: 1, extraRecords: [], exonsAdded: [])
        XCTAssertEqual(one.genesLeftOut, ["ENSG00000020219.9"], "version 1 of the list keeps the three")
    }

    /// Version 2 keeps LGE's `exon` lines of a kept gene and every line of an extra, as version 1 does (BIO-SOLO-GTF items 2
    /// and 3), and an LGE line of a gene it leaves out goes with that gene.
    func testRuleVersionTwoKeepsLGEsExonLinesOfAKeptGeneAndEveryExtraLine() throws {
        let (input, _) = try gencodeCut()
        let lge = "chr18\tLGE\texon\t47022287\t47023927\t.\t-\t.\tgene_id \"ENSG00000278674.2\"; transcript_id \"ENST00000611323.1\";\n"
        let gone = "chr16\tLGE\texon\t67882461\t67886367\t.\t+\t.\tgene_id \"ENSG00000263126.1\"; transcript_id \"ENST00000572067.1\";\n"
        let extra = "NC_045512.2\tLGE\texon\t1\t50\t.\t+\t.\tgene_id \"NC_045512.2\"; transcript_id \"NC_045512.2\";\n"
        let made = try TenxGTFFilter.filter(input + Data((lge + gone + extra).utf8), list: .gencode2020A,
                                            extraRecords: ["NC_045512.2"], exonsAdded: ["ENSG00000278674.2"])
        let text = String(decoding: made.bytes, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix(lge + extra), text)
        XCTAssertFalse(text.contains(gone))
        XCTAssertEqual(made.genesLeftOut.count, 4)
    }
}

/// The rule on a whole GTF outside the repository, which a lane runs by hand to measure it (SOLO-PLAN M4, Check). Set
/// `LUNGFISH_TENX_GTF_IN` to a plain GTF and `LUNGFISH_TENX_GTF_OUT` to an empty folder. For each list and each rule version
/// it writes the made file as `<version>-<list>.gtf`, or the refusal as `<version>-<list>.refused`, and a line of counts to
/// `counts.tsv`. With neither set the test is skipped, and the default tier never sets them.
final class TenxGTFFilterConformanceTests: XCTestCase {
    func testTheRuleOnTheGTFTheEnvironmentNames() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["LUNGFISH_TENX_GTF_IN"], let output = environment["LUNGFISH_TENX_GTF_OUT"] else {
            throw XCTSkip("LUNGFISH_TENX_GTF_IN and LUNGFISH_TENX_GTF_OUT name no GTF to measure.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        var counts = "version\tlist\tgenesLeftOut\tbytes\tsha256\n"
        let runs: [(TenxGTFFilter.List, Int)] = [(.mkgtf300, 1), (.gencode2020A, 1), (.gencode2020A, 2)]
        for (list, version) in runs {
            let name = "\(version)-\(list.rawValue)"
            do {
                let made = try TenxGTFFilter.filter(data, list: list, ruleVersion: version, extraRecords: [], exonsAdded: [])
                try made.bytes.write(to: folder.appendingPathComponent("\(name).gtf"))
                counts += "\(version)\t\(list.rawValue)\t\(made.genesLeftOut.count)\t\(made.size)\t\(made.sha256)\n"
            } catch let error as STARIndexError {
                try Data(error.message.utf8).write(to: folder.appendingPathComponent("\(name).refused"))
                counts += "\(version)\t\(list.rawValue)\trefused\t\t\n"
            }
        }
        try Data(counts.utf8).write(to: folder.appendingPathComponent("counts.tsv"))
    }
}
