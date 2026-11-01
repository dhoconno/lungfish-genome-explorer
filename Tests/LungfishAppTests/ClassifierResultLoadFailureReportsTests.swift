// ClassifierResultLoadFailureReportsTests.swift - The words of a NAO-MGS or NVD result that does not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ALERT-C5. The words functions `MainWindowFailureReports.openNaoMgsResult` and `openNvdResult` sort an
// error by what it is. A sentence the display functions throw for a result folder with a missing file, or for a NAO-MGS
// database in an older layout, gets the cause and the step that fixes it. Any other error gets the general words, and
// the error's own text goes only to the details. `ClassifierResultLoadFailureAlertTests` drives the same functions
// through the real display routes and reads the sheet.

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

@MainActor
final class ClassifierResultLoadFailureReportsTests: XCTestCase {
    private static let naoMgsOlderLayoutSentence = "This NAO-MGS bundle uses an older derived database layout and needs explicit repair or re-import before viewing. Viewing no longer rewrites scientific bundle data automatically."

    private func displayError(domain: String, code: Int, _ sentence: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: sentence])
    }

    // MARK: - NAO-MGS

    func testNaoMgsResultMissingAFileNamesTheResultAndPointsToImportingAgain() {
        let sentences = [
            1: "manifest.json not found in NAO-MGS bundle",
            2: "hits.sqlite not found \u{2014} bundle may need re-import",
        ]
        for (code, sentence) in sentences {
            let report = MainWindowFailureReports.openNaoMgsResult(
                named: "naomgs-run7", displayError(domain: "NaoMgsDisplay", code: code, sentence)
            )
            assertFailureAlert(report, title: "Could not open the NAO-MGS result", rawErrorText: sentence)
            XCTAssertTrue(report.whatHappened.contains("naomgs-run7"), "the result is named")
            XCTAssertTrue(report.whatHappened.contains("missing a file"), "the cause is a missing file")
            XCTAssertTrue(report.nextStep.hasPrefix("Import the NAO-MGS result again"))
        }
    }

    func testNaoMgsResultInAnOlderLayoutSaysSoAndPointsToImportingAgain() {
        let report = MainWindowFailureReports.openNaoMgsResult(
            named: "naomgs-run7",
            displayError(domain: "NaoMgsDisplay", code: 3, Self.naoMgsOlderLayoutSentence)
        )
        assertFailureAlert(report, title: "Could not open the NAO-MGS result", rawErrorText: "derived database layout")
        XCTAssertTrue(report.whatHappened.contains("naomgs-run7"), "the result is named")
        XCTAssertTrue(report.whatHappened.contains("older layout"))
        XCTAssertTrue(report.whatHappened.contains("does not change a result when it opens one"))
        XCTAssertFalse(report.whatHappened.contains("missing a file"), "an older layout is not a missing file")
        XCTAssertTrue(report.nextStep.hasPrefix("Import the NAO-MGS result again"))
    }

    func testNaoMgsResultThatFailsForAnyOtherReasonTakesTheGeneralWords() {
        let foreign = displayError(domain: "NvdDisplay", code: 1, "manifest.json not found in NVD bundle")
        for error in [rawFailureError(), foreign] {
            let report = MainWindowFailureReports.openNaoMgsResult(named: "naomgs-run7", error)
            assertFailureAlert(
                report, title: "Could not open the NAO-MGS result", rawErrorText: error.localizedDescription
            )
            XCTAssertTrue(report.whatHappened.contains("naomgs-run7"), "the result is named")
            XCTAssertTrue(report.whatHappened.contains("could not read"))
            XCTAssertFalse(report.whatHappened.contains("missing a file"), "only the NAO-MGS sentences say so")
            XCTAssertTrue(report.nextStep.contains("select the result in the sidebar again"))
            XCTAssertTrue(report.nextStep.contains("import the NAO-MGS result again"))
        }
    }

    // MARK: - NVD

    func testNvdResultMissingAFileNamesTheResultAndPointsToImportingAgain() {
        let sentences = [
            1: "manifest.json not found in NVD bundle",
            2: "hits.sqlite not found \u{2014} bundle may need re-import",
        ]
        for (code, sentence) in sentences {
            let report = MainWindowFailureReports.openNvdResult(
                named: "nvd-run7", displayError(domain: "NvdDisplay", code: code, sentence)
            )
            assertFailureAlert(report, title: "Could not open the NVD result", rawErrorText: sentence)
            XCTAssertTrue(report.whatHappened.contains("nvd-run7"), "the result is named")
            XCTAssertTrue(report.whatHappened.contains("missing a file"), "the cause is a missing file")
            XCTAssertTrue(report.nextStep.hasPrefix("Import the NVD result again"))
        }
    }

    func testNvdResultThatFailsForAnyOtherReasonTakesTheGeneralWords() {
        let foreign = displayError(domain: "NaoMgsDisplay", code: 3, Self.naoMgsOlderLayoutSentence)
        for error in [rawFailureError(), foreign] {
            let report = MainWindowFailureReports.openNvdResult(named: "nvd-run7", error)
            assertFailureAlert(report, title: "Could not open the NVD result", rawErrorText: error.localizedDescription)
            XCTAssertTrue(report.whatHappened.contains("nvd-run7"), "the result is named")
            XCTAssertTrue(report.whatHappened.contains("could not read"))
            XCTAssertFalse(report.whatHappened.contains("older layout"), "NVD has no older layout sentence")
            XCTAssertTrue(report.nextStep.contains("select the result in the sidebar again"))
            XCTAssertTrue(report.nextStep.contains("import the NVD result again"))
        }
    }

    // MARK: - The match

    /// The words match the domain and code of the errors the display functions throw. The real-fault sheet tests cover
    /// codes 1 and 2 of both. A NAO-MGS database in an older layout cannot be built cheaply, so this reads the source.
    func testTheDisplayFunctionsStillThrowTheDomainsAndCodesTheWordsMatch() throws {
        let source = combinedMainSplitViewControllerSource()
        let naoMgsStart = try XCTUnwrap(source.range(of: "func displayNaoMgsResultFromSidebar("))
        let nvdStart = try XCTUnwrap(source[naoMgsStart.upperBound...].range(of: "func displayNvdResultFromSidebar("))
        let nvdEnd = try XCTUnwrap(source[nvdStart.upperBound...].range(of: "\n    func "))
        let naoMgsBody = String(source[naoMgsStart.lowerBound..<nvdStart.lowerBound])
        let nvdBody = String(source[nvdStart.lowerBound..<nvdEnd.lowerBound])
        let naoMgs = MainWindowFailureReports.naoMgsDisplayErrorDomain
        let nvd = MainWindowFailureReports.nvdDisplayErrorDomain
        for code in 1...3 {
            XCTAssertTrue(naoMgsBody.contains("NSError(domain: \"\(naoMgs)\", code: \(code),"), "NAO-MGS code \(code)")
        }
        for code in 1...2 {
            XCTAssertTrue(nvdBody.contains("NSError(domain: \"\(nvd)\", code: \(code),"), "NVD code \(code)")
        }
        XCTAssertTrue(naoMgsBody.contains(Self.naoMgsOlderLayoutSentence), "the older layout sentence is code 3")
    }
}
