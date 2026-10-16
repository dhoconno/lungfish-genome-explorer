// SRADownloadPreparationTests.swift - Browser metadata, settings handoff and cancellation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class SRADownloadPreparationTests: XCTestCase {
    func testPreparationCanBeCancelledBeforeMetadataReturns() async throws {
        _ = NSApplication.shared
        let model = makeModel()
        startPreparation(model)
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" })
        defer { OperationCenter.shared.acknowledgeCancellation(id: row.id); OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertTrue(row.isCancellable, "Preparation must install Cancel before returning to the UI")
        OperationCenter.shared.cancel(id: row.id)
        await waitUntil { OperationCenter.shared.items.first { $0.id == row.id }?.state == .cancelled }
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == row.id }?.state, .cancelled)
        XCTAssertFalse(model.isDownloading)
    }

    func testMissingPresentationWindowEndsTheRowInsteadOfLeavingItRunning() async throws {
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        let model = makeModel()
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .failed }
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(row.state, .failed)
        XCTAssertFalse(row.logEntries.isEmpty)
        XCTAssertFalse(model.isDownloading)
    }

    func testDismissalKeepsTheOriginalParentAndSettingsCancelEndsTheRow() async throws {
        let (parent, browser) = makeWindows()
        defer { parent.close() }
        let model = makeModel()
        model.downloadPresentationWindow = parent
        model.onDownloadStarted = {
            parent.endSheet(browser)
            parent.orderOut(nil) // Neither keyWindow nor mainWindow can supply the destination now.
        }
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        let settings = try XCTUnwrap(parent.attachedSheet)
        XCTAssertTrue(settings.contentViewController is FASTQImportConfigSheet)
        XCTAssertTrue(settings.sheetParent === parent)
        let cancel = try XCTUnwrap(button("Cancel", in: settings.contentView!))
        cancel.performClick(nil)
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled }
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertNil(OperationCenter.shared.items.first { $0.id == id }?.cliCommand)
        XCTAssertFalse(model.isDownloading)
    }

    func testOperationsCancelDismissesSettingsWithoutStartingDownload() async throws {
        let (parent, browser) = makeWindows()
        defer { parent.close() }
        let model = makeModel()
        model.downloadPresentationWindow = parent
        model.onDownloadStarted = { parent.endSheet(browser) }
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        XCTAssertTrue(parent.attachedSheet?.contentViewController is FASTQImportConfigSheet)
        OperationCenter.shared.cancel(id: id)
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled }
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertNil(parent.attachedSheet)
        XCTAssertNil(OperationCenter.shared.items.first { $0.id == id }?.cliCommand)
    }

    func testClosingTheParentCancelsPendingMetadata() async throws {
        let (parent, _) = makeWindows()
        let client = SuspendedSRAHTTPClient()
        let model = makeModel(client: client)
        model.downloadPresentationWindow = parent
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { await client.started }
        let started = await client.started
        XCTAssertTrue(started)
        parent.close()
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled }
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .cancelled)
        await waitUntil { await client.cancelled }
        let cancelled = await client.cancelled
        XCTAssertTrue(cancelled, "Closing the window must cancel the network request too")
        XCTAssertFalse(model.isDownloading)
    }

    func testOperationsCancelStopsPendingMetadataWithoutShowingSettings() async throws {
        let (parent, browser) = makeWindows()
        defer { parent.close() }
        let client = SuspendedSRAHTTPClient()
        let model = makeModel(client: client)
        model.downloadPresentationWindow = parent
        var dismissed = false
        model.onDownloadStarted = { dismissed = true; parent.endSheet(browser) }
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { await client.started }
        let started = await client.started
        XCTAssertTrue(started)
        OperationCenter.shared.cancel(id: id)
        await waitUntil { await client.cancelled }
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled }
        let cancelled = await client.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertEqual(OperationCenter.shared.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertFalse(dismissed)
        XCTAssertFalse(model.isDownloading)
    }

    func testMetadataOutageStillOffersManualSettingsAndLogsTheReason() async throws {
        let (parent, browser) = makeWindows()
        defer { parent.close() }
        let model = makeModel(client: UnavailableSRAHTTPClient())
        model.downloadPresentationWindow = parent
        model.onDownloadStarted = { parent.endSheet(browser) }
        startPreparation(model)
        let id = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == "SRR9000001" }?.id)
        defer { OperationCenter.shared.acknowledgeCancellation(id: id); OperationCenter.shared.clearItem(id: id) }
        await waitUntil { parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        XCTAssertTrue(parent.attachedSheet?.contentViewController is FASTQImportConfigSheet)
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertTrue(row.logEntries.contains { $0.message.contains("Choose the settings manually") })
        XCTAssertTrue(row.isCancellable)
        OperationCenter.shared.cancel(id: id)
        await waitUntil { OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled }
    }

    /// Begins the SRA row and hands it to the preparation, as the browser's download does once its
    /// row has begun. Never call `model.performBatchDownload()` in this file. The model keeps no
    /// route context, so that call stops at the No Project Open refusal before any row (lane A60,
    /// DatabaseBrowserNoProjectDownloadRefusalTests), and the live presenter's app-modal alert
    /// waits for a click that never comes, which hangs the run. The row begins here instead, which
    /// leaves the preparation's window to `downloadPresentationWindow`.
    private func startPreparation(_ model: DatabaseBrowserViewModel) {
        let id = OperationCenter.shared.begin(
            title: "SRR9000001", detail: "Preparing 1 record(s)...", operationType: .download, cliCommand: nil
        ).rowID
        model.isDownloading = true
        model.prepareSRADownload(records: model.selectedRecord.map { [$0] } ?? [], operationID: id)
    }

    private func makeWindows() -> (NSWindow, NSWindow) {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        parent.beginSheet(browser)
        browser.makeKey()
        return (parent, browser)
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { button(title, in: $0) }.first
    }

    private func makeModel(client: any HTTPClient = MockHTTPClient(responses: [Data("[]".utf8)])) -> DatabaseBrowserViewModel {
        let model = DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: client),
            enaService: ENAService(httpClient: client))
        model.selectedRecord = SearchResultRecord(id: "SRR9000001", accession: "SRR9000001", title: "Test", source: .ena)
        return model
    }


}

private actor SuspendedSRAHTTPClient: HTTPClient {
    var started = false
    var cancelled = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = true; throw error }
        throw URLError(.timedOut)
    }
}

private struct UnavailableSRAHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}
