// TwelveSLayoutSeamTests.swift - The two 12S tables save their column layouts to the suite they are given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), M2 step 1. Both 12S tables are `BatchTableView` subclasses, so they key their
// layout by the table's type name and the result name (`TwelveSAmpliconResultViewController.swift:504`), and the
// controller they share with the other tables takes a suite through `userDefaults`. This class opens each table on a
// suite for one result and then for another, which saves the layout of the first, and reads both stores. The suite
// holds the layout and no key named for the result reaches `UserDefaults.standard`, which in a test host is the domain
// `com.apple.dt.xctest.tool`.

import AppKit
import XCTest
@testable import LungfishTwelveSUI
import LungfishKit
import LungfishTestSupport

@MainActor
final class TwelveSLayoutSeamTests: XCTestCase {
    private func assertATableSavesOnlyToItsSuite<Row>(
        _ table: BatchTableView<Row>,
        kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let suite = makeTestDefaultsSuite(prefix: "TwelveSLayoutSeamTests")
        table.metadataColumns.userDefaults = suite.defaults
        let result = "layout-seam-\(UUID().uuidString)"
        table.resultIdentity = "\(result)-first"
        XCTAssertEqual(
            table.metadataColumns.persistenceKey, "LungfishTwelveSUI.\(kind):\(result)-first",
            "the key the table builds for its layout", file: file, line: line
        )
        table.resultIdentity = "\(result)-second"
        let saved = (suite.defaults.persistentDomain(forName: suite.name) ?? [:]).keys.filter { $0.contains(result) }
        XCTAssertEqual(saved.count, 1, "the table saved the layout of the key it left in the suite", file: file, line: line)
        XCTAssertTrue(saved.allSatisfy { $0.hasSuffix("\(result)-first") }, "\(saved)", file: file, line: line)
        let leaked = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains(result) }
        XCTAssertTrue(leaked.isEmpty, "\(leaked) reached the test host's own domain", file: file, line: line)
    }

    func testTheTargetTableSavesOnlyToItsSuite() {
        assertATableSavesOnlyToItsSuite(TwelveSTargetTableView(), kind: "TwelveSTargetTableView")
    }

    func testTheUnresolvedTableSavesOnlyToItsSuite() {
        assertATableSavesOnlyToItsSuite(TwelveSUnresolvedTableView(), kind: "TwelveSUnresolvedTableView")
    }
}
