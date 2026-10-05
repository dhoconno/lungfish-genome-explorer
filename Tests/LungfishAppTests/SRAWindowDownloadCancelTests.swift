// SRAWindowDownloadCancelTests.swift - The Operations panel's Cancel stops the window's SRA download
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Review finding S3-3: the window's SRA download ran in a detached task
/// that nothing held, and it registered no cancel callback, so the
/// Operations panel's Cancel did nothing. ENA here is a scripted portal that
/// never answers until it is cancelled, so no test reaches the network.
final class SRAWindowDownloadCancelTests: XCTestCase {

    @MainActor
    func testCancelInTheOperationsPanelStopsTheDownloadPromptly() async throws {
        let suite = "sra-window-download-cancel-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let portal = HangingPortal()
        let viewModel = DatabaseBrowserViewModel(
            source: .ena,
            enaService: ENAService(httpClient: portal),
            sraDownloadSuiteName: suite
        )
        let id = OperationCenter.shared.begin(
            title: "SRA cancel test",
            detail: "Starting...",
            operationType: .download,
            cliCommand: nil
        ).rowID
        defer { OperationCenter.shared.clearItem(id: id) }

        viewModel.startENADownloadTask(
            records: [SearchResultRecord(id: "SRR1", accession: "SRR1", title: "SRR1", source: .ena)],
            importConfig: FASTQImportConfiguration(
                inputFiles: [],
                detectedPlatform: .illumina,
                confirmedPlatform: .illumina,
                pairingMode: .pairedEnd,
                qualityBinning: .illumina4,
                skipClumpify: true,
                deleteOriginals: false,
                postImportRecipe: nil,
                resolvedPlaceholders: [:],
                recipeName: nil,
                compressionLevel: .balanced
            ),
            downloadCenterTaskID: id,
            totalCount: 1
        )

        let asked = await waitUntil(timeout: .seconds(30)) { portal.started.isSet }
        XCTAssertTrue(asked, "the download reached ENA's lookup")
        OperationCenter.shared.cancel(id: id)

        // Well inside OperationCenter's 10 s grace period, so the row ends
        // because the worker stopped, not because the grace period ran out.
        let lookupCancelled = await waitUntil(timeout: .seconds(5)) { portal.cancelled.isSet }
        XCTAssertTrue(lookupCancelled, "the cancel reaches the run in progress")
        let ended = await waitUntil(timeout: .seconds(5)) {
            OperationCenter.shared.items.first { $0.id == id }?.state == .cancelled
        }
        XCTAssertTrue(ended, "the row ends as cancelled, got \(String(describing: OperationCenter.shared.items.first { $0.id == id }?.state))")
    }
}

/// ENA's portal, answering only when the request is cancelled.
private final class HangingPortal: HTTPClient, Sendable {
    let started = CancelFlag()
    let cancelled = CancelFlag()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started.set()
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            cancelled.set()
            throw error
        }
        throw URLError(.timedOut)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        _ = try await data(for: request)
        throw URLError(.timedOut)
    }
}

private final class CancelFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
