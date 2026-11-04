// DottedMateNamesTests.swift - Mates named SRR1.7.1 and SRR1.7.2 are mates to every rule that pairs by name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow
import LungfishPortable
import LungfishTestSupport

/// Row READ-LAYOUT-DOTTED-MATES. `fastq-dump --split-3 --readids` names the mates of spot 7 `SRR1.7.1` and `SRR1.7.2`.
/// The rule reads such names as mates only when both end `.1` and `.2`, the stems are equal, and the stem itself ends
/// in `.` and digits. `SRR1.1` and `SRR1.2` are spots of single reads and stay single reads, since pairing unrelated
/// reads is the worse error.
final class DottedMateNamesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "dotted-mates")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func write(_ names: [String], to file: String) throws -> URL {
        let url = root.appendingPathComponent(file)
        try names.map { "@\($0)\nACGTACGT\n+\nIIIIIIII\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func dottedPairs(_ spots: ClosedRange<Int>, run: String = "SRR1") -> [String] {
        spots.flatMap { ["\(run).\($0).1 \($0) length=8", "\(run).\($0).2 \($0) length=8"] }
    }

    func testTheRuleReadsADottedPair() {
        let mates = [
            ("SRR1.1.1", "SRR1.1.2"),
            ("SRR1.1.1 1 length=8", "SRR1.1.2 1 length=8"),
            ("@SRR1.1.1", "@SRR1.1.2"),
            ("ERR77.5000.1", "ERR77.5000.2"),
            ("DRR5.1.1\tx", "DRR5.1.2\ty"),
            ("run.b.7.1", "run.b.7.2"),
        ]
        for (first, second) in mates {
            XCTAssertTrue(FASTQReadLayoutClassifier.areMates(first, second), "\(first) and \(second)")
        }
    }

    /// A name that could be read either way stays a single read. These pass at the base and pin the edge of the rule.
    func testTheRuleLeavesEveryOtherFormSingle() {
        let single = [
            ("SRR1.1", "SRR1.2"),
            ("x.1", "x.2"),
            ("read.a.1", "read.a.2"),
            ("SRR1.1.2", "SRR1.1.1"),
            ("SRR1.1.1", "SRR1.2.2"),
            ("SRR1.1.1", "SRR1.1.3"),
            ("SRR1.1.2", "SRR1.1.3"),
            ("SRR1..1", "SRR1..2"),
            (".1.1", ".1.2"),
            ("SRR1.1.1/1", "SRR1.1.2/2"),
            ("SRR1.1.1", "SRR1.1.2/2"),
            ("SRR1.1.1 1:N:0:A", "SRR1.1.2 2:N:0:A"),
            ("SRR1.1_1", "SRR1.1_2"),
            ("SRR1.1.10", "SRR1.1.20"),
        ]
        for (first, second) in single {
            XCTAssertFalse(FASTQReadLayoutClassifier.areMates(first, second), "\(first) and \(second)")
        }
    }

    func testAFileOfDottedPairsIsStrict() throws {
        let input = try write(Self.dottedPairs(1...3), to: "pairs.fastq")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
        XCTAssertEqual(resolution.layout, .strictlyInterleaved, resolution.reason)
        XCTAssertEqual(resolution.classification?.matePairs, 3)
        XCTAssertEqual(resolution.classification?.unpairedRecords, 0)
    }

    /// Single reads under these names pair nothing, whole file. Passes at the base.
    func testSingleReadsUnderDottedAndSpotNamesStaySingle() throws {
        for (file, names) in [
            ("spots", (1...6).map { "SRR1.\($0)" }),
            ("read-ones", (1...6).map { "SRR1.\($0).1 \($0) length=8" }),
        ] {
            let input = try write(names, to: "\(file).fastq")
            let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
            XCTAssertEqual(resolution.layout, .singleEnd, "\(file): \(resolution.reason)")
            XCTAssertEqual(resolution.classification?.matePairs, 0, file)
        }
    }

