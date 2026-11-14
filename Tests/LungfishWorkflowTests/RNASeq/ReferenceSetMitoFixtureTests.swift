// ReferenceSetMitoFixtureTests.swift - The owner on the cynomolgus mitochondrion of `refset-mito` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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

/// The same fixture through real gffread from the configured root. It skips when no gffread is installed there.
final class ReferenceSetMitoFixtureConformanceTests: XCTestCase {
    func testGffreadWritesEachMitochondrialGeneAtItsCDSAndStopLength() async throws {
        let deriver = GffreadTranscriptDeriver()
        do {
            _ = try await deriver.toolVersion()
        } catch {
            throw XCTSkip("gffread is not installed in the configured root: \(error.localizedDescription)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refset-mito-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: deriver)
        let records = try ReferenceSetAnnotationReader.fastaRecords(outcome.url.appendingPathComponent("derived/transcripts.fa"))
        XCTAssertEqual(records.count, 13, records.map(\.name).joined(separator: " "))
        XCTAssertEqual(records.map { String($0.length) }.sorted(), ReferenceSetMitoFixture.lengths.sorted())
        XCTAssertFalse(records.map(\.name).contains("unknown_transcript_1"))
    }
}
