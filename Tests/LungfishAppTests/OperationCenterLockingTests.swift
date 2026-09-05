// OperationCenterLockingTests.swift - Bundle mutation lock invariants
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit

@MainActor
final class OperationCenterLockingTests: XCTestCase {
    func testStartWithLockedBundleRecordsBlockedOperationWithoutReplacingLockHolder() throws {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/locked-reference.lungfishref", isDirectory: true)

        let firstID = center.start(
            title: "Annotation Import A",
            detail: "Importing first track",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )
        let secondID = center.start(
            title: "Annotation Import B",
            detail: "Importing second track",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )

        XCTAssertEqual(center.activeLockHolder(for: bundleURL)?.id, firstID)
        XCTAssertFalse(center.canStartOperation(on: bundleURL))

        let second = try XCTUnwrap(center.items.first { $0.id == secondID })
        XCTAssertEqual(second.state, .failed)
        XCTAssertEqual(second.targetBundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(second.errorMessage, "Bundle is busy")
        XCTAssertTrue(second.detail.contains("Annotation Import A"))

        center.complete(id: firstID, detail: "Complete")
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testAnnotationImportCallSitesPassTargetBundleURLForLocking() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift"
            ),
            encoding: .utf8
        )
        let importCenterSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/App/AppDelegate+ImportCenter.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            Self.operationStartBlock(titled: "Annotation Import", in: sidebarSource)
                .contains("targetBundleURL: bundleURL"),
            "Sidebar/drop annotation imports must acquire a bundle mutation lock."
        )
        XCTAssertTrue(
            Self.operationStartBlock(titled: "Annotation Import", in: importCenterSource)
                .contains("targetBundleURL: bundleURL"),
            "Import Center annotation imports must acquire a bundle mutation lock."
        )
    }

    func testWorkerTerminalCallsAcknowledgeCancellationAndSuppressDelivery() throws {
        let completions: [@MainActor (OperationCenter, UUID, URL) -> Bool] = [
            { center, id, _ in center.complete(id: id, detail: "Done") },
            { $0.complete(id: $1, detail: "Done", bundleURLs: [$2]) },
            { $0.complete(id: $1, detail: "Done", outputURLs: [$2]) },
            { center, id, _ in center.completeWithWarning(id: id, detail: "Warning") },
            { $0.completeWithWarning(id: $1, detail: "Warning", bundleURLs: [$2]) },
            { $0.completeWithWarning(id: $1, detail: "Warning", outputURLs: [$2]) },
            { center, id, _ in center.fail(id: id, detail: "Late failure") }
        ]
        for finish in completions {
            let center = OperationCenter()
            let url = URL(fileURLWithPath: "/tmp/cancellation-race.lungfishref")
            var deliveries = 0
            center.onBundleReady = { _ in deliveries += 1 }
            let id = center.start(title: "Worker", detail: "Working", targetBundleURL: url, onCancel: {})
            center.cancel(id: id)
            XCTAssertFalse(finish(center, id, url), "Cancellation must suppress success/failure UI")
            let item = try XCTUnwrap(center.items.first { $0.id == id })
            XCTAssertEqual(item.state, .cancelled, "Worker return must acknowledge drained cancellation")
            XCTAssertNotNil(item.finishedAt)
            XCTAssertTrue(item.bundleURLs.isEmpty)
            XCTAssertTrue(item.outputURLs.isEmpty)
            XCTAssertNil(item.onCancel)
            XCTAssertEqual(deliveries, 0)
            XCTAssertTrue(center.canStartOperation(on: url))
            let replacement = center.start(title: "Replacement", detail: "Working", targetBundleURL: url)
            XCTAssertFalse(finish(center, id, url))
            XCTAssertEqual(center.activeLockHolder(for: url)?.id, replacement)
        }
    }

    func testTerminalRowCannotReinstallCancellationCallback() throws {
        let center = OperationCenter()
        let id = center.start(title: "Worker", detail: "Working", onCancel: {})
        XCTAssertTrue(center.complete(id: id, detail: "Done"))
        center.setCancelCallback(for: id, callback: {})
        XCTAssertNil(try XCTUnwrap(center.items.first { $0.id == id }).onCancel)
    }

    func testCancellationSignalReturnDoesNotReleaseWorkerLease() async throws {
        let center = OperationCenter()
        let url = URL(fileURLWithPath: "/tmp/cancellation-barrier.lungfishref")
        let signalReturned = expectation(description: "signal delivered")
        let workerMayFinish = DispatchSemaphore(value: 0)
        let workerFinished = expectation(description: "worker drained")
        let id = center.start(title: "Worker", detail: "Working", targetBundleURL: url, onCancel: {
            signalReturned.fulfill()
        })
        DispatchQueue.global().async {
            workerMayFinish.wait()
            DispatchQueue.main.async {
                _ = center.complete(id: id, detail: "Worker drained")
                workerFinished.fulfill()
            }
        }
        center.cancel(id: id)
        center.cancel(id: id)
        await fulfillment(of: [signalReturned], timeout: 2)
        // Drain the main queue after the callback has returned. Worker cleanup
        // remains blocked independently of cancellation delivery.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelling)
        XCTAssertNil(center.items.first { $0.id == id }?.finishedAt)
        center.clearCompleted()
        center.clearItem(id: id)
        XCTAssertEqual(center.activeLockHolder(for: url)?.id, id)
        let blocked = center.start(title: "Blocked", detail: "Working", targetBundleURL: url)
        XCTAssertEqual(center.items.first { $0.id == blocked }?.state, .failed)
        workerMayFinish.signal()
        await fulfillment(of: [workerFinished], timeout: 2)
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertTrue(center.canStartOperation(on: url))
    }

    func testDelayedChildExitAndCleanupKeepCancellationLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let signalled = directory.appendingPathComponent("signalled")
        let allowExit = directory.appendingPathComponent("allow-exit")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
        trap 'touch "\(signalled.path)"; while [ ! -f "\(allowExit.path)" ]; do sleep 0.01; done; printf drained >&2; exit 0' TERM
        touch "\(ready.path)"
        while :; do sleep 0.01; done
        """]
        let stderr = Pipe()
        process.standardError = stderr
        let center = OperationCenter()
        let target = directory.appendingPathComponent("synthetic.lungfishref")
        let id = center.start(title: "Harmless helper", detail: "Running", targetBundleURL: target, onCancel: {
            process.terminate()
        })
        let cleanupAllowed = DispatchSemaphore(value: 0)
        let drained = expectation(description: "child and stderr drained")
        let finished = expectation(description: "worker cleanup complete")
        try process.run()
        defer {
            try? Data().write(to: allowExit)
            cleanupAllowed.signal()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().async {
            process.waitUntilExit()
            let output = stderr.fileHandleForReading.readDataToEndOfFile()
            XCTAssertTrue(String(decoding: output, as: UTF8.self).hasSuffix("drained"), "Child must write its final stderr marker before EOF")
            drained.fulfill()
            cleanupAllowed.wait()
            DispatchQueue.main.async {
                center.acknowledgeCancellation(id: id)
                finished.fulfill()
            }
        }
        try await waitForMarker(ready)
        center.cancel(id: id)
        try await waitForMarker(signalled)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelling)
        XCTAssertEqual(center.activeLockHolder(for: target)?.id, id)
        try Data().write(to: allowExit)
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelling)
        XCTAssertEqual(center.activeLockHolder(for: target)?.id, id)
        cleanupAllowed.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .cancelled)
        XCTAssertTrue(center.canStartOperation(on: target))
    }

    private func waitForMarker(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func operationStartBlock(titled title: String, in source: String) -> String {
        guard let titleRange = source.range(of: #"title: "\#(title)""#),
              let startRange = source[..<titleRange.lowerBound].range(of: "OperationCenter.shared.start(", options: .backwards),
              let endRange = source[titleRange.upperBound...].range(of: "\n        )") else {
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}
