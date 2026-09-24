// ImportCenterSequentialBundleImportTests.swift - FEA-05 regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Before this fix, `ImportCenterViewModel.dispatchFileImport` looped over every selected
// URL and called `appDelegate.importBAMFromURL`/`importVCFFromURL` for each one
// synchronously and unconditionally. Each of those calls starts an `OperationCenter`
// operation that holds the target bundle's write lock for the whole import
// (`performBAMImport`/`performVCFImport`); since the import itself runs asynchronously
// (a detached CLI subprocess), the SECOND and later calls in the loop always ran while
// the first import's operation was still `.running`, so `canStartOperation` refused them
// and only the first file was ever actually imported. Import Center closed immediately
// and recorded every file as `succeeded: true` in history regardless.
//
// `queueSequentialBundleImports` fixes this by starting one file, waiting for its
// operation to reach a terminal state (`MainSplitViewController.pollUntilOperationTerminal`,
// the same primitive already used elsewhere in the app for sequential fan-outs), then
// starting the next -- and records each file's history entry with its own real outcome
// instead of the whole batch as `succeeded: true`. These tests exercise that queuing
// against a real (test-local, not `.shared`) `OperationCenter`, using a fake `start`
// closure standing in for `importBAMFromURL`/`importVCFFromURL` so the test does not
// depend on samtools or a real BAM/VCF import pipeline being available.

import XCTest
@testable import LungfishApp
import LungfishKit

@MainActor
final class ImportCenterSequentialBundleImportTests: XCTestCase {
    func testThreeFilesAreStartedOneAtATimeNotAllAtOnce() async throws {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/three-bam-fixture.lungfishref", isDirectory: true)
        let viewModel = ImportCenterViewModel()
        // `ImportHistoryEntry` history persists across tests via UserDefaults
        // (`ImportCenterViewModel.init()` loads it), so start from a known-empty list
        // rather than asserting on the total count.
        viewModel.clearHistory()

        let urls = (1...3).map { URL(fileURLWithPath: "/tmp/sample\($0).sorted.bam") }
        // Tracks how many imports were concurrently "in flight" (started but not yet
        // completed) at any point, so the test can assert the queue never lets two run
        // at once -- which is exactly the FEA-05 bug: three simultaneous `.start()` calls
        // sharing one bundle lock.
        var inFlight = 0
        var maxConcurrentInFlight = 0
        var startedURLsInOrder: [URL] = []
        var activeOpIDs: [UUID] = []

        viewModel.queueSequentialBundleImports(urls: urls, action: .bam, center: center) { url in
            // A real caller would refuse to start a second import here because
            // `canStartOperation` is false while a prior one is still running (this is
            // exactly the FEA-05 bug); asserting `inFlight == 0` at start time is the
            // direct behavioural check that the queue never even attempts that.
            XCTAssertEqual(inFlight, 0, "a new import must not start while a prior one is still in flight")
            inFlight += 1
            maxConcurrentInFlight = max(maxConcurrentInFlight, inFlight)
            startedURLsInOrder.append(url)

            let opID = center.start(title: "Importing \(url.lastPathComponent)", detail: "Importing...",
                                     operationType: .bamImport, targetBundleURL: bundleURL)
            activeOpIDs.append(opID)
            // Simulate the real import's async completion, exactly like
            // `performBAMImport`'s "detached work, then complete on the main actor" shape,
            // so the queue is genuinely waiting on `OperationCenter` state rather than on
            // a synchronous return.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                inFlight -= 1
                _ = center.complete(id: opID, detail: "Imported")
            }
            return opID
        }

        try await waitFor { viewModel.importHistory.count == urls.count }

        XCTAssertEqual(maxConcurrentInFlight, 1, "at most one BAM import should ever be in flight at a time")
        XCTAssertEqual(startedURLsInOrder, urls, "files should be started in the order they were selected")
        XCTAssertEqual(Set(activeOpIDs).count, 3, "each file must get its own operation, not share one")

        // Every file actually completed (this is the direct fix for "only the first
        // imports"): all three history entries are real successes, not the old
        // unconditional `succeeded: true` regardless of what actually happened.
        XCTAssertEqual(viewModel.importHistory.count, 3)
        XCTAssertTrue(viewModel.importHistory.allSatisfy(\.succeeded))
        XCTAssertEqual(Set(viewModel.importHistory.map(\.fileName)), Set(urls.map(\.lastPathComponent)))
    }

    func testARefusedFileIsRecordedAsFailedNotSucceeded() async throws {
        let center = OperationCenter()
        let viewModel = ImportCenterViewModel()
        viewModel.clearHistory()
        let urls = [
            URL(fileURLWithPath: "/tmp/refused.sorted.bam"),
            URL(fileURLWithPath: "/tmp/accepted.sorted.bam"),
        ]

        viewModel.queueSequentialBundleImports(urls: urls, action: .bam, center: center) { url in
            // The first file has no bundle open / is otherwise refused before ever
            // reaching `OperationCenter` -- exactly what `importBAMFromURL` returns `nil`
            // for today (no bundle loaded, a write-lock conflict elsewhere, etc).
            guard url.lastPathComponent == "accepted.sorted.bam" else { return nil }
            let opID = center.start(title: "Importing", detail: "Importing...", operationType: .bamImport)
            _ = center.complete(id: opID, detail: "Imported")
            return opID
        }

        try await waitFor { viewModel.importHistory.count == 2 }

        let refused = try XCTUnwrap(viewModel.importHistory.first { $0.fileName == "refused.sorted.bam" })
        XCTAssertFalse(refused.succeeded, "a refused import must not be recorded as succeeded")
        let accepted = try XCTUnwrap(viewModel.importHistory.first { $0.fileName == "accepted.sorted.bam" })
        XCTAssertTrue(accepted.succeeded)
    }

    private func waitFor(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the queued imports to finish")
    }
}
