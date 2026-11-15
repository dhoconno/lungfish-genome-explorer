// ReferenceSetMitoFixtureTests.swift - The owner on the cynomolgus mitochondrion of `refset-mito` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// NC_012670.1 of RefSeq Macaca_fascicularis_5.0 release 101 as the deposit gives it (`Tests/Fixtures/rnaseq/refset-mito/`).
/// Its 13 genes have a CDS and a stop codon and no exon, all 13 CDS share the transcript id `unknown_transcript_1`, and
/// its 24 exons (tRNA and rRNA) have an empty `gene_id` (P5-REFS finding 1, ADJ-SC:77-83 with ADJ-SC-3:11).
enum ReferenceSetMitoFixture {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RNASeq/
        .deletingLastPathComponent()   // LungfishWorkflowTests/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("Fixtures/rnaseq/refset-mito", isDirectory: true)

    static let genes = ["ND1", "ND2", "COX1", "COX2", "ATP8", "ATP6", "COX3", "ND3", "ND4L", "ND4", "ND5", "ND6", "CYTB"]
    /// Each gene's CDS plus its stop codon, the exon LGE's layout gives it, in bases.
    static let lengths = ["955", "1042", "1539", "684", "207", "681", "784", "346", "297", "1378", "1812", "528", "1141"]

    static func request(_ layout: ReferenceSetLayout) -> ReferenceSetRequest {
        ReferenceSetRequest(
            name: "Cynomolgus mitochondrion", species: "Macaca fascicularis", assemblyName: "Macaca_fascicularis_5.0",
            annotationSource: "RefSeq", annotationRelease: "101", genome: folder.appendingPathComponent("cynomolgus-mt.fa"),
            annotation: folder.appendingPathComponent("cynomolgus-mt.gtf"), layout: layout,
            assemblyReport: folder.appendingPathComponent("cynomolgus-mt_assembly_report.txt"))
    }

    static func build(_ layout: ReferenceSetLayout, root: URL, deriver: any ReferenceSetTranscriptDeriving) async throws
        -> (outcome: ReferenceSetOutcome, genes: [[String]], records: [String]) {
        let owner = ReferenceSetOwner(storageRoot: root, deriver: deriver, provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let outcome = try await owner.build(request(layout))
        let derived = outcome.url.appendingPathComponent("derived", isDirectory: true)
        let genes = try String(contentsOf: derived.appendingPathComponent("genes.tsv"), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let records = try ReferenceSetAnnotationReader.fastaRecords(derived.appendingPathComponent("transcripts.fa"))
        return (outcome, genes, records.map(\.name))
    }
}

final class ReferenceSetMitoFixtureTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("refset-mito-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLGELayoutGivesEachMitochondrialGeneItsCDSAndStopAsOneRecord() async throws {
        let (outcome, genes, records) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(genes.map { $0[0] }, ReferenceSetMitoFixture.genes, "the deposit's gene order")
        XCTAssertEqual(genes.map { $0[4] }, ReferenceSetMitoFixture.lengths)
        XCTAssertEqual(Set(genes.map { $0[3] }), ["NC_012670.1"])
        XCTAssertEqual(records.count, 13, records.joined(separator: " "))
        XCTAssertFalse(records.contains("unknown_transcript_1"), "the shared id names no record")
        XCTAssertEqual(outcome.manifest.derivation.exonsAdded, ReferenceSetMitoFixture.genes)
        XCTAssertEqual(outcome.manifest.derivation.keptWithoutExon, [])
        XCTAssertEqual(outcome.manifest.derivation.droppedFeatures.count, 24, "the exons of empty gene_id")
        XCTAssertEqual(outcome.manifest.mitochondrialContigs, ["NC_012670.1"], "found by the assembly report, never by name")
        XCTAssertEqual(outcome.notes, [], "a set that names a mitochondrial contig has nothing to say")
    }

    func testTheDepositLayoutKeepsTheMitochondrialGenesWithoutAnExon() async throws {
        let (outcome, genes, records) = try await ReferenceSetMitoFixture.build(
            .deposit(study: "GSE296788"), root: root, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(genes.map { $0[0] }, ReferenceSetMitoFixture.genes)
        XCTAssertEqual(genes.map { $0[4] }, Array(repeating: "0", count: 13), "the deposit adds no exon")
        XCTAssertEqual(records, [], "a gene with no exon writes no transcript")
        XCTAssertEqual(outcome.manifest.derivation.keptWithoutExon, ReferenceSetMitoFixture.genes)
        XCTAssertEqual(outcome.manifest.derivation.exonsAdded, [])
        XCTAssertEqual(outcome.manifest.derivation.droppedFeatures.count, 24)
        XCTAssertEqual(outcome.manifest.mitochondrialContigs, ["NC_012670.1"])
    }
}

/// The same fixture through real gffread, the RNA-seq pack's, from the conda root (`LUNGFISH_CONDA_ROOT` when it is
/// set, else the configured root). It skips when no gffread is installed there, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.
final class ReferenceSetMitoFixtureConformanceTests: XCTestCase {
    func testGffreadWritesEachMitochondrialGeneAtItsCDSAndStopLength() async throws {
        let gffread = try await ToolAvailability.require("gffread", environment: "gffread")
        let deriver = GffreadTranscriptDeriver()
        let version: String
        do {
            version = try await deriver.toolVersion()
        } catch {
            try ToolAvailability.skipOrFail("gffread at \(gffread.path) gives no version: \(error.localizedDescription)")
        }
        print("ReferenceSetMitoFixtureConformanceTests: gffread \(version) at \(gffread.path)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refset-mito-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: deriver)
        let records = try ReferenceSetAnnotationReader.fastaRecords(outcome.url.appendingPathComponent("derived/transcripts.fa"))
        XCTAssertEqual(records.count, 13, records.map(\.name).joined(separator: " "))
        XCTAssertEqual(records.map { String($0.length) }.sorted(), ReferenceSetMitoFixture.lengths.sorted())
        XCTAssertFalse(records.map(\.name).contains("unknown_transcript_1"))

        // RS-COUNTING-GTF: derived/genes.gtf has 13 exon lines whose merged lengths equal gffread's 13 records.
        let gtf = try String(contentsOf: outcome.url.appendingPathComponent("derived/genes.gtf"), encoding: .utf8)
        var exonLengths: [String: Int] = [:]
        for exon in referenceSetExonLines(gtf) {
            exonLengths[exon[6], default: 0] += (Int(exon[3]) ?? 0) - (Int(exon[2]) ?? 0) + 1
        }
        XCTAssertEqual(referenceSetExonLines(gtf).count, 13)
        XCTAssertEqual(exonLengths, Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.length) }))
        XCTAssertEqual(try outcome.manifest.requireCountingGTF().sha256,
                       try ProvenanceFileHasher.sha256(of: outcome.url.appendingPathComponent("derived/genes.gtf")))
    }
}
