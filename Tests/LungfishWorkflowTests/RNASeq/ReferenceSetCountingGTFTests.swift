// ReferenceSetCountingGTFTests.swift - `derived/genes.gtf`, the GTF that STAR, STARsolo and featureCounts read
// (Phase 5.3 lane RS-COUNTING-GTF, BIO-COUNTING-GTF items 2 and 8, ARCH-COUNTING-GTF items 1 and 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import XCTest
@testable import LungfishWorkflow

/// Sets written before the set kept its counting GTF (`Tests/Fixtures/rnaseq/refset-v1/`): RS-REFSET's manifest of
/// Ensembl 107, and a schema 1 set of the cynomolgus mitochondrion that the code of 1f0ae3090 wrote with gffread 0.12.9.
enum ReferenceSetV1Fixture {
    static let folder = ReferenceSetMitoFixture.folder.deletingLastPathComponent()
        .appendingPathComponent("refset-v1", isDirectory: true)
    static let ensembl107 = folder.appendingPathComponent("ensembl-107.reference-set.json")
    static let ensembl107ID = "macaca_fascicularis-Macaca_fascicularis_6.0-ensembl107-lge-a76ad74c82e6"

    static func mitoSet() throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".\(ReferenceSetManifest.folderExtension)") }
        guard names.count == 1 else { throw ReferenceSetError.unreadable("one set in \(folder.path), found \(names)") }
        return folder.appendingPathComponent(names[0], isDirectory: true)
    }

    /// A copy of `set` in the sets folder of `root`, as a storage root holds it.
    static func install(_ set: URL, in root: URL) throws -> URL {
        let sets = root.appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        let copy = sets.appendingPathComponent(set.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: set, to: copy)
        return copy
    }
}

/// The `exon` lines of a GTF as `[contig, source, start, end, strand, gene_id, transcript_id]`.
func referenceSetExonLines(_ text: String) -> [[String]] {
    text.split(separator: "\n").compactMap { line -> [String]? in
        guard let feature = ReferenceSetGTFFeature(String(line)), feature.type == "exon" else { return nil }
        let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return [cells[0], cells[1], cells[3], cells[4], cells[6], feature.gene, feature.transcript]
    }
}

final class ReferenceSetCountingGTFTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("refset-gtf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func owner(_ deriver: StandInTranscriptDeriver = StandInTranscriptDeriver()) -> ReferenceSetOwner {
        ReferenceSetOwner(storageRoot: root, deriver: deriver, provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    func countingGTF(_ outcome: ReferenceSetOutcome) throws -> String {
        try String(contentsOf: outcome.url.appendingPathComponent("derived/genes.gtf"), encoding: .utf8)
    }

    func transcriptTable(_ outcome: ReferenceSetOutcome) throws -> [String] {
        try String(contentsOf: outcome.url.appendingPathComponent("derived/transcripts.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { String($0.split(separator: "\t")[0]) }
    }

    /// `derived.countingGTF` as the published `reference-set.json` holds it.
    func entry(_ outcome: ReferenceSetOutcome) throws -> [String: Any] {
        let data = try Data(contentsOf: outcome.url.appendingPathComponent(ReferenceSetManifest.filename))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let derived = try XCTUnwrap(json["derived"] as? [String: Any])
        return try XCTUnwrap(derived["countingGTF"] as? [String: Any], "reference-set.json names no countingGTF")
    }

    func mitoRequest(_ layout: ReferenceSetLayout, extra annotation: Bool = false) -> ReferenceSetRequest {
        var request = ReferenceSetMitoFixture.request(layout)
        let folder = ReferenceSetMitoFixture.folder
        request.extras = [ReferenceSetExtraInput(
            name: "sars-cov-2", kind: .virus, fasta: folder.appendingPathComponent("sars-cov-2.fa"),
            annotation: annotation ? folder.appendingPathComponent("sars-cov-2-genes.gtf") : nil)]
        return request
    }

    // MARK: - BIO-COUNTING-GTF item 8: the file and its entry

    func testTheMitoSetKeepsAnExonForEachOfItsThirteenGenesAndAnEntryOfTheFile() async throws {
        let deriver = StandInTranscriptDeriver()
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: deriver)
        let text = try countingGTF(outcome)
        XCTAssertEqual(deriver.annotations.count, 1)
        XCTAssertEqual(text, deriver.annotations.first?.text, "the host part is byte-equal to the GTF gffread read")
        let exons = referenceSetExonLines(text)
        XCTAssertEqual(exons.map { $0[5] }, ReferenceSetMitoFixture.genes, "one exon line a gene, from its CDS and stop codon")
        XCTAssertFalse(exons.contains { $0[6] == "unknown_transcript_1" }, "the shared id is renamed in the file too")
        XCTAssertEqual(Set(exons.map { $0[6] }), Set(try transcriptTable(outcome)), "the ids of transcripts.tsv")

        let entry = try entry(outcome)
        let file = outcome.url.appendingPathComponent("derived/genes.gtf")
        XCTAssertEqual(entry["path"] as? String, "derived/genes.gtf")
        XCTAssertEqual(entry["sha256"] as? String, try ProvenanceFileHasher.sha256(of: file))
        XCTAssertEqual((entry["size"] as? NSNumber)?.int64Value, file.fileSizeBytes)
        XCTAssertEqual(entry["tool"] as? String, "lungfish")
        XCTAssertEqual(entry["version"] as? String, WorkflowRun.currentAppVersion)
        XCTAssertEqual(outcome.manifest.schemaVersion, 2)
    }

    func testAnExtraInLGEsLayoutAddsOneExonARecordAfterTheHostPart() async throws {
        let deriver = StandInTranscriptDeriver()
        let outcome = try await owner(deriver).build(mitoRequest(.lge))
        let host = try XCTUnwrap(deriver.annotations.first?.text)
        let line = "NC_045512.2\tLGE\texon\t1\t29903\t.\t+\t.\tgene_id \"NC_045512.2\"; transcript_id \"NC_045512.2\";\n"
        XCTAssertEqual(try countingGTF(outcome), host + line, "the host part, then one line a record of the extra")
        XCTAssertEqual(Set(referenceSetExonLines(try countingGTF(outcome)).map { $0[6] }), Set(try transcriptTable(outcome)))
    }

    func testAnExtraInTheDepositLayoutAddsTheGTFLGEWroteFromItsAnnotation() async throws {
        let deriver = StandInTranscriptDeriver()
        let outcome = try await owner(deriver).build(mitoRequest(.deposit(study: "GSE296788"), extra: true))
        XCTAssertEqual(deriver.annotations.count, 2, "the host GTF and the extra's")
        XCTAssertEqual(try countingGTF(outcome), deriver.annotations.map(\.text).joined())
    }

    func testAnExtrasOwnExonsFollowTheHostPartInTheDepositLayout() async throws {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let files = ["genome.fa": ReferenceSetOwnerTests.genome, "genes.gtf": ReferenceSetOwnerTests.annotation,
                     "virus.fa": ReferenceSetOwnerTests.virus, "virus.gtf": ReferenceSetOwnerTests.virusAnnotation]
        for (name, text) in files { try Data(text.utf8).write(to: inputs.appendingPathComponent(name)) }
        let request = ReferenceSetRequest(
            name: "Test set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB", annotationRelease: "7",
            genome: inputs.appendingPathComponent("genome.fa"), annotation: inputs.appendingPathComponent("genes.gtf"),
            extras: [ReferenceSetExtraInput(name: "virus", kind: .virus, fasta: inputs.appendingPathComponent("virus.fa"),
                                            annotation: inputs.appendingPathComponent("virus.gtf"))],
            layout: .deposit(study: "GSE1"))
        let deriver = StandInTranscriptDeriver()
        let outcome = try await owner(deriver).build(request)
        let text = try countingGTF(outcome)
        XCTAssertEqual(text, deriver.annotations.map(\.text).joined())
        XCTAssertEqual(referenceSetExonLines(text).map { $0[6] }, ["T1", "T1", "T2", "vt1", "vt2"])
        XCTAssertEqual(Set(referenceSetExonLines(text).map { $0[6] }), Set(try transcriptTable(outcome)))
    }

    // MARK: - ARCH-COUNTING-GTF item 1: a set written before

    func testTheSavedEnsembl107ManifestOfSchema1StillLoads() throws {
        let set = root.appendingPathComponent("\(ReferenceSetV1Fixture.ensembl107ID).lungfishrefset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: ReferenceSetV1Fixture.ensembl107, to: set.appendingPathComponent(ReferenceSetManifest.filename))
        let manifest = try ReferenceSetManifest.load(from: set)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.id, ReferenceSetV1Fixture.ensembl107ID)
        XCTAssertEqual(manifest.derived.transcripts.sha256, "89aaf6114b0b8e026afc4b3e88644888c385b176a27f1ee864560121361d6ea8")
        XCTAssertFalse(manifest.namedFiles.contains { $0.path == "derived/genes.gtf" }, "a schema 1 set names no counting GTF")
    }

    func testASchema2ManifestLoadsAndASchema3ManifestIsRefusedBeforeTheDecode() throws {
        let text = try String(contentsOf: ReferenceSetV1Fixture.ensembl107, encoding: .utf8)
        for version in [2, 3] {
            let set = root.appendingPathComponent("schema-\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            // Schema 3's body cannot decode as schema 2 (no id, and `derived` is a string), so only a refusal made
            // before the decode can name the version.
            let body = version == 2
                ? text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
                : "{ \"schemaVersion\" : 3, \"derived\" : \"a layout this LGE does not know\" }"
            try Data(body.utf8).write(to: set.appendingPathComponent(ReferenceSetManifest.filename))
            if version == 2 {
                XCTAssertEqual(try ReferenceSetManifest.load(from: set).schemaVersion, 2)
            } else {
                XCTAssertThrowsError(try ReferenceSetManifest.load(from: set)) { error in
                    XCTAssertEqual(error as? ReferenceSetError, .newerSchema(3))
                }
            }
        }
    }

    func testAVersion1SetSettlesAndABuildOfTheSameInputsPublishesBesideItUnderANewID() async throws {
        let old = try ReferenceSetV1Fixture.install(try ReferenceSetV1Fixture.mitoSet(), in: root)
        let oldManifest = try ReferenceSetManifest.load(from: old)
        XCTAssertEqual(oldManifest.schemaVersion, 1)
        XCTAssertTrue(try owner().settled(old, id: oldManifest.id).reused, "a schema 1 set settles as before")

        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        XCTAssertFalse(outcome.reused, "the schema 1 set lacks the counting GTF, so it is not reused")
        XCTAssertNotEqual(outcome.manifest.id, oldManifest.id)
        XCTAssertEqual(outcome.manifest.id.dropLast(12), oldManifest.id.dropLast(12), "only the digest moves")
        let sets = root.appendingPathComponent(ReferenceSetOwner.folderName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sets.path).sorted(),
                       [old.lastPathComponent, outcome.url.lastPathComponent].sorted(), "both folders stay")
        XCTAssertEqual(try ReferenceSetManifest.load(from: old), oldManifest, "the schema 1 set is not upgraded in place")
    }

    /// ARCH-COUNTING-GTF, Routes, Replaced file.
    func testACountingGTFOfAnotherSizeFailsSettling() async throws {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        try Data("#replaced\n".utf8).write(to: outcome.url.appendingPathComponent("derived/genes.gtf"))
        XCTAssertThrowsError(try owner().settled(outcome.url, id: outcome.manifest.id)) { error in
            XCTAssertEqual(error as? ReferenceSetError, .publishedSetDiffers(id: outcome.manifest.id, file: "derived/genes.gtf"))
        }
    }

    // MARK: - BIO-COUNTING-GTF item 2: the check

    func testTheCheckRefusesAGTFAndTablesThatDifferInOneIDAndInOneLengthAndNamesBoth() throws {
        let folder = root.appendingPathComponent("check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func exon(_ start: Int, _ end: Int, _ strand: String, _ gene: String, _ transcript: String) -> String {
            "chr1\tt\texon\t\(start)\t\(end)\t.\t\(strand)\t.\tgene_id \"\(gene)\"; transcript_id \"\(transcript)\";\n"
        }
        // T1's exons overlap, so its merged length is 15 + 10 = 25.
        let gtf = exon(1, 10, "+", "G1", "T1") + exon(21, 30, "+", "G1", "T1") + exon(5, 15, "+", "G1", "T1")
            + exon(40, 50, "-", "G2", "T2") + exon(60, 63, "+", "G3", "T3-GTF")
        func check(table third: String, t2 length: Int) throws {
            try Data(gtf.utf8).write(to: folder.appendingPathComponent("genes.gtf"))
            try Data("transcript_id\tgene_id\nT1\tG1\nT2\tG2\n\(third)\tG3\n".utf8)
                .write(to: folder.appendingPathComponent("transcripts.tsv"))
            let fasta = ">T1\n\(String(repeating: "A", count: 25))\n>T2 two\n\(String(repeating: "C", count: length))\n>\(third)\nGGGG\n"
            try Data(fasta.utf8).write(to: folder.appendingPathComponent("transcripts.fa"))
            try ReferenceSetCountingGTF.check(folder.appendingPathComponent("genes.gtf"),
                                              transcriptTable: folder.appendingPathComponent("transcripts.tsv"),
                                              transcripts: folder.appendingPathComponent("transcripts.fa"))
        }
        XCTAssertThrowsError(try check(table: "T3-FA", t2: 4)) { error in
            let length = "T2 (11 bases of exons in the GTF, 4 in the FASTA)"
            XCTAssertEqual(error as? ReferenceSetError,
                           .countingGTFDiffers(onlyInGTF: ["T3-GTF"], onlyInTable: ["T3-FA"], lengths: [length]))
            XCTAssertEqual(error.localizedDescription, "The GTF that STAR and featureCounts would read and the transcript "
                + "FASTA that salmon reads differ, so the set was not built. Only in the GTF's exon lines: T3-GTF. Only in "
                + "the transcript table: T3-FA. Exon lengths differ for \(length).")
        }
        XCTAssertNoThrow(try check(table: "T3-GTF", t2: 11), "the same exons and lengths pass")
    }

    func testABuildWhoseTranscriptFASTADiffersFromItsCountingGTFIsRefusedAndLeavesNoStage() async throws {
        do {
            _ = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: ShortFirstRecordDeriver())
            XCTFail("a record shorter than its exons must be refused")
        } catch let error as ReferenceSetError {
            guard case .countingGTFDiffers(let onlyInGTF, let onlyInTable, let lengths) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(onlyInGTF + onlyInTable, [])
            XCTAssertEqual(lengths, ["ND1:unknown_transcript_1 (955 bases of exons in the GTF, 4 in the FASTA)"])
        }
        let sets = root.appendingPathComponent(ReferenceSetOwner.folderName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sets.path), [], "the stage goes as for any failed build")
    }

    // MARK: - ARCH-COUNTING-GTF item 1 and BIO-COUNTING-GTF section 3: the refusal

    func testASetOfSchema1IsRefusedForCountingInWordsThatNameTheRebuildAndWhy() async throws {
        let id = ReferenceSetV1Fixture.ensembl107ID
        let rebuild = "Build the set again from the same files. It gets a new id, and \(id) stays for its salmon results."
        let ensembl = try JSONDecoder().decode(ReferenceSetManifest.self, from: Data(contentsOf: ReferenceSetV1Fixture.ensembl107))
        XCTAssertNil(ensembl.derived.countingGTF, "a schema 1 manifest decodes with no counting GTF")
        XCTAssertThrowsError(try ensembl.requireCountingGTF()) { error in
            XCTAssertEqual(error.localizedDescription,
                           "The set \(id) was built before LGE kept the GTF that STAR and featureCounts read. \(rebuild)")
        }

        var withExtra = ensembl
        withExtra.extras = [.init(name: "ERCC92", kind: .spikeIn, path: "extras/ERCC92.fa", sha256: "aa", annotationPath: nil,
                                  annotationSHA256: nil, records: ["ERCC-00002"], notHost: true)]
        XCTAssertThrowsError(try withExtra.requireCountingGTF()) { error in
            XCTAssertEqual(error.localizedDescription, "The set \(id) was built before LGE kept the GTF that STAR and "
                + "featureCounts read. The set holds the extra ERCC92, which has no GTF line. \(rebuild)")
        }

        let mito = try ReferenceSetManifest.load(from: try ReferenceSetV1Fixture.mitoSet())
        XCTAssertThrowsError(try mito.requireCountingGTF()) { error in
            XCTAssertEqual(error as? ReferenceSetError, .builtBeforeCountingGTF(id: mito.id, reasons: [
                "LGE gave 13 genes an exon from their CDS and stop codon (ND1, ND2, COX1 and 10 more), and the set keeps no "
                    + "GTF with those exons, so STAR would count 0 for them.",
                "LGE renamed 13 transcripts.", "LGE left out 24 features with no gene_id."]))
            XCTAssertTrue(error.localizedDescription.hasPrefix("The set \(mito.id) was built before LGE kept the GTF that "
                + "STAR and featureCounts read. LGE gave 13 genes"), error.localizedDescription)
        }

        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(try outcome.manifest.requireCountingGTF(), outcome.manifest.derived.countingGTF)
        XCTAssertEqual(try outcome.manifest.requireCountingGTF().path, "derived/genes.gtf")
    }
}

/// gffread that writes the first record 4 bases long, whatever its exons.
struct ShortFirstRecordDeriver: ReferenceSetTranscriptDeriving {
    let inner = StandInTranscriptDeriver()

    func toolVersion() async throws -> String { try await inner.toolVersion() }

    func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
        try await inner.writeTranscripts(genome: genome, annotation: annotation, to: output)
        var lines = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
        lines[1] = "ACGT"
        try Data(lines.joined(separator: "\n").utf8).write(to: output)
    }
}
