// AffectedResultsDEMUX-DUAL-FORMTests.swift - The affected row of a custom dual-index file whose two rows could swap
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-FORM (ruling BIO-DUAL-FORM item 5, words UX-WORDS-2 section 4 as BIO-WORDS-CONFIRM corrects them). Every
// published build up to Preview 2026.11.12 (13764) read the secondary sequence of a custom dual-index definition at Both Ends
// with no sample sheet only as written. When the definition held two rows with first barcodes that match and secondary
// sequences that are reverse complements of each other, each within the error rate, and listed the i5 primer's barcodes,
// those two samples got each other's reads. `kind(of:)` reads the definition the run kept in its result folder, then the
// file the record names. The kind is read by its raw value, so the tests build at the base, which has no such kind.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXDUALFORMTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-dual-form-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    /// The kind of the row DEMUX-DUAL-FORM.
    private func swap() throws -> AffectedResultKind {
        try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexDualFormSwap"), "the kind of DEMUX-DUAL-FORM")
    }

    func testTheDualFormRowHoldsEveryBuildUpToTheFix() throws {
        let swap = try swap()
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-DUAL-FORM" })
        XCTAssertEqual(row.kinds, [swap])
        XCTAssertNil(row.firstBuild, "the writer of the column as written is older than any build a row names")
        XCTAssertEqual(row.lastBuild, 13764, "Preview 2026.11.12, the newest published build, lacks the fix")
        XCTAssertEqual(row.fixCommit, "95021de8b", "the choice of form, the first commit that reads the column as the reads carry it")
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.11.12", 13764)))
        XCTAssertEqual(row.sentence, "This run read the secondary sequence of each row of your Custom Definition as written, and "
                       + "two of its rows have first barcodes that match and secondary sequences that are reverse complements of "
                       + "each other, each within the error rate, so if the definition lists the i5 primer's barcodes, those two "
                       + "samples hold each other's reads.")
        XCTAssertEqual(row.whatToDo, "Run Demultiplex Barcodes again with this version, which reads the secondary sequence the "
                       + "way your reads carry it or stops and says why.")
        // The kind is a narrower `fastqDemultiplexDualSearchedAnywhere`, so a record up to 13672 keeps the sentences of the
        // rows of that kind beside this one (manager ruling on BIO-DUAL-FORM item 5, as BIO-DUAL-ANCHOR item 12).
        let all = ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-DUAL-UNANCHORED", "DEMUX-DUAL-FORM"]
        XCTAssertEqual(ids(4192, swap), all, "2026.8.1")
        XCTAssertEqual(ids(12972, swap), all, "Stable 2026.11.7")
        XCTAssertEqual(ids(13672, swap), ["DEMUX-DUAL-UNANCHORED", "DEMUX-DUAL-FORM"], "Preview 2026.11.11")
        XCTAssertEqual(ids(13764, swap), ["DEMUX-DUAL-FORM"], "Preview 2026.11.12")
        XCTAssertEqual(ids(13765, swap), [])
        for kind in AffectedResultKind.allCases where kind != swap {
            XCTAssertFalse(ids(13764, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names

    /// A definition file of `rows` under `name` in `parent`, or in the test's folder.
    private func definition(_ rows: [String], name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? folder).appendingPathComponent(name)
        try (["id,i7_sequence,i5_sequence"] + rows).joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// X and Y have the same first barcode and secondary sequences that are exact reverse complements, so they collide at
    /// any error rate. D02 collides with neither.
    private let collidingRows = ["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGAA,TAACTCCT", "D02,GAAGTTGCCG,GGATCTTCCC"]

    /// A record of a Cutadapt run of `lungfish fastq demultiplex` at Both Ends with the options `FastqCommand.swift` records
    /// for that engine, written by `ProvenanceWriter` into `output` and read back from the file. `kept` is the copy of the
    /// definition the run keeps in its result folder (`customBarcodeKit`), and `kit` the path the person named.
    private func writtenRecord(
        kit: String, kept: URL?, output: URL? = nil, engine: String? = "cutadapt", location: String = "bothends",
        resolvedLocation: String? = "bothEnds", null: String? = "random-bases", errorRate: Double? = 0.15,
        paired: Bool = false, secondaryForm: String? = nil
    ) throws -> URL {
        var explicit: [String: ParameterValue] = [
            "kit": .string(kit), "resolvedKit": .string("custom-dual"), "customBarcodeKit": kept.map(ParameterValue.file) ?? .null,
            "location": .string(location), "maxDistanceFrom5Prime": .integer(0), "maxDistanceFrom3Prime": .integer(0),
            "overlap": .integer(3),
        ]
        if let errorRate { explicit["errorRate"] = .number(errorRate) }
        if let resolvedLocation { explicit["resolvedLocation"] = .string(resolvedLocation) }
        if let engine {
            explicit["engine"] = .string(engine)
            explicit["indexSource"] = .string(engine == "header-index" ? "read-names" : "read-sequences")
        }
        if let null { explicit["chanceFloor"] = .dictionary(["null": .string(null), "kitTail": .number(0.01)]) }
        if paired {
            explicit["mateCalls"] = .dictionary([
                "pairs": .integer(40), "bothMatesAgree": .integer(40), "oneMateCalled": .integer(0),
                "matesDisagree": .integer(0), "neitherMateCalled": .integer(0), "singleReads": .integer(0),
            ])
        }
        if let secondaryForm {
            explicit["secondaryForm"] = .string(secondaryForm)
            explicit["secondaryFormVotes"] = .dictionary([
                "readsRead": .integer(80), "asWritten": .integer(0), "reverseComplemented": .integer(80),
                "disputed": .integer(0), "rowsCarrying": .integer(3),
            ])
        }
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
            defaults: ["engine": .null, "location": .string("bothends"), "errorRate": .number(0.15), "overlap": .integer(3)],
            resolved: [:]
        )
        .output(manifest, role: .output)
        .complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        return try ProvenanceWriter().write(built, to: output)
    }

    private func record(
        kit: String, kept: URL?, engine: String? = "cutadapt", location: String = "bothends",
        resolvedLocation: String? = "bothEnds", null: String? = "random-bases", errorRate: Double? = 0.15,
        paired: Bool = false, secondaryForm: String? = nil
    ) throws -> ProvenanceEnvelope {
        let sidecar = try writtenRecord(
            kit: kit, kept: kept, engine: engine, location: location, resolvedLocation: resolvedLocation, null: null,
            errorRate: errorRate, paired: paired, secondaryForm: secondaryForm
        )
        // The test folder is a project, whose records name project-relative paths, so the record is read as the Inspector
        // reads it, from its folder.
        return try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: sidecar.deletingLastPathComponent()))
    }

    /// A Cutadapt record at Both Ends of a definition that holds X and Y names the kind, single and paired, at error 0 and
    /// 0.15 and with no error rate, whatever the floor measured, with no engine field, and with the definition moved,
    /// replaced or deleted since, since the kept copy is read first (BIO-DUAL-FORM item 5).
    func testARecordOfADefinitionWithTwoCollidingRowsNamesTheKind() throws {
        let swap = try swap()
        let path = try definition(collidingRows, name: "dual.csv")
        let kept = try definition(collidingRows, name: "kept-dual.csv")
        for paired in [false, true] {
            for errorRate in [0, 0.15, nil] as [Double?] {
                let envelope = try record(kit: path.path, kept: kept, errorRate: errorRate, paired: paired)
                XCTAssertEqual(AffectedResults.kind(of: envelope), swap, "paired \(paired) error \(String(describing: errorRate))")
            }
        }
        for null in [nil, "start-composition", "saturated-kit"] {
            XCTAssertEqual(AffectedResults.kind(of: try record(kit: path.path, kept: kept, null: null)), swap,
                           "the floor's null \(null ?? "none") does not find a swap")
        }
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: path.path, kept: kept, engine: nil)), swap,
                       "a record before --engine, when Cutadapt was the one engine")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: path.path, kept: kept, location: "both", resolvedLocation: nil)),
                       swap, "Both Ends with no resolved location")
        let moved = folder.appendingPathComponent("moved.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: moved, kept: kept)), swap, "a definition moved since")
        let replaced = try definition(["D02,GAAGTTGCCG,GGATCTTCCC"], name: "replaced.csv")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: replaced.path, kept: kept)), swap,
                       "a definition replaced since by one that holds no colliding pair")
        let deleted = try definition(collidingRows, name: "deleted.csv")
        let envelope = try record(kit: deleted.path, kept: kept)
        try FileManager.default.removeItem(at: deleted)
        XCTAssertEqual(AffectedResults.kind(of: envelope), swap, "a definition deleted since")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: path.path, kept: nil)), swap,
                       "a record with no kept copy reads the file it names")
    }

    /// A result folder with its kept copy names the kind once the project is copied and the original is gone, the way a
    /// project exported and opened again holds it (BIO-DUAL-FORM item 5).
    func testACopiedResultFolderStillNamesTheKind() throws {
        let swap = try swap()
        let output = folder.appendingPathComponent("demultiplex-run", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let kept = try definition(collidingRows, name: "K.csv", in: output)
        _ = try writtenRecord(kit: kept.path, kept: kept, output: output)
        let copyProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-dual-form-copy-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copyProject) }
        try FileManager.default.copyItem(at: folder, to: copyProject)
        try FileManager.default.removeItem(at: folder)
        let copied = copyProject.appendingPathComponent("demultiplex-run", isDirectory: true)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: copied))
        XCTAssertEqual(AffectedResults.kind(of: envelope), swap)
    }

    /// A record that is not such a run names another kind: a pair one base off at error 0, a record of the fixed run that
    /// names the form it read, 5' End, another engine and a definition with no colliding pair (BIO-DUAL-FORM item 5).
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let swap = try swap()
        let anywhere = AffectedResultKind.fastqDemultiplexDualSearchedAnywhere
        // TAACTCAT is one base from TAACTCCT, the reverse complement of AGGAGTTA, so X and Y collide only at k 1.
        let oneOff = try definition(["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGAA,TAACTCAT"], name: "one-off.csv")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: oneOff.path, kept: oneOff, errorRate: 0)), anywhere, "error 0")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: oneOff.path, kept: oneOff, errorRate: 0.15)), swap,
                       "one base off at 0.15 is within the error rate")
        let firstOff = try definition(["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGTA,TAACTCCT"], name: "first-off.csv")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: firstOff.path, kept: firstOff, errorRate: 0)), anywhere,
                       "first barcodes one base apart at error 0")
        let path = try definition(collidingRows, name: "dual.csv")
        XCTAssertNotEqual(AffectedResults.kind(of: try record(kit: path.path, kept: path, secondaryForm: "reverse-complemented")),
                          swap, "the fixed run names the form it read")
        XCTAssertEqual(AffectedResults.kind(of: try record(
            kit: path.path, kept: path, location: "5prime", resolvedLocation: "fivePrime"
        )), .fastqDemultiplexDualOneEnd, "5' End")
        for engine in ["header-index", "exact-bare"] {
            XCTAssertEqual(AffectedResults.kind(of: try record(kit: path.path, kept: path, engine: engine)), .fastqDemultiplex, engine)
        }
        let apart = try definition(["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"], name: "apart.csv")
        XCTAssertEqual(AffectedResults.kind(of: try record(kit: apart.path, kept: apart)), anywhere, "no colliding pair")
    }
}
