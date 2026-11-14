// ReferenceSetOwnerTests.swift - The one owner of RNA-seq reference sets (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
@testable import LungfishWorkflow

/// What gffread 0.12.9 says and does for a gene or transcript line of `transcript_id ""`: it stops with exit status 1
/// and writes no record (measured in RS-REFSET part 6 on RefSeq Mmul_10 release 103).
struct StandInGffreadRefusal: LocalizedError {
    var errorDescription: String? { "gffread stopped with exit status 1: Error: no valid ID found for GFF record" }
}

/// A stand-in for gffread. As gffread 0.12.9 does (ADJ-BIO-51 Q1), it writes one record a transcript id on each
/// contig and strand of the annotation's transcript, exon and CDS lines, in the order the lines give them, so an id
/// two genes share on two strands gives two records of one name. It adds `ghost` and a second `twice` when set,
/// refuses a gene or transcript line of `transcript_id ""` as gffread does, counts its runs and keeps the path and
/// text of each GTF it was given.
final class StandInTranscriptDeriver: ReferenceSetTranscriptDeriving, @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var given: [(path: String, text: String)] = []
    let ghost: String?
    let twice: String?

    init(ghost: String? = nil, twice: String? = nil) {
        self.ghost = ghost
        self.twice = twice
    }

    var runCount: Int { lock.withLock { runs } }

    /// Each GTF gffread was given, read before the stage's work folder goes.
    var annotations: [(path: String, text: String)] { lock.withLock { given } }

    func toolVersion() async throws -> String { "0.12.9" }

    func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
        let text = try String(contentsOf: annotation, encoding: .utf8)
        lock.withLock {
            runs += 1
            given.append((annotation.path, text))
        }
        var ids: [String] = []
        var places = Set<String>()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cells.count == 9, ["gene", "transcript"].contains(cells[2]), cells[8].contains("transcript_id \"\"") {
                throw StandInGffreadRefusal()
            }
            guard cells.count == 9, ["exon", "CDS", "transcript"].contains(cells[2]),
                  let range = cells[8].range(of: #"transcript_id "[^"]+""#, options: .regularExpression) else { continue }
            let id = String(cells[8][range].dropFirst("transcript_id \"".count).dropLast())
            if places.insert("\(id)\t\(cells[0])\t\(cells[6])").inserted { ids.append(id) }
        }
        if let ghost { ids.append(ghost) }
        if let twice { ids.append(twice) }
        try Data(ids.map { ">\($0)\nACGT\n" }.joined().utf8).write(to: output)
    }
}

final class ReferenceSetOwnerTests: XCTestCase {
    var root: URL!
    var inputs: URL!

    static let genome = ">chr1 test chromosome\n" + String(repeating: "ACGTACGTAC", count: 6) + "\n>MT mitochondrion\n"
        + String(repeating: "ACGT", count: 10) + "\n"

    /// G1 has two exons, ND1 on MT has a CDS and a stop codon and no exon, an exon on MT has an empty gene_id,
    /// and G2 comes last. So the genes read G1, ND1, G2.
    static let annotation = """
        #!genome-build test
        chr1\tt\tgene\t1\t30\t.\t+\t.\tgene_id "G1"; gene_name "Alpha"; gene_biotype "protein_coding";
        chr1\tt\ttranscript\t1\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t1\t10\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t21\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        MT\tt\tgene\t1\t12\t.\t+\t.\tgene_id "ND1"; gene "ND1"; gene_biotype "protein_coding";
        MT\tt\tCDS\t1\t9\t.\t+\t0\tgene_id "ND1"; transcript_id "ND1-T";
        MT\tt\tstop_codon\t10\t12\t.\t+\t0\tgene_id "ND1"; transcript_id "ND1-T";
        MT\tt\texon\t20\t30\t.\t+\t.\tgene_id ""; transcript_id "";
        chr1\tt\texon\t40\t50\t.\t-\t.\tgene_id "G2"; transcript_id "T2"; gene_biotype "lncRNA";

        """

