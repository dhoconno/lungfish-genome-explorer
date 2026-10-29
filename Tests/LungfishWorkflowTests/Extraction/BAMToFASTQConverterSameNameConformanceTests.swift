// BAMToFASTQConverterSameNameConformanceTests.swift - The shared converter writes one record for each unflagged SAM record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane FASTQ-SAME-NAME, ruling R1 of the IDPINS review (reviews/IDPINS.md). Tiny BAMs are built from SAM text
// with the managed samtools and run through `convertBAMToSingleFASTQ`, the one converter behind the classifier
// extraction, the by-region and by-ID extraction and the Medaka FASTQ reconstruction. The cases are those of the
// review's `fastq_same_name.py`, with a different sequence and quality on each record so a dropped or mixed-up record
// shows in the text:
//
// - A, two records of one name, flags 0 and 16, side by side. `samtools fastq` wrote the first only.
// - C, two records of one name, flags 0 and 0.
// - D, flags 0 and 16 on two contigs, side by side in file order.
// - G, flags 0 and 16 of one name and a third read after them.
// - H, a pair with the paired flags among reads with none, which the converter splits by flag.
// - E, a proper pair (99 and 147), unchanged: mate 1 before mate 2, the reverse mate restored, and no `/1` or `/2` on a
//   name, since `samtools fastq` adds none when it writes to separate files.
//
// A record the reverse strand holds is written as the read: reverse complement and reversed qualities. A mapped record
// with no sequence is left out, since an empty FASTQ record breaks the tools that read it. A record with no qualities gets
// the quality `samtools fastq` gives it (B), which this test pins as what the tool does.
//
// It runs the managed samtools, so its name holds Conformance and it skips without it unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class BAMToFASTQConverterSameNameConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-fastq-same-name")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    // MARK: - Cases

    /// Cases A, C, D and G under the classifier mask (0xD04) and the service mask (0x900).
    func testRecordsOfOneReadNameWithNeitherMateFlagAreEachWritten() async throws {
        try await Self.requireSamtools()
        let forward = Self.record("r1", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ")
        let reverse = Self.record("r1", 16, pos: 300, seq: "TTCCCCAAAA", qual: "9876543210")
        let first = "@r1\nAAAACCCCGG\n+\nABCDEFGHIJ\n"
        let restored = "@r1\nTTTTGGGGAA\n+\n0123456789\n"
        let cases: [(label: String, records: [String], expected: String)] = [
            ("A flags 0 and 16", [forward, reverse], first + restored),
            (
                "C flags 0 and 0",
                [forward, Self.record("r1", 0, pos: 300, seq: "GGGGTTTTAA", qual: "JIHGFEDCBA")],
                first + "@r1\nGGGGTTTTAA\n+\nJIHGFEDCBA\n"
            ),
            (
                "D flags 0 and 16 on two contigs",
                [forward, Self.record("r1", 16, ref: "ref2", pos: 300, seq: "TTCCCCAAAA", qual: "9876543210")],
                first + restored
            ),
            (
                "G flags 0 and 16, then another read",
                [forward, reverse, Self.record("r2", 0, pos: 400, seq: "CCCCGGGGTT", qual: "0000011111")],
                first + restored + "@r2\nCCCCGGGGTT\n+\n0000011111\n"
            ),
        ]
        for (index, testCase) in cases.enumerated() {
            let bam = try await makeBAM("case-\(index)", records: testCase.records)
            for mask in [0xD04, 0x900] {
                let text = try await convert(bam, flagFilter: mask)
                XCTAssertEqual(text, testCase.expected, "\(testCase.label), samtools -F \(mask)")
            }
        }
    }

    /// Case H, a pair among reads with no paired flag, and case E, the pair alone. The unflagged records come first, in
    /// the BAM's order, as the `-0` stream always came first, then the mates of the pair, mate 1 before mate 2.
    func testFlaggedMatesAreWrittenAsBeforeAndUnflaggedRecordsAroundThemAreKept() async throws {
        try await Self.requireSamtools()
        let pair = try await makeBAM("pair", records: [
            Self.record("r1", 99, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ", mate: ("=", 300)),
            Self.record("r1", 147, pos: 300, seq: "TTCCCCAAAA", qual: "9876543210", mate: ("=", 100)),
        ])
        let pairText = try await convert(pair, flagFilter: 0xD04)
        XCTAssertEqual(
            pairText, "@r1\nAAAACCCCGG\n+\nABCDEFGHIJ\n@r1\nTTTTGGGGAA\n+\n0123456789\n",
            "E a proper pair is written as before, mate 1 then mate 2, the reverse mate restored, no suffix"
        )

        let mixed = try await makeBAM("mixed", records: [
            Self.record("s1", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            Self.record("s1", 16, pos: 120, seq: "TTCCCCAAAA", qual: "9876543210"),
            Self.record("p1", 99, pos: 150, seq: "CCCCGGGGTT", qual: "0000011111", mate: ("=", 300)),
            Self.record("p1", 147, pos: 300, seq: "GGGGAAAACC", qual: "1111122222", mate: ("=", 150)),
            Self.record("s2", 0, pos: 400, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        ])
        let mixedText = try await convert(mixed, flagFilter: 0xD04)
        XCTAssertEqual(
            mixedText,
            "@s1\nAAAACCCCGG\n+\nABCDEFGHIJ\n@s1\nTTTTGGGGAA\n+\n0123456789\n@s2\nACGTACGTAC\n+\nIIIIIIIIII\n"
                + "@p1\nCCCCGGGGTT\n+\n0000011111\n@p1\nGGTTTTCCCC\n+\n2222211111\n",
            "H both mates of s1, the pair p1 and the read s2 are all written"
        )
    }

    /// Case I, a mapped record with no sequence, and case J, a record with no qualities.
    func testRecordWithoutSequenceIsLeftOutAndRecordWithoutQualitiesGetsTheSamtoolsQuality() async throws {
        try await Self.requireSamtools()
        let noSequence = try await makeBAM("no-sequence", records: [
            Self.record("star", 0, pos: 100, seq: "*", qual: "*"),
            Self.record("ok", 0, pos: 200, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
        ])
        let sequenceText = try await convert(noSequence, flagFilter: 0xD04)
        XCTAssertEqual(sequenceText, "@ok\nAAAACCCCGG\n+\nABCDEFGHIJ\n", "I a record with no sequence is left out")

        let noQualities = try await makeBAM("no-qualities", records: [
            Self.record("noqual", 0, pos: 100, seq: "ACGTACGTAC", qual: "*"),
        ])
        let qualityText = try await convert(noQualities, flagFilter: 0xD04)
        XCTAssertEqual(qualityText, "@noqual\nACGTACGTAC\n+\nBBBBBBBBBB\n", "J a record with no qualities gets B")
    }

    /// An output that was right stays byte for byte. The old route, `samtools fastq` over the whole BAM into the four
    /// sidecars joined as READ_OTHER, singletons, READ1 and READ2, is run here directly. The converter must write the
    /// same bytes for proper pairs, for the markers BAM (secondary, supplementary and duplicate records), for single
    /// reads with no repeated name (one on the reverse strand with IUPAC letters, one with no qualities) and for a pair
    /// among single reads.
    func testOutputsThatWereRightStayByteForByte() async throws {
        try await Self.requireSamtools()
        let proper = ClassifierReadIDListSupport.fixture("sarscov2/test.paired_end.sorted.bam")
        let markers = ClassifierReadIDListSupport.fixture("sarscov2/test.paired_end.sorted.markers.bam")
        let singles = try await makeBAM("singles", records: [
            Self.record("u1", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            Self.record("u2", 16, pos: 200, seq: "TTCCCCAAAA", qual: "9876543210"),
            Self.record("u3", 0, pos: 300, seq: "GGGGTTTTAA", qual: "JIHGFEDCBA"),
            Self.record("u4", 16, pos: 400, seq: "ACGTRYKMBVDHSWN", qual: "0123456789ABCDE"),
            Self.record("u5", 0, pos: 500, seq: "ACGTACGTAC", qual: "*"),
        ])
        let interleaved = try await makeBAM("interleaved", records: [
            Self.record("a", 0, pos: 100, seq: "AAAACCCCGG", qual: "ABCDEFGHIJ"),
            Self.record("p1", 99, pos: 150, seq: "CCCCGGGGTT", qual: "0000011111", mate: ("=", 300)),
            Self.record("p1", 147, pos: 300, seq: "GGGGAAAACC", qual: "1111122222", mate: ("=", 150)),
            Self.record("b", 16, pos: 400, seq: "ACGTACGTAC", qual: "IIIIIIIIII"),
        ])
        let cases = [("proper pairs", proper), ("markers", markers), ("single reads", singles), ("a pair among single reads", interleaved)]
        for (label, bam) in cases {
            for mask in [0xD04, 0x900] {
                let before = try await legacyConvert(bam, flagFilter: mask)
                XCTAssertFalse(before.isEmpty, "\(label), samtools -F \(mask) gives reads")
                let written = try await convert(bam, flagFilter: mask)
                XCTAssertEqual(written, before, "\(label), samtools -F \(mask) is not byte for byte the old route")
            }
        }
    }

    // MARK: - Helpers

    private static func requireSamtools() async throws {
        try await ClassifierReadIDListSupport.requireTool(.samtools)
    }

    private static let samHeader = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:ref\tLN:1000\n@SQ\tSN:ref2\tLN:1000\n"

    /// One SAM line. `seq` and `qual` are as the file holds them, so a reverse-strand record carries its bases as they
    /// were aligned.
    private static func record(
        _ name: String, _ flag: Int, ref: String = "ref", pos: Int, seq: String, qual: String,
        mate: (ref: String, pos: Int) = ("*", 0)
    ) -> String {
        let cigar = seq == "*" ? "10M" : "\(seq.count)M"
        return [name, String(flag), ref, String(pos), "60", cigar, mate.ref, String(mate.pos), "0", seq, qual]
            .joined(separator: "\t")
    }

    private func makeBAM(_ name: String, records: [String]) async throws -> URL {
        let sam = root.appendingPathComponent("\(name).sam")
        try (Self.samHeader + records.joined(separator: "\n") + "\n").write(to: sam, atomically: true, encoding: .utf8)
        let bam = root.appendingPathComponent("\(name).bam")
        let result = try await NativeToolRunner.shared.run(
            .samtools, arguments: ["view", "-b", "-o", bam.path, sam.path], timeout: 60
        )
        XCTAssertTrue(result.isSuccess, "samtools view -b failed: \(result.stderr)")
        return bam
    }

    /// The FASTQ text the converter writes for `bam` under the mask `flagFilter`.
    private func convert(_ bam: URL, flagFilter: Int) async throws -> String {
        let temp = root.appendingPathComponent("temp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let output = temp.appendingPathComponent("out.fastq")
        try await convertBAMToSingleFASTQ(
            inputBAM: bam,
            outputFASTQ: output,
            tempDir: temp,
            sidecarPrefix: "reads",
            flagFilter: flagFilter,
            timeout: 60,
            toolRunner: NativeToolRunner.shared
        )
        return try String(contentsOf: output, encoding: .utf8)
    }

    /// What the converter wrote before this lane: `samtools fastq` over the whole BAM into the four sidecars, joined in
    /// the order READ_OTHER, singletons, READ1, READ2.
    private func legacyConvert(_ bam: URL, flagFilter: Int) async throws -> String {
        let temp = root.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let other = temp.appendingPathComponent("other.fastq")
        let singletons = temp.appendingPathComponent("singletons.fastq")
        let first = temp.appendingPathComponent("r1.fastq")
        let second = temp.appendingPathComponent("r2.fastq")
        let result = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: [
                "fastq", "-F", String(flagFilter), "-0", other.path, "-1", first.path, "-2", second.path,
                "-s", singletons.path, bam.path,
            ],
            timeout: 60
        )
        XCTAssertTrue(result.isSuccess, "samtools fastq failed: \(result.stderr)")
        var text = ""
        for part in [other, singletons, first, second] where FileManager.default.fileExists(atPath: part.path) {
            text += try String(contentsOf: part, encoding: .utf8)
        }
        return text
    }
}