    func testAMixedDottedFileCountsItsPairsBesideItsSingles() throws {
        let input = try write(
            Self.dottedPairs(1...3) + ["SRR1.4.1 4 length=8", "SRR1.5.2 5 length=8"] + Self.dottedPairs(6...6),
            to: "mixed.fastq"
        )
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs, resolution.reason)
        XCTAssertEqual(resolution.classification?.matePairs, 4)
        XCTAssertEqual(resolution.classification?.unpairedRecords, 2)
        let counted = try FASTQMixedLayoutHint.countPairsAndSingles(in: input)
        XCTAssertEqual(counted.pairs, 4)
        XCTAssertEqual(counted.singles, 2)
    }

    func testTheSplitByNameSendsDottedMatesToR1AndR2() throws {
        let input = try write(
            Self.dottedPairs(1...2) + ["SRR1.3.1 3 length=8"], to: "mixed.fastq"
        )
        let paths = ["r1", "r2", "single"].map { root.appendingPathComponent("\($0).fastq") }
        for path in paths { FileManager.default.createFile(atPath: path.path, contents: nil) }
        let handles = try paths.map { try FileHandle(forWritingTo: $0) }
        defer { handles.forEach { try? $0.close() } }

        let counts = try FASTQPairInterleaver.partitionMixed(
            interleaved: input, r1: handles[0], r2: handles[1], unpaired: handles[2]
        )

        XCTAssertEqual(counts.pairs, 2)
        XCTAssertEqual(counts.unpaired, 1)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: paths[0]), 2)
        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: paths[2]), 1)
    }

    /// minimap2's short-read preset and bwa-mem2 `-p` pair only records of one name, so their stream writes each dotted
    /// pair under a shared name. Single reads and other names keep their bytes.
    func testTheStreamForANamePairingMapperSharesEachDottedPairsName() throws {
        let input = try write(
            Self.dottedPairs(1...1) + ["SRR1.2.1 2 length=8", "plain"] + Self.dottedPairs(3...3), to: "mixed.fastq"
        )
        let output = root.appendingPathComponent("shared.fastq")

        let pairs = try MappingDottedMateStream.writeSharedMateNames(from: input, to: output)

        XCTAssertEqual(pairs, 2)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8).split(separator: "\n").enumerated().filter { $0.offset % 4 == 0 }.map { String($0.element) },
            ["@SRR1.1/1 1 length=8", "@SRR1.1/2 1 length=8", "@SRR1.2.1 2 length=8", "@plain", "@SRR1.3/1 3 length=8", "@SRR1.3/2 3 length=8"]
        )
        XCTAssertTrue(FASTQReadLayoutClassifier.areMates("SRR1.1/1 1 length=8", "SRR1.1/2 1 length=8"))
        XCTAssertFalse(FASTQReadLayoutClassifier.holdsDottedMateName("SRR1.1"))
        XCTAssertFalse(FASTQReadLayoutClassifier.holdsDottedMateName("read7/1"))
        XCTAssertTrue(FASTQReadLayoutClassifier.holdsDottedMateName("SRR1.7.2 7 length=8"))
    }

    /// BIO ruling 7, route 3. The scan now reads true dotted pairs, so a stated interleaved file in which it finds no
    /// mates at all is a file of single reads, and no tool pairs it by position.
    func testAStatedInterleavedFileWithNoMatesIsNotPairedByPosition() throws {
        let input = try write((1...6).map { "m\($0)" }, to: "singles.fastq")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input], explicit: .strictlyInterleaved)
        XCTAssertEqual(resolution.layout, .singleEnd, resolution.reason)
        XCTAssertEqual(resolution.source, .contentScan)
        XCTAssertEqual(resolution.classification?.unpairedRecords, 6)
        XCTAssertTrue(resolution.reason.contains("The caller stated interleaved pairs"), resolution.reason)
    }

    /// A stated layout on a true dotted pair stands. Passes at the base only through the old test, and after it through
    /// the scan reading the names.
    func testAStatedInterleavedDottedFileStaysInterleaved() throws {
        let input = try write(Self.dottedPairs(1...3), to: "pairs.fastq")
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [input], explicit: .strictlyInterleaved)
        XCTAssertEqual(resolution.layout, .strictlyInterleaved, resolution.reason)
        XCTAssertEqual(resolution.source, .explicit)
    }
}
