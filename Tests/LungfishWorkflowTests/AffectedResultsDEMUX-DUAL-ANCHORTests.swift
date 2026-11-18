// AffectedResultsDEMUX-DUAL-ANCHORTests.swift - The affected row of a custom dual-index file searched anywhere in the read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-ANCHOR, backlog DEMUX-DUAL-UNANCHORED (ruling BIO-DUAL-ANCHOR items 7 and 12, Q4). Every published build up
// to Preview 2026.11.11 (13672) searched the two barcodes of a custom dual-index definition at Both Ends with no sample sheet
// anywhere in each read, so its samples could hold reads placed there by chance. `kind(of:)` reads the definition the run
// kept in its result folder, then the file the record names.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXDUALANCHORTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-dual-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    func testTheDualUnanchoredRowHoldsEveryBuildUpToTheFix() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-DUAL-UNANCHORED" })
        let dual = AffectedResultKind.fastqDemultiplexDualSearchedAnywhere
        XCTAssertEqual(row.kinds, [dual])
        XCTAssertNil(row.firstBuild, "the writer came in e34628cf4, older than any build a row names")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest published build, lacks the fix")
        XCTAssertEqual(row.fixCommit, "413bdd7a1", "the refusal of SATKIT-4, the first commit that stops such a run")
        XCTAssertEqual(row.sentence, "This run looked for the two barcodes of a custom dual-index file anywhere in each read, "
                       + "so some samples may hold reads placed there by chance.")
        XCTAssertEqual(row.whatToDo, "Check each sample against your sample sheet, then run Demultiplex Barcodes again with "
                       + "this version, which looks for the barcodes only at the read ends.")
        XCTAssertEqual(ids(4192, dual), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-DUAL-UNANCHORED"], "2026.8.1")
        XCTAssertEqual(ids(12972, dual), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-DUAL-UNANCHORED"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13672, dual), ["DEMUX-DUAL-UNANCHORED"], "Preview 2026.11.11")
        XCTAssertEqual(ids(13673, dual), [])
        for kind in AffectedResultKind.allCases where kind != dual {
            XCTAssertFalse(ids(13672, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names (test vi)

    /// A definition file of `rows` under `name`, with a `# kit:` line when `sourceKit` is given.
    private func definition(_ rows: [String], name: String, sourceKit: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let header = (sourceKit.map { ["# kit: \($0)"] } ?? []) + ["id,i7_sequence,i5_sequence"]
        try (header + rows).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let dualRows = ["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"]

    /// A record of a Cutadapt run of `lungfish fastq demultiplex` with the options `FastqCommand.swift` records for that
    /// engine, written by `ProvenanceWriter` and read back from the file. `kept` is the copy of the definition the run keeps
    /// in its result folder (`customBarcodeKit`), and `kit` the path the person named.
    private func writtenRecord(
        kit: String, kept: URL?, engine: String? = "cutadapt", location: String = "bothends",
        resolvedLocation: String? = "bothEnds", null: String? = "random-bases", errorRate: Double = 0.15
    ) throws -> ProvenanceEnvelope {
        var explicit: [String: ParameterValue] = [
            "kit": .string(kit), "resolvedKit": .string("custom-dual"), "customBarcodeKit": kept.map(ParameterValue.file) ?? .null,
            "location": .string(location), "maxDistanceFrom5Prime": .integer(0), "maxDistanceFrom3Prime": .integer(0),
            "errorRate": .number(errorRate), "overlap": .integer(3),
        ]
        if let resolvedLocation { explicit["resolvedLocation"] = .string(resolvedLocation) }
        if let engine {
            explicit["engine"] = .string(engine)
            explicit["indexSource"] = .string(engine == "header-index" ? "read-names" : "read-sequences")
        }
        if let null { explicit["chanceFloor"] = .dictionary(["null": .string(null), "kitTail": .number(0.01)]) }
        let output = folder.appendingPathComponent("demultiplex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = output.appendingPathComponent("manifest.json")
        try Data("{}\n".utf8).write(to: manifest)
        let now = Date()
        let built = try ProvenanceRunBuilder(
            workflowName: AffectedResults.RecordName.fastqDemultiplex, workflowVersion: "2026.11.11",
            toolName: "cutadapt", toolVersion: "5.2"
        )
        .argv(["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--kit", kit] + (engine.map { ["--engine", $0] } ?? []))
        .runtime(ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)"))
        .options(
            explicit: explicit,
            defaults: ["engine": .null, "location": .string("bothends"), "errorRate": .number(0.15), "overlap": .integer(3)],
            resolved: [:]
        )
        .output(manifest, role: .output)
        .complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        let sidecar = try ProvenanceWriter().write(built, to: output)
        return try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecar))
    }

    /// A Cutadapt record of a custom dual-index definition with no `# kit:` line at Both Ends names the kind at any error
    /// rate, with the floor of random bases or with no floor, and with no engine field, from before `--engine`. The kept copy
    /// is read first, so a definition moved or replaced since the run still names it (BIO-DUAL-ANCHOR item 7, test vi).
    func testACutadaptRecordOfACustomDualDefinitionAtBothEndsNamesTheKind() throws {
        let dual = AffectedResultKind.fastqDemultiplexDualSearchedAnywhere
        let path = try definition(dualRows, name: "dual.csv")
        let kept = try definition(dualRows, name: "kept-dual.csv")
        for errorRate in [0, 0.15] {
            let record = try writtenRecord(kit: path.path, kept: kept, errorRate: errorRate)
            XCTAssertEqual(record.workflowName, AffectedResults.RecordName.fastqDemultiplex)
            XCTAssertEqual(AffectedResults.kind(of: record), dual, "error \(errorRate)")
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, engine: nil)), dual,
                       "a record before --engine, when Cutadapt was the one engine")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, null: nil)), dual,
                       "a record before the floor")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, null: "saturated-kit")), dual,
                       "a kept run of an unpublished build names the narrower kind, which kind(of:) asks before the saturated kit")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, resolvedLocation: nil)), dual,
                       "a record with no resolved location, at the default location")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, location: "both")), dual)
        let moved = folder.appendingPathComponent("moved.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: moved, kept: kept)), dual, "a definition moved since")
        let replaced = folder.appendingPathComponent("replaced.csv")
        try "id,sequence\nS1,ATTACTCG\n".write(to: replaced, atomically: true, encoding: .utf8)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: replaced.path, kept: kept)), dual,
                       "a definition replaced by a single-index file since")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: nil)), dual,
                       "a record with no kept copy reads the file it names")
    }

    /// A record that is not such a run names another kind: a definition whose `# kit:` line names a built-in dual kit of a
    /// known platform, 5' End, another engine, a floor that measured its null, a single-index definition, a built-in kit and
    /// a definition that cannot be read (BIO-DUAL-ANCHOR item 7, test vi).
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let path = try definition(dualRows, name: "dual.csv")
        let truseq = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-ht-dual"))
        XCTAssertNotEqual(truseq.platform, .unknown)
        let builtOn = try definition(truseq.barcodes.prefix(2).map { "\($0.id),\($0.i7Sequence),\($0.i5Sequence ?? "")" },
                                     name: "truseq-plate.csv", sourceKit: truseq.id)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: builtOn.path, kept: builtOn)), .fastqDemultiplex,
                       "a definition built on a built-in dual kit")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
            kit: path.path, kept: path, location: "5prime", resolvedLocation: "fivePrime"
        )), .fastqDemultiplex, "5' End")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: path, resolvedLocation: "threePrime")),
                       .fastqDemultiplex, "the resolved location decides")
        for engine in ["header-index", "exact-bare"] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: path, engine: engine)),
                           .fastqDemultiplex, engine)
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: path, null: "start-composition")),
                       .fastqDemultiplex, "the floor measured a null")
        let single = folder.appendingPathComponent("single.csv")
        try "id,sequence\nS1,ATTACTCG\nS2,TCCGGAGA\n".write(to: single, atomically: true, encoding: .utf8)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: single.path, kept: single)), .fastqDemultiplex,
                       "a single-index definition")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: truseq.id, kept: nil)), .fastqDemultiplex,
                       "a built-in dual kit")
        let gone = folder.appendingPathComponent("gone.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: gone, kept: nil)), .fastqDemultiplex,
                       "a definition that cannot be read")
    }
}
