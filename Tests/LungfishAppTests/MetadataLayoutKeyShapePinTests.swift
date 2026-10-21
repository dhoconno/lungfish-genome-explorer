// MetadataLayoutKeyShapePinTests.swift - The key each table type builds for its column layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.52 (PREFS-SUITES), pin of QA 1. A table keys the layout of its metadata columns by a kind and
// the path of the result it shows, and the controller stores the layout under `org.lungfish.metadata-column-layout.`
// plus that key. A renamed kind or type silently drops every layout a user saved, so this class holds the text each
// table type builds today. It runs before the defaults seam of the same lane and passes before and after it. It only
// reads the key a table holds, since no layout event fires, so it writes to no defaults domain. The NAO-MGS and NVD
// views build their key when a result is configured, so those two pins give the view a suite through its test override
// and set the key once only, which saves no layout (13.52-QA Fix 1).

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
@testable import LungfishTaxTriageUI
import LungfishIO
import LungfishKit
import LungfishTestSupport

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

    /// `NaoMgsResultViewController.configureWithCachedRows` sets the key (`:424-426`) from the result folder it is given.
    func testTheNaoMgsViewKeysItsLayoutByTheNaoMgsTaxonomyKind() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutKeyShapePinTests")
        NaoMgsResultViewController.testMetadataUserDefaultsOverride = suite.defaults
        defer { NaoMgsResultViewController.testMetadataUserDefaultsOverride = nil }
        let view = NaoMgsResultViewController()
        view.loadViewIfNeeded()
        XCTAssertNil(view.metadataColumnController.persistenceKey, "a new view holds no key")
        view.configureWithCachedRows(
            [],
            manifest: NaoMgsManifest(
                sampleName: "sample-1",
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 10,
                taxonCount: 1,
                topTaxon: "Example virus",
                topTaxonId: 1234
            ),
            bundleURL: URL(fileURLWithPath: identity)
        )
        XCTAssertEqual(view.metadataColumnController.persistenceKey, "naomgs.taxonomy:/pins/result-folder")
        XCTAssertNil(
            UserDefaults.standard.object(
                forKey: "org.lungfish.metadata-column-layout.naomgs.taxonomy:/pins/result-folder"
            ),
            "the pin saved no layout to the test host's own domain"
        )
    }

    /// The `bundleURL` `didSet` of `NvdResultViewController` (`:129-135`) sets the key from the result folder it is given.
    func testTheNvdViewKeysItsLayoutByTheNvdContigsKind() {
        let suite = makeTestDefaultsSuite(prefix: "MetadataLayoutKeyShapePinTests")
        NvdResultViewController.testMetadataUserDefaultsOverride = suite.defaults
        defer { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let view = NvdResultViewController()
        view.loadViewIfNeeded()
        XCTAssertNil(view.metadataColumnController.persistenceKey, "a new view holds no key")
        view.configureWithCachedRows(
            [],
            manifest: NvdManifest(
                experiment: "pins", sampleCount: 1, contigCount: 0, hitCount: 0,
                blastDbVersion: nil, snakemakeRunId: nil, sourceDirectoryPath: "/tmp",
                samples: [], cachedTopContigs: nil
            ),
            bundleURL: URL(fileURLWithPath: identity)
        )
        XCTAssertEqual(view.metadataColumnController.persistenceKey, "nvd.contigs:/pins/result-folder")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "org.lungfish.metadata-column-layout.nvd.contigs:/pins/result-folder"),
            "the pin saved no layout to the test host's own domain"
        )
    }
}
