// FASTQReadNameIndexTests.swift - The one parser of the mate and index a read name carries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXRUN (L1). No code read the index in a read name: `detectMate` kept the mate of a
// `1:N:0:...` comment and dropped the index (DEMUX-HEADER-INDEX-NOT-READ).

import XCTest
@testable import LungfishIO

final class FASTQReadNameIndexTests: XCTestCase {
    func testCasavaIndexFieldParses() throws {
        let dual = FASTQReadNameIndex(rawName: "A00123:8:H5:1:1101:1000:2000 1:N:0:ATCACGAT+TTCGAGCG")
        XCTAssertEqual(dual.readID, "A00123:8:H5:1:1101:1000:2000")
        XCTAssertEqual(dual.mate, 1)
        XCTAssertEqual(dual.i7, "ATCACGAT")
        XCTAssertEqual(dual.i5, "TTCGAGCG")

        let single = FASTQReadNameIndex(rawName: "r1 2:Y:0:attactcg")
        XCTAssertEqual(single.mate, 2)
        XCTAssertEqual(single.i7, "ATTACTCG")
        XCTAssertNil(single.i5)

        for noIndex in [
            "r1 1:N:0:2",                    // a sample number
            "r1 1:N:0:NNNNNNNN",             // an empty index read
            "r1 1:N:0:NNNNNNNN+TTCGAGCG",    // no first index
            "r1 1:N:0:",                     // an empty field
            "r1 1:N:0",                      // a missing field
            "r1 1:N:X:ATTACTCG",             // not a Casava comment
            "r1 1:Q:0:ATTACTCG",
            "r1 1:N:0:ATTA-TCG",             // a letter that is not a base
            "SRR000001.1 1 length=150",      // SRA's default defline
            "r1",
        ] {
            XCTAssertFalse(FASTQReadNameIndex(rawName: noIndex).hasIndex, noIndex)
        }
        XCTAssertNil(FASTQReadNameIndex(rawName: "r1 1:N:0:ATTACTCG+NNNNNNNN").i5, "an all-N i5 is no index")
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1 1:N:0:ATTACTCG+NNNNNNNN").i7, "ATTACTCG")

        // The UMI BCL Convert appends to the read ID is not the index.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/platform-headers/illumina-nextseq2000-umi.fastq")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        let names = stride(from: 0, to: lines.count, by: 4).map { lines[$0].dropFirst() }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let parsed = FASTQReadNameIndex(rawName: name)
            XCTAssertEqual(parsed.i7, "GATCAG", String(name))
            XCTAssertEqual(parsed.i5, "CTGATC", String(name))
            XCTAssertTrue(parsed.readID.hasSuffix(":ACGTACGT"), "the UMI stays in the read ID")
        }
    }

    /// The mate rules `detectMate` used before the parser took them over.
    func testMateComesFromTheSuffixOrTheComment() {
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1/1").mate, 1)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1/1").readID, "r1")
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1/2 1:N:0:ACGT").mate, 2)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1/2 1:N:0:ACGT").readID, "r1")
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1 2:N:0:ACGT").readID, "r1")
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1 2:N:0:ACGT").mate, 2)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1 1:").mate, 1)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "r1 3:N:0:ACGT").mate, 0)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "SRR1.1 1 length=150").mate, 0)
        XCTAssertEqual(FASTQReadNameIndex(rawName: "SRR1.1 1 length=150").readID, "SRR1.1")
    }
}
