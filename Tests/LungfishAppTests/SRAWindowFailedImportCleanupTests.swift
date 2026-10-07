// SRAWindowFailedImportCleanupTests.swift - A run whose import failed leaves nothing for the next run of the batch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Finding F7-N4: `startENADownloadTask` removes each run's staging folder
/// with a `defer` after the import, and no test covered the case where the
/// import fails. Here every import fails, because `lungfish-cli` is a stand-in
/// script that exits 1, and the SRA Toolkit route serves both runs from the
/// recorded fasterq-dump output, since ENA is scripted to be down. When the
/// second run starts, the first run's folder must already be gone.
final class SRAWindowFailedImportCleanupTests: XCTestCase {

    @MainActor
    func testAFailedImportRemovesTheRunsFolderBeforeTheNextRunStarts() async throws {
        let root = try TestTempDirectory.make(prefix: "sra-window-failed-import")
        defer { TestTempDirectory.cleanup(root) }
        let fakeCLI = root.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\necho 'import refused by the test' >&2\nexit 1\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }

        let first = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let second = SRAToolkitRecordedRunner.singleEndRun
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        let recorded = SRAToolkitRecordedRunner(testFile: #filePath).runner
        let seen = SeenFolders()
        // Notes, when the second run's prefetch starts, whether the first
        // run's folder is still in the batch folder, then runs the recording.
        let observing = SRAToolkitRunner(prefetch: recorded.prefetch, fasterqDump: recorded.fasterqDump) { executable, arguments in
            if executable == recorded.prefetch, arguments.first == second, let index = arguments.firstIndex(of: "-O") {
                let batch = URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent()
                seen.record(batch: batch, firstRunFolderExists: FileManager.default.fileExists(atPath: batch.appendingPathComponent(first).path))
            }
            return try await recorded.run(executable, arguments)
        }
        let service = SRAService(ncbiService: NCBIService(httpClient: archives, environment: [:]), httpClient: archives, toolkitRunner: observing)

        let suite = "sra-window-failed-import-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let viewModel = DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: archives, environment: [:]),
            enaService: ENAService(httpClient: archives),
            sraDownloadSuiteName: suite
        )
        let id = OperationCenter.shared.begin(
            title: "SRA failed import cleanup test",
            detail: "Starting...",
            operationType: .download,
            cliCommand: nil
        ).rowID
        defer { OperationCenter.shared.clearItem(id: id) }

        SRAWindowDownloadSeams.$sraService.withValue(service) {
            viewModel.startENADownloadTask(
                records: [first, second].map { SearchResultRecord(id: $0, accession: $0, title: $0, source: .ena) },
                importConfig: FASTQImportConfiguration(
                    inputFiles: [],
                    detectedPlatform: .illumina,
                    confirmedPlatform: .illumina,
                    pairingMode: .pairedEnd,
                    qualityBinning: .none,
                    skipClumpify: true,
                    deleteOriginals: false,
                    postImportRecipe: nil,
                    resolvedPlaceholders: [:],
                    recipeName: nil,
                    compressionLevel: .fast
                ),
                downloadCenterTaskID: id,
                totalCount: 2
            )
        }

        let reachedSecondRun = await waitUntil(timeout: .seconds(60)) { seen.batch != nil }
        XCTAssertTrue(reachedSecondRun, "the batch went on to the second run after the first import failed")
        XCTAssertEqual(seen.firstRunFolderExists, false, "the first run's folder is removed after its failed import")
        let batch = try XCTUnwrap(seen.batch)
        let batchRemoved = await waitUntil(timeout: .seconds(60)) {
            !FileManager.default.fileExists(atPath: batch.path)
        }
        XCTAssertTrue(batchRemoved, "the batch folder is removed when the batch ends")
        let lines = OperationCenter.shared.items.first { $0.id == id }?.logEntries.map(\.message) ?? []
        XCTAssertFalse(lines.isEmpty)
    }
}

/// What the observing toolkit saw when the second run started.
private final class SeenFolders: Sendable {
    private let state = OSAllocatedUnfairLock<(batch: URL?, exists: Bool?)>(initialState: (nil, nil))
    var batch: URL? { state.withLock { $0.batch } }
    var firstRunFolderExists: Bool? { state.withLock { $0.exists } }
    func record(batch: URL, firstRunFolderExists: Bool) {
        state.withLock { $0 = (batch, firstRunFolderExists) }
    }
}
