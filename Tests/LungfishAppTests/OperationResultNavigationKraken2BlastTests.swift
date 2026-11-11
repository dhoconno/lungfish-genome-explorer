// OperationResultNavigationKraken2BlastTests.swift - Results of a BLAST row saved inside a Kraken 2 result (Phase 4, ROW12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Walk row 12 of Preview 2026.11.6. A BLAST search started from a Kraken 2 result is saved inside that result, and its
// Operations row is begun with no route context, as every BLAST row is (`beginKraken2BlastVerificationOperation`). The
// Results button then asked the sidebar for the search folder alone, which the sidebar does not list, and ended in
// "Unable to show results". The ancestor tests of OPS-RESULTS-BLAST-ANCESTOR gave the walk a project themselves and stood a
// closure in for the sidebar. This test runs the chain a click runs, with no stand-in: the producer's row, the
// navigation's selection step, and the rows the sidebar scanner built from the project's files.

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxonomyUI
@testable import LungfishWorkflow

@MainActor
final class OperationResultNavigationKraken2BlastTests: XCTestCase {
    private var root: URL!
    private var kraken2: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var rows: [UUID] = []

    /// The Kraken 2 result view may save its column layout to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?
    /// The drawer's open state and height go to this suite, never the standard defaults.
    private var drawerDefaults: TestDefaultsSuite?

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "results-kraken2-blast")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        let suite = TestDefaultsSuite(prefix: "OperationResultNavigationKraken2BlastTests")
        drawerDefaults = suite
        TaxaCollectionsDrawerSeams.defaults = suite.defaults

        let project = root.appendingPathComponent("Row12.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        kraken2 = try makeKraken2Result(named: "kraken2-2026-10-21T18-05-55", in: analyses)

        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
        split.sidebarController.openProject(at: project)
        // Only the test starts a rescan, so no watcher event lands at a time the test did not choose.
        split.sidebarController.detachFilesystemWatcherForTesting()
    }

    override func tearDown() async throws {
        for row in rows { OperationCenter.shared.clearItem(id: row) }
        rows = []
        controller?.sidebarController.closeProject()
        window?.contentViewController = nil
        window = nil
        controller = nil
        TaxaCollectionsDrawerSeams.defaults = .standard
        drawerDefaults = nil
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - ROW12

    /// A BLAST search saved inside a Kraken 2 result, its row begun with no route as the producer begins it and completed
    /// with the search folder as its output. Results selects the Kraken 2 result that holds the search, in the sidebar the
    /// scanner built, and reports that it found a row.
    func testResultsOfAKraken2BlastRowSelectsTheKraken2ResultInTheRealSidebar() async throws {
        let search = kraken2.appendingPathComponent(
            "blast-verifications/Riboviria-2026-11-11T21-02-28-34e0b879", isDirectory: true
        )
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        let record = search.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        try Data("{}".utf8).write(to: record)

        // The producer begins the row with no route (ViewerViewController+Taxonomy.swift) and completes it with the
        // search folder (ViewerViewController+BlastSubmit.swift), the record's folder with its trailing slash.
        let started = ViewerViewController.beginKraken2BlastVerificationOperation(
            taxonName: "Riboviria", cliCommand: nil
        ) { _ in }
        let id = started.rowID
        rows.append(id)
        XCTAssertTrue(OperationCenter.shared.complete(
            id: id,
            detail: "0 supporting, 20 contradicting of 20 reads",
            outputURLs: [record.deletingLastPathComponent()]
        ))
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertNil(item.routeContext, "the row is begun as the producer begins it, with no route")

        let selected = await OperationResultNavigation.selectResult(of: item, in: controller.sidebarController)
        XCTAssertTrue(selected, "Results found no row for a search saved inside a Kraken 2 result")
        XCTAssertEqual(
            controller.sidebarController.selectedItems().compactMap { $0.url?.standardizedFileURL.path },
            [kraken2.standardizedFileURL.path],
            "the Kraken 2 result that holds the search is selected"
        )
        guard selected else { return }
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            self.controller.viewerController.taxonomyViewController?.batchURL?.standardizedFileURL
                == self.kraken2.standardizedFileURL
        }, "the selected Kraken 2 result is shown")
    }

    // MARK: - Fixtures

    /// The routing fixture's Kraken 2 database, the analysis metadata and the classification sidecar, the files of a
    /// Kraken 2 result folder in `Analyses/`.
    private func makeKraken2Result(named name: String, in analyses: URL) throws -> URL {
        let result = try RoutingSafetyNetFixtures.kraken2Result(named: name, in: analyses, samples: ["SRR12486983"])
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: false, created: Date()),
            to: result
        )
        let sidecar = """
        {"config":{"databaseName":"Viral","databaseVersion":"2026-01","goal":"profile","confidence":0.2,\
        "minimumHitGroups":2,"threads":1,"sampleDisplayName":"SRR12486983"},\
        "toolVersion":"2.1.3","runtime":42,"savedAt":"2026-10-01T00:00:00Z"}
        """
        try sidecar.write(
            to: result.appendingPathComponent(ClassificationResult.sidecarFilename), atomically: true, encoding: .utf8
        )
        return result
    }
}
