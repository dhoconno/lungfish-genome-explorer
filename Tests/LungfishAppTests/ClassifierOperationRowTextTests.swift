// ClassifierOperationRowTextTests.swift - The words of the classifier Operations rows that stay in the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Pins the alert titles, the batch sample prefix and the database warning line of the Kraken2 and
/// EsViritu launches. Each expected string is the one the launch closures built inline before they
/// moved to `AppDelegate+ClassificationRowText.swift`, so a change here changes what users read.
/// The completion details are pinned in `ClassificationCompletionDetailTests` in LungfishWorkflow.
@MainActor
final class ClassifierOperationRowTextTests: XCTestCase {
    func testTheFourFailureAlertsKeepTheirTitles() {
        XCTAssertEqual(AppDelegate.classificationFailedAlertTitle, "Classification Failed")
        XCTAssertEqual(AppDelegate.classificationBatchFailedAlertTitle, "Classification Batch Failed")
        XCTAssertEqual(AppDelegate.esVirituFailedAlertTitle, "EsViritu Failed")
        XCTAssertEqual(AppDelegate.esVirituBatchFailedAlertTitle, "EsViritu Batch Failed")
    }

    func testBatchSamplePrefixCountsPositionsFromOne() {
        XCTAssertEqual(
            AppDelegate.classificationBatchSamplePrefix(index: 0, sampleCount: 3, sampleID: "air-A"),
            "Sample 1/3 (air-A)"
        )
        XCTAssertEqual(
            AppDelegate.classificationBatchSamplePrefix(index: 2, sampleCount: 3, sampleID: "air-C"),
            "Sample 3/3 (air-C)"
        )
    }

    func testBatchProgressLineReadsPrefixColonMessage() {
        let prefix = AppDelegate.classificationBatchSamplePrefix(index: 1, sampleCount: 4, sampleID: "S2")
        XCTAssertEqual("\(prefix): Running Kraken2", "Sample 2/4 (S2): Running Kraken2")
    }

    func testDatabaseBuildWarningNamesTheErrorAndTheLazyRebuild() {
        XCTAssertEqual(
            AppDelegate.classificationDatabaseBuildWarning("disk is full"),
            "Database build failed: disk is full \u{2014} batch will rebuild lazily on open"
        )
    }

    func testPolicyTSVFieldFollowsTheAppsTSVFieldRule() {
        let values = ["plain", "with\ttab", "with\nline", "with \"quote\"", "", "a\r\nb", "tab\tand \"quote\""]
        for value in values {
            XCTAssertEqual(
                ClassificationBatchOutcomePolicy.tsvField(value),
                appTSVField(value),
                "the policy and the app must escape \(value.debugDescription) alike"
            )
        }
        XCTAssertEqual(ClassificationBatchOutcomePolicy.tsvField("with\ttab"), "\"with\ttab\"")
        XCTAssertEqual(ClassificationBatchOutcomePolicy.tsvField("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}