    static let virus = ">V1 test virus\nACGTACGT\n>V2\nGGCC\n"
    static let virusAnnotation = """
        V1\td\texon\t1\t8\t.\t+\t.\tgene_id "vg1"; transcript_id "vt1"; gene_name "Orf1";
        V2\td\texon\t1\t4\t.\t+\t.\tgene_id "vg2"; transcript_id "vt2"; gene_name "Orf2";

        """

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("refset-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try write(Self.genome, "genome.fa")
        try write(Self.annotation, "genes.gtf")
        try write(Self.virus, "virus.fa")
        try write(Self.virusAnnotation, "virus.gtf")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func write(_ text: String, _ name: String) throws {
        try Data(text.utf8).write(to: inputs.appendingPathComponent(name))
    }

    func request(layout: ReferenceSetLayout = .lge, virusAnnotation: Bool = false) -> ReferenceSetRequest {
        let virus = ReferenceSetExtraInput(
            name: "virus", kind: .virus, fasta: inputs.appendingPathComponent("virus.fa"),
            annotation: virusAnnotation ? inputs.appendingPathComponent("virus.gtf") : nil)
        return ReferenceSetRequest(
            name: "Test set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB",
            annotationRelease: "7", genome: inputs.appendingPathComponent("genome.fa"),
            annotation: inputs.appendingPathComponent("genes.gtf"), extras: [virus], layout: layout)
    }

    func owner(_ deriver: StandInTranscriptDeriver, root: URL? = nil) -> ReferenceSetOwner {
        ReferenceSetOwner(storageRoot: root ?? self.root, deriver: deriver, provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    func rows(_ outcome: ReferenceSetOutcome, _ file: String) throws -> [[String]] {
        try String(contentsOf: outcome.url.appendingPathComponent("derived/\(file)"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rnaseq-reference-sets").path).sorted()
    }

    // MARK: - Reading

    func testAnAnnotationNameMissingFromTheGenomeIsRefusedWithTheNames() async throws {
        try write(Self.annotation + "chr9\tt\texon\t1\t5\t.\t+\t.\tgene_id \"G9\"; transcript_id \"T9\";\n", "genes.gtf")
        do {
            _ = try await owner(StandInTranscriptDeriver()).build(request())
            XCTFail("a name the genome lacks must be refused")
        } catch let error as ReferenceSetError {
            XCTAssertEqual(error, .namesMissingFromGenome(["chr9"]))
            XCTAssertTrue(error.localizedDescription.contains("chr9"), error.localizedDescription)
        }
        XCTAssertEqual(try entries(), [], "the refused build leaves no stage and no set")
    }

    func testATranscriptIDInOneFileAndNotTheOtherIsRefused() async throws {
        do {
            _ = try await owner(StandInTranscriptDeriver(ghost: "TX-GHOST")).build(request())
            XCTFail("a transcript the annotation lacks must be refused")
        } catch let error as ReferenceSetError {
            XCTAssertEqual(error, .transcriptsDiffer(onlyInAnnotation: [], onlyInTranscripts: ["TX-GHOST"]))
        }
        XCTAssertEqual(try entries(), [])
    }

    func testLGELayoutGivesTheCDSWithoutExonItsCDSAndStopAndOneFeatureARecord() async throws {
        let outcome = try await owner(StandInTranscriptDeriver()).build(request())
        let genes = try rows(outcome, "genes.tsv")
        XCTAssertEqual(genes.first, ["gene_id", "name", "biotype", "contig", "length", "not_host", "mask", "unreliable"])
        XCTAssertEqual(genes.dropFirst().map { $0[0] }, ["G1", "ND1", "G2", "V1", "V2"], "deposit order, extras last")
        XCTAssertEqual(genes.dropFirst().map { $0[4] }, ["20", "12", "11", "8", "4"])
        XCTAssertEqual(genes.dropFirst().map { $0[5] }, ["false", "false", "false", "true", "true"])
        XCTAssertEqual(genes[2], ["ND1", "ND1", "protein_coding", "MT", "12", "false", "", ""])
        XCTAssertEqual(outcome.manifest.derivation.exonsAdded, ["ND1"])
        XCTAssertEqual(outcome.manifest.derivation.keptWithoutExon, [])
        XCTAssertEqual(outcome.manifest.derivation.droppedFeatures, ["MT\texon\t20\t30"])
        XCTAssertEqual(outcome.manifest.mitochondrialContigs, ["MT"])
        XCTAssertEqual(outcome.manifest.extras.map(\.records), [["V1", "V2"]])
        XCTAssertEqual(try rows(outcome, "transcripts.tsv").map { $0[0] + ">" + $0[1] },
                       ["transcript_id>gene_id", "T1>G1", "ND1-T>ND1", "T2>G2", "V1>V1", "V2>V2"])
        let transcripts = try String(contentsOf: outcome.url.appendingPathComponent("derived/transcripts.fa"), encoding: .utf8)
        XCTAssertEqual(transcripts, ">T1\nACGT\n>ND1-T\nACGT\n>T2\nACGT\n" + Self.virus, "gffread's records, then each extra's as given")
        XCTAssertTrue(outcome.url.lastPathComponent.hasPrefix("testus_examplus-T1-testdb7-lge-"), outcome.url.lastPathComponent)
        XCTAssertEqual(try entries(), [outcome.url.lastPathComponent])
    }

    func testTheDepositLayoutKeepsTheGeneWithoutAnExonAndTheDepositsOwnFeatures() async throws {
        let outcome = try await owner(StandInTranscriptDeriver()).build(request(layout: .deposit(study: "GSE1"), virusAnnotation: true))
        let genes = try rows(outcome, "genes.tsv").dropFirst()
        XCTAssertEqual(genes.map { $0[0] }, ["G1", "ND1", "G2", "vg1", "vg2"])
        XCTAssertEqual(genes.map { $0[1] }, ["Alpha", "ND1", "G2", "Orf1", "Orf2"])
        XCTAssertEqual(genes.map { $0[4] }, ["20", "0", "11", "8", "4"], "the deposit adds no exon, so ND1 counts 0")
        XCTAssertEqual(outcome.manifest.derivation.keptWithoutExon, ["ND1"])
        XCTAssertEqual(outcome.manifest.derivation.exonsAdded, [])
        XCTAssertEqual(outcome.manifest.layout, .init(kind: "deposit", study: "GSE1"))
        XCTAssertTrue(outcome.url.lastPathComponent.hasPrefix("testus_examplus-T1-testdb7-deposit-GSE1-"), outcome.url.lastPathComponent)
    }

    // MARK: - Inputs given through links

    /// A person's genome is often a relative link into another release's folder (part 3, GR on gse183579). The owner
    /// reads and copies the file the link names, under the name given, so the set holds no link that points nowhere.
    func testAnInputGivenAsARelativeLinkIsCopiedAsTheFileItNames() async throws {
        let otherRoot = root.deletingLastPathComponent().appendingPathComponent("root-direct", isDirectory: true)
        let direct = try await owner(StandInTranscriptDeriver(), root: otherRoot).build(request())
        let real = inputs.deletingLastPathComponent().appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        for name in ["genome.fa", "genes.gtf", "virus.fa"] {
            try FileManager.default.moveItem(at: inputs.appendingPathComponent(name), to: real.appendingPathComponent(name))
            try FileManager.default.createSymbolicLink(
                atPath: inputs.appendingPathComponent(name).path, withDestinationPath: "../real/\(name)")
        }

        let linked = try await owner(StandInTranscriptDeriver()).build(request())
        XCTAssertEqual(linked.manifest.id, direct.manifest.id, "a link names the same bytes under the same name, so the same id")
        for path in ["genome/genome.fa", "annotation/genes.gtf", "extras/virus.fa"] {
            let kind = try FileManager.default.attributesOfItem(atPath: linked.url.appendingPathComponent(path).path)[.type]
            XCTAssertEqual(kind as? FileAttributeType, .typeRegular, "\(path) is a copy of the file the link names")
        }
        XCTAssertEqual(try String(contentsOf: linked.url.appendingPathComponent("genome/genome.fa"), encoding: .utf8), Self.genome)
    }

    // MARK: - The id

    func testTheSameInputsGiveTheSameIDAndAChangedExtraOrLayoutANewOne() async throws {
        let first = try await owner(StandInTranscriptDeriver()).build(request())
        let otherRoot = root.deletingLastPathComponent().appendingPathComponent("root-2", isDirectory: true)
        let again = try await owner(StandInTranscriptDeriver(), root: otherRoot).build(request())
        XCTAssertEqual(first.manifest.id, again.manifest.id)
        XCTAssertFalse(again.reused)

        let deposit = try await owner(StandInTranscriptDeriver()).build(request(layout: .deposit(study: "GSE1"), virusAnnotation: true))
        XCTAssertNotEqual(deposit.manifest.id, first.manifest.id)

        try write(">V1 test virus\nACGTACGA\n>V2\nGGCC\n", "virus.fa")
        let changed = try await owner(StandInTranscriptDeriver()).build(request())
        XCTAssertNotEqual(changed.manifest.id, first.manifest.id, "one changed byte of an extra makes a new id")
        XCTAssertEqual(changed.manifest.id.count, first.manifest.id.count)
    }

    func testTheDigestIsTheContentListOfThePage() {
        let id = ReferenceSetID.make(
            species: "Macaca mulatta", assembly: "Mmul_10", annotationSource: "Ensembl", annotationRelease: "100",
            layout: .lge, contents: [.init(role: "genome", fileName: "g.fa", sha256: "aa"), .init(role: "annotation", fileName: "a.gtf", sha256: "bb")],
            deriveVersion: "0.12.9")
        let list = "genome\tg.fa\taa\nannotation\ta.gtf\tbb\nlayout\tlge\nderive\tgffread 0.12.9\n"
        XCTAssertEqual(id, "macaca_mulatta-Mmul_10-ensembl100-lge-" + String(ReferenceSetID.sha256Hex(Data(list.utf8)).prefix(12)))
    }

    // MARK: - The owner

    func testASecondBuildOfTheSameIDReusesTheSetAndRunsNoGffread() async throws {
        let deriver = StandInTranscriptDeriver()
        let first = try await owner(deriver).build(request())
        let second = try await owner(deriver).build(request())
        XCTAssertEqual(deriver.runCount, 1, "the second build runs no gffread")
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.manifest, first.manifest)
        XCTAssertEqual(try entries(), [first.url.lastPathComponent])
    }

    func testAStageLeftByACrashGoesBeforeTheNextBuildAndAHeldStageStays() async throws {
        let sets = root.appendingPathComponent("rnaseq-reference-sets", isDirectory: true)
        let crashed = sets.appendingPathComponent(".old.lungfishrefset.creating-\(UUID().uuidString)", isDirectory: true)
        let held = sets.appendingPathComponent(".busy.lungfishrefset.creating-\(UUID().uuidString)", isDirectory: true)
        let other = sets.appendingPathComponent("notes", isDirectory: true)
        for folder in [crashed, held, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A running build holds its stage with an exclusive flock on the folder.
        let descriptor = open(held.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { close(descriptor) }

        let outcome = try await owner(StandInTranscriptDeriver()).build(request())
        XCTAssertEqual(try entries(), [held.lastPathComponent, outcome.url.lastPathComponent, "notes"].sorted())
    }
}
