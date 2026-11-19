// AffectedResultsDEMUX-SINGLE-OFFSET-SHIFTTests.swift - The affected row of a single-index run that searched barcodes set in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-SINGLE-OFFSET-SHIFT (ruling BIO-SINGLE-OFFSET item 3, lane-shared-4 AFFECTED). Every published build from
// 2026.8.1 (4192), the first that holds the writer fe644e767, up to Preview 2026.11.12 (13764) searched a single-index kit
// with a 5' or 3' Distance above 0 with lines that rank a line further in above the right row's line by its N's, so some
// reads landed in another sample with no word. `kind(of:)` names a record of such a run: the built-in TruSeq Single Index
// Set A or B, or a definition that loads one sequence a row on a platform that reads one strand, the kept copy first, with
// the distance of the searched end above 0. The kind is read by its raw value, so the tests build at the base.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXSINGLEOFFSETSHIFTTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-single-offset-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    /// The kind of the row DEMUX-SINGLE-OFFSET-SHIFT.
    private func single() throws -> AffectedResultKind {
        try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexSingleOffset"), "the kind of DEMUX-SINGLE-OFFSET-SHIFT")
    }

    func testTheSingleOffsetRowHoldsEveryPublishedBuildFromTheWriterUpToTheFix() throws {
        let single = try single()
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-SINGLE-OFFSET-SHIFT" })
        XCTAssertEqual(row.kinds, [single])
        XCTAssertEqual(row.firstBuild, 4192, "2026.8.1, the first published build that holds the writer fe644e767")
        XCTAssertEqual(row.lastBuild, 13764, "Preview 2026.11.12, the newest published build, lacks the fix")
        XCTAssertEqual(row.fixCommit, "1a29a8dc0", "the check of placed reads on this route")
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.8.1", 4192)))
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.11.12", 13764)))
        XCTAssertEqual(row.sentence, "This run searched for single barcodes set in from the read end, and the build that ran "
                       + "it could place some reads in another sample.")
        XCTAssertEqual(row.whatToDo, "Run it again in this version.")
        // The kind is a narrower `fastqDemultiplex`, so a record up to Stable 2026.11.7 keeps the sentence of
        // DEMUX-GROUPED-DROPS-INPUTS beside this one.
        XCTAssertEqual(ids(4191, single), ["DEMUX-GROUPED-DROPS-INPUTS"], "a build before 2026.8.1")
        XCTAssertEqual(ids(4192, single), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-SINGLE-OFFSET-SHIFT"], "2026.8.1")
        XCTAssertEqual(ids(12972, single), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-SINGLE-OFFSET-SHIFT"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13764, single), ["DEMUX-SINGLE-OFFSET-SHIFT"], "Preview 2026.11.12")
        XCTAssertEqual(ids(13765, single), [])
        for kind in AffectedResultKind.allCases where kind != single {
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

    private let singleRows = ["A01,TGGGCGAA", "A02,AGTGGGCG", "A03,GAAGTTGC"]

    /// A record of a Cutadapt run of `lungfish fastq demultiplex` with the options `FastqCommand.swift` records for that
    /// engine, written by `ProvenanceWriter` into `output` and read back from the file. `kept` is the copy of the
    /// definition the run keeps in its result folder (`customBarcodeKit`), and `kit` the id or path the person named.
    private func writtenRecord(
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, output: URL? = nil, engine: String? = "cutadapt",
        location: String? = "5prime", resolvedLocation: String? = nil, fivePrime: Int = 3, threePrime: Int = 0,
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
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, engine: String? = "cutadapt", location: String? = "5prime",
        resolvedLocation: String? = nil, fivePrime: Int = 3, threePrime: Int = 0, null: String? = "random-bases",
        errorRate: Double? = 0.15
    ) throws -> AffectedResultKind? {
        let sidecar = try writtenRecord(
            kit: kit, resolvedKit: resolvedKit, kept: kept, engine: engine, location: location,
            resolvedLocation: resolvedLocation, fivePrime: fivePrime, threePrime: threePrime, null: null, errorRate: errorRate
        )
        // The test folder is a project, whose records name project-relative paths, so the record is read as the Inspector
        // reads it, from its folder.
        return AffectedResults.kind(of: try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: sidecar.deletingLastPathComponent())))
    }

    /// The setups the ruling counts: TruSeq Single Index Set A or B by id in `kit` or `resolvedKit`, and a definition of one
    /// sequence a row with no `# kit:` line or one that names a TruSeq single kit; 5' End and Both Ends with the 5' Distance
    /// above 0, Both Ends by default, and 3' End with the 3' Distance above 0; any error rate; no engine field; any floor;
    /// and the definition moved, replaced or deleted since, since the kept copy is read first (BIO-SINGLE-OFFSET item 3).
    func testARecordOfEachSetupTheRulingCountsNamesTheKind() throws {
        let single = try single()
        for id in ["truseq-single-a", "truseq-single-b"] {
            XCTAssertEqual(try kind(kit: id), single, "\(id) at 5' End")
            XCTAssertEqual(try kind(kit: "/gone/\(id).csv", resolvedKit: id), single, "\(id) in resolvedKit")
            XCTAssertEqual(try kind(kit: id, location: "bothends", fivePrime: 8), single, "\(id) at Both Ends")
            XCTAssertEqual(try kind(kit: id, location: nil, fivePrime: 1), single, "\(id) at the default location")
            XCTAssertEqual(try kind(kit: id, location: "3prime", fivePrime: 0, threePrime: 3), single, "\(id) at 3' End")
            XCTAssertEqual(try kind(kit: id, location: "5prime", resolvedLocation: "fivePrime"), single, "\(id) resolved")
        }
        let path = try definition(singleRows, name: "single.csv")
        let kept = try definition(singleRows, name: "kept-single.csv")
        for errorRate in [0, 0.15, nil] as [Double?] {
            XCTAssertEqual(try kind(kit: path.path, kept: kept, errorRate: errorRate), single, "error \(String(describing: errorRate))")
        }
        for null in [nil, "start-composition"] {
            XCTAssertEqual(try kind(kit: path.path, kept: kept, null: null), single, "the floor's null \(null ?? "none")")
        }
        XCTAssertEqual(try kind(kit: path.path, kept: kept, engine: nil), single, "a record before --engine")
        XCTAssertEqual(try kind(kit: path.path, kept: kept, location: "3prime", fivePrime: 0, threePrime: 2), single, "3' End")
        XCTAssertEqual(try kind(kit: path.path, kept: kept, location: "bothends", fivePrime: 3, threePrime: 3), single,
                       "Both Ends searches the 5' offsets")
        XCTAssertEqual(try kind(kit: folder.appendingPathComponent("moved.csv").path, kept: kept), single, "moved since")
        let dual = try definition(["D01,TGGGCGAA,AGGAGTTA"], name: "replaced.csv")
        XCTAssertEqual(try kind(kit: dual.path, kept: kept), single, "replaced since by a dual definition")
        XCTAssertEqual(try kind(kit: path.path, kept: nil), single, "a record with no kept copy reads the file it names")
        let onTruSeq = try definition(["D701,ATTACTCG", "D702,TCCGGAGA"], name: "on-truseq.csv", kitLine: "truseq-single-a")
        XCTAssertEqual(try kind(kit: onTruSeq.path, kept: onTruSeq), single, "a definition built on TruSeq Set A")
    }

    /// A result folder with its kept copy names the kind once the project is copied and the original is gone, the way a
    /// project exported and opened again holds it.
    func testACopiedResultFolderStillNamesTheKind() throws {
        let single = try single()
        let output = folder.appendingPathComponent("demultiplex-run", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let kept = try definition(singleRows, name: "K.csv", in: output)
        _ = try writtenRecord(kit: kept.path, kept: kept, output: output)
        let copyProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-single-offset-copy-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copyProject) }
        try FileManager.default.copyItem(at: folder, to: copyProject)
        try FileManager.default.removeItem(at: folder)
        let copied = copyProject.appendingPathComponent("demultiplex-run", isDirectory: true)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: copied))
        XCTAssertEqual(AffectedResults.kind(of: envelope), single)
    }

    /// A record that is not such a run names another kind: the searched distance at 0 first (both at 0, 5' End or Both
    /// Ends with only the 3' Distance, 3' End with only the 5' Distance), another engine, a built-in kit that reads both
    /// strands or is dual, a definition built on a kit that reads both strands, and a definition that cannot be read.
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let path = try definition(singleRows, name: "single.csv")
        for id in ["truseq-single-a", path.path] {
            XCTAssertEqual(try kind(kit: id, fivePrime: 0), .fastqDemultiplex, "\(id) at 0/0")
            XCTAssertEqual(try kind(kit: id, fivePrime: 0, threePrime: 3), .fastqDemultiplex, "\(id) 5' End with a 3' Distance")
            XCTAssertEqual(try kind(kit: id, location: "bothends", fivePrime: 0, threePrime: 3), .fastqDemultiplex,
                           "\(id) Both Ends with a 3' Distance")
            XCTAssertEqual(try kind(kit: id, location: "3prime", fivePrime: 3, threePrime: 0), .fastqDemultiplex,
                           "\(id) 3' End with a 5' Distance")
            XCTAssertEqual(try kind(kit: id, location: "5prime", resolvedLocation: "threePrime"), .fastqDemultiplex,
                           "\(id): the resolved location decides")
            for engine in ["header-index", "exact-bare"] {
                XCTAssertEqual(try kind(kit: id, engine: engine), .fastqDemultiplex, "\(id) \(engine)")
            }
        }
        for id in ["ont-nbd114-96", "ont-rbk114-24", "m13-universal-primers"] {
            XCTAssertEqual(try kind(kit: id, location: "bothends", fivePrime: 3, threePrime: 3), .fastqDemultiplex, id)
        }
        // The built-in dual kits are another lane's (DEMUX-LINKED-OFFSET-SHIFT), so only this kind is pinned away.
        for id in ["truseq-ht-dual", "nextera-xt-v2"] {
            XCTAssertNotEqual(try kind(kit: id, location: "bothends", fivePrime: 3, threePrime: 3), try single(), id)
        }
        let onONT = try definition(["RB01,AAGAAAGTTGTCGGTGTCTTTGTG"], name: "on-ont.csv", kitLine: "ont-rbk114-24")
        XCTAssertEqual(try kind(kit: onONT.path, kept: onONT), .fastqDemultiplex, "a definition built on a rapid kit")
        XCTAssertEqual(try kind(kit: folder.appendingPathComponent("gone.csv").path), .fastqDemultiplex, "cannot be read")
    }

    /// Each kind `kind(of:)` asks before this one keeps its records: a run the floor could not judge names the
    /// saturated-kit kind, and a custom dual definition names its own kinds (BIO-SINGLE-OFFSET item 3).
    func testEachKindAskedBeforeItKeepsItsRecords() throws {
        XCTAssertEqual(try kind(kit: "truseq-single-a", null: "saturated-kit"), .fastqDemultiplexSaturatedKit, "the floor said so")
        // 100 four-base barcodes at two 5' offsets hold half of all reads or more by chance (DemultiplexSaturatedKitTests).
        let bases = ["A", "C", "G", "T"]
        let fours = bases.flatMap { a in bases.flatMap { b in bases.flatMap { c in bases.map { a + b + c + $0 } } } }
        let hundred = try definition(fours.prefix(100).enumerated().map { "B\($0.offset),\($0.element)" }, name: "hundred.csv")
        XCTAssertEqual(try kind(kit: hundred.path, kept: hundred, fivePrime: 1, null: nil), .fastqDemultiplexSaturatedKit,
                       "a kit the floor cannot judge at a distance above 0")
        let dual = try definition(["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"], name: "dual.csv")
        XCTAssertEqual(try kind(kit: dual.path, kept: dual, location: "bothends", fivePrime: 3, threePrime: 3),
                       .fastqDemultiplexDualSearchedAnywhere, "a custom dual definition at Both Ends")
        XCTAssertEqual(try kind(kit: dual.path, kept: dual, location: "5prime"), .fastqDemultiplexDualOneEnd, "at 5' End")
        let colliding = try definition(["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGAA,TAACTCCT"], name: "colliding.csv")
        XCTAssertEqual(try kind(kit: colliding.path, kept: colliding, location: "bothends", fivePrime: 3, threePrime: 3),
                       try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexDualFormSwap")), "two rows that swap")
    }
}
