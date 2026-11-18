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
        XCTAssertEqual(row.sentence, "This run used a kit whose barcodes match about half of all reads or more by chance, "
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

    // MARK: - The built-in Fluidigm kit (BIO-SATKIT-FLUIDIGM item 5 and Q2)

    /// A record of `lungfish fastq demultiplex` as `FastqCommand.swift` builds it, with the options it records for each
    /// engine, written by `ProvenanceWriter` and read back from the file.
    private func writtenRecord(
        kit: String, resolvedKit: String? = nil, engine: String?, errorRate: Double?
    ) throws -> ProvenanceEnvelope {
        var explicit: [String: ParameterValue] = [
            "kit": .string(kit), "resolvedKit": .string(resolvedKit ?? kit), "customBarcodeKit": .null,
        ]
        if let engine {
            explicit["engine"] = .string(engine)
            explicit["indexSource"] = .string(engine == "header-index" ? "read-names" : "read-sequences")
        }
        if let errorRate {
            explicit["location"] = .string("bothends")
            explicit["errorRate"] = .number(errorRate)
            explicit["maxDistanceFrom5Prime"] = .integer(0)
        }
        let output = folder.appendingPathComponent("demultiplex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = output.appendingPathComponent("manifest.json")
        try Data("{}\n".utf8).write(to: manifest)
        let now = Date()
        let built = try ProvenanceRunBuilder(
            workflowName: AffectedResults.RecordName.fastqDemultiplex, workflowVersion: "2026.11.11",
            toolName: engine == "cutadapt" || engine == nil ? "cutadapt" : "lungfish", toolVersion: "5.0"
        )
        .argv(["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--kit", kit] + (engine.map { ["--engine", $0] } ?? []))
        .runtime(ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)"))
        .options(explicit: explicit, defaults: ["engine": .null, "errorRate": .number(0.15)], resolved: [:])
        .output(manifest, role: .output)
        .complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        let sidecar = try ProvenanceWriter().write(built, to: output)
        return try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecar))
    }

    /// Cutadapt searches the 864 bare 10-base barcodes of the built-in kit anywhere in the read and places nearly every read
    /// in one by chance, at every error rate (BIO-SATKIT-FLUIDIGM Q2: 46.7% of real shotgun reads at error 0). So a Cutadapt
    /// record of the kit is the narrower kind at any rate, and a record of another engine or another built-in kit is not.
    func testACutadaptRecordOfTheFluidigmKitNamesTheNarrowerKindAtAnyErrorRate() throws {
        let fluidigm = "fluidigm-access-array"
        for errorRate in [0, 0.1, 0.15] {
            let record = try writtenRecord(kit: fluidigm, engine: "cutadapt", errorRate: errorRate)
            XCTAssertEqual(record.workflowName, AffectedResults.RecordName.fastqDemultiplex)
            XCTAssertEqual(AffectedResults.kind(of: record), .fastqDemultiplexSaturatedKit, "error \(errorRate)")
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: fluidigm, engine: nil, errorRate: nil)),
                       .fastqDemultiplexSaturatedKit, "a record before --engine, when Cutadapt was the one engine")
        for engine in ["header-index", "exact-bare"] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: fluidigm, engine: engine, errorRate: nil)),
                           .fastqDemultiplex, engine)
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: "ont-nbd114", engine: "cutadapt", errorRate: 0.15)),
                       .fastqDemultiplex, "another built-in kit")
    }

    /// A definition whose `# kit:` line names the Fluidigm kit is searched as the kit is, its bare barcodes anywhere in the
    /// read, so its record is the narrower kind at any rate, error 0 included (BIO-SATKIT-ANYWHERE item 5, test iv). The
    /// record names the definition file and the custom kit's id, not the Fluidigm id, and the kit the file loads is not a
    /// kit of single barcodes, so at the base it was never the kind. A definition built on another kit is not such a run.
    func testARecordOfADefinitionBuiltOnTheFluidigmKitNamesTheNarrowerKind() throws {
        func definition(on kit: BarcodeKitDefinition, name: String) throws -> String {
            let rows = kit.barcodes.prefix(48).map { "\($0.id),\($0.i7Sequence)" }
            let url = folder.appendingPathComponent(name)
            try (["# kit: \(kit.id)", "id,sequence"] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let plate = try definition(on: BarcodeKitRegistry.fluidigmAccessArray, name: "fluidigm-plate.csv")
        for errorRate in [0, 0.15] {
            let record = try writtenRecord(kit: plate, resolvedKit: "custom-fluidigm-plate", engine: "cutadapt", errorRate: errorRate)
            XCTAssertEqual(AffectedResults.kind(of: record), .fastqDemultiplexSaturatedKit, "error \(errorRate)")
        }
        let older = try writtenRecord(kit: plate, resolvedKit: "custom-fluidigm-plate", engine: nil, errorRate: 0)
        XCTAssertEqual(AffectedResults.kind(of: older), .fastqDemultiplexSaturatedKit, "a record before --engine")
        let names = try writtenRecord(kit: plate, resolvedKit: "custom-fluidigm-plate", engine: "header-index", errorRate: nil)
        XCTAssertEqual(AffectedResults.kind(of: names), .fastqDemultiplex, "the split by the read names")
        let ont = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "ont-nbd114"))
        let other = try definition(on: ont, name: "ont-plate.csv")
        let record = try writtenRecord(kit: other, resolvedKit: "custom-ont-plate", engine: "cutadapt", errorRate: 0)
        XCTAssertEqual(AffectedResults.kind(of: record), .fastqDemultiplex, "a definition built on another kit")
    }
}
