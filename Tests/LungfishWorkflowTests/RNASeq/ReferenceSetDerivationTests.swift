// ReferenceSetDerivationTests.swift - The GTF LGE writes for gffread, the transcript check and the set's record
// (Phase 5.1 lane RS-REFSET, ADJ-BIO-51 items 1, 2 and 4, ADJ-ARCH-51 items 6 and 8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class ReferenceSetDerivationTests: XCTestCase {
    var root: URL!
    var inputs: URL!

    /// As RefSeq writes a mitochondrion: one transcript id for ND1 on + and ND6 on -, and a tRNA exon of empty
    /// gene_id under the same id.
    static let annotation = """
        chr1\tt\tgene\t1\t30\t.\t+\t.\tgene_id "G1"; gene_name "Alpha"; gene_biotype "protein_coding";
        chr1\tt\ttranscript\t1\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t1\t10\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t21\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        MT\tRefSeq\texon\t1\t4\t.\t+\t.\tgene_id ""; transcript_id "unknown_transcript_1"; gbkey "tRNA";
        MT\tRefSeq\tgene\t5\t16\t.\t+\t.\tgene_id "ND1"; gene "ND1"; gene_biotype "protein_coding";
        MT\tRefSeq\tCDS\t5\t13\t.\t+\t0\tgene_id "ND1"; transcript_id "unknown_transcript_1"; gene "ND1";
        MT\tRefSeq\tstart_codon\t5\t7\t.\t+\t0\tgene_id "ND1"; transcript_id "unknown_transcript_1"; gene "ND1";
        MT\tRefSeq\tstop_codon\t14\t16\t.\t+\t0\tgene_id "ND1"; transcript_id "unknown_transcript_1"; gene "ND1";
        MT\tRefSeq\tgene\t20\t31\t.\t-\t.\tgene_id "ND6"; gene "ND6"; gene_biotype "protein_coding";
        MT\tRefSeq\tCDS\t23\t31\t.\t-\t0\tgene_id "ND6"; transcript_id "unknown_transcript_1"; gene "ND6";
        MT\tRefSeq\tstop_codon\t20\t22\t.\t-\t0\tgene_id "ND6"; transcript_id "unknown_transcript_1"; gene "ND6";
        chr1\tt\texon\t51\t60\t.\t-\t.\tgene_id "G2"; transcript_id "T2"; gene_biotype "lncRNA";

        """

    /// P1 has only a gene line, and P2 a gene and a transcript line, so neither has an exon or a CDS. gffread 0.12.9
    /// writes a record from P2's transcript line alone and none from P1 (measured at the lane).
    static let featureless = """
        chr1\tt\tgene\t31\t40\t.\t+\t.\tgene_id "P1"; gene_biotype "pseudogene";
        chr1\tt\tgene\t41\t50\t.\t-\t.\tgene_id "P2"; gene_biotype "other";
        chr1\tt\ttranscript\t41\t50\t.\t-\t.\tgene_id "P2"; transcript_id "TP2";

        """

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("refset-gtf-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try write(ReferenceSetOwnerTests.genome, "genome.fa")
        try write(Self.annotation, "genes.gtf")
        try write(ReferenceSetOwnerTests.virus, "virus.fa")
        try write(ReferenceSetOwnerTests.virusAnnotation, "virus.gtf")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func write(_ text: String, _ name: String) throws {
        try Data(text.utf8).write(to: inputs.appendingPathComponent(name))
    }

    func request(_ layout: ReferenceSetLayout = .lge, extraGTF: Bool = false) -> ReferenceSetRequest {
        let virus = ReferenceSetExtraInput(
            name: "virus", kind: .virus, fasta: inputs.appendingPathComponent("virus.fa"),
            annotation: extraGTF ? inputs.appendingPathComponent("virus.gtf") : nil)
        return ReferenceSetRequest(
            name: "Test set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB",
            annotationRelease: "7", genome: inputs.appendingPathComponent("genome.fa"),
            annotation: inputs.appendingPathComponent("genes.gtf"), extras: [virus], layout: layout)
    }

    func build(_ request: ReferenceSetRequest, _ deriver: StandInTranscriptDeriver, argv: [String] = []) async throws -> ReferenceSetOutcome {
        try await ReferenceSetOwner(storageRoot: root, deriver: deriver, provenanceWriter: ProvenanceWriter(signingProvider: nil))
            .build(request, argv: argv)
    }

    func column(_ outcome: ReferenceSetOutcome, _ file: String, _ index: Int) throws -> [String] {
        try String(contentsOf: outcome.url.appendingPathComponent("derived/\(file)"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { String($0.split(separator: "\t", omittingEmptySubsequences: false)[index]) }
    }

    func pairs(_ outcome: ReferenceSetOutcome) throws -> [String] {
        zip(try column(outcome, "transcripts.tsv", 0), try column(outcome, "transcripts.tsv", 1)).map { "\($0)>\($1)" }
    }

    /// The `derivation` object of `reference-set.json` as written, so a key the code lacks reads as missing.
    func derivation(_ outcome: ReferenceSetOutcome) throws -> [String: Any] {
        let data = try Data(contentsOf: outcome.url.appendingPathComponent(ReferenceSetManifest.filename))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["derivation"] as? [String: Any])
    }

    /// The lines of a GTF that name `gene` as their gene_id.
    static func lines(_ text: String, gene: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.contains("gene_id \"\(gene)\";") }
    }

    // MARK: - ADJ-BIO-51 item 1: gffread reads only a GTF LGE writes

    func testGffreadReadsLGEsOwnGTFWithEachSharedIDRenamedAndTheExonAddedInLGEsLayout() async throws {
        let deriver = StandInTranscriptDeriver()
        let outcome = try await build(request(), deriver)
        let given = try XCTUnwrap(deriver.annotations.first)
        XCTAssertTrue(given.path.contains(".creating-") && given.path.contains("/.work/"), given.path)
        XCTAssertFalse(given.text.contains("gene_id \"\";"), "the GTF leaves out each line of empty gene_id")
        XCTAssertFalse(given.text.contains("transcript_id \"unknown_transcript_1\""), "a shared id is renamed on each line")
        XCTAssertEqual(Self.lines(given.text, gene: "ND1").filter { $0.contains("\tCDS\t") }.count, 1)
        XCTAssertTrue(Self.lines(given.text, gene: "ND1").filter { $0.contains("\tCDS\t") }
            .allSatisfy { $0.contains("transcript_id \"ND1:unknown_transcript_1\";") })
        XCTAssertEqual(Self.lines(given.text, gene: "ND1").filter { $0.contains("\texon\t") },
                       ["MT\tLGE\texon\t5\t16\t.\t+\t.\tgene_id \"ND1\"; transcript_id \"ND1:unknown_transcript_1\";"])
        XCTAssertEqual(Self.lines(given.text, gene: "ND6").filter { $0.contains("\texon\t") },
                       ["MT\tLGE\texon\t20\t31\t.\t-\t.\tgene_id \"ND6\"; transcript_id \"ND6:unknown_transcript_1\";"])

        let names = try ReferenceSetAnnotationReader.fastaRecords(outcome.url.appendingPathComponent("derived/transcripts.fa")).map(\.name)
        XCTAssertEqual(names, ["T1", "ND1:unknown_transcript_1", "ND6:unknown_transcript_1", "T2", "V1", "V2"])
        XCTAssertEqual(try pairs(outcome), ["T1>G1", "ND1:unknown_transcript_1>ND1", "ND6:unknown_transcript_1>ND6", "T2>G2", "V1>V1", "V2>V2"])
        XCTAssertEqual(try column(outcome, "genes.tsv", 0), ["G1", "ND1", "ND6", "G2", "V1", "V2"])
        XCTAssertEqual(try column(outcome, "genes.tsv", 4), ["20", "12", "12", "10", "8", "4"])
        let record = try derivation(outcome)
        XCTAssertEqual(record["exonsAdded"] as? [String], ["ND1", "ND6"])
        XCTAssertEqual(record["droppedFeatures"] as? [String], ["MT\texon\t1\t4"])
        XCTAssertEqual(record["renamedTranscripts"] as? [[String: String]], [
            ["transcript": "unknown_transcript_1", "gene": "ND1", "renamed": "ND1:unknown_transcript_1"],
            ["transcript": "unknown_transcript_1", "gene": "ND6", "renamed": "ND6:unknown_transcript_1"],
        ])
    }

    func testTheDepositLayoutGivesGffreadNoCodingLineOfAGeneKeptWithoutAnExon() async throws {
        let deriver = StandInTranscriptDeriver()
        let outcome = try await build(request(.deposit(study: "GSE1"), extraGTF: true), deriver)
        XCTAssertEqual(deriver.annotations.count, 2, "the genome's GTF and the extra's")
        for given in deriver.annotations { XCTAssertTrue(given.path.contains("/.work/"), given.path) }
        let host = try XCTUnwrap(deriver.annotations.first).text
        XCTAssertEqual(Self.lines(host, gene: "ND1"),
                       ["MT\tRefSeq\tgene\t5\t16\t.\t+\t.\tgene_id \"ND1\"; gene \"ND1\"; gene_biotype \"protein_coding\";"])
        XCTAssertEqual(Self.lines(host, gene: "ND6").count, 1, "only the gene line")
        XCTAssertFalse(host.contains("unknown_transcript_1"))
        XCTAssertFalse(host.contains("gene_id \"\";"))

        XCTAssertEqual(try column(outcome, "genes.tsv", 0), ["G1", "ND1", "ND6", "G2", "vg1", "vg2"])
        XCTAssertEqual(try column(outcome, "genes.tsv", 4), ["20", "0", "0", "10", "8", "4"], "13 genes at length 0 on RefSeq 5.0")
        XCTAssertEqual(try pairs(outcome), ["T1>G1", "T2>G2", "vt1>vg1", "vt2>vg2"], "no record for a gene kept without an exon")
        let record = try derivation(outcome)
        XCTAssertEqual(record["keptWithoutExon"] as? [String], ["ND1", "ND6"])
        XCTAssertEqual(record["renamedTranscripts"] as? [[String: String]], [], "the left-out lines rename nothing")
    }

    // MARK: - ADJ-BIO-51 item 2: a name written twice

    func testTwoRecordsOfOneNameAreRefused() async throws {
        do {
            _ = try await build(request(), StandInTranscriptDeriver(twice: "T1"))
            XCTFail("a transcript name written twice must be refused")
        } catch let error as ReferenceSetError {
            XCTAssertTrue(error.localizedDescription.contains("more than one record named T1"), error.localizedDescription)
        }
        let sets = root.appendingPathComponent(ReferenceSetOwner.folderName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sets.path), [], "no stage and no set")
    }

    // MARK: - ADJ-BIO-51 item 4: a gene with no exon and no CDS

    func testAGeneWithNoExonAndNoCDSIsListedByNameAndLeftOutOfTheTables() async throws {
        try write(Self.annotation + Self.featureless, "genes.gtf")
        let deriver = StandInTranscriptDeriver()
        let outcome = try await build(request(), deriver)
        let listed = outcome.url.appendingPathComponent("derived/genes-without-features.tsv")
        XCTAssertEqual(try String(contentsOf: listed, encoding: .utf8), "gene_id\tcontig\tbiotype\nP1\tchr1\tpseudogene\nP2\tchr1\tother\n")
        let entry = try XCTUnwrap(try derivation(outcome)["genesWithoutFeatures"] as? [String: Any])
        XCTAssertEqual(entry["path"] as? String, "derived/genes-without-features.tsv")
        XCTAssertEqual(entry["count"] as? Int, 2)
        XCTAssertEqual(entry["sha256"] as? String, try ProvenanceFileHasher.sha256(of: listed))
        XCTAssertTrue(Set(try column(outcome, "genes.tsv", 0)).isDisjoint(with: ["P1", "P2"]))
        XCTAssertFalse(try pairs(outcome).contains("TP2>P2"))
        XCTAssertEqual(Self.lines(try XCTUnwrap(deriver.annotations.first).text, gene: "P2"), [],
                       "gffread writes a record from a transcript line alone, so the GTF leaves the gene out")
    }

    // MARK: - RS-REFSET-BIO B1: a set with no mitochondrial contig says so

    func testASetWithNoMitochondrialContigSaysSoInItsNotes() async throws {
        try write(">chr1 test chromosome\n" + String(repeating: "ACGTACGTAC", count: 6) + "\n", "genome.fa")
        try write("chr1\tt\texon\t1\t10\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\";\n", "genes.gtf")
        let first = try await build(request(), StandInTranscriptDeriver())
        XCTAssertEqual(first.manifest.mitochondrialContigs, [])
        XCTAssertEqual(first.notes.count, 1, "\(first.notes)")
        XCTAssertTrue(first.notes.first?.contains("no mitochondrial contig") ?? false, "\(first.notes)")
        let again = try await build(request(), StandInTranscriptDeriver())
        XCTAssertTrue(again.reused)
        XCTAssertEqual(again.notes, first.notes, "a reused set says the same")
    }

    // MARK: - RS-REFSET part 6: a gene line of empty transcript_id

    /// Two genes of NC_005943.1 of RefSeq Mmul_10 release 103 (GCF_003339765.1), every line as given but its trailing
    /// space. Each gene line carries `transcript_id ""`, as all 40,307 of that release do, and gffread 0.12.9 refuses
    /// such a line with "no valid ID found for GFF record".
    static let mmul10 = """
        NC_005943.1\tRefSeq\tgene\t3182\t3256\t.\t+\t.\tgene_id "KEG06_t03"; transcript_id ""; db_xref "GeneID:64986588"; gbkey "Gene"; gene_biotype "tRNA"; locus_tag "KEG06_t03";
        NC_005943.1\tRefSeq\ttranscript\t3182\t3256\t.\t+\t.\tgene_id "KEG06_t03"; transcript_id "unassigned_transcript_1564"; codons "2,3"; gbkey "tRNA"; locus_tag "KEG06_t03"; product "tRNA-Leu"; transcript_biotype "tRNA";
        NC_005943.1\tRefSeq\texon\t3182\t3256\t.\t+\t.\tgene_id "KEG06_t03"; transcript_id "unassigned_transcript_1564"; codons "2,3"; locus_tag "KEG06_t03"; product "tRNA-Leu"; transcript_biotype "tRNA"; exon_number "1";
        NC_005943.1\tRefSeq\tgene\t3259\t4213\t.\t+\t.\tgene_id "KEG06_p13"; transcript_id ""; db_xref "GeneID:2846627"; gbkey "Gene"; gene "ND1"; gene_biotype "protein_coding"; locus_tag "KEG06_p13";
        NC_005943.1\tRefSeq\ttranscript\t3259\t4213\t.\t+\t.\tgene_id "KEG06_p13"; transcript_id "unassigned_transcript_1565"; gbkey "mRNA"; gene "ND1"; locus_tag "KEG06_p13"; transcript_biotype "mRNA";
        NC_005943.1\tRefSeq\texon\t3259\t4213\t.\t+\t.\tgene_id "KEG06_p13"; transcript_id "unassigned_transcript_1565"; gene "ND1"; locus_tag "KEG06_p13"; transcript_biotype "mRNA"; exon_number "1";
        NC_005943.1\tRefSeq\tCDS\t3259\t4210\t.\t+\t0\tgene_id "KEG06_p13"; transcript_id "unassigned_transcript_1565"; gbkey "CDS"; gene "ND1"; locus_tag "KEG06_p13"; note "TAA stop codon is completed by the addition of 3' A residues to the mRNA"; product "NADH dehydrogenase subunit 1"; protein_id "YP_026104.1"; transl_except "(pos:4213..4213,aa:TERM)"; transl_table "2"; exon_number "1";
        NC_005943.1\tRefSeq\tstart_codon\t3259\t3261\t.\t+\t0\tgene_id "KEG06_p13"; transcript_id "unassigned_transcript_1565"; gbkey "CDS"; gene "ND1"; locus_tag "KEG06_p13"; note "TAA stop codon is completed by the addition of 3' A residues to the mRNA"; product "NADH dehydrogenase subunit 1"; protein_id "YP_026104.1"; transl_except "(pos:4213..4213,aa:TERM)"; transl_table "2"; exon_number "1";
        NC_005943.1\tRefSeq\tstop_codon\t4211\t4213\t.\t+\t0\tgene_id "KEG06_p13"; transcript_id "unassigned_transcript_1565"; gbkey "CDS"; gene "ND1"; locus_tag "KEG06_p13"; note "TAA stop codon is completed by the addition of 3' A residues to the mRNA"; product "NADH dehydrogenase subunit 1"; protein_id "YP_026104.1"; transl_except "(pos:4213..4213,aa:TERM)"; transl_table "2"; exon_number "1";

        """

    /// The two gene lines as gffread should read them: the empty `transcript_id` gone and nothing else changed.
    static let mmul10GeneLines = [
        "NC_005943.1\tRefSeq\tgene\t3182\t3256\t.\t+\t.\tgene_id \"KEG06_t03\"; db_xref \"GeneID:64986588\"; gbkey \"Gene\"; gene_biotype \"tRNA\"; locus_tag \"KEG06_t03\";",
        "NC_005943.1\tRefSeq\tgene\t3259\t4213\t.\t+\t.\tgene_id \"KEG06_p13\"; db_xref \"GeneID:2846627\"; gbkey \"Gene\"; gene \"ND1\"; gene_biotype \"protein_coding\"; locus_tag \"KEG06_p13\";",
    ]

    /// A stand-in for NC_005943.1, long enough for both genes.
    static let mmul10Genome = ">NC_005943.1 Macaca mulatta mitochondrion, complete genome\n" + String(repeating: "ACGTACGTAC", count: 440) + "\n"

    func testAGeneLineOfEmptyTranscriptIDReachesGffreadWithoutThatID() async throws {
        try write(Self.mmul10Genome, "genome.fa")
        try write(Self.mmul10, "genes.gtf")
        for (layout, extraGTF) in [(ReferenceSetLayout.lge, false), (.deposit(study: "GSE1"), true)] {
            let deriver = StandInTranscriptDeriver()
            let outcome = try await build(request(layout, extraGTF: extraGTF), deriver)
            let given = try XCTUnwrap(deriver.annotations.first).text
            XCTAssertFalse(given.contains("transcript_id \"\""), "\(layout)")
            XCTAssertEqual(given.split(separator: "\n").map(String.init).filter { $0.contains("\tgene\t") }, Self.mmul10GeneLines)
            XCTAssertEqual(given.split(separator: "\n").count, 9, "every line kept")
            XCTAssertEqual(Array(try pairs(outcome).prefix(2)), ["unassigned_transcript_1564>KEG06_t03", "unassigned_transcript_1565>KEG06_p13"])
            XCTAssertEqual(Array(try column(outcome, "genes.tsv", 0).prefix(2)), ["KEG06_t03", "KEG06_p13"])
            XCTAssertEqual(Array(try column(outcome, "genes.tsv", 4).prefix(2)), ["75", "955"])
            XCTAssertEqual(try derivation(outcome)["renamedTranscripts"] as? [[String: String]], [])
        }
    }

    // MARK: - ADJ-ARCH-51 item 6: an extra's GTF is in the id

    func testTwoDepositBuildsThatDifferOnlyInAnExtrasGTFGetTwoIdsAndNoReuse() async throws {
        let first = try await build(request(.deposit(study: "GSE1"), extraGTF: true), StandInTranscriptDeriver())
        try write(ReferenceSetOwnerTests.virusAnnotation.replacingOccurrences(of: "Orf2", with: "Orf9"), "virus.gtf")
        let second = try await build(request(.deposit(study: "GSE1"), extraGTF: true), StandInTranscriptDeriver())
        XCTAssertNotEqual(second.manifest.id, first.manifest.id)
        XCTAssertFalse(second.reused)
        XCTAssertNotEqual(second.url, first.url)
        let sets = root.appendingPathComponent(ReferenceSetOwner.folderName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sets.path).count, 2, "two folders")
    }

    func testTheDigestOfAContentListWithAnExtraAnnotationLineIsPinned() {
        // printf 'genome\tg.fna.gz\taa\nannotation\ta.gtf.gz\tbb\nextra\tmtb\tcc\nextra annotation\tmtb.gtf\tdd\n
        // layout\tdeposit-GSE296788\nderive\tgffread 0.12.9\nderive\tlungfish 2\n' | shasum -a 256 gives 3b7bb7bedebb...
        // (19059f8d4847 before the line of ARCH-COUNTING-GTF item 1)
        let id = ReferenceSetID.make(
            species: "Macaca fascicularis", assembly: "Macaca_fascicularis_5.0", annotationSource: "RefSeq",
            annotationRelease: "101", layout: .deposit(study: "GSE296788"),
            contents: [.init(role: "genome", fileName: "g.fna.gz", sha256: "aa"), .init(role: "annotation", fileName: "a.gtf.gz", sha256: "bb"),
                       .init(role: "extra", fileName: "mtb", sha256: "cc"), .init(role: "extra annotation", fileName: "mtb.gtf", sha256: "dd")],
            deriveVersion: "0.12.9")
        XCTAssertEqual(id, "macaca_fascicularis-Macaca_fascicularis_5.0-refseq101-deposit-GSE296788-3b7bb7bedebb")
    }

    // MARK: - ADJ-ARCH-51 item 8: the provenance folder arrives with the rename

    func testThePublishedSetHoldsItsProvenanceFolderAndNoStagePath() async throws {
        let argv = ["lungfish-cli", "rnaseq", "reference-set", "--genome", "genome.fa", "--annotation", "genes.gtf"]
        let outcome = try await build(request(), StandInTranscriptDeriver(), argv: argv)
        let rootRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outcome.url))
        let rollupURL = outcome.url.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        let rollup = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: rollupURL))
        XCTAssertEqual(rollup.workflowName, rootRecord.workflowName)
        XCTAssertEqual(rollup.argv, rootRecord.argv)
        XCTAssertEqual(rootRecord.argv, argv)
        XCTAssertTrue(rootRecord.outputs.contains { $0.path == outcome.url.appendingPathComponent("derived/transcripts.fa").path })
        for record in [rootRecord, rollup] {
            let paths = record.argv + record.files.map(\.path) + record.outputs.map(\.path)
                + record.steps.flatMap { $0.argv + $0.inputs.map(\.path) + $0.outputs.map(\.path) }
            XCTAssertFalse(paths.contains { $0.contains(".creating-") }, "\(paths)")
        }
    }
}

