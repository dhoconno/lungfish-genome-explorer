// MatePairFileNamingTests.swift - Two files are mates when their names say so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

final class MatePairFileNamingTests: XCTestCase {

    func testRecognisesEveryMarkerTheWindowPairsBy() {
        let pairs = [
            ("sample_R1.fastq", "sample_R2.fastq"),
            ("sample_R1_001.fastq.gz", "sample_R2_001.fastq.gz"),
            ("sample_1.fq.gz", "sample_2.fq.gz"),
            ("sample.r1.fastq", "sample.r2.fastq"),
            ("sample-r1.fastq", "sample-r2.fastq"),
            ("Sample_r1.FASTQ", "Sample_R2.fastq"),
        ]
        for (r1, r2) in pairs {
            let pair = MatePairFileNaming.matePair(in: [Self.url(r1), Self.url(r2)])
            XCTAssertEqual(pair?.r1.lastPathComponent, r1, "\(r1) and \(r2) are mates")
            XCTAssertEqual(pair?.r2.lastPathComponent, r2)
        }
    }

    func testOrdersTheMatesR1FirstWhateverTheInputOrder() {
        let pair = MatePairFileNaming.matePair(in: [Self.url("s_R2.fastq"), Self.url("s_R1.fastq")])
        XCTAssertEqual(pair?.r1.lastPathComponent, "s_R1.fastq")
        XCTAssertEqual(pair?.r2.lastPathComponent, "s_R2.fastq")
    }

    func testRefusesFilesThatAreNotOneSamplesMates() {
        let notPairs = [
            ("a_R1.fastq", "b_R2.fastq"),
            ("s_R1.fastq", "s_R1.fastq"),
            ("run_0.fastq", "run_1.fastq"),
            ("reads.fastq", "more-reads.fastq"),
            ("s_R1.fastq", "s.fastq"),
        ]
        for (first, second) in notPairs {
            XCTAssertNil(
                MatePairFileNaming.matePair(in: [Self.url(first), Self.url(second)]),
                "\(first) and \(second) are not mates"
            )
        }
        XCTAssertNil(MatePairFileNaming.matePair(in: [Self.url("s_R1.fastq")]))
        XCTAssertNil(MatePairFileNaming.matePair(in: [Self.url("s_R1.fastq"), Self.url("s_R2.fastq"), Self.url("s_R3.fastq")]))
    }

    func testStemAndRoleStripCompressionAndMarkers() {
        let (stem, role) = MatePairFileNaming.stemAndRole(of: Self.url("Lib A_S1_R2_001.fastq.gz"))
        XCTAssertEqual(stem, "Lib_A_S1")
        XCTAssertEqual(role, .read2)
        XCTAssertEqual(MatePairFileNaming.stemAndRole(of: Self.url("reads.fq")).role, .single)
    }

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/data/\(name)")
    }
}
