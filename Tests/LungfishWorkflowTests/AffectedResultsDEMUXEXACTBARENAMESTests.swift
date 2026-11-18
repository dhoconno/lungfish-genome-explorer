// AffectedResultsDEMUXEXACTBARENAMESTests.swift - The affected row of an Exact Bare run on barcodes that sit in the read names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-EXACTBARE-NAMES (BIO-DEMUX-THREE item 11, section 2a). Every build with Exact Bare Barcode, from
// its landing in 4389cd101 (build 2135) to 13672 (Preview 2026.11.11), searched the read sequences for barcodes that sat in the
// read names and made sample files of chance matches. `kind(of:)` reads the first names of the input the record names and
// counts the kit's barcodes in them by the route owner's rule.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class AffectedResultsDEMUXEXACTBARENAMESTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "affected-exactbare-names")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
    }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forBuilds: build...build, kind: kind).map(\.backlogID)
    }

    func testTheExactBareNamesRowHoldsEveryBuildWithTheEngine() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "DEMUX-EXACT-BARE-NO-FLOOR" })
        XCTAssertEqual(row.kinds, [.fastqDemultiplexExactBareNames])
        XCTAssertEqual(row.firstBuild, 2135, "4389cd101 brought Exact Bare Barcode in")
        XCTAssertEqual(row.lastBuild, 13672, "Preview 2026.11.11, the newest published build, lacks the fix")
        XCTAssertEqual(row.sentence, "This run searched the read sequences for barcodes that sit in the read names, so its "
                       + "sample files may hold chance matches.")
        XCTAssertEqual(row.whatToDo, "Run it again with the barcodes read from the read names.")
        let names = AffectedResultKind.fastqDemultiplexExactBareNames
        XCTAssertEqual(ids(2134, names), ["DEMUX-GROUPED-DROPS-INPUTS"], "the build before the engine")
        XCTAssertEqual(ids(2135, names), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-EXACT-BARE-NO-FLOOR"])
        XCTAssertEqual(ids(12972, names), ["DEMUX-GROUPED-DROPS-INPUTS", "DEMUX-EXACT-BARE-NO-FLOOR"], "Stable 2026.11.7")
        XCTAssertEqual(ids(13672, names), ["DEMUX-EXACT-BARE-NO-FLOOR"], "Preview 2026.11.11")
        XCTAssertEqual(ids(13673, names), [])
        for kind in AffectedResultKind.allCases where kind != names {
            XCTAssertFalse(ids(13672, kind).contains(row.backlogID), "\(kind)")
        }
    }

    // MARK: - The kind a demultiplexing record names

    private static let twelve = ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC", "ATTCAGAA", "GAATTCGT", "CTGAAGCT",
                                 "TAATGCGC", "CGGCTATG", "TCCGCGAA", "TCTCGCGC", "AGCGATAG"]

    /// 2,000 reads whose names carry the comment `comment(i)`, or no comment when it gives nil.
    private func reads(_ name: String, comment: (Int) -> String?) throws -> URL {
        let url = root.appendingPathComponent(name)
        let names = (0..<2_000).map { index in comment(index).map { "r\(index) \($0)" } ?? "r\(index)" }
        try DemuxFloorFixtures.write(names: names, seed: 17, to: url)
        return url
    }

    /// A record of `lungfish fastq demultiplex` as `FastqCommand.swift` writes it for `engine`, written by `ProvenanceWriter` and
    /// read back from the file. Records before this fix carry no `optIn`.
    private func writtenRecord(input: URL, kit: String, engine: String, optIn: Bool? = nil) throws -> ProvenanceEnvelope {
        var explicit: [String: ParameterValue] = [
            "input": .file(input), "kit": .string(kit), "resolvedKit": .string("custom-twelve"), "customBarcodeKit": .null,
            "engine": .string(engine), "indexSource": .string(engine == "header-index" ? "read-names" : "read-sequences"),
        ]
        if engine == "exact-bare" {
            explicit["searchMode"] = .string("whole-read")
            explicit["chanceCheck"] = .string("none")
            if let optIn { explicit["optIn"] = .boolean(optIn) }
        }
        let output = root.appendingPathComponent("demultiplex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = output.appendingPathComponent("manifest.json")
        try Data("{}\n".utf8).write(to: manifest)
        let now = Date()
        let built = try ProvenanceRunBuilder(
            workflowName: AffectedResults.RecordName.fastqDemultiplex, workflowVersion: "2026.11.11",
            toolName: engine == "cutadapt" ? "cutadapt" : "lungfish", toolVersion: "5.0"
        )
        .argv(["lungfish-cli", "fastq", "demultiplex", input.path, "--kit", kit, "--engine", engine])
        .runtime(ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.11 (13672)"))
        .options(explicit: explicit, defaults: ["engine": .null], resolved: [:])
        .output(manifest, role: .output)
        .complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
        let sidecar = try ProvenanceWriter().write(built, to: output)
        return try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecar))
    }

    func testAnExactBareRecordWhoseInputNamesCarryTheKitsBarcodesNamesTheNarrowerKind() throws {
        let definition = root.appendingPathComponent("Twelve.csv")
        let rows = Self.twelve.enumerated().map { "BC\(String(format: "%02d", $0.offset + 1)),\($0.element)" }
        try (["id,sequence"] + rows).joined(separator: "\n").write(to: definition, atomically: true, encoding: .utf8)
        let kit = definition.path
        let indexed = try reads("indexed.fastq") { "1:N:0:\(Self.twelve[$0 % 2])" }
        let plain = try reads("plain.fastq") { _ in nil }
        let library = try reads("library.fastq") { _ in "1:N:0:GTCAGTAC" }
        let narrower = AffectedResultKind.fastqDemultiplexExactBareNames

        let record = try writtenRecord(input: indexed, kit: kit, engine: "exact-bare")
        XCTAssertEqual(record.workflowName, AffectedResults.RecordName.fastqDemultiplex)
        XCTAssertEqual(AffectedResults.kind(of: record), narrower, "two of the kit's barcodes in the names")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: plain, kit: kit, engine: "exact-bare")),
                       .fastqDemultiplex, "names with no index")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: library, kit: kit, engine: "exact-bare")),
                       .fastqDemultiplex, "one library index")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: plain, kit: kit, engine: "exact-bare", optIn: true)),
                       .fastqDemultiplex, "the flag was given and the names carry no barcode")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: indexed, kit: kit, engine: "exact-bare", optIn: true)),
                       narrower, "a run kept by choice on names that carry the barcodes")
        for engine in ["header-index", "cutadapt"] {
            XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: indexed, kit: kit, engine: engine)),
                           .fastqDemultiplex, engine)
        }
        let gone = root.appendingPathComponent("gone.fastq")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: gone, kit: kit, engine: "exact-bare")),
                       .fastqDemultiplex, "an input that cannot be read")
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: gone, kit: kit, engine: "exact-bare", optIn: true)),
                       narrower, "the flag decides when the names cannot be read")
        let goneKit = root.appendingPathComponent("gone.csv").path
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: indexed, kit: goneKit, engine: "exact-bare")),
                       .fastqDemultiplex, "a definition that cannot be read")

        // The window records the bundle it ran on, whose primary FASTQ holds the reads.
        let bundle = root.appendingPathComponent("pool.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: indexed, to: bundle.appendingPathComponent("pool.fastq"))
        XCTAssertEqual(AffectedResults.kind(of: try writtenRecord(input: bundle, kit: kit, engine: "exact-bare")), narrower,
                       "a bundle whose reads carry the barcodes in their names")
    }
}
