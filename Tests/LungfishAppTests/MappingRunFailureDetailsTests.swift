// MappingRunFailureDetailsTests.swift - Show Details of a Map Reads failure names no private type (WALKFIX, W-31)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
@testable import LungfishApp

/// W-31 of the 2026-11-05 walk. Show Details of a Map Reads batch alert read "Error domain LungfishApp.(unknown context
/// at $105401cd8).MappingRunFailureWords, code 1", the debug line of a private Swift type. The failed line's words
/// are an error of the "Mapping" domain now.
final class MappingRunFailureDetailsTests: XCTestCase {
    func testBatchFailureDetailsNameNoPrivateType() throws {
        var failures = MappingBatchFailures()
        failures.record(.failed("Invalid gzip format (expected magic bytes 0x1f 0x8b)"), sample: "HG002_chr20-second-sample")
        failures.record(.failed("Gzip file is empty."), sample: "HG002_chr20_10_0-10_5Mb")

        let report = try XCTUnwrap(failures.report(totalSamples: 2))
        let details = try XCTUnwrap(report.details)

        XCTAssertFalse(details.contains("unknown context"), "Show Details names a private Swift type: \(details)")
        XCTAssertTrue(details.contains("HG002_chr20-second-sample\nInvalid gzip format (expected magic bytes 0x1f 0x8b)"), details)
        XCTAssertTrue(details.contains("Error domain Mapping"), "the domain a person reads is Mapping: \(details)")
    }

    func testSingleSampleReasonOfSeveralLinesNamesNoPrivateType() throws {
        var failures = MappingBatchFailures()
        failures.record(.failed("Map Reads failed.\nsamtools: the second line of the reason"), sample: "sample-one")

        let report = try XCTUnwrap(failures.report(totalSamples: 1))
        let details = try XCTUnwrap(report.details)

        XCTAssertFalse(details.contains("unknown context"), "Show Details names a private Swift type: \(details)")
        XCTAssertTrue(details.contains("the second line of the reason"), details)
        XCTAssertTrue(details.contains("Error domain Mapping"), "the domain a person reads is Mapping: \(details)")
    }
}
