// MetadataLayoutKeyShapePinTests.swift - The key each table type builds for its column layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), pin of QA 1. A table keys the layout of its metadata columns by a kind and
// the path of the result it shows, and the controller stores the layout under `org.lungfish.metadata-column-layout.`
// plus that key. A renamed kind or type silently drops every layout a user saved, so this class holds the text each
// table type builds today. It runs before the defaults seam of the same lane and passes before and after it. It only
// reads the key a table holds, since no layout event fires, so it writes to no defaults domain.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishTaxTriageUI
import LungfishKit

@MainActor
final class MetadataLayoutKeyShapePinTests: XCTestCase {
    private let identity = "/pins/result-folder"

    /// A table of the shared base keys its layout by the type's reflected name and the identity.
    private func assertBatchTableKey<Row>(
        _ table: BatchTableView<Row>,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(table.metadataColumns.persistenceKey, "a new table holds no key", file: file, line: line)
        table.resultIdentity = identity
        XCTAssertEqual(table.metadataColumns.persistenceKey, expected, file: file, line: line)
    }

    func testTheTaxonomyTableKeysItsLayoutByTheTaxonomyOutlineKind() {
        let table = TaxonomyTableView(frame: .zero)
        XCTAssertNil(table.metadataColumns.persistenceKey, "a new table holds no key")
        table.resultIdentity = identity
        XCTAssertEqual(table.metadataColumns.persistenceKey, "taxonomy.outline:/pins/result-folder")
    }

    func testTheViralDetectionTableKeysItsLayoutByTheEsVirituDetectionsKind() {
        let table = ViralDetectionTableView(frame: .zero)
        XCTAssertNil(table.metadataColumns.persistenceKey, "a new table holds no key")
        table.resultIdentity = identity
        XCTAssertEqual(table.metadataColumns.persistenceKey, "esviritu.detections:/pins/result-folder")
    }

    func testTheBatchClassificationTableKeysItsLayoutByItsTypeName() {
        assertBatchTableKey(
            BatchClassificationTableView(frame: .zero), "LungfishApp.BatchClassificationTableView:/pins/result-folder"
        )
    }

    func testTheBatchEsVirituTableKeysItsLayoutByItsTypeName() {
        assertBatchTableKey(
            BatchEsVirituTableView(frame: .zero), "LungfishEsVirituUI.BatchEsVirituTableView:/pins/result-folder"
        )
    }

    func testTheBatchTaxTriageTableKeysItsLayoutByItsTypeName() {
        assertBatchTableKey(
            BatchTaxTriageTableView(frame: .zero), "LungfishTaxTriageUI.BatchTaxTriageTableView:/pins/result-folder"
        )
    }

    func testTheMappingContigTableKeysItsLayoutByItsTypeName() {
        assertBatchTableKey(
            MappingContigTableView(frame: .zero), "LungfishApp.MappingContigTableView:/pins/result-folder"
        )
    }
}
