// AffectedResultsDEMUX-DUAL-BARE-REVERSETests.swift - The affected row of a custom dual-index file searched at one read end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-BARE-REVERSE (ruling BIO-BARE-REVERSE items 5 (v) and 6). Every published build up to Preview 2026.11.12
// (13764) searched a custom dual-index definition at 5' End or 3' End with no sample sheet with one barcode of each pair free
// and the swapped pair as its other strand, so reads from the reverse strand were left unassigned and chance matches could
// fill a sample. `kind(of:)` reads the definition the run kept in its result folder, then the file the record names. The
// kind is read by its raw value, so the tests build at the base, which has no such kind.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXDUALBAREREVERSETests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-dual-bare-reverse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    /// The kind of the row DEMUX-DUAL-BARE-REVERSE.
    private func oneEnd() throws -> AffectedResultKind {
        try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexDualOneEnd"), "the kind of DEMUX-DUAL-BARE-REVERSE")
    }

    func testTheDualBareReverseRowHoldsEveryBuildUpToTheFix() throws {
        let oneEnd = try oneEnd()
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-DUAL-BARE-REVERSE" })
        XCTAssertEqual(row.kinds, [oneEnd])
        XCTAssertNil(row.firstBuild, "the one-end lines are older than any build a row names")
        XCTAssertEqual(row.lastBuild, 13764, "Preview 2026.11.12, the newest published build, lacks the fix")
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.11.12", 13764)))
        XCTAssertEqual(row.sentence, "This demultiplexing searched a dual-index definition at one read end only, so reads from "
                       + "the reverse strand were left unassigned and chance matches could fill a sample.")
        XCTAssertEqual(row.whatToDo, "Run it again at Both Ends.")
        XCTAssertEqual(ids(4192, oneEnd), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-DUAL-BARE-REVERSE"], "2026.8.1")
        XCTAssertEqual(ids(12972, oneEnd), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-DUAL-BARE-REVERSE"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13672, oneEnd), ["DEMUX-DUAL-BARE-REVERSE"], "Preview 2026.11.11")
        XCTAssertEqual(ids(13764, oneEnd), ["DEMUX-DUAL-BARE-REVERSE"], "Preview 2026.11.12")
        XCTAssertEqual(ids(13765, oneEnd), [])
        for kind in AffectedResultKind.allCases where kind != oneEnd {
            XCTAssertFalse(ids(13764, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names (test v)

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
        kit: String, kept: URL?, engine: String? = "cutadapt", location: String = "5prime",
        resolvedLocation: String? = "fivePrime", null: String? = "random-bases", errorRate: Double = 0.15
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
            workflowName: AffectedResults.RecordName.fastqDemultiplex, workflowVersion: "2026.11.12",
            toolName: "cutadapt", toolVersion: "5.2"
        )
        .argv(["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--kit", kit, "--location", location]
              + (engine.map { ["--engine", $0] } ?? []))
        .runtime(ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.12 (13764)"))
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

    /// A Cutadapt record of a custom dual-index definition with no `# kit:` line at 5' End or 3' End names the kind, in every
    /// spelling `--location` takes, at any error rate and whatever the floor measured, and with no engine field, from before
    /// `--engine`. The resolved location decides before the location. The kept copy is read first, so a definition moved or
    /// replaced since the run still names it (BIO-BARE-REVERSE items 5 (v) and 6).
    func testACutadaptRecordOfACustomDualDefinitionAtOneReadEndNamesTheKind() throws {
        let oneEnd = try oneEnd()
        let path = try definition(dualRows, name: "dual.csv")
        let kept = try definition(dualRows, name: "kept-dual.csv")
        let spellings = [
            ("5prime", "fivePrime"), ("five-prime", "fivePrime"), ("fiveprime", "fivePrime"),
            ("3prime", "threePrime"), ("three-prime", "threePrime"), ("threeprime", "threePrime"),
        ]
        for (location, resolved) in spellings {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
                kit: path.path, kept: kept, location: location, resolvedLocation: resolved
            )), oneEnd, location)
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
                kit: path.path, kept: kept, location: location.uppercased(), resolvedLocation: nil
            )), oneEnd, "\(location) with no resolved location")
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
            kit: path.path, kept: kept, location: "bothends", resolvedLocation: "threePrime"
        )), oneEnd, "the resolved location decides")
        for errorRate in [0, 0.15] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, errorRate: errorRate)), oneEnd,
                           "error \(errorRate)")
        }
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, engine: nil)), oneEnd,
                       "a record before --engine, when Cutadapt was the one engine")
        for null in [nil, "start-composition", "saturated-kit"] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: kept, null: null)), oneEnd,
                           "the floor's null \(null ?? "none") does not find the reads of the reverse strand")
        }
        let moved = folder.appendingPathComponent("moved.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: moved, kept: kept)), oneEnd, "a definition moved since")
        let replaced = folder.appendingPathComponent("replaced.csv")
        try "id,sequence\nS1,ATTACTCG\n".write(to: replaced, atomically: true, encoding: .utf8)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: replaced.path, kept: kept)), oneEnd,
                       "a definition replaced by a single-index file since")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: nil)), oneEnd,
                       "a record with no kept copy reads the file it names")
    }

    /// A record that is not such a run names another kind: the same definition at Both Ends keeps the kind of
    /// DEMUX-DUAL-UNANCHORED, and `nextera-xt-v2`, a definition whose `# kit:` line names a built-in dual kit, another
    /// engine, a single-index definition and a definition that cannot be read name neither (BIO-BARE-REVERSE item 5 (v)).
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let path = try definition(dualRows, name: "dual.csv")
        let anywhere = AffectedResultKind.fastqDemultiplexDualSearchedAnywhere
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
            kit: path.path, kept: path, location: "bothends", resolvedLocation: "bothEnds"
        )), anywhere, "Both Ends")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
            kit: path.path, kept: path, location: "both", resolvedLocation: nil
        )), anywhere, "Both Ends with no resolved location")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
            kit: path.path, kept: path, location: "5prime", resolvedLocation: "bothEnds"
        )), anywhere, "the resolved location decides")
        let nextera = BarcodeKitRegistry.nexteraXTv2.id
        for (location, resolved) in [("bothends", "bothEnds"), ("5prime", "fivePrime"), ("3prime", "threePrime")] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(
                kit: nextera, kept: nil, location: location, resolvedLocation: resolved
            )), .fastqDemultiplex, "nextera-xt-v2 at \(location)")
        }
        let truseq = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-ht-dual"))
        let builtOn = try definition(truseq.barcodes.prefix(2).map { "\($0.id),\($0.i7Sequence),\($0.i5Sequence ?? "")" },
                                     name: "truseq-plate.csv", sourceKit: truseq.id)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: builtOn.path, kept: builtOn)), .fastqDemultiplex,
                       "a definition built on a built-in dual kit")
        for engine in ["header-index", "exact-bare"] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: path.path, kept: path, engine: engine)),
                           .fastqDemultiplex, engine)
        }
        let single = folder.appendingPathComponent("single.csv")
        try "id,sequence\nS1,ATTACTCG\nS2,TCCGGAGA\n".write(to: single, atomically: true, encoding: .utf8)
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: single.path, kept: single)), .fastqDemultiplex,
                       "a single-index definition")
        let gone = folder.appendingPathComponent("gone.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(kit: gone, kept: nil)), .fastqDemultiplex,
                       "a definition that cannot be read")
    }
}
