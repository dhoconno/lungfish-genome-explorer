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

    // MARK: - begin(...): a refusal the caller cannot ignore

    /// The core contract test for ARC-04/FEA-07: `begin` must hand back a
    /// value the caller has to switch on, and the refused case must not be
    /// mistakable for a started operation.
    func testBeginReturnsRefusedWhenBundleIsLocked() throws {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/locked-begin.lungfishref", isDirectory: true)

        let firstResult = center.begin(
            title: "First Operation",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )
        guard case .started(let firstID) = firstResult else {
            return XCTFail("Expected the first begin() to start, since nothing holds the lock yet.")
        }

        let secondResult = center.begin(
            title: "Second Operation",
            detail: "Should be refused",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )
        guard case .refused(let refusal) = secondResult else {
            return XCTFail("Expected the second begin() to be refused while the first operation holds the lock.")
        }
        XCTAssertEqual(refusal.blockingOperationTitle, "First Operation")
        XCTAssertTrue(refusal.message.contains("First Operation"))

        // The visible "Bundle is busy" row still exists, matching `start`'s behaviour.
        let refusedItem = try XCTUnwrap(center.items.first { $0.id == refusal.id })
        XCTAssertEqual(refusedItem.state, .failed)
        XCTAssertEqual(refusedItem.errorMessage, "Bundle is busy")

        center.complete(id: firstID, detail: "Complete")
        guard case .started = center.begin(
            title: "Third Operation",
            detail: "Should start once the lock is released",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        ) else {
            return XCTFail("Expected begin() to start once the lock holder completed.")
        }
    }

    func testBeginStartsNormallyWithNoConflict() throws {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/unlocked-begin.lungfishref", isDirectory: true)

        let result = center.begin(
            title: "Solo Operation",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL
        )
        guard case .started(let id) = result else {
            return XCTFail("Expected begin() to start when nothing else holds the lock.")
        }
        XCTAssertEqual(center.items.first { $0.id == id }?.state, .running)
        XCTAssertEqual(result.startedID, id)
    }

    // MARK: - Caller-family tests: the refused caller must never touch the transport

    /// Simulates the annotation-import caller family
    /// (`AppDelegate+ImportCenter.performSingleAnnotationTrackImport` and
    /// `MainSplitViewController+FASTQImport`'s sidebar-drop twin): both now
    /// call `begin` and must not invoke the annotation-attach closure when
    /// refused.
    func testAnnotationImportCallerNeverAttachesWhenBundleIsLocked() {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/annotation-import.lungfishref", isDirectory: true)
        _ = center.begin(title: "Existing Import", detail: "Running", operationType: .bundleBuild, targetBundleURL: bundleURL)

        var attachInvoked = false
        func performAnnotationImport() {
            let result = center.begin(
                title: "Annotation Import",
                detail: "Importing...",
                operationType: .bundleBuild,
                targetBundleURL: bundleURL
            )
            guard case .started = result else { return }
            attachInvoked = true
        }
        performAnnotationImport()

        XCTAssertFalse(attachInvoked, "The annotation-attach work must never run when the bundle is locked.")
    }

    /// Simulates the MSA export caller family (`ViewerViewController+MSAExport.exportMSAAlignment`
    /// and `ViewerViewController.exportMSASelectionViaCLI`): the CLI runner must never launch
    /// when the target bundle is locked.
    func testMSAExportCallerNeverLaunchesRunnerWhenBundleIsLocked() {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/msa-export.lungfishmsa", isDirectory: true)
        _ = center.begin(title: "Existing MSA Op", detail: "Running", operationType: .multipleSequenceAlignmentAction, targetBundleURL: bundleURL)

        var runnerLaunched = false
        func exportMSAAlignment() {
            let result = center.begin(
                title: "Export Alignment",
                detail: "Exporting...",
                operationType: .multipleSequenceAlignmentAction,
                targetBundleURL: bundleURL
            )
            guard case .started = result else { return }
            runnerLaunched = true
        }
        exportMSAAlignment()

        XCTAssertFalse(runnerLaunched, "The CLI MSA runner must never launch when the bundle is locked.")
    }

    /// Simulates the four MSA/tree viewer actions in `ViewerViewController.swift`
    /// (annotation add/project, IQ-TREE inference, tree transform): each now
    /// guards its runner launch behind `begin`'s `.started` case.
    func testMSATreeViewerActionsNeverLaunchRunnerWhenBundleIsLocked() {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/msa-tree-viewer.lungfishmsa", isDirectory: true)
        _ = center.begin(title: "Existing Tree Op", detail: "Running", operationType: .phylogeneticTreeInference, targetBundleURL: bundleURL)

        let operationTypes: [OperationType] = [
            .multipleSequenceAlignmentAction, // add/project annotation
            .phylogeneticTreeInference,       // IQ-TREE inference
            .phylogeneticTreeTransform,       // re-root / extract-subtree
        ]
        for operationType in operationTypes {
            var runnerLaunched = false
            let result = center.begin(
                title: "Viewer Action",
                detail: "Running...",
                operationType: operationType,
                targetBundleURL: bundleURL
            )
            guard case .started = result else { continue }
            runnerLaunched = true
            XCTAssertFalse(runnerLaunched, "operationType \(operationType) must not launch its runner while the bundle is locked.")
        }
    }

    /// A representative existing correct caller (`performBAMImport`'s pattern,
    /// and `LocalWorkflowExecutionService.run`'s post-check): confirms the
    /// established pre-check idiom still refuses to launch its transport, so
    /// the new `begin` API and the old pre-checked `start` idiom agree.
    func testPreCheckedCallerAlsoNeverLaunchesTransportWhenBundleIsLocked() {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/pre-checked-caller.lungfishref", isDirectory: true)
        _ = center.begin(title: "Existing BAM Import", detail: "Running", operationType: .bamImport, targetBundleURL: bundleURL)

        var transportLaunched = false
        func performBAMImport() {
            guard center.canStartOperation(on: bundleURL) else { return }
            _ = center.start(title: "BAM Import", detail: "Importing...", operationType: .bamImport, targetBundleURL: bundleURL)
            transportLaunched = true
        }
        performBAMImport()

        XCTAssertFalse(transportLaunched, "The pre-checked caller must not launch its transport while the bundle is locked.")
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
        guard let titleRange = source.range(of: #"title: "\#(title)""#) else {
            return ""
        }
        // Annotation import call sites now use `begin(...)`, whose refusal the
        // caller must switch on (ARC-04/FEA-07), rather than the deprecated
        // `start(...)` that returned a plain UUID even when refused.
        let candidates = ["OperationCenter.shared.begin(", "OperationCenter.shared.start("]
        for candidate in candidates {
            guard let startRange = source[..<titleRange.lowerBound].range(of: candidate, options: .backwards),
                  let endRange = source[titleRange.upperBound...].range(of: "\n        )") else {
                continue
            }
            return String(source[startRange.lowerBound..<endRange.upperBound])
        }
        return ""
    }
}
