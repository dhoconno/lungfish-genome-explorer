// AffectedResultsDEMUXSATKITTests.swift - The affected row of a kit the chance floor cannot judge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-SATKIT (BIO-DEMUX-THREE section 1). Every build up to the fix published the chance matches
// of a Cutadapt search with a kit whose uniform share reaches 0.5, so a result whose record names such a run and a build up to
// 13672 (Preview 2026.11.11) carries the row. `kind(of:)` reads the kit from the record's definition file.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXSATKITTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-satkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    func testTheSaturatedKitRowHoldsEveryBuildUpToTheFix() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-FLOOR-SATURATED-KIT" })
        XCTAssertEqual(row.kinds, [.fastqDemultiplexSaturatedKit])
        XCTAssertNil(row.firstBuild, "every build before the fix, older than any build a row names")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest published build, lacks the fix")
        XCTAssertEqual(row.sentence, "This run's barcodes are so short that reads with no barcode match them by chance, "
                       + "so its sample files may hold chance matches.")
        let saturated = AffectedResultKind.fastqDemultiplexSaturatedKit
        XCTAssertEqual(ids(4192, saturated), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-FLOOR-SATURATED-KIT"], "2026.8.1")
        XCTAssertEqual(ids(12972, saturated), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-FLOOR-SATURATED-KIT"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13672, saturated), ["DEMUX-FLOOR-SATURATED-KIT"], "Preview 2026.11.11")
        XCTAssertEqual(ids(13673, saturated), [])
        for kind in AffectedResultKind.allCases where kind != saturated {
            XCTAssertFalse(ids(13672, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names

    /// A record of `lungfish fastq demultiplex` with the options its writer records (`FastqCommand.swift`).
    private func record(_ options: [String: ParameterValue]) -> ProvenanceEnvelope {
        var record = ProvenanceEnvelope.fixture()
        record.workflowName = AffectedResults.RecordName.fastqDemultiplex
        record.options = ProvenanceOptions(explicit: options)
        return record
    }

    private func definition(_ barcodes: [String], name: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        let rows = barcodes.enumerated().map { "BC\($0.offset + 1),\($0.element)" }
        try (["id,sequence"] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private var fours: [String] {
        let letters = Array("ACGT")
        return (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
    }

    func testARecordWhoseKitHoldsHalfOfAllReadsNamesTheNarrowerKind() throws {
        let short = try definition(Array(fours.prefix(192)), name: "short.csv")
        let cutadapt: [String: ParameterValue] = ["engine": .string("cutadapt"), "kit": .string(short), "errorRate": .number(0.15)]
        XCTAssertEqual(AffectedResults.kind(of: record(cutadapt)), .fastqDemultiplexSaturatedKit, "0.75 of all reads")
        var older = cutadapt
        older["engine"] = nil
        XCTAssertEqual(AffectedResults.kind(of: record(older)), .fastqDemultiplexSaturatedKit, "a record before --engine")
        var exact = cutadapt
        exact["engine"] = .string("exact-bare")
        XCTAssertEqual(AffectedResults.kind(of: record(exact)), .fastqDemultiplex, "only the Cutadapt search has the floor")
        var gone = cutadapt
        gone["kit"] = .string(folder.appendingPathComponent("gone.csv").path)
        XCTAssertEqual(AffectedResults.kind(of: record(gone)), .fastqDemultiplex, "a definition that cannot be read")
        XCTAssertEqual(AffectedResults.kind(of: record(["kit": .string("truseq-single-a")])), .fastqDemultiplex)
        let optIn: [String: ParameterValue] = ["chanceFloor": .dictionary(["null": .string("saturated-kit")])]
        XCTAssertEqual(AffectedResults.kind(of: record(optIn)), .fastqDemultiplexSaturatedKit, "a run kept by choice")
        var measured = cutadapt
        measured["chanceFloor"] = .dictionary(["null": .string("start-composition")])
        XCTAssertEqual(AffectedResults.kind(of: record(measured)), .fastqDemultiplex, "the floor measured this kit")
    }

    /// 100 four-base barcodes hold 0.39 of single reads and 0.78 of fragments, so the mates a record placed decide. Five
    /// 5' offsets multiply the lines, and an 8-base kit of 12 barcodes is far under the share.
    func testTheMatesTheOffsetsAndTheErrorRateOfTheRecordCount() throws {
        let hundred = try definition(Array(fours.prefix(100)), name: "hundred.csv")
        let single: [String: ParameterValue] = ["engine": .string("cutadapt"), "kit": .string(hundred), "errorRate": .number(0.15)]
        XCTAssertEqual(AffectedResults.kind(of: record(single)), .fastqDemultiplex)
        var paired = single
        paired["mateCalls"] = .dictionary(["pairs": .integer(500)])
        XCTAssertEqual(AffectedResults.kind(of: record(paired)), .fastqDemultiplexSaturatedKit)
        var offsets = single
        offsets["maxDistanceFrom5Prime"] = .integer(1)
        XCTAssertEqual(AffectedResults.kind(of: record(offsets)), .fastqDemultiplexSaturatedKit, "two lines a barcode")
        let eights = ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC", "ATTCAGAA", "GAATTCGT", "CTGAAGCT", "TAATGCGC",
                      "CGGCTATG", "TCCGCGAA", "TCTCGCGC", "AGCGATAG"]
        let eight = try definition(eights, name: "eight.csv")
        XCTAssertEqual(AffectedResults.kind(of: record(["kit": .string(eight), "errorRate": .number(0.3)])), .fastqDemultiplex)
    }
}
