// AffectedResultsDEMUX-LINKED-OFFSET-SHIFTTests.swift - The affected row of a built-in dual-kit run that searched indexes set in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-LINKED-OFFSET-SHIFT (ruling BIO-LINKED-OFFSET item 3, lane-shared-4 AFFECTED). Every published build from
// 2026.8.1 (4192), the first that holds the writer fe644e767, up to Preview 2026.11.12 (13764) searched the built-in TruSeq
// HT Dual Index or Nextera XT Index Kit v2 kit, or a definition made on one of them or on IDT for Illumina UD Indexes, at
// Both Ends with a 5' or 3' Distance above 0 with lines that rank a line further in above the right row's line by its N's,
// so some reads landed in another sample with no word. `kind(of:)` names a record of such a run. A dual definition with no
// kit line is the route of DEMUX-DUAL-OFFSET-SHIFT and does not name it. The kind is read by its raw value, so the tests
// build at the base.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXLINKEDOFFSETSHIFTTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-linked-offset-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    /// The kind of the row DEMUX-LINKED-OFFSET-SHIFT.
    private func linked() throws -> AffectedResultKind {
        try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexBuiltInDualOffset"), "the kind of DEMUX-LINKED-OFFSET-SHIFT")
    }

    func testTheBuiltInDualOffsetRowHoldsEveryPublishedBuildFromTheWriterUpToTheFix() throws {
        let linked = try linked()
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-LINKED-OFFSET-SHIFT" })
        XCTAssertEqual(row.kinds, [linked])
        XCTAssertEqual(row.firstBuild, 4192, "2026.8.1, the first published build that holds the writer fe644e767")
        XCTAssertEqual(row.lastBuild, 13764, "Preview 2026.11.12, the newest published build, lacks the fix")
        XCTAssertEqual(row.fixCommit, "97c49c71f", "the check of placed reads on this route")
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.8.1", 4192)))
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.11.12", 13764)))
        XCTAssertEqual(row.sentence, "This run searched for dual indexes set in from the read ends, and the build that ran it "
                       + "could place some reads in another sample.")
        XCTAssertEqual(row.whatToDo, "Run it again in this version.")
        // The kind is a narrower `fastqDemultiplex`, so a record up to Stable 2026.11.7 keeps the sentence of
        // DEMUX-GROUPED-DROPS-INPUTS beside this one.
        XCTAssertEqual(ids(4191, linked), ["DEMUX-GROUPED-DROPS-INPUTS"], "a build before 2026.8.1")
        XCTAssertEqual(ids(4192, linked), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-LINKED-OFFSET-SHIFT"], "2026.8.1")
        XCTAssertEqual(ids(12972, linked), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-LINKED-OFFSET-SHIFT"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13764, linked), ["DEMUX-LINKED-OFFSET-SHIFT"], "Preview 2026.11.12")
        XCTAssertEqual(ids(13765, linked), [])
        for kind in AffectedResultKind.allCases where kind != linked {
            XCTAssertFalse(ids(13764, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names

    /// A definition file of `rows` under `name` in `parent`, or in the test's folder, with the `# kit:` line `kitLine`.
    private func definition(_ rows: [String], name: String, in parent: URL? = nil, kitLine: String? = nil) throws -> URL {
        let url = (parent ?? folder).appendingPathComponent(name)
        let columns = rows.first?.split(separator: ",").count ?? 2
        let header = (kitLine.map { ["# kit: \($0)"] } ?? []) + [columns > 2 ? "id,sequence,secondary_sequence" : "id,sequence"]
        try (header + rows).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let truseqRows = ["D702-D508,TCCGGAGA,GTACTGAC", "D706-D508,GAATTCGT,GTACTGAC"]
    private let nexteraRows = ["N711-S502,AAGAGGCA,CTCTCTAT", "N703-S502,AGGCAGAA,CTCTCTAT"]
    private let idtRows = ["W01,ACGTTGCAAC,TTGGCCAAGG", "W02,TGCAACGTTG,CCAAGGTTGG"]
    private let customDualRows = ["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"]

    /// A record of a Cutadapt run of `lungfish fastq demultiplex` with the options `FastqCommand.swift` records for that
    /// engine, written by `ProvenanceWriter` into `output` and read back from the file. `kept` is the copy of the
    /// definition the run keeps in its result folder (`customBarcodeKit`), and `kit` the id or path the person named.
    private func writtenRecord(
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, output: URL? = nil, engine: String? = "cutadapt",
        location: String? = "bothends", resolvedLocation: String? = nil, fivePrime: Int = 3, threePrime: Int = 3,
        null: String? = "random-bases", errorRate: Double? = 0.15
    ) throws -> URL {
        var explicit: [String: ParameterValue] = [
            "kit": .string(kit), "resolvedKit": .string(resolvedKit ?? kit),
            "customBarcodeKit": kept.map(ParameterValue.file) ?? .null,
            "maxDistanceFrom5Prime": .integer(fivePrime), "maxDistanceFrom3Prime": .integer(threePrime), "overlap": .integer(3),
        ]
        if let location { explicit["location"] = .string(location) }
        if let resolvedLocation { explicit["resolvedLocation"] = .string(resolvedLocation) }
        if let errorRate { explicit["errorRate"] = .number(errorRate) }
        if let engine {
            explicit["engine"] = .string(engine)
            explicit["indexSource"] = .string(engine == "header-index" ? "read-names" : "read-sequences")
        }
        if let null { explicit["chanceFloor"] = .dictionary(["null": .string(null), "kitTail": .number(0.01)]) }
        let output = output ?? folder.appendingPathComponent("demultiplex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = output.appendingPathComponent("manifest.json")
        try Data("{}\n".utf8).write(to: manifest)
        let now = Date()
        let built = try ProvenanceRunBuilder(
            workflowName: AffectedResults.RecordName.fastqDemultiplex, workflowVersion: "2026.11.12",
            toolName: "cutadapt", toolVersion: "5.2"
        )
        .argv(["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--kit", kit] + (engine.map { ["--engine", $0] } ?? []))
        .runtime(ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.12 (13764)"))
        .options(
            explicit: explicit,
            defaults: [
                "engine": .null, "location": .string("bothends"), "maxDistanceFrom5Prime": .integer(0),
                "maxDistanceFrom3Prime": .integer(0), "errorRate": .number(0.15), "overlap": .integer(3),
            ],
            resolved: [:]
        )
        .output(manifest, role: .output)
        .complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        return try ProvenanceWriter().write(built, to: output)
    }

    private func kind(
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, engine: String? = "cutadapt",
        location: String? = "bothends", resolvedLocation: String? = nil, fivePrime: Int = 3, threePrime: Int = 3,
        null: String? = "random-bases", errorRate: Double? = 0.15
    ) throws -> AffectedResultKind? {
        let sidecar = try writtenRecord(
            kit: kit, resolvedKit: resolvedKit, kept: kept, engine: engine, location: location,
            resolvedLocation: resolvedLocation, fivePrime: fivePrime, threePrime: threePrime, null: null, errorRate: errorRate
        )
        // The test folder is a project, whose records name project-relative paths, so the record is read as the Inspector
        // reads it, from its folder.
        return AffectedResults.kind(of: try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: sidecar.deletingLastPathComponent())))
    }

    /// The setups the ruling counts: the built-in TruSeq HT or Nextera XT v2 kit by id in `kit` or `resolvedKit`, and a
    /// definition whose `# kit:` line names one of them or IDT for Illumina UD Indexes; Both Ends, by name, resolved or by
    /// default; a 5' or 3' Distance above 0; any error rate; no engine field; any floor; and the definition moved, replaced
    /// or deleted since, since the kept copy is read first (BIO-LINKED-OFFSET item 3).
    func testARecordOfEachSetupTheRulingCountsNamesTheKind() throws {
        let linked = try linked()
        for id in ["truseq-ht-dual", "nextera-xt-v2"] {
            XCTAssertEqual(try kind(kit: id), linked, "\(id) at 3/3")
            XCTAssertEqual(try kind(kit: "/gone/\(id).csv", resolvedKit: id), linked, "\(id) in resolvedKit")
            XCTAssertEqual(try kind(kit: id, fivePrime: 8, threePrime: 0), linked, "\(id) with only a 5' Distance")
            XCTAssertEqual(try kind(kit: id, fivePrime: 0, threePrime: 1), linked, "\(id) with only a 3' Distance")
            XCTAssertEqual(try kind(kit: id, location: nil), linked, "\(id) at the default location")
            XCTAssertEqual(try kind(kit: id, location: "both", resolvedLocation: "bothEnds"), linked, "\(id) resolved")
            XCTAssertEqual(try kind(kit: id, engine: nil), linked, "\(id) in a record before --engine")
        }
        for (kitLine, rows) in [("truseq-ht-dual", truseqRows), ("nextera-xt-v2", nexteraRows), ("idt-ud-indexes", idtRows)] {
            let path = try definition(rows, name: "\(kitLine).csv", kitLine: kitLine)
            let kept = try definition(rows, name: "kept-\(kitLine).csv", kitLine: kitLine)
            XCTAssertEqual(try kind(kit: path.path, kept: kept), linked, "a definition on \(kitLine)")
            XCTAssertEqual(try kind(kit: path.path, kept: nil), linked, "\(kitLine): no kept copy reads the file it names")
            XCTAssertEqual(try kind(kit: folder.appendingPathComponent("moved.csv").path, kept: kept), linked,
                           "\(kitLine) moved since")
            let replaced = try definition(customDualRows, name: "replaced-\(kitLine).csv")
            XCTAssertEqual(try kind(kit: replaced.path, kept: kept), linked, "\(kitLine) replaced since by a custom definition")
        }
        for errorRate in [0, 0.15, nil] as [Double?] {
            XCTAssertEqual(try kind(kit: "truseq-ht-dual", errorRate: errorRate), linked, "error \(String(describing: errorRate))")
        }
        for null in [nil, "start-composition"] {
            XCTAssertEqual(try kind(kit: "nextera-xt-v2", null: null), linked, "the floor's null \(null ?? "none")")
        }
    }

    /// A result folder with its kept copy names the kind once the project is copied and the original is gone, the way a
    /// project exported and opened again holds it.
    func testACopiedResultFolderStillNamesTheKind() throws {
        let linked = try linked()
        let output = folder.appendingPathComponent("demultiplex-run", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let kept = try definition(nexteraRows, name: "plate.csv", in: output, kitLine: "nextera-xt-v2")
        _ = try writtenRecord(kit: kept.path, kept: kept, output: output)
        let copyProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-linked-offset-copy-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copyProject) }
        try FileManager.default.copyItem(at: folder, to: copyProject)
        try FileManager.default.removeItem(at: folder)
        let copied = copyProject.appendingPathComponent("demultiplex-run", isDirectory: true)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: copied))
        XCTAssertEqual(AffectedResults.kind(of: envelope), linked)
    }

    /// A record that is not such a run does not name the kind: both distances at 0 first, then 5' End and 3' End (refused
    /// for a dual kit, and a custom one names its own kind), another engine, the built-in IDT UD kit (refused before any
    /// line), single-index kits, a definition on a single-index or ONT kit, and a definition that cannot be read.
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let linked = try linked()
        let onTruSeq = try definition(truseqRows, name: "on-truseq.csv", kitLine: "truseq-ht-dual")
        for id in ["truseq-ht-dual", "nextera-xt-v2", onTruSeq.path] {
            XCTAssertEqual(try kind(kit: id, kept: id.hasPrefix("/") ? onTruSeq : nil, fivePrime: 0, threePrime: 0),
                           .fastqDemultiplex, "\(id) at 0/0")
            for (location, resolved) in [("5prime", "fivePrime"), ("3prime", "threePrime")] {
                XCTAssertEqual(try kind(kit: id, location: location, resolvedLocation: resolved), .fastqDemultiplex,
                               "\(id) at \(location)")
            }
            XCTAssertEqual(try kind(kit: id, location: "bothends", resolvedLocation: "fivePrime"), .fastqDemultiplex,
                           "\(id): the resolved location decides")
            for engine in ["header-index", "exact-bare"] {
                XCTAssertEqual(try kind(kit: id, engine: engine), .fastqDemultiplex, "\(id) \(engine)")
            }
        }
        XCTAssertEqual(try kind(kit: "idt-ud-indexes"), .fastqDemultiplex, "the built-in IDT UD kit")
        XCTAssertNotEqual(try kind(kit: "truseq-single-a", fivePrime: 3, threePrime: 0), linked, "a single-index kit")
        let onSingle = try definition(["D701,ATTACTCG", "D702,TCCGGAGA"], name: "on-single.csv", kitLine: "truseq-single-a")
        XCTAssertNotEqual(try kind(kit: onSingle.path, kept: onSingle), linked, "a definition on a single-index kit")
        let onONT = try definition(["RB01,AAGAAAGTTGTCGGTGTCTTTGTG"], name: "on-ont.csv", kitLine: "ont-rbk114-24")
        XCTAssertEqual(try kind(kit: onONT.path, kept: onONT), .fastqDemultiplex, "a definition built on a rapid kit")
        XCTAssertEqual(try kind(kit: folder.appendingPathComponent("gone.csv").path), .fastqDemultiplex, "cannot be read")
    }

    /// A dual definition with no kit line, the route of DEMUX-DUAL-OFFSET-SHIFT, does not name the kind: at Both Ends it
    /// keeps the kinds of DEMUX-DUAL-UNANCHORED and DEMUX-DUAL-FORM, and at one end the kind of DEMUX-DUAL-BARE-REVERSE,
    /// which `kind(of:)` asks first. A kit the floor could not judge keeps its kind (BIO-LINKED-OFFSET item 3).
    func testEachKindAskedBeforeItKeepsItsRecords() throws {
        let linked = try linked()
        let dual = try definition(customDualRows, name: "dual.csv")
        for (fivePrime, threePrime) in [(3, 3), (8, 0), (0, 1)] {
            let named = try kind(kit: dual.path, kept: dual, fivePrime: fivePrime, threePrime: threePrime)
            XCTAssertNotEqual(named, linked, "a dual definition with no kit line at \(fivePrime)/\(threePrime)")
            XCTAssertEqual(named, .fastqDemultiplexDualSearchedAnywhere, "\(fivePrime)/\(threePrime)")
        }
        XCTAssertEqual(try kind(kit: dual.path, kept: dual, location: "5prime", resolvedLocation: "fivePrime"),
                       .fastqDemultiplexDualOneEnd, "at 5' End")
        let colliding = try definition(["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGAA,TAACTCCT"], name: "colliding.csv")
        XCTAssertEqual(try kind(kit: colliding.path, kept: colliding),
                       try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexDualFormSwap")), "two rows that swap")
        XCTAssertEqual(try kind(kit: BarcodeKitRegistry.fluidigmAccessArray.id, location: "5prime", threePrime: 0),
                       .fastqDemultiplexSaturatedKit, "a kit the floor cannot judge")
        XCTAssertEqual(try kind(kit: "truseq-single-a", location: "5prime", threePrime: 0),
                       try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexSingleOffset")), "a single-index kit")
    }
}