/// The RefSeq Mmul_10 release 103 cut through real gffread, from the conda root (`LUNGFISH_CONDA_ROOT` when it is set,
/// else the configured root). It skips when no gffread is installed there, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.
final class ReferenceSetRefSeqGeneLineConformanceTests: XCTestCase {
    func testGffreadReadsTheGeneLinesLGEWritesAndWritesOneRecordATranscript() async throws {
        let gffread = try await ToolAvailability.require("gffread", environment: "gffread")
        print("ReferenceSetRefSeqGeneLineConformanceTests: gffread at \(gffread.path)")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("refset-mmul10-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let genome = base.appendingPathComponent("genome.fa")
        let annotation = base.appendingPathComponent("genes.gtf")
        try Data(ReferenceSetDerivationTests.mmul10Genome.utf8).write(to: genome)
        try Data(ReferenceSetDerivationTests.mmul10.utf8).write(to: annotation)
        let request = ReferenceSetRequest(
            name: "Rhesus mitochondrion", species: "Macaca mulatta", assemblyName: "Mmul_10", annotationSource: "RefSeq",
            annotationRelease: "103", genome: genome, annotation: annotation, layout: .lge)
        let outcome = try await ReferenceSetOwner(
            storageRoot: root, deriver: GffreadTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil)
        ).build(request)
        let records = try ReferenceSetAnnotationReader.fastaRecords(outcome.url.appendingPathComponent("derived/transcripts.fa"))
        XCTAssertEqual(records.map(\.name), ["unassigned_transcript_1564", "unassigned_transcript_1565"])
        XCTAssertEqual(records.map(\.length), [75, 955])
    }
}
