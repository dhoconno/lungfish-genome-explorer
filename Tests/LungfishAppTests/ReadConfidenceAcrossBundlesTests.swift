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
//
// The fix round (BIO SF2, 2026-11-06) widens the same rule to every filter that reaches depth and read counts. The consensus
// quality limits, the duplicate, secondary and supplementary toggles and the read group filter start at their defaults when a
// different bundle opens, and the same bundle keeps them. `testTheOtherDepthFiltersReadTheDefaultOnTheNextBundleThatOpens` pins it.

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

    /// The block's own rule, without a window. The same bundle keeps the value across the clear that every selection makes. A
    /// different bundle starts at the default, and so does a return to the first bundle after a second one. Classifier evidence
    /// starts at the default and leaves no bundle behind. The consensus confidence and the read group filter follow the same rule
    /// (BIO SF2), and the same bundle keeps them as REFMAP's rule keeps a read group filter.
    func testTheBlockResetsOnlyWhenADifferentBundleLoads() {
        let viewModel = ReadStyleSectionViewModel()
        let first = root.appendingPathComponent("first.lungfishref", isDirectory: true)
        let second = root.appendingPathComponent("second.lungfishref", isDirectory: true)

        viewModel.resetConfidenceUnlessSameBundle(at: first)
        viewModel.minMapQ = 30
        viewModel.consensusMinMapQ = 30
        viewModel.selectedReadGroups = ["S1-rg"]
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 30, "the same bundle lost its confidence")
        XCTAssertEqual(viewModel.consensusMinMapQ, 30, "the same bundle lost its consensus confidence")
        XCTAssertEqual(viewModel.selectedReadGroups, ["S1-rg"], "the same bundle lost its read group filter")

        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: second)
        XCTAssertEqual(viewModel.minMapQ, 0, "a different bundle kept the confidence")
        XCTAssertEqual(viewModel.consensusMinMapQ, 0, "a different bundle kept the consensus confidence")
        XCTAssertTrue(viewModel.selectedReadGroups.isEmpty, "a different bundle kept the read group filter")

        viewModel.minMapQ = 20
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 0, "a return to the first bundle kept the second bundle's confidence")

        viewModel.minMapQ = 10
        viewModel.consensusMinBaseQ = 20
        viewModel.resetConfidenceForClassifierEvidence()
        XCTAssertEqual(viewModel.minMapQ, 0, "classifier evidence kept a bundle's confidence")
        XCTAssertEqual(viewModel.consensusMinBaseQ, 0, "classifier evidence kept a bundle's consensus base quality")
        viewModel.minMapQ = 5
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 0, "a bundle kept the confidence set on classifier evidence")
    }

    /// A confidence kept across a detour to an item that opens no reference bundle must reach the viewport that reopens the bundle.
    /// The bundle is still the last one the block loaded, so the Inspector keeps the value, and the reads and depth must be under it.
    func testAConfidenceSurvivesADetourToAnotherItemAndTheViewportAgrees() async throws {
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
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the viewport")

        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Quick Look" })
        let detourRow = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let detourRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("detour", isDirectory: true))
        let detour = try await detourRow.build(RoutingRowContext(root: detourRoot, paths: SafetyNetPathRenderer(root: detourRoot)))
        harness.select(detour.item)
        await harness.split.bundleOpenTask?.value
        harness.select(rows.first.item)
        await harness.split.bundleOpenTask?.value
        let reopened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) == firstURL && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(reopened, "the first reference never reopened after the detour")

        XCTAssertEqual(readStyle.minMapQ, 30, "the detour took the confidence away from the Inspector")
        XCTAssertEqual(
            viewportConfidence(viewer), 30,
            "the reopened bundle's reads and depth are not under the confidence the Inspector shows"
        )
    }

    /// The other filters that reach depth and read counts go back to their defaults with the confidence when a different bundle
    /// opens, in the Inspector and in the viewport that depth and the reads come from.
    func testTheOtherDepthFiltersReadTheDefaultOnTheNextBundleThatOpens() async throws {
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

        readStyle.consensusMinMapQ = 30
        readStyle.consensusMinBaseQ = 20
        readStyle.showDuplicates = true
        readStyle.showSecondary = true
        readStyle.showSupplementary = true
        readStyle.selectedReadGroups = ["S1-rg"]
        readStyle.onSettingsChanged?()
        let firstView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(firstView.consensusMinMapQSetting, 30, "the Inspector's consensus confidence never reached the first viewport")
        XCTAssertEqual(firstView.selectedReadGroupsSetting, ["S1-rg"], "the Inspector's read group filter never reached the first viewport")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        let fresh = ReadStyleSectionViewModel()
        XCTAssertEqual(readStyle.consensusMinMapQ, fresh.consensusMinMapQ, "the Inspector shows the first bundle's consensus confidence")
        XCTAssertEqual(readStyle.consensusMinBaseQ, fresh.consensusMinBaseQ, "the Inspector shows the first bundle's consensus base quality")
        XCTAssertEqual(readStyle.showDuplicates, fresh.showDuplicates, "the Inspector includes duplicates on the second bundle")
        XCTAssertEqual(readStyle.showSecondary, fresh.showSecondary, "the Inspector includes secondary alignments on the second bundle")
        XCTAssertEqual(readStyle.showSupplementary, fresh.showSupplementary, "the Inspector includes supplementary alignments on the second bundle")
        XCTAssertEqual(readStyle.selectedReadGroups, fresh.selectedReadGroups, "the Inspector keeps the first bundle's read group filter")

        let secondView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(secondView.consensusMinMapQSetting, 0, "the second bundle's depth is filtered by the first bundle's consensus confidence")
        XCTAssertEqual(secondView.consensusMinBaseQSetting, 0, "the second bundle's depth is filtered by the first bundle's base quality")
        XCTAssertEqual(secondView.excludeFlagsSetting, fresh.computedExcludeFlags, "the second bundle's reads are filtered by the first bundle's flags")
        XCTAssertTrue(secondView.selectedReadGroupsSetting.isEmpty, "the second bundle's reads are filtered by the first bundle's read groups")
    }

    /// The reset reaches the viewport while the Inspector is hidden. The slider's change handler lives in the Inspector's own view,
    /// so if that view were what carried the reset, a hidden Inspector would read 0 when it returned while the reads stayed at 30.
    func testTheResetReachesTheViewportWhileTheInspectorIsHidden() async throws {
        // Collapsing the window's Inspector saves its state to the runner's defaults, so these keys go back as they were.
        let panelDefaults = HostDefaultsRestorer(keys: [
            MainSplitViewController.sidebarCollapsedDefaultsKey, MainSplitViewController.inspectorCollapsedDefaultsKey,
            MainSplitViewController.sidebarWidthDefaultsKey, MainSplitViewController.inspectorWidthDefaultsKey,
        ])
        defer { panelDefaults.restore() }
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

        harness.split.setInspectorVisible(false, animated: false, source: "ReadConfidenceAcrossBundlesTests")
        XCTAssertFalse(harness.split.isInspectorVisible, "the window's Inspector did not collapse")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        XCTAssertEqual(readStyle.minMapQ, 0, "the Inspector keeps the first bundle's confidence on the second bundle")
        XCTAssertEqual(
            viewportConfidence(viewer), 0,
            "the second bundle's reads and depth stay under the first bundle's confidence while the Inspector is hidden"
        )
    }
}
