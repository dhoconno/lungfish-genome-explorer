// SRAWindowBatchSnapshotTests.swift - A batch keeps the archive preference it started with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Review nit from lane S4: the window reads the archive preference once
/// per batch, so changing it mid-batch does not split the batch between
/// archives. ENA's portal is scripted to be down and the SRA Toolkit is a
/// scripted runner that fails, so nothing reaches the network or runs a tool.
final class SRAWindowBatchSnapshotTests: XCTestCase {

    @MainActor
    func testChangingThePreferenceMidBatchDoesNotChangeTheBatchsLaterRuns() async throws {
        let suite = "sra-window-batch-snapshot-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SRADownloadSourcePreference.ena.store(in: defaults)

        let portal = DownPortal()
        let viewModel = DatabaseBrowserViewModel(
            source: .ena,
            enaService: ENAService(httpClient: portal),
            sraDownloadSuiteName: suite
        )
        let toolkitRuns = RunRecorder()
        let prefetch = URL(fileURLWithPath: "/scripted/sra-tools/bin/prefetch")
        let toolkit = SRAToolkitRunner(prefetch: prefetch, fasterqDump: URL(fileURLWithPath: "/scripted/sra-tools/bin/fasterq-dump")) { executable, arguments in
            if executable == prefetch, let accession = arguments.first {
                toolkitRuns.append(accession)
                // The user switches to Prefer NCBI while the first run downloads.
                if let defaults = UserDefaults(suiteName: suite) {
                    SRADownloadSourcePreference.ncbi.store(in: defaults)
                }
            }
            return SRAToolkitRunner.Result(exitCode: 3, stderr: "scripted failure")
        }
        let service = SRAService(ncbiService: NCBIService(httpClient: portal), httpClient: portal, toolkitRunner: toolkit)

        let id = OperationCenter.shared.begin(
            title: "SRA batch snapshot test",
            detail: "Starting...",
            operationType: .download,
            cliCommand: nil
        ).rowID
        defer { OperationCenter.shared.clearItem(id: id) }

        SRAWindowDownloadSeams.$sraService.withValue(service) {
            viewModel.startENADownloadTask(
                records: ["SRR1", "SRR2"].map { SearchResultRecord(id: $0, accession: $0, title: $0, source: .ena) },
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
                totalCount: 2
            )
        }

        let ended = await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.items.first { $0.id == id }?.state == .failed
        }
        XCTAssertTrue(ended, "both runs fail and the batch ends")
        XCTAssertEqual(toolkitRuns.values, ["SRR1", "SRR2"])
        XCTAssertEqual(SRADownloadSourcePreference.stored(in: defaults), .ncbi, "the preference did change mid-batch")

        let lines = OperationCenter.shared.items.first { $0.id == id }?.logEntries.map(\.message) ?? []
        XCTAssertFalse(lines.contains { $0.contains("Prefer NCBI") }, "no run of the batch used the new preference: \(lines)")
        XCTAssertTrue(
            lines.contains { $0.contains("SRR2") && $0.contains("using SRA Toolkit") },
            "the second run still asked ENA first, then fell back: \(lines)"
        )
    }
}

/// ENA's portal and NCBI, both down.
private struct DownPortal: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        return (Data("<html>down</html>".utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw URLError(.cannotFindHost)
    }
}

private final class RunRecorder: Sendable {
    private let stored = OSAllocatedUnfairLock<[String]>(initialState: [])
    var values: [String] { stored.withLock { $0 } }
    func append(_ value: String) { stored.withLock { $0.append(value) } }
}
