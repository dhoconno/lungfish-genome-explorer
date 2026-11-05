// FailurePresenterDetailsTests.swift - The details area names no private Swift type (WALKFIX, W-31)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishKit

/// A Swift error type that is private to its file. Its NSError domain names the type's address, as in
/// "Module.(unknown context at $105401cd8).Type", which a bench scientist cannot use.
private struct FilePrivateReason: LocalizedError {
    var errorDescription: String? { "Invalid gzip format (expected magic bytes 0x1f 0x8b)" }
}

/// W-31 of the 2026-11-05 walk. Show Details read "Error domain LungfishApp.(unknown context at $105401cd8)
/// .MappingRunFailureWords, code 1". A domain that holds "(unknown context at" is a debug line of a private Swift
/// type, so the details keep the error's own words and leave that line out.
final class FailurePresenterDetailsTests: XCTestCase {
    private let reason = "Invalid gzip format (expected magic bytes 0x1f 0x8b)"

    func testDetailsOmitAPrivateTypeDomain() {
        let bridged = NSError(
            domain: "LungfishApp.(unknown context at $105401cd8).MappingRunFailureWords",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
        let report = FailureReport(failedStep: "Run Map Reads", whatHappened: "A.", nextStep: "B.", underlying: bridged)
        XCTAssertEqual(report.details, reason, "the details keep the error's words and drop the domain line")
    }

    func testDetailsOfAFilePrivateSwiftErrorNameNoUnknownContext() {
        let report = FailureReport(failedStep: "Run Map Reads", whatHappened: "A.", nextStep: "B.", underlying: FilePrivateReason())
        let details = report.details ?? ""
        XCTAssertTrue(details.contains(reason), details)
        XCTAssertFalse(details.contains("unknown context"), "a private type's address is no words for a person: \(details)")
    }

    func testItemErrorDetailsOfAPrivateTypeNameNoUnknownContext() {
        let report = FailureReport(
            failedStep: "Run Map Reads for 2 of 2 samples",
            whatHappened: "A.",
            nextStep: "B.",
            itemErrors: [(name: "sample-one", error: FilePrivateReason()), (name: "sample-two", error: FilePrivateReason())]
        )
        let details = report.details ?? ""
        XCTAssertTrue(details.hasPrefix("sample-one\n\(reason)"), details)
        XCTAssertTrue(details.contains("sample-two\n\(reason)"), details)
        XCTAssertFalse(details.contains("unknown context"), details)
    }
}
