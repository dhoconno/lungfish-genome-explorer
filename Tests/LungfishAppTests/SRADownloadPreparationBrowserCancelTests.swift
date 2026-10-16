// SRADownloadPreparationBrowserCancelTests.swift - The Database Browser's Cancel during the SRA lookup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// While the lookup runs, the browser reads `Downloading...` and its Cancel stays enabled. These
// tests press that Cancel through the dialog state, the call the dialog's button makes, with the
// preparation's lookup held open by a stand-in archive. They watch the row, the lookup's request
// and the windows, never the source text.

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class SRADownloadPreparationBrowserCancelTests: XCTestCase {
    @MainActor
    private struct Browser {
        let parent: NSWindow
        let sheet: NSWindow
        let controller: DatabaseBrowserViewController
        var state: DatabaseSearchDialogState { controller.dialogState }
        var model: DatabaseBrowserViewModel { controller.dialogState.sraRunsViewModel }
    }

    /// The browser over a project window, as it is presented.
    private func openBrowser() -> Browser {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        let controller = DatabaseBrowserViewController(source: .ena)
        let sheet = NSWindow(contentViewController: controller)
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet)
        controller.dialogState.sraRunsViewModel.downloadPresentationWindow = parent
        return Browser(parent: parent, sheet: sheet, controller: controller)
    }

    /// Replaces the preparation's lookup, and its hand-off when given, until the returned closure runs.
    private func replaceSeams(
        lookUp: @escaping @MainActor (DatabaseBrowserViewModel, String) async throws -> SRARunMetadataLookup.Outcome,
        handOff: (@MainActor (DatabaseBrowserViewModel, [SearchResultRecord], FASTQImportConfiguration, UUID, Int) -> Void)? = nil
    ) -> () -> Void {
        let savedLookUp = DatabaseBrowserViewModel.sraRunLookUp
        let savedHandOff = DatabaseBrowserViewModel.sraHandOff
        DatabaseBrowserViewModel.sraRunLookUp = lookUp
        if let handOff { DatabaseBrowserViewModel.sraHandOff = handOff }
        return {
            DatabaseBrowserViewModel.sraRunLookUp = savedLookUp
            DatabaseBrowserViewModel.sraHandOff = savedHandOff
        }
    }

    /// A lookup whose two archives wait on `client` until the lookup is cancelled.
    private static func heldOpen(_ client: SRAPreparationSuspendedClient, _ accession: String) async throws
        -> SRARunMetadataLookup.Outcome
    {
        try await SRARunMetadataLookup(ena: ENAService(httpClient: client), ncbi: NCBIService(httpClient: client))
            .lookUpRuns([accession])
    }

    func testTodaysCancelClosesTheDialogAndLeavesThePreparingRowRunningWithItsLookupAlive() async throws {
        let client = SRAPreparationSuspendedClient()
        let restore = replaceSeams(lookUp: { _, accession in try await Self.heldOpen(client, accession) })
        defer { restore() }
        let browser = openBrowser()
        defer { browser.parent.close() }
        let id = try SRAPreparationFixtures.startPreparation(browser.model)
        defer { SRAPreparationFixtures.end(id) }
        await waitUntil(timeout: .seconds(10)) { await client.started }
        let started = await client.started
        XCTAssertTrue(started, "the lookup is in flight")
        XCTAssertEqual(browser.state.statusText, "Downloading...", "the dialog reads Downloading while the lookup runs")

        browser.state.cancel()

        await waitUntil(timeout: .seconds(10)) { browser.parent.attachedSheet == nil }
        XCTAssertNil(browser.parent.attachedSheet, "Cancel closes the dialog")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(SRAPreparationFixtures.row(id)?.state, .running, "today's Cancel cancels no row")
        let cancelled = await client.cancelled
        XCTAssertFalse(cancelled, "today's Cancel leaves the lookup running")
    }
}
