// TaxTriageSampleNegativeControlTests.swift - Tests for negative control field
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class TaxTriageSampleNegativeControlTests: XCTestCase {

    func testDefaultIsNotNegativeControl() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq")
        )
        XCTAssertFalse(sample.isNegativeControl)
    }

    func testExplicitNegativeControl() {
        let sample = TaxTriageSample(
            sampleId: "NTC",
            fastq1: URL(fileURLWithPath: "/data/NTC.fq"),
            isNegativeControl: true
        )
        XCTAssertTrue(sample.isNegativeControl)
    }

    func testCodableRoundTrip() throws {
        let sample = TaxTriageSample(
            sampleId: "NTC",
            fastq1: URL(fileURLWithPath: "/data/NTC.fq"),
            isNegativeControl: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(sample)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageSample.self, from: data)

        XCTAssertEqual(decoded.sampleId, "NTC")
        XCTAssertTrue(decoded.isNegativeControl)
    }

    func testBackwardCompatibleDecoding() throws {
        // Simulate a JSON without the isNegativeControl field (legacy data)
        let json = """
        {
            "sampleId": "S1",
            "fastq1": "file:///data/R1.fq",
            "platform": "ILLUMINA"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageSample.self, from: data)

        XCTAssertEqual(decoded.sampleId, "S1")
        XCTAssertFalse(decoded.isNegativeControl)
    }

    func testEquality() {
        let a = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq"),
            isNegativeControl: false
        )
        let b = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq"),
            isNegativeControl: true
        )
        XCTAssertNotEqual(a, b)
    }
}
