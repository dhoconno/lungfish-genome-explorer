// ReadConfidenceAcrossBundlesTests.swift - A Minimum alignment confidence belongs to the bundle it was set on (Phase 3.2 lane S3BESIDE, ALIGN-CONFIDENCE-CARRY)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// W-27 of the 3.2 session 1 walk. A confidence of 30 set on one reference stayed 30 on the next bundle that opened, because
// `ReadStyleSectionViewModel.clear()` did not reset `minMapQ`, and the open pushes the block's value to the viewport. Depth and
// the pale reads changed and only the Inspector showed the filter. Both tests go through the sidebar and the Inspector's block,
// the only production writer of the viewport's filter, as `ReferenceBundleReadFilterSameRowTests` does. No store keeps the
// value per bundle (`rg minMapQ Sources` finds the block, the notification and the viewer), so the row is a reset.
//
// The manager ruled on the first agent's open question (option b, 2026-11-06). The confidence resets only when a different bundle
// opens, and selecting the same reference row again keeps the value the person set, as REFMAP's rule keeps a read group filter
// (`ReferenceBundleReadFilterSameRowTests`). `testAConfidenceStaysWhenTheSameRowIsSelectedAgain` pins that case. A reset inside
// `ReadStyleSectionViewModel.clear()` fails it, because the Inspector clears the block on every selection, the same row included.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class ReadConfidenceAcrossBundlesTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ReadConfidenceAcrossBundles")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    /// Two reference rows of the window's sidebar, each built in a folder of its own, so each is a bundle of its own.
    private func twoReferenceRows() async throws -> (first: RoutingRowFixture, second: RoutingRowFixture) {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Reference" })
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let firstRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("first", isDirectory: true))
        let secondRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("second", isDirectory: true))
        let first = try await row.build(RoutingRowContext(root: firstRoot, paths: SafetyNetPathRenderer(root: firstRoot)))
        let second = try await row.build(RoutingRowContext(root: secondRoot, paths: SafetyNetPathRenderer(root: secondRoot)))
        return (first, second)
    }

    private func openedBundleURL(_ viewer: ViewerViewController) -> URL? {
        viewer.referenceBundleViewportController?.testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
    }

    private func viewportConfidence(_ viewer: ViewerViewController) -> Int? {
        viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView.minMapQSetting
    }

    /// What a person does: set the confidence on one reference, then select another reference.
    func testAConfidenceSetOnOneBundleReadsTheDefaultOnTheNextBundleThatOpens() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let firstOpened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(firstOpened, "the first reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the first bundle's viewport")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        XCTAssertEqual(readStyle.minMapQ, 0, "the Inspector shows the first bundle's confidence on the second bundle")
        XCTAssertEqual(viewportConfidence(viewer), 0, "the second bundle's reads and depth are filtered by the first bundle's confidence")
    }

    /// A value set on a bundle stays while that bundle stays open, in focus mode and under a later push of the block's settings.
    func testAConfidenceStaysWhileTheSameBundleStaysOpen() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let opened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        viewport.testEnterFocusedDetailMode()
        XCTAssertEqual(viewportConfidence(viewer), 30, "focus mode took the confidence away")
        XCTAssertEqual(readStyle.minMapQ, 30, "focus mode took the confidence out of the Inspector")

        readStyle.onSettingsChanged?()
        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "a later push rebuilt the viewport")
        XCTAssertEqual(viewportConfidence(viewer), 30, "a later push took the confidence away")
        XCTAssertEqual(readStyle.minMapQ, 30, "the Inspector no longer shows the confidence the reads are under")
    }

    /// REFMAP's rule for the confidence: a value set in the Inspector stays when the same reference row is selected again.
    func testAConfidenceStaysWhenTheSameRowIsSelectedAgain() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let opened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the viewport")

        harness.select(rows.first.item)
        await harness.split.bundleOpenTask?.value

        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "the same input rebuilt the viewport")
        XCTAssertEqual(readStyle.minMapQ, 30, "the same row took the confidence away from the Inspector")
        XCTAssertEqual(viewportConfidence(viewer), 30, "the same row took the confidence away from the reads and depth")
    }
}
