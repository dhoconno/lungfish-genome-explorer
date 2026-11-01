// CzIdResultLoadFailureReportsTests.swift - The words of a CZ-ID result that does not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane CZID, UX review SF1. The words function `MainWindowFailureReports.openCzIdResult` names the result
// and the next step, in the form the NAO-MGS and NVD words of ALERT-C5 use for an error that is not one of their
// own. The error's own text goes only to the details area. `CzIdSurfaceRouteTests` drives the same function through
// the real display route and reads the sheet.

import XCTest
@testable import LungfishApp
@testable import LungfishKit

final class CzIdResultLoadFailureReportsTests: XCTestCase {
    func testTheWordsNameTheResultAndTheNextStepAndKeepTheErrorInTheDetails() {
        let error = NSError(domain: "CzIdTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "raw decoder text"])

        let report = MainWindowFailureReports.openCzIdResult(named: "cornea-czid.lungfishtax", error)

        XCTAssertEqual(report.title, "Could not open the CZ-ID result")
        XCTAssertTrue(report.whatHappened.contains("\u{201C}cornea-czid.lungfishtax\u{201D}"), "the result is named")
        XCTAssertTrue(report.nextStep.contains("select the result in the sidebar again"), report.nextStep)
        XCTAssertTrue(report.nextStep.contains("import the CZ-ID result again"), report.nextStep)
        XCTAssertFalse(report.body.contains("raw decoder text"), "the error's text is in the body: \(report.body)")
        XCTAssertTrue(report.details?.contains("raw decoder text") ?? false, "the details lost the error's text")
        XCTAssertTrue(report.details?.contains("Error domain CzIdTest, code 7") ?? false, "the details lost the domain and code")
    }
}
