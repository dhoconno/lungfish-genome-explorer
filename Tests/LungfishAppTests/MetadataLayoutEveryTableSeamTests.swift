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
@testable import LungfishTaxonomyUI

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

    /// A table whose owner keeps its view in view memory saves no layout at all, in its suite or in the host's domain,
    /// from its first key on (VS A10, QA 6). It still reads an old key as its starting value, which
    /// `BatchClassificationTableLayoutKeyTests` pins.
    private func assertAnAdoptingTableSavesNothing(
        _ columns: MetadataColumnController,
        file: StaticString = #filePath,
        line: UInt = #line,
        open: (String) -> Void
    ) {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutEveryTableSeamTests")
        columns.userDefaults = suite.defaults
        let folder = "layout-seam-\(UUID().uuidString)"
        open("/\(folder)/first")
        open("/\(folder)/second")
        let saved = (suite.defaults.persistentDomain(forName: suite.name) ?? [:]).keys.filter { $0.contains(folder) }
        XCTAssertEqual(saved, [], "the table saved a layout that view memory holds", file: file, line: line)
        let leaked = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains(folder) }
        XCTAssertTrue(leaked.isEmpty, "\(leaked) reached the test host's own domain", file: file, line: line)
    }

    func testTheTaxonomyTableSavesOnlyToItsSuite() {
        let table = TaxonomyTableView(frame: .zero)
        assertAnAdoptingTableSavesNothing(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheViralDetectionTableSavesOnlyToItsSuite() {
        let table = ViralDetectionTableView(frame: .zero)
        assertAnAdoptingTableSavesNothing(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheBatchClassificationTableSavesOnlyToItsSuite() {
        let table = BatchClassificationTableView(frame: .zero)
        assertAnAdoptingTableSavesNothing(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheBatchEsVirituTableSavesOnlyToItsSuite() {
        let table = BatchEsVirituTableView(frame: .zero)
        assertAnAdoptingTableSavesNothing(table.metadataColumns) { table.resultIdentity = $0 }
    }

    func testTheMappingContigTableSavesOnlyToItsSuite() {
        let table = MappingContigTableView(frame: .zero)
        assertATableSavesOnlyToItsSuite(table.metadataColumns) { table.resultIdentity = $0 }
    }

    /// The Taxonomy view owns two tables and hands both out through its test accessors.
    func testTheTaxonomyViewsTwoTablesSaveOnlyToTheirSuites() {
        let view = TaxonomyViewController()
        assertAnAdoptingTableSavesNothing(view.testTableView.metadataColumns) { view.testTableView.resultIdentity = $0 }
        assertAnAdoptingTableSavesNothing(view.testBatchTableView.metadataColumns) { view.testBatchTableView.resultIdentity = $0 }
    }

    /// The EsViritu view owns two tables and hands both out through its test accessors, which the stored unique reads
    /// pin of `LungfishEsVirituUITests` uses before it opens a result (decision MD45).
    func testTheEsVirituViewsTwoTablesSaveOnlyToTheirSuites() {
        let view = EsVirituResultViewController()
        assertAnAdoptingTableSavesNothing(view.testDetectionTableView.metadataColumns) {
            view.testDetectionTableView.resultIdentity = $0
        }
        assertAnAdoptingTableSavesNothing(view.testBatchTableView.metadataColumns) { view.testBatchTableView.resultIdentity = $0 }
    }

    /// The NAO-MGS table keeps its column layout in view memory since VS-CLASS item 2, so it saves none to its defaults,
    /// the suite of its override included (VS A10, QA 6).
    func testTheNaoMgsViewsTableSavesNothingToItsSuite() {
        let view = NaoMgsResultViewController()
        view.loadViewIfNeeded() // The controller would save a layout only once the view has attached its table.
        XCTAssertTrue(view.metadataColumnController.isViewMemoryAdopted, "the table declares view memory")
        assertAnAdoptingTableSavesNothing(view.metadataColumnController) {
            view.metadataColumnController.persistenceKey = "naomgs.taxonomy:\($0)"
        }
    }

    /// The NVD table keeps its column layout in view memory since VS-CLASS item 3, so it saves none to its defaults,
    /// the suite of its override included (VS A10, QA 6).
    func testTheNvdViewsTableSavesNothingToItsSuite() {
        let view = NvdResultViewController()
        view.loadViewIfNeeded() // The controller would save a layout only once the view has attached its table.
        XCTAssertTrue(view.metadataColumnController.isViewMemoryAdopted, "the table declares view memory")
        assertAnAdoptingTableSavesNothing(view.metadataColumnController) {
            view.metadataColumnController.persistenceKey = "nvd.contigs:\($0)"
        }
    }
}
