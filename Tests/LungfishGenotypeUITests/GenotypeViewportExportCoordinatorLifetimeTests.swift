// GenotypeViewportExportCoordinatorLifetimeTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The lifetime contract of GenotypeViewportExportCoordinator (Phase 2.3 lane
// L4b, REVIEW.md R6). The controller is the coordinator's only owner and the
// coordinator reads the controller through an unowned reference, so every
// escaping closure on the export path captures the coordinator weakly. When
// the controller is released while a save panel or an export task is still
// outstanding, the closure must find a nil coordinator and stop, with no
// runner call past that point, no export event and no read of the freed
// controller. Both tests are windowless and build their result in memory.

import AppKit
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// Records what the export path hands its seams.
@MainActor
private final class LifetimeRecorder {
    var events: [String] = []
    var runnerCalls = 0
    var runnerReturned = false
    var savePanelCompletion: ((URL?) -> Void)?

    func record(_ event: GenotypeExcelExportEvent) {
        switch event {
        case .started: events.append("started")
        case .succeeded: events.append("succeeded")
        case .failed(let message): events.append("failed " + message)
        }
    }
}

/// Holds the runner on a continuation until the test releases it, so the
/// controller can be dropped while the export task is in flight.
@MainActor
private final class RunnerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class GenotypeViewportExportCoordinatorLifetimeTests: GenotypeResultViewportTestCase {
    /// A configured windowless controller over `root` with the recorder's
    /// event sink installed. The caller installs the panel and runner seams.
    private func makeConfiguredController(root: URL, recorder: LifetimeRecorder) -> GenotypeResultViewController {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9),
        ]))
        controller.onExcelExportEvent = { recorder.record($0) }
        return controller
    }

    /// The save panel outlives the controller. Its completion must find a nil
    /// coordinator and return before the runner, the events or the controller.
    func testSavePanelCompletionAfterControllerReleaseExportsNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "ExportCoordinatorLifetimePanel")
        defer { TestTempDirectory.cleanup(root) }
        let recorder = LifetimeRecorder()
        weak var weakController: GenotypeResultViewController?

        autoreleasepool {
            let controller = makeConfiguredController(root: root, recorder: recorder)
            weakController = controller
            controller.excelSavePanelPresenter = { _, _, completion in recorder.savePanelCompletion = completion }
            controller.viewportExportRunner = { _, _, _ in
                await MainActor.run { recorder.runnerCalls += 1 }
            }
            controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        }

        let completion = try XCTUnwrap(recorder.savePanelCompletion, "The panel must be up before the controller goes away")
        XCTAssertEqual(recorder.events, [])
        await waitUntil(timeout: .seconds(1)) { weakController == nil }
        XCTAssertNil(weakController, "The controller must be released while its save panel is still up")

        completion(root.appendingPathComponent("late.xlsx"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.runnerCalls, 0, "A completion that outlives the controller must not run the export")
        XCTAssertEqual(recorder.events, [], "A completion that outlives the controller must publish nothing")
    }

    /// The export task outlives the controller. The runner finishes, and the
    /// task's completion must find a nil coordinator and publish nothing.
    func testExportTaskFinishingAfterControllerReleasePublishesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "ExportCoordinatorLifetimeTask")
        defer { TestTempDirectory.cleanup(root) }
        let recorder = LifetimeRecorder()
        let gate = RunnerGate()
        defer { gate.release() }
        weak var weakController: GenotypeResultViewController?

        autoreleasepool {
            let controller = makeConfiguredController(root: root, recorder: recorder)
            weakController = controller
            controller.excelSavePanelPresenter = { _, _, completion in
                completion(root.appendingPathComponent("late.xlsx"))
            }
            controller.viewportExportRunner = { _, _, _ in
                await MainActor.run { recorder.runnerCalls += 1 }
                await gate.wait()
                await MainActor.run { recorder.runnerReturned = true }
            }
            controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        }

        XCTAssertEqual(recorder.events, ["started"], "The started event is published before the export task begins")
        await waitUntil(timeout: .seconds(1)) { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting, "The runner must be in flight before the controller goes away")
        XCTAssertEqual(recorder.runnerCalls, 1)
        await waitUntil(timeout: .seconds(1)) { weakController == nil }
        XCTAssertNil(weakController, "The controller must be released while the export task is suspended")

        gate.release()
        await waitUntil(timeout: .seconds(1)) { recorder.runnerReturned }
        XCTAssertTrue(recorder.runnerReturned, "The suspended runner must finish once the gate opens")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.events, ["started"], "No succeeded or failed event may follow once the controller is gone")
    }
}
