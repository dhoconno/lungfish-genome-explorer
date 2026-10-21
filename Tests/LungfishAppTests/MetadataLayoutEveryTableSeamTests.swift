// MetadataLayoutEveryTableSeamTests.swift - Every table that keys a column layout can be opened on a suite
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), M2 step 1. `MetadataLayoutDefaultsSeamTests` shows that a controller saves to
// the defaults it is given. This class opens each other table of the result views on a suite, the way a test of its
// view does, by the instance the view owns, and reads both stores. The suite holds the layout of the key the table
// left, and no key named for the result folder reaches `UserDefaults.standard`, which in a test host is the domain
// `com.apple.dt.xctest.tool`. The NAO-MGS and NVD views keep their older `testMetadataUserDefaultsOverride`, which
// the last two tests give the same reading.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
import LungfishKit
import LungfishTestSupport

@MainActor
final class MetadataLayoutEveryTableSeamTests: XCTestCase {
    private static let layoutPrefix = "org.lungfish.metadata-column-layout."

    /// Opens a table for one result folder and then for another, which saves the layout of the first key, and reads
    /// the suite and the standard defaults. `open` gives the table the identity it is called with.
    private func assertTheLayoutStaysInTheSuite(
        _ suite: TestDefaultsSuite,
        open: (String) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let folder = "layout-seam-\(UUID().uuidString)"
        open("/\(folder)/first")
        open("/\(folder)/second")
        let saved = (suite.defaults.persistentDomain(forName: suite.name) ?? [:]).keys.filter { $0.contains(folder) }
        XCTAssertEqual(saved.count, 1, "the table saved the layout of the key it left in the suite", file: file, line: line)
        XCTAssertTrue(
            saved.allSatisfy { $0.hasPrefix(Self.layoutPrefix) && $0.hasSuffix("/first") },
            "\(saved)", file: file, line: line
        )
        let leaked = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains(folder) }
        XCTAssertTrue(leaked.isEmpty, "\(leaked) reached the test host's own domain", file: file, line: line)
    }

    /// Gives `columns` a suite, then runs the reading above on it.
    private func assertATableSavesOnlyToItsSuite(
        _ columns: MetadataColumnController,
        file: StaticString = #filePath,
        line: UInt = #line,
        open: (String) -> Void
    ) {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutEveryTableSeamTests")
        columns.userDefaults = suite.defaults
        assertTheLayoutStaysInTheSuite(suite, open: open, file: file, line: line)
    }

    func testTheTaxonomyTableSavesOnlyToItsSuite() {
        let table = TaxonomyTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheViralDetectionTableSavesOnlyToItsSuite() {
        let table = ViralDetectionTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheBatchClassificationTableSavesOnlyToItsSuite() {
        let table = BatchClassificationTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheBatchEsVirituTableSavesOnlyToItsSuite() {
        let table = BatchEsVirituTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheMappingContigTableSavesOnlyToItsSuite() {
        let table = MappingContigTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    /// The Taxonomy view owns two tables and hands both out through its test accessors.
    func testTheTaxonomyViewsTwoTablesSaveOnlyToTheirSuites() {
        let view = TaxonomyViewController()
        assertATableSavesOnlyToItsSuite(view.testTableView.metadataColumns) { view.testTableView.resultIdentity = $0 }
        assertATableSavesOnlyToItsSuite(view.testBatchTableView.metadataColumns) { view.testBatchTableView.resultIdentity = $0 }
    }

    /// The EsViritu view owns two tables and hands both out through its test accessors, which the stored unique reads
    /// pin of `LungfishEsVirituUITests` uses before it opens a result (decision MD45).
    func testTheEsVirituViewsTwoTablesSaveOnlyToTheirSuites() {
        let view = EsVirituResultViewController()
        assertATableSavesOnlyToItsSuite(view.testDetectionTableView.metadataColumns) {
            view.testDetectionTableView.resultIdentity = $0
        }
        assertATableSavesOnlyToItsSuite(view.testBatchTableView.metadataColumns) { view.testBatchTableView.resultIdentity = $0 }
    }

    func testTheNaoMgsViewKeepsItsLayoutOnTheSuiteOfItsOverride() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutEveryTableSeamTests")
        NaoMgsResultViewController.testMetadataUserDefaultsOverride = suite.defaults
        defer { NaoMgsResultViewController.testMetadataUserDefaultsOverride = nil }
        let view = NaoMgsResultViewController()
        view.loadViewIfNeeded() // The controller saves a layout only once the view has attached its table.
        XCTAssertTrue(view.metadataColumnController.userDefaults === suite.defaults)
        assertTheLayoutStaysInTheSuite(suite) { view.metadataColumnController.persistenceKey = "naomgs.taxonomy:\($0)" }
    }

    func testTheNvdViewKeepsItsLayoutOnTheSuiteOfItsOverride() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutEveryTableSeamTests")
        NvdResultViewController.testMetadataUserDefaultsOverride = suite.defaults
        defer { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let view = NvdResultViewController()
        view.loadViewIfNeeded() // The controller saves a layout only once the view has attached its table.
        XCTAssertTrue(view.metadataColumnController.userDefaults === suite.defaults)
        assertTheLayoutStaysInTheSuite(suite) { view.metadataColumnController.persistenceKey = "nvd.contigs:\($0)" }
    }
}
