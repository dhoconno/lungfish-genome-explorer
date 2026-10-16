// SRAPreparationTestSupport.swift - Windows, models and stand-in archives for the SRA preparation tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The preparation tests of lane U63 begin the SRA row themselves and hand it to
// `prepareSRADownload`, as the browser does once its row has begun. That works with and without
// the no-project refusal of lane A60, which stops a download at No Project Open before any row.

import AppKit
import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishApp

/// An archive whose request waits until its task is cancelled, and records both facts. A lookup
/// that ends is a lookup whose request saw the cancellation.
actor SRAPreparationSuspendedClient: HTTPClient {
    private(set) var started = false
    private(set) var cancelled = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error }
        throw URLError(.timedOut)
    }
}

/// An archive that cannot be reached, so ENA and NCBI both fail.
struct SRAPreparationUnavailableClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

@MainActor
enum SRAPreparationFixtures {
    /// A project window with the browser's sheet on it.
    static func makeWindows() -> (parent: NSWindow, browser: NSWindow) {
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

    /// A browser model whose two archives answer through `client`.
    static func makeModel(client: any HTTPClient) -> DatabaseBrowserViewModel {
        DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: client),
            enaService: ENAService(httpClient: client))
    }

    /// Begins the row of one SRA run and hands it to the preparation, as the browser's download does
    /// once its row has begun. The model keeps no route context, which leaves the preparation's
    /// window to `downloadPresentationWindow`.
    static func startPreparation(_ model: DatabaseBrowserViewModel, accession: String = "SRR9000001") throws -> UUID {
        let id = try XCTUnwrap(
            OperationCenter.shared.begin(
                title: accession, detail: "Preparing 1 record(s)...", operationType: .download, cliCommand: nil
            ).startedID)
        model.isDownloading = true
        model.prepareSRADownload(
            records: [SearchResultRecord(id: accession, accession: accession, title: "Test", source: .ena)],
            operationID: id)
        return id
    }

    static func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// Ends and forgets a row a test began, so no later test sees it.
    static func end(_ id: UUID) {
        OperationCenter.shared.acknowledgeCancellation(id: id)
        OperationCenter.shared.clearItem(id: id)
    }

    static func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { button(title, in: $0) }.first
    }
}
