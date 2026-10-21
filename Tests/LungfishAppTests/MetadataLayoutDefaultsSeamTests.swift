// MetadataLayoutDefaultsSeamTests.swift - A table's column layouts go to the defaults it is given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), M864. The controller of a table saves a layout under the key the table holds,
// and the defaults it wrote to were always `UserDefaults.standard`, which in a test host is the domain
// `com.apple.dt.xctest.tool`. These tests give the controllers a suite and read both stores, so a regression that
// writes to the standard domain again fails here and not only in the leak check.

import AppKit
import XCTest
@testable import LungfishTaxTriageUI
import LungfishKit
import LungfishTestSupport

@MainActor
final class MetadataLayoutDefaultsSeamTests: XCTestCase {
    private static let layoutPrefix = "org.lungfish.metadata-column-layout."

    /// The keys the suite holds.
    private func keys(of suite: TestDefaultsSuite) -> [String] {
        (suite.defaults.persistentDomain(forName: suite.name) ?? [:]).keys.sorted()
    }

    func testAControllerKeepsTheStandardDefaultsUntilATestSetsASuite() {
        XCTAssertTrue(MetadataColumnController().userDefaults === UserDefaults.standard)
    }

    func testABatchTableSavesTheLayoutItHeldToTheSuiteItWasGiven() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutDefaultsSeamTests")
        let table = BatchTaxTriageTableView(frame: .zero)
        table.metadataColumns.userDefaults = suite.defaults
        table.resultIdentity = "/seam/first"
        table.resultIdentity = "/seam/second"
        let saved = Self.layoutPrefix + "LungfishTaxTriageUI.BatchTaxTriageTableView:/seam/first"
        XCTAssertEqual(keys(of: suite), [saved], "the table saved the layout of the key it left in the suite")
        XCTAssertNil(UserDefaults.standard.object(forKey: saved), "nothing reached the test host's own domain")
    }

    func testTheTaxTriageViewKeepsBothTablesLayoutsInItsLayoutDefaults() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutDefaultsSeamTests")
        let view = TaxTriageResultViewController()
        view.layoutDefaults = suite.defaults
        let organisms = view.testOrganismTableView.metadataColumns
        let batch = view.testBatchFlatTableView.metadataColumns
        organisms.persistenceKey = "organisms:/seam/a"
        organisms.persistenceKey = "organisms:/seam/b"
        batch.persistenceKey = "batch:/seam/a"
        batch.persistenceKey = "batch:/seam/b"
        let saved = [Self.layoutPrefix + "organisms:/seam/a", Self.layoutPrefix + "batch:/seam/a"]
        XCTAssertEqual(keys(of: suite), saved.sorted(), "both tables saved the layout of the key they left in the suite")
        for key in saved {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) reached the test host's own domain")
        }
    }
}
