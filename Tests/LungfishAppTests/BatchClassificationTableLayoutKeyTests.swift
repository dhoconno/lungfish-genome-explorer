// BatchClassificationTableLayoutKeyTests.swift - The Kraken2 batch table keeps the layout key it was saved under
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane LEAF. The shared base keys a saved column layout by the reflected type name, which holds the module
// name. `BatchClassificationTableView` moved from LungfishApp to LungfishTaxonomyUI, so without a seam every column
// choice a person saved for the table would be dropped once. The table overrides `layoutKeyTypeName` with the name it
// was saved under. `MetadataLayoutKeyShapePinTests` holds the key text. This class writes a layout through a defaults
// suite and reads one that an earlier version saved, so the key the table writes and reads is the one on disk.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport
@testable import LungfishTaxonomyUI

@MainActor
final class BatchClassificationTableLayoutKeyTests: XCTestCase {
    private let layoutPrefix = "org.lungfish.metadata-column-layout."
    private let savedTypeName = "LungfishApp.BatchClassificationTableView"
    private let identity = "/pins/result-folder"

    private func layoutKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(layoutPrefix) }.sorted()
    }

    func testTheTableWritesItsLayoutUnderTheKeyItHadBeforeTheMove() {
        let suite = makeTestDefaultsSuite(prefix: "BatchClassificationTableLayoutKeyTests")
        let table = BatchClassificationTableView(frame: .zero)
        table.metadataColumns.userDefaults = suite.defaults
        table.resultIdentity = identity
        XCTAssertTrue(layoutKeys(in: suite.defaults).isEmpty, "showing a result saves nothing")

        // Leaving a result saves its layout under the key it was shown with.
        table.resultIdentity = "/pins/other-result-folder"

        XCTAssertEqual(
            layoutKeys(in: suite.defaults),
            [layoutPrefix + savedTypeName + ":" + identity],
            "the layout is saved under the key of the LungfishApp type name, not of the module that holds the table"
        )
    }

    func testTheTableReadsALayoutThatWasSavedUnderTheKeyItHadBeforeTheMove() {
        let suite = makeTestDefaultsSuite(prefix: "BatchClassificationTableLayoutKeyTests")
        let saved = #"{"version":1,"visibleMetadata":[],"#
            + #""columnOrder":["percent","readsClade","readsDirect","rank","name","sample"],"metadataWidths":{}}"#
        suite.defaults.set(Data(saved.utf8), forKey: layoutPrefix + savedTypeName + ":" + identity)

        let table = BatchClassificationTableView(frame: .zero)
        table.metadataColumns.userDefaults = suite.defaults
        let orderBefore = table.tableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertEqual(orderBefore.first, "sample", "a new table lists the sample column first")

        table.resultIdentity = identity

        let orderAfter = table.tableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertEqual(
            orderAfter.prefix(6).map { $0 },
            ["percent", "readsClade", "readsDirect", "rank", "name", "sample"],
            "the table applies the column order that was saved under the key it had before the move"
        )
    }
}
