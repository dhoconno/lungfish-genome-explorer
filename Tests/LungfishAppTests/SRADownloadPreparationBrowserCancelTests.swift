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
import os
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

    func testTheDialogsCancelEndsThePreparingRowItsLookupAndTheSettingsStep() async throws {
        let client = SRAPreparationSuspendedClient()
        let restore = replaceSeams(lookUp: { _, accession in try await Self.heldOpen(client, accession) })
        defer { restore() }
        let browser = openBrowser()
        defer { browser.parent.close() }
        var settingsStepReached = false
        browser.controller.onDownloadStarted = { settingsStepReached = true }
        let id = try SRAPreparationFixtures.startPreparation(browser.model)
        defer { SRAPreparationFixtures.end(id) }
        await waitUntil(timeout: .seconds(10)) { await client.started }
        let started = await client.started
        XCTAssertTrue(started, "the lookup is in flight")
        XCTAssertEqual(browser.state.statusText, "Downloading...", "the dialog reads Downloading while the lookup runs")

        browser.state.cancel()

        await waitUntil(timeout: .seconds(10)) { SRAPreparationFixtures.row(id)?.state == .cancelled }
        await waitUntil(timeout: .seconds(10)) { await client.cancelled }
        let row = try XCTUnwrap(SRAPreparationFixtures.row(id))
        XCTAssertEqual(row.state, .cancelled, "Cancel ends the preparing row")
        XCTAssertEqual(row.detail, "Cancelled by user")
        XCTAssertTrue(row.logEntries.contains { $0.message == "Looking up SRA run metadata..." }, "the row keeps its log")
        let cancelled = await client.cancelled
        XCTAssertTrue(cancelled, "the lookup's request ends with the row")
        XCTAssertFalse(browser.model.isDownloading)
        XCTAssertNil(browser.parent.attachedSheet, "the dialog closes")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.parent.attachedSheet, "no settings sheet follows")
        XCTAssertFalse(settingsStepReached, "the settings step never ran")
    }

    func testARowAlreadyHandedToTheDownloadKeepsRunningWhenTheBrowserCancels() async throws {
        let client = SRAPreparationSuspendedClient()
        let handedOver = OSAllocatedUnfairLock(initialState: [UUID]())
        let downloadCancelled = OSAllocatedUnfairLock(initialState: false)
        let restore = replaceSeams(
            lookUp: { model, accession in
                if accession == "SRR9000001" {
                    return try await SRARunMetadataLookup(ena: model.enaService, ncbi: model.ncbiService).lookUpRuns([])
                }
                return try await Self.heldOpen(client, accession)
            },
            handOff: { _, _, _, id, _ in
                // What the download does with its row: keep it running behind a callback of its own.
                handedOver.withLock { $0.append(id) }
                OperationCenter.shared.setCancelCallback(for: id) { downloadCancelled.withLock { $0 = true } }
            })
        defer { restore() }
        let browser = openBrowser()
        defer { browser.parent.close() }
        browser.controller.onDownloadStarted = { [parent = browser.parent, sheet = browser.sheet] in parent.endSheet(sheet) }

        // First run. The lookup answers, the settings open and the person confirms them.
        let first = try SRAPreparationFixtures.startPreparation(browser.model, accession: "SRR9000001")
        defer { SRAPreparationFixtures.end(first) }
        await waitUntil(timeout: .seconds(10)) { browser.parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        let settings = try XCTUnwrap(browser.parent.attachedSheet)
        XCTAssertTrue(settings.contentViewController is FASTQImportConfigSheet)
        let importButton = try XCTUnwrap(SRAPreparationFixtures.button("Import", in: try XCTUnwrap(settings.contentView)))
        importButton.performClick(nil)
        await waitUntil(timeout: .seconds(10)) { handedOver.withLock { $0 } == [first] }
        XCTAssertEqual(handedOver.withLock { $0 }, [first], "the confirmed settings hand the first row to the download")
        XCTAssertFalse(browser.model.preparingSRADownloadIDs.contains(first), "a handed-over row no longer prepares")

        // Second run. Its lookup is still open when the browser's Cancel is pressed.
        let second = try SRAPreparationFixtures.startPreparation(browser.model, accession: "SRR9000002")
        defer { SRAPreparationFixtures.end(second) }
        await waitUntil(timeout: .seconds(10)) { await client.started }
        XCTAssertEqual(browser.model.preparingSRADownloadIDs, [second])

        browser.state.cancel()

        await waitUntil(timeout: .seconds(10)) { SRAPreparationFixtures.row(second)?.state == .cancelled }
        XCTAssertEqual(SRAPreparationFixtures.row(second)?.state, .cancelled, "the preparing row is cancelled")
        XCTAssertEqual(SRAPreparationFixtures.row(first)?.state, .running, "the handed-over row keeps running")
        XCTAssertFalse(downloadCancelled.withLock { $0 }, "its download is not cancelled")
    }
}
