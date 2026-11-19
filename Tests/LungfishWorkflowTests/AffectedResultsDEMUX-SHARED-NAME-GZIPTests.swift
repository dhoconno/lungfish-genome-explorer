// AffectedResultsDEMUX-SHARED-NAME-GZIPTests.swift - The affected row of a dual-kit run whose gzip outputs shared a name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-SHARED-NAME-GZIP (ruling BIO-SHARED-NAME-GZIP item 3). Every published build from 2026.8.1 (4192) up to Preview
// 2026.11.12 (13764) ran the built-in TruSeq HT Dual Index or Nextera XT Index Kit v2 kit, or a definition whose `# kit:`
// line names one of them or IDT for Illumina UD Indexes, at Both Ends with Cutadapt writing `{name}.fastq.gz`, and wrote
// each row on two lines, so each row's output past about 202 KB of gzip lost every read with no word and the counts showed
// only the reads it kept. The record carries the kit and the Cutadapt step's `-o` (`FastqCommand.swift`, `stepCommand`
// from the run's `nativeCommand`, since 2026.8.1), so `kind(of:)` names such a record by both. No record names a sample
// sheet, since the command has none. The kind is read by its raw value, so the tests build at the base.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AffectedResultsDEMUXSHAREDNAMEGZIPTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-shared-name-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    /// The kind of the row DEMUX-SHARED-NAME-GZIP.
    private func shared() throws -> AffectedResultKind {
        try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexSharedNameGzip"), "the kind of DEMUX-SHARED-NAME-GZIP")
    }

    func testTheSharedNameRowHoldsEveryPublishedBuildFromTheWriterUpToTheFix() throws {
        let shared = try shared()
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-SHARED-NAME-GZIP" })
        XCTAssertEqual(row.kinds, [shared])
        XCTAssertEqual(row.firstBuild, 4192, "2026.8.1, the first published build an affected row names")
        XCTAssertEqual(row.lastBuild, 13764, "Preview 2026.11.12, the newest published build, lacks the fix")
        XCTAssertEqual(row.fixCommit, "4f90ac633", "plain Cutadapt outputs when an adapter name repeats")
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.8.1", 4192)))
        XCTAssertTrue(AffectedResults.publishedReleases.contains(.init("2026.11.12", 13764)))
        XCTAssertEqual(row.sentence, "This run searched for pairs of barcodes, and the build that ran it could leave out all "
                       + "the reads of a sample without a warning and count only the reads it kept.")
        XCTAssertEqual(row.whatToDo, "Run it again in this version.")
        // The kind is a narrower `fastqDemultiplex`, so a record up to Stable 2026.11.7 keeps the sentence of
        // DEMUX-GROUPED-DROPS-INPUTS beside this one.
        XCTAssertEqual(ids(4191, shared), ["DEMUX-GROUPED-DROPS-INPUTS"], "a build before 2026.8.1")
        XCTAssertEqual(ids(4192, shared), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-SHARED-NAME-GZIP"], "2026.8.1")
        XCTAssertEqual(ids(12972, shared), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-SHARED-NAME-GZIP"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13764, shared), ["DEMUX-SHARED-NAME-GZIP"], "Preview 2026.11.12")
        XCTAssertEqual(ids(13765, shared), [])
        for kind in AffectedResultKind.allCases where kind != shared {
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
    /// engine and its Cutadapt step, whose `-o` names `outputName` in the run's work folder, or no step when it is nil,
    /// written by `ProvenanceWriter` into `output` and read back from the file. `kept` is the copy of the definition the
    /// run keeps in its result folder (`customBarcodeKit`), and `kit` the id or path the person named.
    private func writtenRecord(
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, output: URL? = nil, engine: String? = "cutadapt",
        location: String? = "bothends", resolvedLocation: String? = nil, fivePrime: Int = 0, threePrime: Int = 0,
        outputName: String? = "{name}.fastq.gz", null: String? = "random-bases", errorRate: Double? = 0.15
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
        let work = folder.appendingPathComponent(".tmp/lungfish-demux-1", isDirectory: true)
        let now = Date()
        var builder = try ProvenanceRunBuilder(
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
        if let outputName {
            let demux = work.appendingPathComponent("demux-output", isDirectory: true)
            let unassigned = outputName.hasSuffix(".gz") ? "unassigned.fastq.gz" : "unassigned.fastq"
            builder = builder.step(ProvenanceStep(toolName: "cutadapt", toolVersion: "5.2", argv: [
                "-g", "file:\(work.appendingPathComponent("adapters.fasta").path)", "-e", "0.15", "--overlap", "3",
                "--action", "trim", "-o", demux.appendingPathComponent(outputName).path,
                "--untrimmed-output", demux.appendingPathComponent(unassigned).path,
                "--json", work.appendingPathComponent("cutadapt-report.json").path, "--cores", "4", "reads.fastq",
            ], exitStatus: 0))
        }
        let built = try builder.complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        return try ProvenanceWriter().write(built, to: output)
    }

    private func kind(
        kit: String, resolvedKit: String? = nil, kept: URL? = nil, engine: String? = "cutadapt",
        location: String? = "bothends", resolvedLocation: String? = nil, fivePrime: Int = 0, threePrime: Int = 0,
        outputName: String? = "{name}.fastq.gz", null: String? = "random-bases", errorRate: Double? = 0.15
    ) throws -> AffectedResultKind? {
        let sidecar = try writtenRecord(
            kit: kit, resolvedKit: resolvedKit, kept: kept, engine: engine, location: location,
            resolvedLocation: resolvedLocation, fivePrime: fivePrime, threePrime: threePrime, outputName: outputName,
            null: null, errorRate: errorRate
        )
        // The test folder is a project, whose records name project-relative paths, so the record is read as the Inspector
        // reads it, from its folder.
        return AffectedResults.kind(of: try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: sidecar.deletingLastPathComponent())))
    }

    /// The setups the ruling counts: the built-in TruSeq HT or Nextera XT v2 kit by id in `kit` or `resolvedKit`, and a
    /// definition whose `# kit:` line names one of them or IDT for Illumina UD Indexes; Both Ends, by name, resolved or by
    /// default; Cutadapt's `-o` naming `{name}.fastq.gz`; both distances 0, the command's defaults; any error rate; no
    /// engine field; any floor; and the definition moved, replaced or deleted since, since the kept copy is read first.
    func testARecordOfEachSetupTheRulingCountsNamesTheKind() throws {
        let shared = try shared()
        for id in ["truseq-ht-dual", "nextera-xt-v2"] {
            XCTAssertEqual(try kind(kit: id), shared, "\(id) at 0/0")
            XCTAssertEqual(try kind(kit: "/gone/\(id).csv", resolvedKit: id), shared, "\(id) in resolvedKit")
            XCTAssertEqual(try kind(kit: id, location: nil), shared, "\(id) at the default location")
            XCTAssertEqual(try kind(kit: id, location: "both", resolvedLocation: "bothEnds"), shared, "\(id) resolved")
            XCTAssertEqual(try kind(kit: id, engine: nil), shared, "\(id) in a record before --engine")
        }
        for (kitLine, rows) in [("truseq-ht-dual", truseqRows), ("nextera-xt-v2", nexteraRows), ("idt-ud-indexes", idtRows)] {
            let path = try definition(rows, name: "\(kitLine).csv", kitLine: kitLine)
            let kept = try definition(rows, name: "kept-\(kitLine).csv", kitLine: kitLine)
            XCTAssertEqual(try kind(kit: path.path, kept: kept), shared, "a definition on \(kitLine)")
            XCTAssertEqual(try kind(kit: path.path, kept: nil), shared, "\(kitLine): no kept copy reads the file it names")
            XCTAssertEqual(try kind(kit: folder.appendingPathComponent("moved.csv").path, kept: kept), shared,
                           "\(kitLine) moved since")
            let replaced = try definition(customDualRows, name: "replaced-\(kitLine).csv")
            XCTAssertEqual(try kind(kit: replaced.path, kept: kept), shared, "\(kitLine) replaced since by a custom definition")
        }
        for errorRate in [0, 0.15, nil] as [Double?] {
            XCTAssertEqual(try kind(kit: "truseq-ht-dual", errorRate: errorRate), shared, "error \(String(describing: errorRate))")
        }
        for null in [nil, "start-composition"] {
            XCTAssertEqual(try kind(kit: "nextera-xt-v2", null: null), shared, "the floor's null \(null ?? "none")")
        }
    }

    /// A result folder with its kept copy names the kind once the project is copied and the original is gone, the way a
    /// project exported and opened again holds it.
    func testACopiedResultFolderStillNamesTheKind() throws {
        let shared = try shared()
        let output = folder.appendingPathComponent("demultiplex-run", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let kept = try definition(nexteraRows, name: "plate.csv", in: output, kitLine: "nextera-xt-v2")
        _ = try writtenRecord(kit: kept.path, kept: kept, output: output)
        let copyProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-shared-name-copy-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: copyProject) }
        try FileManager.default.copyItem(at: folder, to: copyProject)
        try FileManager.default.removeItem(at: folder)
        let copied = copyProject.appendingPathComponent("demultiplex-run", isDirectory: true)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: copied))
        XCTAssertEqual(AffectedResults.kind(of: envelope), shared)
    }

    /// A record that is not such a run does not name the kind: a run of this version first, whose Cutadapt wrote
    /// `{name}.fastq`, then a record with no Cutadapt `-o`, 5' End and 3' End (refused for a dual kit), another engine,
    /// the built-in IDT UD kit (refused before any line), a single-index kit, whose names are each on one line at 0, a
    /// definition on a single-index or ONT kit, and a definition that cannot be read.
    func testOtherDemultiplexRecordsDoNotNameTheKind() throws {
        let shared = try shared()
        let onTruSeq = try definition(truseqRows, name: "on-truseq.csv", kitLine: "truseq-ht-dual")
        for id in ["truseq-ht-dual", "nextera-xt-v2", onTruSeq.path] {
            let kept = id.hasPrefix("/") ? onTruSeq : nil
            XCTAssertEqual(try kind(kit: id, kept: kept, outputName: "{name}.fastq"), .fastqDemultiplex,
                           "\(id): Cutadapt wrote plain outputs")
            XCTAssertEqual(try kind(kit: id, kept: kept, outputName: nil), .fastqDemultiplex, "\(id): no Cutadapt -o")
            for (location, resolved) in [("5prime", "fivePrime"), ("3prime", "threePrime")] {
                XCTAssertEqual(try kind(kit: id, kept: kept, location: location, resolvedLocation: resolved),
                               .fastqDemultiplex, "\(id) at \(location)")
            }
            XCTAssertEqual(try kind(kit: id, kept: kept, location: "bothends", resolvedLocation: "fivePrime"),
                           .fastqDemultiplex, "\(id): the resolved location decides")
            for engine in ["header-index", "exact-bare"] {
                XCTAssertEqual(try kind(kit: id, kept: kept, engine: engine), .fastqDemultiplex, "\(id) \(engine)")
            }
        }
        XCTAssertEqual(try kind(kit: "idt-ud-indexes"), .fastqDemultiplex, "the built-in IDT UD kit")
        XCTAssertEqual(try kind(kit: "truseq-single-a", location: "5prime"), .fastqDemultiplex, "a single-index kit at 0")
        let onSingle = try definition(["D701,ATTACTCG", "D702,TCCGGAGA"], name: "on-single.csv", kitLine: "truseq-single-a")
        XCTAssertNotEqual(try kind(kit: onSingle.path, kept: onSingle), shared, "a definition on a single-index kit")
        let onONT = try definition(["RB01,AAGAAAGTTGTCGGTGTCTTTGTG"], name: "on-ont.csv", kitLine: "ont-rbk114-24")
        XCTAssertEqual(try kind(kit: onONT.path, kept: onONT), .fastqDemultiplex, "a definition built on a rapid kit")
        XCTAssertEqual(try kind(kit: folder.appendingPathComponent("gone.csv").path), .fastqDemultiplex, "cannot be read")
    }

    /// A built-in dual kit at a distance names the kind of DEMUX-LINKED-OFFSET-SHIFT, whose sentence now says a sample's
    /// reads could be left out, and a dual definition with no kit line keeps the kinds of DEMUX-DUAL-UNANCHORED,
    /// DEMUX-DUAL-FORM and DEMUX-DUAL-BARE-REVERSE, which `kind(of:)` asks first (BIO-SHARED-NAME-GZIP item 3).
    func testEachKindAskedBeforeItKeepsItsRecords() throws {
        let shared = try shared()
        let linked = try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexBuiltInDualOffset"))
        for (fivePrime, threePrime) in [(3, 3), (8, 0), (0, 1)] {
            XCTAssertEqual(try kind(kit: "nextera-xt-v2", fivePrime: fivePrime, threePrime: threePrime), linked,
                           "a built-in dual kit at \(fivePrime)/\(threePrime)")
        }
        let dual = try definition(customDualRows, name: "dual.csv")
        let named = try kind(kit: dual.path, kept: dual)
        XCTAssertNotEqual(named, shared, "a dual definition with no kit line")
        XCTAssertEqual(named, .fastqDemultiplexDualSearchedAnywhere)
        XCTAssertEqual(try kind(kit: dual.path, kept: dual, location: "5prime", resolvedLocation: "fivePrime"),
                       .fastqDemultiplexDualOneEnd, "at 5' End")
        let colliding = try definition(["X,TGGGCGAA,AGGAGTTA", "Y,TGGGCGAA,TAACTCCT"], name: "colliding.csv")
        XCTAssertEqual(try kind(kit: colliding.path, kept: colliding),
                       try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexDualFormSwap")), "two rows that swap")
        XCTAssertEqual(try kind(kit: "truseq-single-a", location: "5prime", fivePrime: 8),
                       try XCTUnwrap(AffectedResultKind(rawValue: "fastqDemultiplexSingleOffset")), "a single-index kit")
    }
}
