// SidebarSearchStatePreservationTests.swift - A search must not cost the sidebar its folders or selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

/// Preview 2026.9.57 click-test: after searching the sidebar while a Kraken2
/// or genotyping run was in progress, the run's completion rescan collapsed
/// every folder, dropped the selection, and the finished result was never
/// selected. The search filter shows copies of the rows, so the rescan saw
/// nothing expanded and could not select the new result.
@MainActor
final class SidebarSearchStatePreservationTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!
    private var batchFolder: URL!
    private var notesURL: URL!
    private var sidebar: SidebarViewController!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSearchState-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        batchFolder = projectURL.appendingPathComponent("Imports/Batch1", isDirectory: true)
        try FileManager.default.createDirectory(at: batchFolder, withIntermediateDirectories: true)
        notesURL = batchFolder.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: notesURL, atomically: true, encoding: .utf8)
        // A completed analysis so the Analyses group exists before the run.
        let earlier = try AnalysesFolder.createAnalysisDirectory(
            tool: "skesa", in: projectURL, date: Date(timeIntervalSince1970: 1_715_000_000)
        )
        AnalysesFolder.markAnalysisComplete(earlier)

        sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.openProject(at: projectURL)
        sidebar.expandItemForTesting(batchFolder)
        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder), "precondition")
        XCTAssertTrue(sidebar.selectItem(forURL: notesURL), "precondition")
    }

    override func tearDownWithError() throws {
        sidebar?.closeProject()
        sidebar = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func finishAnalysis() throws -> URL {
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        AnalysesFolder.markAnalysisComplete(dir)
        return dir
    }

    func testClearingASearchRestoresExpandedFoldersAndSelection() {
        sidebar.applySearchForTesting("no-such-item")
        XCTAssertTrue(sidebar.isSearchFilterShownForTesting)

        sidebar.clearSearchForTesting()

        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder))
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, notesURL.standardizedFileURL)
    }

    func testRescanDuringASearchKeepsExpandedFoldersForWhenTheSearchIsCleared() async throws {
        sidebar.applySearchForTesting("no-such-item")
        _ = try finishAnalysis()
        await sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)?.value
        XCTAssertTrue(sidebar.isSearchFilterShownForTesting, "the user's search stays on screen")

        sidebar.clearSearchForTesting()

        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder))
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, notesURL.standardizedFileURL)
    }

    func testRescanWithoutASearchKeepsExpandedFolders() async throws {
        _ = try finishAnalysis()
        await sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)?.value
        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder))
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, notesURL.standardizedFileURL)
    }

    func testRevealingAFinishedResultSelectsItAndKeepsFoldersExpanded() async throws {
        let result = try finishAnalysis()
        let revealed = await sidebar.reloadAndRevealItem(forURL: result).value
        XCTAssertTrue(revealed)
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, result.standardizedFileURL)
        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder))
    }

    /// The gate caught this under parallel load: a file-watcher rescan
    /// started while the reveal's own scan ran, the reveal's scan was
    /// discarded as stale, and the reveal gave up before the newer scan
    /// applied. A superseding scan is started here on purpose.
    func testRevealingAFinishedResultSurvivesASupersedingRescan() async throws {
        let result = try finishAnalysis()
        // The reveal's own scan runs freely. The superseding scan is held at
        // the barrier until the reveal has finished, so the reveal's scan is
        // always discarded as stale and nothing has applied the new row.
        let (held, release) = AsyncStream<Void>.makeStream()
        let reveal = sidebar.reloadAndRevealItem(forURL: result)
        SidebarViewController.scanBarrierForTesting = { for await _ in held { break } }
        let superseding = sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)
        SidebarViewController.scanBarrierForTesting = nil
        defer { SidebarViewController.scanBarrierForTesting = nil }

        let revealed = await reveal.value
        release.yield()
        release.finish()
        await superseding?.value

        XCTAssertTrue(revealed)
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, result.standardizedFileURL)
    }

    func testRevealingAResultHiddenByASearchClearsTheSearch() async throws {
        sidebar.applySearchForTesting("no-such-item")
        let result = try finishAnalysis()
        let revealed = await sidebar.reloadAndRevealItem(forURL: result).value
        XCTAssertTrue(revealed)
        XCTAssertFalse(sidebar.isSearchFilterShownForTesting)
        XCTAssertEqual(sidebar.selectedFileURL?.standardizedFileURL, result.standardizedFileURL)
        XCTAssertTrue(sidebar.isItemExpandedForTesting(batchFolder))
    }
}
