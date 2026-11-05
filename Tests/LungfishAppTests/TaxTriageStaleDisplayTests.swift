// TaxTriageStaleDisplayTests.swift - A stale TaxTriage database never shows its old rows with no words (3.2 TTREADS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A TaxTriage database that an older Lungfish built holds Reads counted on the first reference of each organism alone, so
// an organism with several references, such as the eight segments of Influenza A, can read 0. The app rebuilds such a
// database once a session when the project can be written. After that try is spent, in a second window, after a failed
// rebuild or in a project open read-only, the viewer used to fall through to the stored rows and show the false 0 with
// no words (BIO review of lane TTREADS, F3, and ARCH blocker 1). It now says in words that the counts are not shown.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

@MainActor
final class TaxTriageStaleDisplayTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!

    /// The TaxTriage result view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-stale-display")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        controller = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// Red at 0ea86b0a9, which showed the stored rows once the session's one try was used.
    func testStaleDatabaseAfterSpentRebuildShowsWordsNotRows() throws {
        let batch = try makeStaleBatch()
        // The session already tried this rebuild, as after a failed rebuild or in a second window.
        XCTAssertTrue(TaxTriageStaleDatabaseRebuilds.shouldAttempt(for: batch.appendingPathComponent("taxtriage.sqlite")))

        controller.displayContent(for: SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch))

        XCTAssertNil(controller.viewerController.taxTriageViewController, "no rows load from a database an older Lungfish counted")
        let words = controller.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("older version of Lungfish"), "the words say why the rows are not shown: \(words)")
        XCTAssertTrue(words.contains("build-db taxtriage"), "the words name the command that recounts them: \(words)")
        XCTAssertTrue(words.contains("--force"), words)
        XCTAssertTrue(words.contains(batch.path), "the words name the result folder: \(words)")
    }

    /// A batch folder with the sample folder of a TaxTriage 3.3.8 organism report and a database of its first row that
    /// carries no `read_count` mark, as a database built before 3.2 does.
    private func makeStaleBatch() throws -> URL {
        let batch = root.appendingPathComponent("taxtriage-batch-2026-11-05T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/taxtriage-odr-3.3.8/SRR12486983", isDirectory: true)
        try FileManager.default.copyItem(at: sample, to: batch.appendingPathComponent("SRR12486983", isDirectory: true))
        let report = try String(contentsOf: sample.appendingPathComponent("report/SRR12486983.odr.txt"), encoding: .utf8)
        let row = try XCTUnwrap(TaxTriageOrganismReport.parse(tsv: report).first, "the fixture report holds a row")
        let database = try TaxTriageDatabase.create(
            at: batch.appendingPathComponent("taxtriage.sqlite"),
            rows: [row],
            metadata: ["tool": "taxtriage", TaxTriageDatabase.taxonomySourceMetadataKey: "organism_report"]
        )
        XCTAssertTrue(database.isStale(forResultDirectory: batch), "the fixture database is stale")
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true, created: Date()),
            to: batch
        )
        return batch
    }
}
