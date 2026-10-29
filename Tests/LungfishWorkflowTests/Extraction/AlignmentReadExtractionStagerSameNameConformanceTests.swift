// AlignmentReadExtractionStagerSameNameConformanceTests.swift - The viewer's region extraction writes each record of one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane FASTQ-SAME-NAME-2, finding F2 of the review of lane FASTQ-SAME-NAME (reviews/FASTQ-SAME-NAME.md) and
// ruling R1 of the IDPINS review (reviews/IDPINS.md). `samtools fastq` writes one record for consecutive records of one
// name when neither carries READ1 or READ2, so the two mates of an SRA-named read that were mapped as single reads came
// out of the alignment viewer's Extract Reads from a region as one record while the count the row shows is
// `samtools view -c`. Tiny BAMs are built from SAM text with the managed samtools, indexed, and run through
// `AlignmentReadExtractionStager.stageRegion`, the stager behind the viewer's region extraction and
// `lungfish-cli extract reads` with a region:
//
// - A region that holds both records of one name (flags 0 and 16), a proper pair and another read writes five records,
//   the number `samtools view -c` gives for the region, with the reverse record restored and no `/1` or `/2`.
// - A region of records with a mate flag only is written byte for byte as the old route wrote it: `samtools fastq` over
//   the region's BAM into the four sidecars, joined as READ_OTHER, singletons, READ1, READ2.
// - Each step of the split is recorded with its inputs and outputs, as the stager records its own steps.
//
// It runs the managed samtools, so its name holds Conformance and it skips without it unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class AlignmentReadExtractionStagerSameNameConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "stager-same-name")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    private static let region = "ref:50-500"

    /// Both records of `s1` carry neither mate flag, a pair `p1` carries both, and `s2` stands alone. `far` lies outside
    /// the region.
    private static let mixedRecords = [
        record("s1", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
        record("s1", 16, pos: 120, seq: "TTCCCCAAAA", qual: "9876543210"),
        record("p1", 99, pos: 150, seq: "CCCCGGGGTT", qual: "0000011111", mate: 300),
        record("p1", 147, pos: 300, seq: "GGGGAAAACC", qual: "1111122222", mate: 150),
        record("s2", 0, pos: 400, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        record("far", 0, pos: 800, seq: "CCCCGGGGTT", qual: "0000011111"),
    ]

    // MARK: - Cases

    /// The written file holds one record for each record `samtools view -c` counts in the region. The unflagged records
    /// come first in the BAM's order, then the pair, mate 1 before mate 2, the reverse records restored.
    func testRegionWithTwoUnflaggedRecordsOfOneNameWritesBothAndTheWrittenCountMatchesSamtools() async throws {
        try await Self.requireSamtools()
        let (bam, index) = try await makeIndexedBAM("same-name", records: Self.mixedRecords)
        let transaction = try await stage(bam: bam, index: index)
        defer { transaction.cleanup() }

        let counted = try await samtoolsCount(bam: bam, index: index)
        XCTAssertEqual(counted, 5, "samtools view -c of the region counts five records")
        let text = try String(contentsOf: transaction.stagedFiles[0].stagedURL, encoding: .utf8)
        XCTAssertEqual(
            text.split(separator: "\n").count / 4, counted,
            "the FASTQ holds a record for each of the \(counted) records samtools view -c counts, and the row shows that count"
        )
        XCTAssertEqual(transaction.readCount, counted, "the count the row shows")
        XCTAssertEqual(
            text,
            "@s1\nAAAACCCCGG\n+\nABCDEFGHIJ\n@s1\nTTTTGGGGAA\n+\n0123456789\n@s2\nACGTACGTAC\n+\nIIIIIIIIII\n"
                + "@p1\nCCCCGGGGTT\n+\n0000011111\n@p1\nGGTTTTCCCC\n+\n2222211111\n",
            "both records of s1 are written, the reverse one restored, and the pair p1 as before"
        )
    }

    /// Records with READ1 or READ2 keep their bytes: the region's FASTQ equals what `samtools fastq` wrote over the
    /// region's BAM, a pair with its mates side by side, a mate alone (a singleton) and a record with both flags.
    func testRegionOfRecordsWithAMateFlagIsWrittenByteForByteAsSamtoolsFastqWroteIt() async throws {
        try await Self.requireSamtools()
        let (bam, index) = try await makeIndexedBAM("flagged", records: [
            Self.record("p1", 99, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ", mate: 110),
            Self.record("p1", 147, pos: 110, seq: "TTCCCCAAAA", qual: "9876543210", mate: 100),
            Self.record("m1", 73, pos: 200, seq: "CCCCGGGGTT", qual: "0000011111", mate: 200),
            Self.record("o1", 193, pos: 250, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        ])
        let before = try await legacyRegionText(bam: bam, index: index)
        XCTAssertEqual(before.split(separator: "\n").count / 4, 4, "the old route writes the four records of the region")

        let transaction = try await stage(bam: bam, index: index)
        defer { transaction.cleanup() }
        let text = try String(contentsOf: transaction.stagedFiles[0].stagedURL, encoding: .utf8)
        XCTAssertEqual(text, before, "a region of records with a mate flag is not byte for byte the old route")
    }

    /// The selection of the records with a mate flag, `samtools fastq` over it, the selection of the others as SAM text and
    /// the write of the FASTQ are each a record with an exit status and inputs and outputs that carry checksums.
    func testEachStepOfTheSplitIsRecordedWithItsInputsAndOutputs() async throws {
        try await Self.requireSamtools()
        let (bam, index) = try await makeIndexedBAM("records", records: Self.mixedRecords)
        let transaction = try await stage(bam: bam, index: index)
        defer { transaction.cleanup() }

        let steps = transaction.executionRecords
        let flagged = try XCTUnwrap(steps.first { $0.argv.contains("--rf") }, "no record of the records with a mate flag")
        let unflagged = try XCTUnwrap(steps.first { $0.argv.contains("SAM") }, "no record of the records with no mate flag")
        let fastq = try XCTUnwrap(steps.first { $0.argv.contains("fastq") }, "no record of samtools fastq")
        let write = try XCTUnwrap(steps.last { $0.toolName == "lungfish alignment FASTQ merge" }, "no record of the FASTQ write")
        for step in [flagged, unflagged, fastq, write] {
            XCTAssertEqual(step.exitStatus, 0, "\(step.toolName) \(step.argv.joined(separator: " "))")
            XCTAssertFalse(step.outputs.isEmpty, "\(step.toolName) records its outputs")
            XCTAssertTrue(step.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        }
        XCTAssertEqual(
            fastq.inputs.map(\.path), flagged.outputs.map(\.path),
            "samtools fastq reads the BAM of the records with a mate flag, not the whole selection"
        )
        XCTAssertTrue(
            write.inputs.map(\.path).contains(unflagged.outputs[0].path),
            "the FASTQ write reads the SAM text of the records with no mate flag"
        )
    }

    // MARK: - By-ID staging (`stageReadIDsFromBAM`)

    // The by-name staging from the alignment evidence, the fallback of the selected-reads extraction and the CLI's
    // `extract reads` with names from a BAM, collated the selection and ran `samtools fastq` or `fasta` over all of it, so
    // two records of one name with neither mate flag came out as one. The cases are those above with the names asked for.
    // Pairs come first, as `samtools` wrote them, then the unflagged records in the BAM's order.

    /// Names `s1`, `p1` and `s2` hold five records. Both records of `s1` are written, the count the row shows is the
    /// number `samtools view -c -N` gives for the names, and the pair is the record text the old route wrote.
    func testByIDStageWithTwoUnflaggedRecordsOfOneNameWritesBothAndTheCountMatchesTheNamesAsked() async throws {
        try await assertByIDStageKeepsEveryRecord(format: .fastq)
    }

    func testByIDStageAsFASTAWithTwoUnflaggedRecordsOfOneNameWritesBoth() async throws {
        try await assertByIDStageKeepsEveryRecord(format: .fasta)
    }

    /// Records with READ1 or READ2 keep their bytes: two pairs' worth of such records (a pair, a mate alone and a record
    /// with both flags) come out of the stager as they came out of `samtools view -N`, `collate` and `fastq`, the output
    /// file and the singletons file each.
    func testByIDStageOfRecordsWithAMateFlagIsWrittenByteForByteAsSamtoolsWroteIt() async throws {
        try await Self.requireSamtools()
        let (bam, _) = try await makeIndexedBAM("by-id-flagged", records: [
            Self.record("p1", 99, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ", mate: 110),
            Self.record("p1", 147, pos: 110, seq: "TTCCCCAAAA", qual: "9876543210", mate: 100),
            Self.record("m1", 73, pos: 200, seq: "CCCCGGGGTT", qual: "0000011111", mate: 200),
            Self.record("o1", 193, pos: 250, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        ])
        let ids: Set<String> = ["p1", "m1", "o1"]
        let before = try await legacyByID(bam: bam, ids: ids, format: .fastq)
        XCTAssertEqual(
            Self.records(before.output, lines: 4).count + Self.records(before.singletons, lines: 4).count, 4,
            "the old route writes the four records"
        )

        let transaction = try await stageByID(bam: bam, ids: ids, format: .fastq)
        defer { transaction.cleanup() }
        let texts = try transaction.stagedFiles.filter { $0.stagedURL.pathExtension == "fastq" }
            .map { try String(contentsOf: $0.stagedURL, encoding: .utf8) }
        XCTAssertEqual(
            texts, [before.output, before.singletons].filter { !$0.isEmpty },
            "records with a mate flag are not byte for byte the old route"
        )
    }

    /// The selection is split by mate flag in two recorded steps, `samtools collate` reads the BAM of the records with a
    /// mate flag only, and the payload step lists the SAM text of the others among its inputs.
    func testByIDStageRecordsTheSplitAndCollatesOnlyTheRecordsWithAMateFlag() async throws {
        try await Self.requireSamtools()
        let (bam, _) = try await makeIndexedBAM("by-id-steps", records: Self.mixedRecords)
        let transaction = try await stageByID(bam: bam, ids: ["s1", "p1", "s2"], format: .fastq)
        defer { transaction.cleanup() }

        let steps = transaction.executionRecords
        let flagged = try XCTUnwrap(steps.first { $0.argv.contains("--rf") }, "no record of the records with a mate flag")
        let unflagged = try XCTUnwrap(steps.first { $0.argv.contains("SAM") }, "no record of the records with no mate flag")
        let collate = try XCTUnwrap(steps.first { $0.argv.contains("collate") }, "no record of samtools collate")
        let payload = try XCTUnwrap(
            steps.last { $0.toolName == "lungfish alignment extraction payload finalizer" }, "no record of the payload step"
        )
        for step in [flagged, unflagged, collate] {
            XCTAssertEqual(step.exitStatus, 0, "\(step.toolName) \(step.argv.joined(separator: " "))")
            XCTAssertTrue(step.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        }
        XCTAssertEqual(
            collate.inputs.map(\.path), flagged.outputs.map(\.path),
            "samtools collate reads the BAM of the records with a mate flag, not the whole selection"
        )
        XCTAssertTrue(
            payload.inputs.map(\.path).contains(unflagged.outputs[0].path),
            "the payload step lists the SAM text of the records with no mate flag"
        )
    }

    /// The common SRA case: no record of the names asked for carries a mate flag, so the BAM of the records with a mate flag
    /// is empty and every record is written by the unflagged route, in the BAM's order, the reverse one restored.
    func testByIDStageOfRecordsWithNoMateFlagWritesEachOfThem() async throws {
        try await Self.requireSamtools()
        let (bam, _) = try await makeIndexedBAM("by-id-unflagged", records: Self.mixedRecords)
        let ids: Set<String> = ["s1", "s2"]
        let transaction = try await stageByID(bam: bam, ids: ids, format: .fastq)
        defer { transaction.cleanup() }

        let counted = try await samtoolsCountByName(bam: bam, ids: ids)
        XCTAssertEqual(counted, 3, "samtools view -c -N counts three records for the two names")
        XCTAssertEqual(transaction.readCount, counted, "the count the row shows")
        let text = try String(contentsOf: transaction.stagedFiles[0].stagedURL, encoding: .utf8)
        XCTAssertEqual(
            text,
            "@s1\nAAAACCCCGG\n+\nABCDEFGHIJ\n@s1\nTTTTGGGGAA\n+\n0123456789\n@s2\nACGTACGTAC\n+\nIIIIIIIIII\n",
            "each of the three records is written"
        )
    }

    private func assertByIDStageKeepsEveryRecord(format: ReadIDBAMExtractionFormat) async throws {
        try await Self.requireSamtools()
        let (bam, _) = try await makeIndexedBAM("by-id-\(format.rawValue)", records: Self.mixedRecords)
        let (pairOnly, _) = try await makeIndexedBAM("pair-\(format.rawValue)", records: Array(Self.mixedRecords[2...3]))
        let ids: Set<String> = ["s1", "p1", "s2"]
        let transaction = try await stageByID(bam: bam, ids: ids, format: format)
        defer { transaction.cleanup() }

        let lines = format == .fastq ? 4 : 2
        let counted = try await samtoolsCountByName(bam: bam, ids: ids)
        XCTAssertEqual(counted, 5, "samtools view -c -N counts five records for the three names")
        XCTAssertEqual(transaction.readCount, counted, "the count the row shows")
        let text = try String(contentsOf: transaction.stagedFiles[0].stagedURL, encoding: .utf8)
        let written = Self.records(text, lines: lines)
        XCTAssertEqual(written.count, counted, "the \(format.rawValue) holds a record for each of the \(counted) records samtools counts")
        let pair = Self.records(try await legacyByID(bam: pairOnly, ids: ["p1"], format: format).output, lines: lines)
        let unflagged = format == .fastq
            ? ["@s1\nAAAACCCCGG\n+\nABCDEFGHIJ\n", "@s1\nTTTTGGGGAA\n+\n0123456789\n", "@s2\nACGTACGTAC\n+\nIIIIIIIIII\n"]
            : [">s1\nAAAACCCCGG\n", ">s1\nTTTTGGGGAA\n", ">s2\nACGTACGTAC\n"]
        XCTAssertEqual(
            written.sorted(), (pair + unflagged).sorted(),
            "both records of s1 are written, the reverse one restored, and the pair p1 as before"
        )
    }

    private func stageByID(
        bam: URL, ids: Set<String>, format: ReadIDBAMExtractionFormat
    ) async throws -> AlignmentReadExtractionTransaction {
        try await AlignmentReadExtractionStager().stageReadIDsFromBAM(config: ReadIDBAMExtractionConfig(
            bamURL: bam,
            readIDs: ids,
            format: format,
            outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
            outputBaseName: "selected"
        ))
    }

    /// The records `samtools view -c -N` counts for the names under the by-ID default filter (no secondary or supplementary).
    private func samtoolsCountByName(bam: URL, ids: Set<String>) async throws -> Int {
        let names = root.appendingPathComponent("names-\(UUID().uuidString).txt")
        try ids.sorted().joined(separator: "\n").write(to: names, atomically: true, encoding: .utf8)
        let result = try await samtools(["view", "-c", "-F", "2304", "-N", names.path, bam.path])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// What the by-name stager wrote before this lane step: the named records into one BAM, `samtools collate`, then
    /// `samtools fastq` or `fasta` with READ_OTHER and the singletons to sidecars and READ_OTHER appended to the output.
    private func legacyByID(
        bam: URL, ids: Set<String>, format: ReadIDBAMExtractionFormat
    ) async throws -> (output: String, singletons: String) {
        let stem = "legacy-\(UUID().uuidString)"
        let names = root.appendingPathComponent("\(stem).names.txt")
        try ids.sorted().joined(separator: "\n").write(to: names, atomically: true, encoding: .utf8)
        let filtered = root.appendingPathComponent("\(stem).filtered.bam")
        let collated = root.appendingPathComponent("\(stem).collated.bam")
        let output = root.appendingPathComponent("\(stem).out.\(format.rawValue)")
        let singletons = root.appendingPathComponent("\(stem).singletons.\(format.rawValue)")
        let other = root.appendingPathComponent("\(stem).other.\(format.rawValue)")
        try await samtools(["view", "-b", "-N", names.path, "-F", "2304", "-o", filtered.path, bam.path])
        try await samtools(["collate", "-o", collated.path, filtered.path])
        try await samtools([format.rawValue, "-F", "0", "-0", other.path, "-s", singletons.path, "-o", output.path, collated.path])
        func text(_ url: URL) throws -> String {
            FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        }
        return (try text(output) + text(other), try text(singletons))
    }

    /// The records of FASTQ or FASTA text, `lines` lines each, as the strings they are written as.
    private static func records(_ text: String, lines: Int) -> [String] {
        let all = text.split(separator: "\n").map(String.init)
        return stride(from: 0, to: all.count, by: lines).map {
            all[$0..<min($0 + lines, all.count)].joined(separator: "\n") + "\n"
        }
    }

    // MARK: - Helpers

    private static func requireSamtools() async throws {
        try await ClassifierReadIDListSupport.requireTool(.samtools)
    }

    private static let samHeader = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:ref\tLN:1000\n"

    /// One SAM line on `ref`, with the mate at `mate` on the same reference when there is one.
    private static func record(_ name: String, _ flag: Int, pos: Int, seq: String, qual: String, mate: Int? = nil) -> String {
        [name, String(flag), "ref", String(pos), "60", "\(seq.count)M", mate == nil ? "*" : "=", String(mate ?? 0), "0", seq, qual]
            .joined(separator: "\t")
    }

    private func makeIndexedBAM(_ name: String, records: [String]) async throws -> (bam: URL, index: URL) {
        let sam = root.appendingPathComponent("\(name).sam")
        try (Self.samHeader + records.joined(separator: "\n") + "\n").write(to: sam, atomically: true, encoding: .utf8)
        let bam = root.appendingPathComponent("\(name).bam")
        let index = root.appendingPathComponent("\(name).bam.bai")
        try await samtools(["view", "-b", "-o", bam.path, sam.path])
        try await samtools(["index", "-b", bam.path, index.path])
        return (bam, index)
    }

    private func stage(bam: URL, index: URL) async throws -> AlignmentReadExtractionTransaction {
        try await AlignmentReadExtractionStager().stageRegion(config: BAMRegionExtractionConfig(
            bamURL: bam,
            indexURL: index,
            regions: [Self.region],
            outputDirectory: root.appendingPathComponent("caller-output", isDirectory: true),
            outputBaseName: "selected"
        ))
    }

    /// The records `samtools view -c` counts in the region under the viewer's default filter (duplicates left out).
    private func samtoolsCount(bam: URL, index: URL) async throws -> Int {
        let result = try await samtools(["view", "-c", "-F", "1024", "-X", bam.path, index.path, Self.region])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// What the stager wrote before this lane: the region's records into one BAM, `samtools fastq` over the whole of it into
    /// the four sidecars, joined in the order READ_OTHER, singletons, READ1, READ2.
    private func legacyRegionText(bam: URL, index: URL) async throws -> String {
        let filtered = root.appendingPathComponent("legacy.filtered.bam")
        let parts = ["other", "singletons", "r1", "r2"].map { root.appendingPathComponent("legacy.\($0).fastq") }
        try await samtools(["view", "-b", "-F", "1024", "-o", filtered.path, "-X", bam.path, index.path, Self.region])
        try await samtools([
            "fastq", "-F", "0", "-0", parts[0].path, "-s", parts[1].path, "-1", parts[2].path, "-2", parts[3].path,
            filtered.path,
        ])
        var text = ""
        for part in parts where FileManager.default.fileExists(atPath: part.path) {
            text += try String(contentsOf: part, encoding: .utf8)
        }
        return text
    }

    @discardableResult
    private func samtools(_ arguments: [String]) async throws -> NativeToolResult {
        let result = try await NativeToolRunner.shared.run(.samtools, arguments: arguments, timeout: 60)
        XCTAssertTrue(result.isSuccess, "samtools \(arguments[0]) failed: \(result.stderr)")
        return result
    }
}
