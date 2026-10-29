// NaoMgsExportItemStateTests.swift - the NAO-MGS Export item follows the database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.40 M2 (UX ruling W3). A NAO-MGS result that opens from its cached rows has no database, so the
// Export button is disabled with W3's second text, and the database view enables it again with the shared help.

import AppKit
import XCTest
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishNaoMgsUI

@MainActor
final class NaoMgsExportItemStateTests: XCTestCase {
    private var root: URL?
    /// The result view saves its column layout to `UserDefaults.standard` under the path of this class's folders.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        hostDefaults = HostDefaultsRestorer(owns: { $0.contains("/naomgs-export-item") || $0.contains("/naomgs-export-opening") })
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        hostDefaults?.restore()
        try await super.tearDown()
    }

    func testNaoMgsExportButtonFollowsTheDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-export-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        let hit = NaoMgsVirusHit(
            sample: "sample-A", seqId: "sample-A-1000-1", taxId: 1000,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100, refStart: 100,
            refEnd: 200, readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100), subjectSeqId: "NC_1000", subjectTitle: "Taxon 1000",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
        let database = try NaoMgsDatabase.create(at: folder.appendingPathComponent("hits.sqlite"), hits: [hit])
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 1, taxonCount: 1,
            topTaxon: "Taxon 1000", topTaxonId: 1000
        )
        let vc = NaoMgsResultViewController()
        vc.testDisableMiniBAMLoading = true
        vc.loadViewIfNeeded()

        // A result that opens from its cached rows has no database.
        vc.configureWithCachedRows([], manifest: manifest)
        XCTAssertFalse(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, ClassifierExportWords.missingDatabaseHelp)
        XCTAssertEqual(vc.actionBar.exportButton.accessibilityHelp(), ClassifierExportWords.missingDatabaseHelp)

        // The database view replaces them, and the item is enabled with the shared help.
        vc.configure(database: database, manifest: manifest, bundleURL: folder)
        let shared = LungfishHelpContent.resultExport
        XCTAssertTrue(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, shared.summary)
        XCTAssertEqual(vc.actionBar.exportButton.accessibilityHelp(), shared.detail ?? shared.summary)

        // Let the table load so no task outlives the view controller.
        for _ in 0..<100 where vc.testDisplayedTaxonOrder.count != 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testCachedRowsWithTheDatabaseFilePresentReadTheOpeningWords() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-export-opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder
        // The result's database file is in its folder and the viewer still shows the cached rows while it opens.
        try Data().write(to: folder.appendingPathComponent("hits.sqlite"))
        let hit = NaoMgsVirusHit(
            sample: "sample-A", seqId: "sample-A-1000-1", taxId: 1000,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100, refStart: 100,
            refEnd: 200, readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100), subjectSeqId: "NC_1000", subjectTitle: "Taxon 1000",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
        let database = try NaoMgsDatabase.create(at: folder.appendingPathComponent("opened.sqlite"), hits: [hit])
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 1, taxonCount: 1,
            topTaxon: "Taxon 1000", topTaxonId: 1000
        )
        let vc = NaoMgsResultViewController()
        vc.testDisableMiniBAMLoading = true
        vc.loadViewIfNeeded()

        vc.configureWithCachedRows([], manifest: manifest, bundleURL: folder)
        let opening = "Export is ready once this result finishes opening."
        XCTAssertFalse(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, opening)
        XCTAssertEqual(vc.actionBar.exportButton.accessibilityHelp(), opening)

        // The database view replaces them, and the item is enabled with the shared help.
        vc.configure(database: database, manifest: manifest, bundleURL: folder)
        let shared = LungfishHelpContent.resultExport
        XCTAssertTrue(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, shared.summary)
        XCTAssertEqual(vc.actionBar.exportButton.accessibilityHelp(), shared.detail ?? shared.summary)

        for _ in 0..<100 where vc.testDisplayedTaxonOrder.count != 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
